import CoreGraphics
import CoreText
import Foundation
import XCTest

@testable import NagiEngineCore
@testable import NagiEngineCoreText

// MARK: - Fixtures
//
// The same discipline as the line-breaking file: these tests assert **relations
// and invariants**, never exact break positions, absolute metrics or pixel
// goldens. A system font can be updated under them, and pinning one is the
// business of a later golden / determinism gate. Nothing here copies a font
// measurement into the file as a constant either — where a coordinate or a
// bound is needed, it is derived, from CoreText or from the scene's own line
// artifacts, at the moment it is used.

private func systemFont(_ name: String, size: CGFloat = 16) -> CTFont {
    CTFontCreateWithName(name as CFString, size, nil)
}

private let latinFont = systemFont("Helvetica")
private let cjkFont = systemFont("PingFang SC")

private func segment(_ string: String, unit: String = "u") -> PrimaryTextSegment {
    PrimaryTextSegment(unitID: DocumentUnitID(rawValue: unit), string: string)
}

private let node = NodeID(rawValue: "txt-node")
private let otherNode = NodeID(rawValue: "txt-node-other")

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

/// Combining marks sit on ordinary storage boundaries. This corpus is here to
/// show that no caret policy of our own is invented here, not to claim cluster
/// semantics.
private let combiningCorpus = "cafe\u{0301} nai\u{0308}ve re\u{0301}sume\u{0301} e\u{0301}tude"

/// A cap on loops that walk a session, so a session that stops advancing fails
/// the test instead of hanging it.
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

/// A copy of an artifact with one field replaced, so a test can build a line the
/// validator has to refuse.
private func artifact(
    like original: CoreTextLineArtifact,
    measurement: LineMeasurement? = nil,
    naturalBlockExtent: Double? = nil,
    line: CTLine? = nil,
    typographicWidth: CGFloat? = nil
) -> CoreTextLineArtifact {
    var resolved = measurement ?? original.measurement
    if let naturalBlockExtent {
        resolved = LineMeasurement(
            consumedUTF16Range: resolved.consumedUTF16Range,
            naturalBlockExtent: naturalBlockExtent
        )
    }
    return CoreTextLineArtifact(
        measurement: resolved,
        line: line ?? original.line,
        ascent: original.ascent,
        descent: original.descent,
        leading: original.leading,
        typographicWidth: typographicWidth ?? original.typographicWidth
    )
}

/// Every number a foreground colour must not be able to move.
private func metrics(of scene: CoreTextPlainTextPageScene) -> [CGFloat] {
    scene.lines.flatMap { line in
        [
            line.top,
            line.baseline,
            line.artifact.ascent,
            line.artifact.descent,
            line.artifact.leading,
            line.artifact.typographicWidth,
            CGFloat(line.artifact.measurement.naturalBlockExtent)
        ]
    }
}

// MARK: - A bitmap in the page's own space

/// A transparent bitmap whose user space is the page's: origin at the page's
/// top-left corner, x growing right and y growing down. `inset` leaves a margin
/// of untouched pixels around the page, which is where a test can paint and read
/// back state that is outside the scene's own clip.
///
/// The byte order is stated rather than left to the platform, so the channel
/// offsets a test reads are the ones it thinks it is reading.
private func pageContext(size: CGSize, inset: Int = 0) throws -> CGContext {
    let width = Int(size.width.rounded()) + 2 * inset
    let height = Int(size.height.rounded()) + 2 * inset
    let context = try XCTUnwrap(
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        )
    )
    context.translateBy(x: CGFloat(inset), y: CGFloat(height - inset))
    context.scaleBy(x: 1, y: -1)
    return context
}

/// Deliberately **not** `Equatable`. Coverage counts are not comparable across
/// two passes in different colours: CoreGraphics' text smoothing makes
/// antialiased coverage depend on the colour, so an equal-count assertion would
/// assert something that is not true of the platform. What two passes of one
/// page must share is its geometry and its metrics, and those are checked
/// directly, field by field.
private struct Coverage {
    /// Pixels carrying any alpha at all.
    let count: Int

    /// Where those pixels are, in the bitmap's own buffer coordinates.
    let box: CGRect

    /// Pixels whose red channel is the largest of the three.
    let redDominant: Int

    /// Pixels whose green channel is the largest of the three.
    let greenDominant: Int

    /// Pixels whose blue channel is the largest of the three.
    let blueDominant: Int
}

private func deviceRed() throws -> CGColor {
    try XCTUnwrap(
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1, 0, 0, 1])
    )
}

private func deviceGreen() throws -> CGColor {
    try XCTUnwrap(
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 1, 0, 1])
    )
}

private func deviceBlue() throws -> CGColor {
    try XCTUnwrap(
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 1, 1])
    )
}

/// What the context actually painted.
///
/// `columns` narrows the scan to a band of columns, which is how "nothing was
/// painted in this region" is checked without reading a pixel golden.
private func painted(
    in context: CGContext,
    width: Int,
    height: Int,
    columns: Range<Int>? = nil
) throws -> Coverage {
    let raw = try XCTUnwrap(context.data)
    let bytes = raw.bindMemory(to: UInt8.self, capacity: height * context.bytesPerRow)
    let scanned = columns ?? 0..<width

    var count = 0
    var red = 0
    var green = 0
    var blue = 0
    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1

    for y in 0..<height {
        let row = y * context.bytesPerRow
        for x in scanned {
            // premultipliedLast with byteOrder32Big is R, G, B, A.
            let offset = row + x * 4
            let r = bytes[offset]
            let g = bytes[offset + 1]
            let b = bytes[offset + 2]
            let a = bytes[offset + 3]

            guard a > 0 else { continue }
            count += 1
            if r > g, r > b { red += 1 }
            if g > r, g > b { green += 1 }
            if b > r, b > g { blue += 1 }

            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
    }

    let box = maxX < 0
        ? CGRect.null
        : CGRect(
            x: CGFloat(minX),
            y: CGFloat(minY),
            width: CGFloat(maxX - minX + 1),
            height: CGFloat(maxY - minY + 1)
        )

    return Coverage(
        count: count,
        box: box,
        redDominant: red,
        greenDominant: green,
        blueDominant: blue
    )
}

private func painted(
    by scene: CoreTextPlainTextPageScene,
    colour: CGColor,
    inset: Int = 0
) throws -> Coverage {
    let context = try pageContext(size: scene.size, inset: inset)
    scene.draw(in: context, foregroundColor: colour)
    return try painted(
        in: context,
        width: Int(scene.size.width.rounded()) + 2 * inset,
        height: Int(scene.size.height.rounded()) + 2 * inset
    )
}

/// The buffer rows a mark at the page's top-left corner lands in.
///
/// This is how the bitmap's row order is **measured** instead of assumed: the
/// same construction as the real context, a mark whose page coordinates are
/// known, and the rows it turned up in. The drawing test compares a line's first
/// ink against this, so "the text hangs from the top" is proved rather than
/// asserted.
private func topEdgeRows(
    size: CGSize,
    inset: Int,
    mark: CGFloat = 4
) throws -> Range<Int> {
    let context = try pageContext(size: size, inset: inset)
    context.setFillColor(try deviceGreen())
    context.fill(CGRect(x: 0, y: 0, width: mark, height: mark))

    let coverage = try painted(
        in: context,
        width: Int(size.width.rounded()) + 2 * inset,
        height: Int(size.height.rounded()) + 2 * inset
    )
    guard coverage.count > 0 else { return 0..<0 }
    return Int(coverage.box.minY)..<(Int(coverage.box.maxY) + 1)
}

// MARK: - Tests

final class CoreTextPlainTextPageSceneTests: XCTestCase {

    // MARK: - What the recording backend is for

    /// The recording backend has to change nothing: the core sees the same
    /// backend it always did, and asks for exactly one session.
    func testARecordingBackendMakesExactlyOneSessionAndMatchesThePlainPath() throws {
        let made = segment(mixedCorpus)
        let settings = constraints(inlineExtent: 80, blockExtent: 40)

        let plain = try TextPaginator.paginate(
            segment: made,
            constraints: settings,
            backend: backend(cjkFont)
        )

        let recorder = CoreTextRecordingBackend(backend: backend(cjkFont))
        let recorded = try TextPaginator.paginate(
            segment: made,
            constraints: settings,
            backend: recorder
        )

        XCTAssertEqual(recorded, plain)
        XCTAssertEqual(recorder.makeSessionCallCount, 1)
        XCTAssertNotNil(recorder.session)
    }

    /// An empty segment returns before the core ever asks for a session, so the
    /// count stays at zero and there is nothing to draw.
    func testAnEmptySegmentHasNoPagesAndNeverAsksForASession() throws {
        let empty = segment("")
        let settings = constraints(inlineExtent: 80, blockExtent: 40)

        let recorder = CoreTextRecordingBackend(backend: backend())
        let ranges = try TextPaginator.paginate(
            segment: empty,
            constraints: settings,
            backend: recorder
        )

        XCTAssertEqual(recorder.makeSessionCallCount, 0)
        XCTAssertNil(recorder.session)
        XCTAssertTrue(ranges.utf16Ranges.isEmpty)

        let paginated = try backend().makePaginatedPlainText(
            segment: empty,
            nodeID: node,
            constraints: settings
        )
        XCTAssertEqual(paginated.pageCount, 0)
        XCTAssertNil(paginated.scene(at: 0))
        XCTAssertNil(paginated.scene(at: -1))
    }

    /// The two shapes a call may have, and the combinations that are not a
    /// legitimate empty result. No real run produces the bad ones, which is
    /// exactly why they are handed to the invariant directly.
    func testThePaginationInvariantRefusesEveryOtherCallShape() throws {
        let empty = segment("")
        let made = segment(asciiParagraph)
        let ranges = try TextPaginator.paginate(
            segment: made,
            constraints: constraints(inlineExtent: 120, blockExtent: 40),
            backend: backend()
        )
        let emptyRanges = UnitPageRanges(unitID: empty.unitID, utf16Ranges: [])
        let otherUnit = UnitPageRanges(
            unitID: DocumentUnitID(rawValue: "other"),
            utf16Ranges: ranges.utf16Ranges
        )

        func check(
            _ made: PrimaryTextSegment,
            calls: Int,
            session: Bool,
            pages: UnitPageRanges,
            _ expected: CoreTextPageSceneError,
            _ label: String
        ) {
            XCTAssertThrowsError(
                try CoreTextPaginationInvariant.validate(
                    segment: made,
                    makeSessionCallCount: calls,
                    madeASession: session,
                    pageRanges: pages
                ),
                label
            ) { thrown in
                XCTAssertEqual(thrown as? CoreTextPageSceneError, expected, label)
            }
        }

        // The two shapes that are allowed.
        XCTAssertNoThrow(
            try CoreTextPaginationInvariant.validate(
                segment: empty,
                makeSessionCallCount: 0,
                madeASession: false,
                pageRanges: emptyRanges
            )
        )
        XCTAssertNoThrow(
            try CoreTextPaginationInvariant.validate(
                segment: made,
                makeSessionCallCount: 1,
                madeASession: true,
                pageRanges: ranges
            )
        )

        // An empty segment that built a session, or came back with pages.
        check(
            empty, calls: 1, session: true, pages: emptyRanges,
            .emptySegmentInconsistent(makeSessionCallCount: 1, madeASession: true, pageCount: 0),
            "an empty segment that built a session"
        )
        check(
            empty, calls: 0, session: false, pages: ranges,
            .emptySegmentInconsistent(
                makeSessionCallCount: 0,
                madeASession: false,
                pageCount: ranges.utf16Ranges.count
            ),
            "an empty segment that came back with pages"
        )

        // A non-empty segment without exactly one session.
        check(
            made, calls: 0, session: false, pages: ranges,
            .nonEmptySegmentInconsistent(makeSessionCallCount: 0, madeASession: false),
            "a non-empty segment with no session"
        )
        check(
            made, calls: 2, session: true, pages: ranges,
            .nonEmptySegmentInconsistent(makeSessionCallCount: 2, madeASession: true),
            "a non-empty segment with two sessions"
        )

        // Pages belonging to another unit.
        check(
            made, calls: 1, session: true, pages: otherUnit,
            .pageRangesUnitMismatch(
                expected: made.unitID,
                found: DocumentUnitID(rawValue: "other")
            ),
            "another unit's pages"
        )
    }

    // MARK: - The ranges-only path retains nothing

    /// `makeSession(for:)` on its own is the **ranges-only** path: it exists to
    /// feed `TextPaginator` line measurements, and nothing on it builds a page
    /// scene. A session created that way must therefore retain **no** lines —
    /// otherwise a long unit keeps every one of its `CTLine`s alive for as long
    /// as the session lives, purely because somebody paginated it.
    ///
    /// "Always" is the assertion, not "at the end": the check runs after every
    /// suggestion, so a session that starts retaining at any point fails here.
    ///
    /// The retention the page scene does need happens on the other path — a
    /// session driven by the recording backend — and is protected by
    /// `testBuildingScenesAsksTheSessionForNoFurtherLine`, which reads that
    /// session's artifacts and requires them to be more than one.
    func testTheRangesOnlyPathRetainsNoLines() throws {
        let made = segment(mixedCorpus)
        let settings = constraints(inlineExtent: 80, blockExtent: 40)

        let session = try backend(cjkFont).makeSession(for: made)
        XCTAssertTrue(session.artifacts.isEmpty, "a fresh session has retained nothing")

        var offset = 0
        var suggestions = 0

        while offset < made.utf16Count {
            guard suggestions < stepLimit else {
                XCTFail("the session stopped advancing at \(offset)")
                return
            }
            guard let measurement = try session.suggestLine(
                fromUTF16Offset: offset,
                inlineExtent: settings.inlineExtent
            ) else {
                XCTFail("the session stalled at \(offset)")
                return
            }

            offset = measurement.consumedUTF16Range.upperBound
            suggestions += 1

            XCTAssertTrue(
                session.artifacts.isEmpty,
                "a ranges-only session retained a line after suggestion \(suggestions)"
            )
        }

        XCTAssertGreaterThanOrEqual(
            suggestions,
            2,
            "the corpus has to need more than one line for this to say anything"
        )
    }

    // MARK: - The pages are the core's pages

    func testEverySceneCarriesExactlyTheRangeTheCoreDecided() throws {
        let made = segment(mixedCorpus)
        let settings = constraints(inlineExtent: 80, blockExtent: 40)

        let decided = try TextPaginator.paginate(
            segment: made,
            constraints: settings,
            backend: backend(cjkFont)
        )
        let paginated = try backend(cjkFont).makePaginatedPlainText(
            segment: made,
            nodeID: node,
            constraints: settings
        )

        XCTAssertEqual(paginated.pageRanges, decided)
        XCTAssertEqual(paginated.pageCount, decided.utf16Ranges.count)
        XCTAssertGreaterThan(paginated.pageCount, 1)

        for index in 0..<paginated.pageCount {
            let scene = try XCTUnwrap(paginated.scene(at: index))
            XCTAssertEqual(scene.utf16Range, decided.utf16Ranges[index])
            XCTAssertEqual(scene.pageIndex, index)
            XCTAssertEqual(scene.unitID, made.unitID)
            XCTAssertEqual(scene.nodeID, node)
            XCTAssertEqual(Double(scene.size.width), settings.inlineExtent)
            XCTAssertEqual(Double(scene.size.height), settings.blockExtent)
            XCTAssertGreaterThan(scene.lineCount, 0)
            XCTAssertEqual(scene.lineCount, scene.lines.count)
        }
    }

    func testSceneOutsideThePagesGivesNil() throws {
        let made = segment(asciiParagraph)
        let settings = constraints(inlineExtent: 120, blockExtent: 40)
        let paginated = try backend().makePaginatedPlainText(
            segment: made,
            nodeID: node,
            constraints: settings
        )

        XCTAssertGreaterThan(paginated.pageCount, 0)
        XCTAssertNil(paginated.scene(at: -1))
        XCTAssertNil(paginated.scene(at: paginated.pageCount))
        XCTAssertNil(paginated.scene(at: Int.max))
        XCTAssertNotNil(paginated.scene(at: paginated.pageCount - 1))
    }

    /// The constraints are still the core's to refuse, in the core's order — the
    /// recording backend takes no shortcut around them.
    func testInvalidConstraintsStillComeFromTheCore() throws {
        let made = segment(asciiParagraph)

        let cases: [(TextPaginationConstraints, TextPaginationError)] = [
            (constraints(inlineExtent: 0, blockExtent: 40), .invalidInlineExtent),
            (constraints(inlineExtent: .nan, blockExtent: 40), .invalidInlineExtent),
            (constraints(inlineExtent: 80, blockExtent: 0), .invalidBlockExtent),
            (constraints(inlineExtent: 80, blockExtent: 40, lineSpacing: -1), .invalidLineSpacing)
        ]

        for (settings, expected) in cases {
            XCTAssertThrowsError(
                try backend().makePaginatedPlainText(
                    segment: made,
                    nodeID: node,
                    constraints: settings
                )
            ) { thrown in
                XCTAssertEqual(thrown as? TextPaginationError, expected)
            }
        }

        // An empty segment is no exemption: the constraints are checked first.
        XCTAssertThrowsError(
            try backend().makePaginatedPlainText(
                segment: segment(""),
                nodeID: node,
                constraints: constraints(inlineExtent: 0, blockExtent: 40)
            )
        ) { thrown in
            XCTAssertEqual(thrown as? TextPaginationError, .invalidInlineExtent)
        }
    }

    // MARK: - Nothing is shaped twice

    /// Building the scenes must consume the lines the session already measured.
    /// If it asked for another line, the session's own count would move.
    func testBuildingScenesAsksTheSessionForNoFurtherLine() throws {
        let made = segment(mixedCorpus)
        let settings = constraints(inlineExtent: 80, blockExtent: 40)

        let recorder = CoreTextRecordingBackend(backend: backend(cjkFont))
        let ranges = try TextPaginator.paginate(
            segment: made,
            constraints: settings,
            backend: recorder
        )
        let session = try XCTUnwrap(recorder.session)
        let suggested = session.artifacts.count
        XCTAssertGreaterThan(suggested, 1)

        let scenes = try CoreTextPageSceneBuilder.buildScenes(
            artifacts: session.artifacts,
            pageRanges: ranges,
            segment: made,
            nodeID: node,
            constraints: settings
        )

        XCTAssertEqual(
            session.artifacts.count,
            suggested,
            "building a scene must not measure another line"
        )
        XCTAssertEqual(scenes.reduce(0) { $0 + $1.lineCount }, suggested)
        XCTAssertEqual(scenes.count, ranges.utf16Ranges.count)
    }

    // MARK: - What the builder refuses

    /// The ways the retained lines and the core's ranges can disagree. Each one
    /// would otherwise put geometry on an unverified number.
    func testTheBuilderRefusesEveryStructuralDefect() throws {
        let made = segment(newlineCorpus)
        let settings = constraints(inlineExtent: 160, blockExtent: 40)

        let recorder = CoreTextRecordingBackend(backend: backend())
        let ranges = try TextPaginator.paginate(
            segment: made,
            constraints: settings,
            backend: recorder
        )
        let artifacts = try XCTUnwrap(recorder.session).artifacts
        XCTAssertGreaterThanOrEqual(artifacts.count, 3, "the corpus has to break into several lines")

        func build(
            _ lines: [CoreTextLineArtifact],
            _ pages: UnitPageRanges
        ) throws -> [CoreTextPlainTextPageScene] {
            try CoreTextPageSceneBuilder.buildScenes(
                artifacts: lines,
                pageRanges: pages,
                segment: made,
                nodeID: node,
                constraints: settings
            )
        }

        func expect(
            _ lines: [CoreTextLineArtifact],
            _ pages: UnitPageRanges,
            _ expected: CoreTextPageSceneError,
            _ label: String
        ) {
            XCTAssertThrowsError(try build(lines, pages), label) { thrown in
                XCTAssertEqual(thrown as? CoreTextPageSceneError, expected, label)
            }
        }

        // Undisturbed, the two agree.
        XCTAssertEqual(try build(artifacts, ranges).count, ranges.utf16Ranges.count)

        let firstEnd = artifacts[0].measurement.consumedUTF16Range.upperBound
        let secondStart = artifacts[1].measurement.consumedUTF16Range.lowerBound

        // A line kept beside the wrong measurement.
        expect(
            [artifact(like: artifacts[0], line: artifacts[1].line)] + Array(artifacts.dropFirst()),
            ranges,
            .artifactStringRangeMismatch(atIndex: 0),
            "a line over a range that was not the accepted one"
        )

        // Numbers the geometry would have been built on.
        expect(
            [artifact(like: artifacts[0], typographicWidth: .nan)] + Array(artifacts.dropFirst()),
            ranges,
            .artifactMetricsNotFinite(atIndex: 0),
            "a width that is not a number"
        )

        expect(
            [artifact(like: artifacts[0], typographicWidth: -1)] + Array(artifacts.dropFirst()),
            ranges,
            .artifactWidthNegative(atIndex: 0),
            "a negative width"
        )

        // A natural extent that is not the sum the scene will advance by: two
        // truths about one page's height.
        expect(
            [artifact(
                like: artifacts[0],
                naturalBlockExtent: artifacts[0].measurement.naturalBlockExtent + 1
            )] + Array(artifacts.dropFirst()),
            ranges,
            .artifactNaturalExtentMismatch(atIndex: 0),
            "an extent that is not the sum of its parts"
        )

        // A missing line.
        var missing = artifacts
        missing.remove(at: 1)
        expect(
            missing,
            ranges,
            .artifactNotContiguous(
                atIndex: 1,
                expectedUTF16Offset: firstEnd,
                foundUTF16Offset: artifacts[2].measurement.consumedUTF16Range.lowerBound
            ),
            "a line that went missing"
        )

        // The same line twice.
        var repeated = artifacts
        repeated.insert(artifacts[0], at: 1)
        expect(
            repeated,
            ranges,
            .artifactNotContiguous(
                atIndex: 1,
                expectedUTF16Offset: firstEnd,
                foundUTF16Offset: artifacts[0].measurement.consumedUTF16Range.lowerBound
            ),
            "a line repeated"
        )

        // Two lines the wrong way round.
        var reordered = artifacts
        reordered.swapAt(0, 1)
        expect(
            reordered,
            ranges,
            .artifactNotContiguous(
                atIndex: 0,
                expectedUTF16Offset: 0,
                foundUTF16Offset: secondStart
            ),
            "two lines reordered"
        )

        // A page boundary that falls inside a line.
        var split = ranges.utf16Ranges
        let first = split[0]
        split[0] = first.lowerBound..<(first.upperBound - 1)
        split.insert((first.upperBound - 1)..<first.upperBound, at: 1)
        expect(
            artifacts,
            UnitPageRanges(unitID: made.unitID, utf16Ranges: split),
            .pageRangeSplitsALine(pageIndex: 0),
            "a page boundary inside a line"
        )

        // A page that starts after the line it is supposed to open with.
        var shifted = ranges.utf16Ranges
        let opening = shifted[0]
        shifted[0] = (opening.lowerBound + 1)..<opening.upperBound
        expect(
            artifacts,
            UnitPageRanges(unitID: made.unitID, utf16Ranges: shifted),
            .pageRangeSplitsALine(pageIndex: 0),
            "a page that does not start where its first line starts"
        )

        // Losing the last line leaves the segment uncovered.
        expect(
            Array(artifacts.dropLast()),
            ranges,
            .artifactCoverageIncomplete(
                expectedUTF16Count: made.utf16Count,
                foundUTF16Count: artifacts[artifacts.count - 2].measurement.consumedUTF16Range.upperBound
            ),
            "a segment the lines no longer cover"
        )
    }

    // MARK: - Corpora

    func testEveryCorpusIsCoveredAndEndsOnStorageBoundaries() throws {
        let corpora: [(String, CTFont)] = [
            (asciiParagraph, latinFont),
            (newlineCorpus, latinFont),
            (mixedCorpus, cjkFont),
            (combiningCorpus, latinFont)
        ]

        for (text, font) in corpora {
            let made = segment(text)
            let settings = constraints(inlineExtent: 80, blockExtent: 40)
            let paginated = try backend(font).makePaginatedPlainText(
                segment: made,
                nodeID: node,
                constraints: settings
            )

            XCTAssertGreaterThan(paginated.pageCount, 0)

            var expected = 0
            var lines = 0

            for index in 0..<paginated.pageCount {
                let scene = try XCTUnwrap(paginated.scene(at: index))
                XCTAssertEqual(scene.utf16Range.lowerBound, expected)
                XCTAssertTrue(made.isStorageBoundary(at: scene.utf16Range.lowerBound))
                XCTAssertTrue(made.isStorageBoundary(at: scene.utf16Range.upperBound))
                expected = scene.utf16Range.upperBound
                lines += scene.lineCount
            }

            XCTAssertEqual(expected, made.utf16Count)
            XCTAssertGreaterThan(lines, 0)
        }
    }

    // MARK: - The rules hit testing is built from

    /// The advance rule at its ends, including the case a real font rarely
    /// produces: a line of zero width. `x == width` is inside, because that is
    /// where the insertion point one past the last character sits; only what is
    /// past the width is blank.
    func testTheHitRulesAcceptTheEndsOfTheAdvanceAndRefuseWhatIsPastThem() {
        XCTAssertTrue(CoreTextHitRules.acceptsAdvance(x: 0, typographicWidth: 0))
        XCTAssertFalse(CoreTextHitRules.acceptsAdvance(x: -0.001, typographicWidth: 0))
        XCTAssertFalse(CoreTextHitRules.acceptsAdvance(x: 0.001, typographicWidth: 0))

        XCTAssertTrue(CoreTextHitRules.acceptsAdvance(x: 0, typographicWidth: 12))
        XCTAssertTrue(CoreTextHitRules.acceptsAdvance(x: 12, typographicWidth: 12))
        XCTAssertFalse(CoreTextHitRules.acceptsAdvance(x: 12.001, typographicWidth: 12))
        XCTAssertFalse(CoreTextHitRules.acceptsAdvance(x: -0.001, typographicWidth: 12))
    }

    /// The index rule: closed at both ends, so the insertion point one past the
    /// line is taken, while the "not found" answer and anything further out are
    /// not.
    func testTheHitRulesRefuseTheNotFoundAnswerAndAnythingPastTheLine() {
        let consumed = 5..<11

        XCTAssertTrue(CoreTextHitRules.acceptsIndex(5, consumed: consumed))
        XCTAssertTrue(CoreTextHitRules.acceptsIndex(10, consumed: consumed))
        XCTAssertTrue(
            CoreTextHitRules.acceptsIndex(11, consumed: consumed),
            "one past the end is a legal insertion point"
        )
        XCTAssertFalse(CoreTextHitRules.acceptsIndex(12, consumed: consumed))
        XCTAssertFalse(CoreTextHitRules.acceptsIndex(4, consumed: consumed))
        XCTAssertFalse(CoreTextHitRules.acceptsIndex(-1, consumed: consumed), "the not-found answer")
    }

    // MARK: - Hit testing

    func testTheLineSpacingGapAndTheOutsideOfThePageGiveNil() throws {
        let made = segment(newlineCorpus)
        let spacing = 12.0
        let settings = constraints(inlineExtent: 200, blockExtent: 400, lineSpacing: spacing)
        let paginated = try backend().makePaginatedPlainText(
            segment: made,
            nodeID: node,
            constraints: settings
        )

        let scene = try XCTUnwrap(paginated.scene(at: 0))
        XCTAssertGreaterThanOrEqual(scene.lineCount, 2, "the gap needs two lines on one page")

        let first = scene.lines[0]
        let second = scene.lines[1]
        let gapStart = first.top + CGFloat(first.artifact.measurement.naturalBlockExtent)
        let gapEnd = second.top
        XCTAssertGreaterThan(gapEnd, gapStart, "lineSpacing has to leave a gap")

        // The gap belongs to neither line.
        XCTAssertNil(scene.nativePosition(at: CGPoint(x: 1, y: (gapStart + gapEnd) / 2)))

        // Inside the first line it does not.
        let onFirst = CGPoint(x: 1, y: first.top + first.artifact.ascent / 2)
        XCTAssertNotNil(scene.nativePosition(at: onFirst))

        // Outside the page, and coordinates that are not numbers at all.
        XCTAssertNil(scene.nativePosition(at: CGPoint(x: -1, y: onFirst.y)))
        XCTAssertNil(scene.nativePosition(at: CGPoint(x: scene.size.width + 1, y: onFirst.y)))
        XCTAssertNil(scene.nativePosition(at: CGPoint(x: onFirst.x, y: scene.size.height + 1)))
        XCTAssertNil(scene.nativePosition(at: CGPoint(x: .nan, y: onFirst.y)))
        XCTAssertNil(scene.nativePosition(at: CGPoint(x: onFirst.x, y: .infinity)))
    }

    /// On the x derived from a line's `upperBound`, the scene reports what
    /// CoreText reports at that same point — no more and no less.
    ///
    /// The two CoreText calls are **not** promised to be inverses, and on this
    /// corpus the round-trip did not close: the offset that produced this x is
    /// not what came back. What is promised is that the horizontal rule does not
    /// turn the point away early, and that the index CoreText gives there is the
    /// index returned. The x comes from CoreText and the expectation is derived
    /// from it — neither is written down here.
    func testHittingAtTheEndOfALineReturnsTheIndexCoreTextPlacesThere() throws {
        let made = segment(newlineCorpus)
        let settings = constraints(inlineExtent: 200, blockExtent: 400)
        let paginated = try backend().makePaginatedPlainText(
            segment: made,
            nodeID: node,
            constraints: settings
        )

        let scene = try XCTUnwrap(paginated.scene(at: 0))
        let line = scene.lines[0]
        let consumed = line.artifact.measurement.consumedUTF16Range

        let x = CTLineGetOffsetForStringIndex(line.artifact.line, consumed.upperBound, nil)
        XCTAssertLessThanOrEqual(x, scene.size.width, "the end of the line is on the page")

        let point = CGPoint(x: x, y: line.top + line.artifact.ascent / 2)

        // The same point, in the same coordinates the scene uses, asked of
        // CoreText directly: whatever it answers is what has to come back.
        let relative = CGPoint(x: point.x, y: line.baseline - point.y)
        let expected = CTLineGetStringIndexForPosition(line.artifact.line, relative)

        // First the answer has to be one this layer is allowed to return at all,
        // or the case would be about the rules rather than about the scene.
        XCTAssertTrue(
            CoreTextHitRules.acceptsIndex(expected, consumed: consumed),
            "CoreText's own answer has to fall inside the line's consumed range"
        )
        XCTAssertTrue(
            made.isStorageBoundary(at: expected),
            "and on a legal storage boundary"
        )

        let hit = scene.nativePosition(at: point)
        XCTAssertEqual(hit?.utf16Offset, expected)
        XCTAssertEqual(hit?.nodeID, node)
        XCTAssertEqual(hit?.unitID, made.unitID)
    }

    /// The injected identity answers *which element* and nothing else: it moves
    /// no range, no measurement and no hit.
    func testADifferentInjectedNodeChangesOnlyTheIdentityOfAHit() throws {
        let made = segment(mixedCorpus)
        let settings = constraints(inlineExtent: 80, blockExtent: 40)

        let first = try backend(cjkFont).makePaginatedPlainText(
            segment: made,
            nodeID: node,
            constraints: settings
        )
        let second = try backend(cjkFont).makePaginatedPlainText(
            segment: made,
            nodeID: otherNode,
            constraints: settings
        )

        XCTAssertEqual(first.pageRanges, second.pageRanges)
        XCTAssertEqual(first.pageCount, second.pageCount)

        for index in 0..<first.pageCount {
            let a = try XCTUnwrap(first.scene(at: index))
            let b = try XCTUnwrap(second.scene(at: index))

            XCTAssertEqual(a.size, b.size)
            XCTAssertEqual(a.lineCount, b.lineCount)
            XCTAssertEqual(a.utf16Range, b.utf16Range)
            XCTAssertEqual(a.lines.map(\.top), b.lines.map(\.top))

            let line = a.lines[0]
            let point = CGPoint(x: 1, y: line.top + line.artifact.ascent / 2)
            let hitA = a.nativePosition(at: point)
            let hitB = b.nativePosition(at: point)

            XCTAssertEqual(hitA?.utf16Offset, hitB?.utf16Offset)
            XCTAssertEqual(hitA?.nodeID, node)
            XCTAssertEqual(hitB?.nodeID, otherNode)
        }
    }

    // MARK: - Drawing

    /// Recolouring goes through the context's fill colour. The flag the session
    /// fixed when it shaped the text is what lets that take over, and it means
    /// no colour can move a range or a measurement — which is checked by
    /// comparing the whole recorded set, not just where the lines start.
    func testTwoForegroundColoursDoNotMoveTheRangesOrTheMetrics() throws {
        let made = segment(mixedCorpus)
        let settings = constraints(inlineExtent: 80, blockExtent: 40)
        let paginated = try backend(cjkFont).makePaginatedPlainText(
            segment: made,
            nodeID: node,
            constraints: settings
        )
        let ranges = paginated.pageRanges

        let scene = try XCTUnwrap(paginated.scene(at: 0))
        let before = metrics(of: scene)

        let red = try deviceRed()
        let blue = try deviceBlue()
        let inRed = try painted(by: scene, colour: red)
        let inBlue = try painted(by: scene, colour: blue)

        // Each pass leaves its own colour, and only its own.
        XCTAssertGreaterThan(inRed.redDominant, 0, "the red pass has to leave red pixels")
        XCTAssertEqual(inRed.blueDominant, 0, "and no blue ones")
        XCTAssertGreaterThan(inBlue.blueDominant, 0, "the blue pass has to leave blue pixels")
        XCTAssertEqual(inBlue.redDominant, 0, "and no red ones")

        // Coverage counts and boxes are deliberately **not** compared between the
        // two passes: CoreGraphics' text smoothing makes antialiased coverage
        // depend on the colour, so the two legitimately cover a different number
        // of pixels. What the contract promises is that the geometry does not
        // move, and that is checked in full, field by field, below.

        XCTAssertEqual(paginated.pageRanges, ranges)
        XCTAssertEqual(metrics(of: scene), before)
    }

    /// The glyphs hang from the top of the page, inside the first line's own
    /// band, and the context is handed back as it was found.
    ///
    /// Where the band is comes from CoreText; which buffer row the page's top
    /// edge is comes from a mark of the test's own; and nothing is copied out of
    /// a font as a constant.
    ///
    /// The bitmap is read back in **two disjoint regions**, because one reading
    /// cannot answer both questions: the page's own columns hold only the
    /// glyphs, the caller's margin holds only what the caller painted after the
    /// scene gave the context back. Reading the whole bitmap at once mixes them,
    /// and a tall mark in the margin is enough to make a line drawn upside down
    /// look correctly placed near the top — so neither region is allowed to
    /// stand in for the other.
    func testDrawingPaintsGlyphsAtTheLinesOwnBandAndRestoresTheContext() throws {
        let made = segment("Hi")
        let settings = constraints(inlineExtent: 200, blockExtent: 60)
        let paginated = try backend().makePaginatedPlainText(
            segment: made,
            nodeID: node,
            constraints: settings
        )
        let scene = try XCTUnwrap(paginated.scene(at: 0))

        let inset = 12
        let width = Int(scene.size.width.rounded())
        let height = Int(scene.size.height.rounded())
        let bitmapWidth = width + 2 * inset

        let context = try pageContext(size: scene.size, inset: inset)

        // The caller's own state: a colour, and a text matrix and position set
        // nowhere near their defaults, so "restored" cannot be satisfied by
        // leaving things alone — the scene's flip would otherwise be invisible
        // in the result.
        let callerGreen = try deviceGreen()
        context.setFillColor(callerGreen)
        context.textMatrix = CGAffineTransform(a: 0.5, b: 0.25, c: -0.25, d: 0.5, tx: 7, ty: -3)
        context.textPosition = CGPoint(x: 11, y: 13)

        // Read back what the context actually holds rather than trusting the
        // literals above: setting the text position can move the matrix, so the
        // entry state is whatever the context holds **now**. These three
        // snapshots are what everything below is compared against.
        let ctmBefore = context.ctm
        let textMatrixBefore = context.textMatrix
        let textPositionBefore = context.textPosition

        // And they are not the defaults, or "restored" would prove nothing.
        XCTAssertNotEqual(textMatrixBefore, CGAffineTransform.identity)
        XCTAssertNotEqual(textPositionBefore, CGPoint.zero)

        let red = try deviceRed()
        scene.draw(in: context, foregroundColor: red)

        // Outside the scene's clip, and without setting a colour again: whatever
        // appears here is the colour and the clip the caller was left with.
        context.fill(
            CGRect(
                x: CGFloat(-inset + 2),
                y: CGFloat(2),
                width: CGFloat(inset - 4),
                height: CGFloat(height - 4)
            )
        )

        XCTAssertEqual(context.ctm, ctmBefore, "the transform has to be restored")
        XCTAssertEqual(context.textMatrix, textMatrixBefore, "the text matrix has to come back exactly")
        XCTAssertEqual(context.textPosition, textPositionBefore, "and so does the text position")

        // Two disjoint readings of the same bitmap. Neither may stand in for the
        // other: the page's columns are the glyphs' alone, the margin is the
        // caller's alone.
        let pageHeight = height + 2 * inset
        let glyphs = try painted(
            in: context,
            width: bitmapWidth,
            height: pageHeight,
            columns: inset..<(inset + width)
        )
        let margin = try painted(
            in: context,
            width: bitmapWidth,
            height: pageHeight,
            columns: 0..<inset
        )

        // On the page: the caller's foreground colour, and nothing of the
        // margin's.
        XCTAssertGreaterThan(glyphs.count, 0, "something has to be drawn on the page")
        XCTAssertGreaterThan(glyphs.redDominant, 0, "the glyphs take the caller's foreground colour")
        XCTAssertEqual(glyphs.greenDominant, 0, "the sentinel's colour does not reach the page")

        // In the margin, outside the clip: what the caller painted with the state
        // the scene handed back.
        XCTAssertGreaterThan(
            margin.greenDominant,
            0,
            "the colour and the clip outside the page have to be the caller's again"
        )
        XCTAssertEqual(margin.redDominant, 0, "the glyphs do not reach the margin")

        // Where the glyphs should be, from CoreText rather than from a constant,
        // and taken only from the page's own columns: the mark is tall enough
        // that a flipped line would still sit near the top of a whole-bitmap box.
        let line = scene.lines[0]
        let glyphBounds = CTLineGetBoundsWithOptions(line.artifact.line, .useGlyphPathBounds)
        let topRows = try topEdgeRows(size: scene.size, inset: inset)
        XCTAssertFalse(topRows.isEmpty, "the mark has to land somewhere")

        // The page's own coordinates, read out of the buffer: the inset is where
        // the page begins.
        let firstInkRow = Int(glyphs.box.minY)
        XCTAssertGreaterThanOrEqual(
            firstInkRow,
            topRows.lowerBound,
            "the first ink cannot start above the page's top edge"
        )
        XCTAssertLessThanOrEqual(
            firstInkRow - topRows.lowerBound,
            Int(line.artifact.ascent.rounded(.up)) + 1,
            "the first ink hangs from the top edge, within one ascent"
        )
        XCTAssertLessThanOrEqual(
            Double(glyphs.box.maxX) - Double(inset),
            Double(glyphBounds.maxX) + 2,
            "the ink stops where CoreText says the line's glyphs stop"
        )

        // Nothing beyond the glyphs: the page is not filled behind them.
        let beyondGlyphs = (inset + Int(glyphBounds.maxX.rounded(.up)) + 2)..<bitmapWidth
        XCTAssertFalse(beyondGlyphs.isEmpty, "the page has room past the text")
        let beyond = try painted(
            in: context,
            width: bitmapWidth,
            height: height + 2 * inset,
            columns: beyondGlyphs
        )
        XCTAssertEqual(beyond.count, 0, "the page must not be filled behind the glyphs")
    }
}
