import CoreText
import Foundation
import XCTest

import NagiEngineCore
import NagiEngineCoreText

// MARK: - Fixtures
//
// These tests assert **relations and invariants**, never exact break positions
// or absolute metrics: a system font can be updated under them, and pinning a
// font is the business of a later golden / determinism gate, not of this file.

private func systemFont(_ name: String, size: CGFloat = 16) -> CTFont {
    CTFontCreateWithName(name as CFString, size, nil)
}

private let latinFont = systemFont("Helvetica")
private let cjkFont = systemFont("PingFang SC")

private func segment(_ string: String, unit: String = "u") -> PrimaryTextSegment {
    PrimaryTextSegment(unitID: DocumentUnitID(rawValue: unit), string: string)
}

private let asciiParagraph = """
The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor \
jugs. How vexingly quick daft zebras jump.
"""

private let newlineCorpus = """
first line
second line
third line
fourth line
"""

/// CJK plus non-BMP scalars, so a break that lands inside a surrogate pair has
/// somewhere to happen.
private let mixedCorpus = """
韩立望着眼前的山谷沉默了片刻，山谷之中云雾缭绕，隐约可以听见流水的声音。\
记号 𠀋 与 𝕏𝕐𝕫 之后，他缓缓向前走去，心里盘算着接下来的路。走了大约三百步之后，他停下了。
"""

/// A cap on every loop that follows a session, so a backend that stops
/// advancing fails the test instead of hanging it.
private let stepLimit = 10_000

private func backend(
    _ font: CTFont = latinFont,
    languageTag: String? = nil
) -> CoreTextLineBreakBackend {
    CoreTextLineBreakBackend(font: font, languageTag: languageTag)
}

private func constraints(
    inlineExtent: Double,
    blockExtent: Double,
    lineSpacing: Double = 0
) -> TextPaginationConstraints {
    TextPaginationConstraints(
        inlineExtent: inlineExtent,
        blockExtent: blockExtent,
        lineSpacing: lineSpacing
    )
}

/// Walks a session to the end and returns how many lines it produced.
private func lineCount(
    of segment: PrimaryTextSegment,
    backend: CoreTextLineBreakBackend,
    inlineExtent: Double
) throws -> Int {
    let session = try backend.makeSession(for: segment)
    var offset = 0
    var count = 0

    while offset < segment.utf16Count {
        guard count < stepLimit else {
            XCTFail("the session stopped advancing at \(offset)")
            return count
        }
        guard let measurement = try session.suggestLine(
            fromUTF16Offset: offset,
            inlineExtent: inlineExtent
        ) else {
            XCTFail("the session stalled at \(offset)")
            return count
        }
        offset = measurement.consumedUTF16Range.upperBound
        count += 1
    }

    return count
}

// MARK: - Tests

final class CoreTextLineBreakBackendTests: XCTestCase {

    // MARK: - A session's own answers

    func testASessionAdvancingFromTheStartGivesAWellFormedMeasurement() throws {
        let made = segment(asciiParagraph)
        let session = try backend().makeSession(for: made)

        let measurement = try XCTUnwrap(
            session.suggestLine(fromUTF16Offset: 0, inlineExtent: 200)
        )
        let range = measurement.consumedUTF16Range

        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertGreaterThan(range.upperBound, range.lowerBound)
        XCTAssertLessThanOrEqual(range.upperBound, made.utf16Count)
        XCTAssertTrue(made.isStorageBoundary(at: range.lowerBound))
        XCTAssertTrue(made.isStorageBoundary(at: range.upperBound))
        XCTAssertTrue(measurement.naturalBlockExtent.isFinite)
        XCTAssertGreaterThan(measurement.naturalBlockExtent, 0)
    }

    func testANewlineCorpusIsConsumedInOrderWithoutGapsOrOverlaps() throws {
        let made = segment(newlineCorpus)
        let session = try backend().makeSession(for: made)

        var offset = 0
        var ranges: [Range<Int>] = []

        while offset < made.utf16Count {
            guard ranges.count < stepLimit else {
                XCTFail("the session stopped advancing at \(offset)")
                return
            }
            let measurement = try XCTUnwrap(
                session.suggestLine(fromUTF16Offset: offset, inlineExtent: 400)
            )
            ranges.append(measurement.consumedUTF16Range)
            offset = measurement.consumedUTF16Range.upperBound
        }

        XCTAssertGreaterThan(ranges.count, 1, "a four-line corpus is more than one line")
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, made.utf16Count)

        for (earlier, later) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(earlier.upperBound, later.lowerBound)
        }
    }

    // MARK: - What the paginator accepts from it

    /// Non-BMP scalars are in this corpus on purpose: a page endpoint inside a
    /// surrogate pair would be caught here rather than shipped.
    func testEveryPageEndpointIsAStorageBoundaryAndTheRangesCoverTheSegment() throws {
        let made = segment(mixedCorpus)
        let result = try TextPaginator.paginate(
            segment: made,
            constraints: constraints(inlineExtent: 60, blockExtent: 40),
            backend: backend(cjkFont)
        )

        XCTAssertFalse(result.utf16Ranges.isEmpty)

        var expected = 0
        for range in result.utf16Ranges {
            XCTAssertEqual(range.lowerBound, expected)
            XCTAssertGreaterThan(range.upperBound, range.lowerBound)
            XCTAssertTrue(made.isStorageBoundary(at: range.lowerBound))
            XCTAssertTrue(made.isStorageBoundary(at: range.upperBound))
            expected = range.upperBound
        }
        XCTAssertEqual(expected, made.utf16Count)
    }

    /// Narrower has to mean **more**, not "at least as many": with `>=` a
    /// backend that ignored the extent entirely would still pass.
    func testANarrowerExtentProducesStrictlyMoreLinesAndPages() throws {
        let made = segment(mixedCorpus)

        let narrowLines = try lineCount(of: made, backend: backend(cjkFont), inlineExtent: 40)
        let wideLines = try lineCount(of: made, backend: backend(cjkFont), inlineExtent: 4000)
        XCTAssertGreaterThan(narrowLines, wideLines)

        // A block extent of 1 puts every line on a page of its own — no line is
        // that short — so the page counts inherit the same strict relation.
        let narrowPages = try TextPaginator.paginate(
            segment: made,
            constraints: constraints(inlineExtent: 40, blockExtent: 1),
            backend: backend(cjkFont)
        ).utf16Ranges.count
        let widePages = try TextPaginator.paginate(
            segment: made,
            constraints: constraints(inlineExtent: 4000, blockExtent: 1),
            backend: backend(cjkFont)
        ).utf16Ranges.count

        XCTAssertGreaterThan(narrowPages, widePages)
    }

    func testTheSameInputProducesTheSameRanges() throws {
        let made = segment(mixedCorpus)
        let settings = constraints(inlineExtent: 80, blockExtent: 60)

        let first = try TextPaginator.paginate(
            segment: made,
            constraints: settings,
            backend: backend(cjkFont)
        ).utf16Ranges
        let second = try TextPaginator.paginate(
            segment: made,
            constraints: settings,
            backend: backend(cjkFont)
        ).utf16Ranges

        XCTAssertEqual(first, second)
    }

    func testRealPaginationCoversAtLeastTwoPages() throws {
        let made = segment(mixedCorpus)
        let result = try TextPaginator.paginate(
            segment: made,
            constraints: constraints(inlineExtent: 80, blockExtent: 40),
            backend: backend(cjkFont)
        )

        XCTAssertGreaterThanOrEqual(result.utf16Ranges.count, 2)
        XCTAssertEqual(result.unitID, made.unitID)
    }

    // MARK: - What a directly-called session refuses

    func testASessionRefusesBadInputsWithNamedErrors() throws {
        let made = segment(asciiParagraph)
        let session = try backend().makeSession(for: made)

        for bad in [0.0, -1.0, .nan, .infinity] {
            XCTAssertThrowsError(
                try session.suggestLine(fromUTF16Offset: 0, inlineExtent: bad),
                "expected \(bad) to be refused"
            ) { thrown in
                XCTAssertEqual(
                    thrown as? CoreTextLineBreakError,
                    CoreTextLineBreakError.invalidInlineExtent
                )
            }
        }

        for bad in [-1, Int.max] {
            XCTAssertThrowsError(
                try session.suggestLine(fromUTF16Offset: bad, inlineExtent: 100),
                "expected offset \(bad) to be refused"
            ) { thrown in
                XCTAssertEqual(
                    thrown as? CoreTextLineBreakError,
                    CoreTextLineBreakError.utf16OffsetOutOfBounds(bad)
                )
            }
        }
    }

    /// Landing exactly on the end is not an out-of-range offset; it is the
    /// session saying there is nothing left.
    func testAskingAtTheEndGivesNilRatherThanAnError() throws {
        let made = segment(asciiParagraph)
        let session = try backend().makeSession(for: made)

        XCTAssertNil(
            try session.suggestLine(fromUTF16Offset: made.utf16Count, inlineExtent: 100)
        )
    }

    func testAskingAnEmptySegmentAtZeroGivesNil() throws {
        let made = segment("")
        let session = try backend().makeSession(for: made)

        XCTAssertNil(try session.suggestLine(fromUTF16Offset: 0, inlineExtent: 100))
    }

    // MARK: - The language tag

    /// Both construction paths have to carry a segment the whole way. The tag is
    /// not expected to move a break — the evidence repository measured no
    /// difference within its own corpus — so nothing here asserts that it does.
    func testBothLanguageTagPathsCoverTheWholeSegment() throws {
        let made = segment(mixedCorpus)

        let tags: [String?] = [nil, "ja"]

        for tag in tags {
            let result = try TextPaginator.paginate(
                segment: made,
                constraints: constraints(inlineExtent: 80, blockExtent: 40),
                backend: backend(cjkFont, languageTag: tag)
            )

            XCTAssertGreaterThan(result.utf16Ranges.count, 1, "tag: \(String(describing: tag))")
            XCTAssertEqual(result.utf16Ranges.last?.upperBound, made.utf16Count)
        }
    }
}
