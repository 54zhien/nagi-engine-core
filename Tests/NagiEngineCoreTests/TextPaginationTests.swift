import XCTest
import NagiEngineCore

// MARK: - Fixtures

private func segment(_ string: String, unit: String = "u") -> PrimaryTextSegment {
    PrimaryTextSegment(unitID: DocumentUnitID(rawValue: unit), string: string)
}

private func line(_ range: Range<Int>, _ extent: Double) -> LineMeasurement {
    LineMeasurement(consumedUTF16Range: range, naturalBlockExtent: extent)
}

private func constraints(
    _ inlineExtent: Double,
    _ blockExtent: Double,
    _ lineSpacing: Double
) -> TextPaginationConstraints {
    TextPaginationConstraints(
        inlineExtent: inlineExtent,
        blockExtent: blockExtent,
        lineSpacing: lineSpacing
    )
}

/// A backend whose session hands back whatever the test scripted, and records
/// what it was asked for.
///
/// A session that runs out of script answers `nil` — the same thing a backend
/// says when it has nothing to offer, which is what makes the stall tests
/// honest.
private final class ScriptedSession: LineBreakSession {
    private var script: [LineMeasurement?]
    private(set) var requestedOffsets: [Int] = []
    private(set) var inlineExtents: [Double] = []
    var errorToThrow: Error?

    /// Set by the backend when a session is actually handed out, so a test can
    /// tell "never asked" from "asked and got nothing".
    var segmentWasMade = false

    init(script: [LineMeasurement?]) {
        self.script = script
    }

    func suggestLine(fromUTF16Offset: Int, inlineExtent: Double) throws -> LineMeasurement? {
        requestedOffsets.append(fromUTF16Offset)
        inlineExtents.append(inlineExtent)

        if let errorToThrow { throw errorToThrow }
        guard !script.isEmpty else { return nil }
        return script.removeFirst()
    }
}

private struct ScriptedBackend: LineBreakBackend {
    let session: ScriptedSession
    private let makeSessionError: Error?

    init(script: [LineMeasurement?], makeSessionError: Error? = nil) {
        self.session = ScriptedSession(script: script)
        self.makeSessionError = makeSessionError
    }

    func makeSession(for segment: PrimaryTextSegment) throws -> ScriptedSession {
        if let makeSessionError { throw makeSessionError }
        session.segmentWasMade = true
        return session
    }
}

private enum TestError: Error, Equatable {
    case backendRefusedToMakeASession
    case sessionBlewUp
}

// MARK: - Tests

final class TextPaginationTests: XCTestCase {

    // MARK: - Constraints come first

    func testEachConstraintIsRejectedForItsOwnReason() throws {
        let cases: [(TextPaginationConstraints, TextPaginationError)] = [
            (constraints(0, 10, 0), TextPaginationError.invalidInlineExtent),
            (constraints(-1, 10, 0), TextPaginationError.invalidInlineExtent),
            (constraints(.nan, 10, 0), TextPaginationError.invalidInlineExtent),
            (constraints(.infinity, 10, 0), TextPaginationError.invalidInlineExtent),
            (constraints(10, 0, 0), TextPaginationError.invalidBlockExtent),
            (constraints(10, -1, 0), TextPaginationError.invalidBlockExtent),
            (constraints(10, .nan, 0), TextPaginationError.invalidBlockExtent),
            (constraints(10, .infinity, 0), TextPaginationError.invalidBlockExtent),
            (constraints(10, 10, -1), TextPaginationError.invalidLineSpacing),
            (constraints(10, 10, .nan), TextPaginationError.invalidLineSpacing),
            (constraints(10, 10, .infinity), TextPaginationError.invalidLineSpacing)
        ]

        for (bad, expected) in cases {
            let backend = ScriptedBackend(script: [line(0..<1, 5)])

            XCTAssertThrowsError(
                try TextPaginator.paginate(
                    segment: segment("a"),
                    constraints: bad,
                    backend: backend
                ),
                "expected \(expected)"
            ) { thrown in
                XCTAssertEqual(thrown as? TextPaginationError, expected)
            }

            // Invalid constraints are rejected before anything else happens.
            XCTAssertFalse(backend.session.segmentWasMade)
            XCTAssertTrue(backend.session.requestedOffsets.isEmpty)
        }
    }

    /// Zero spacing is a legal value, not an invalid one.
    func testZeroLineSpacingIsLegal() throws {
        let backend = ScriptedBackend(script: [line(0..<2, 5), line(2..<4, 5)])
        let result = try TextPaginator.paginate(
            segment: segment("abcd"),
            constraints: constraints(100, 10, 0),
            backend: backend
        )

        // 5 + 0 + 5 = 10 fits exactly.
        XCTAssertEqual(result.utf16Ranges, [0..<4])
    }

    /// Emptiness does not excuse invalid constraints: the constraints are
    /// checked first, so the caller learns which thing is actually wrong.
    func testInvalidConstraintsAreReportedBeforeEmptiness() throws {
        let backend = ScriptedBackend(script: [])

        XCTAssertThrowsError(
            try TextPaginator.paginate(
                segment: segment(""),
                constraints: constraints(0, 10, 0),
                backend: backend
            )
        ) { thrown in
            XCTAssertEqual(thrown as? TextPaginationError, TextPaginationError.invalidInlineExtent)
        }

        XCTAssertFalse(backend.session.segmentWasMade)
    }

    // MARK: - The empty segment

    func testAnEmptySegmentProducesNoPagesAndMakesNoSession() throws {
        let backend = ScriptedBackend(script: [line(0..<1, 5)])

        let result = try TextPaginator.paginate(
            segment: segment("", unit: "empty"),
            constraints: constraints(100, 100, 0),
            backend: backend
        )

        XCTAssertEqual(result.unitID, DocumentUnitID(rawValue: "empty"))
        XCTAssertTrue(result.utf16Ranges.isEmpty)
        XCTAssertFalse(backend.session.segmentWasMade)
        XCTAssertTrue(backend.session.requestedOffsets.isEmpty)
    }

    // MARK: - Grouping

    func testOneLineBecomesOnePage() throws {
        let backend = ScriptedBackend(script: [line(0..<3, 10)])

        let result = try TextPaginator.paginate(
            segment: segment("abc", unit: "only"),
            constraints: constraints(100, 100, 0),
            backend: backend
        )

        XCTAssertEqual(result.unitID, DocumentUnitID(rawValue: "only"))
        XCTAssertEqual(result.utf16Ranges, [0..<3])
        XCTAssertEqual(backend.session.requestedOffsets, [0])
    }

    func testALineThatWouldOverflowStartsANewPage() throws {
        let backend = ScriptedBackend(script: [
            line(0..<2, 10),
            line(2..<4, 10),
            line(4..<6, 10)
        ])

        let result = try TextPaginator.paginate(
            segment: segment("abcdef"),
            constraints: constraints(100, 25, 0),
            backend: backend
        )

        // 10, then 20, then 30 > 25.
        XCTAssertEqual(result.utf16Ranges, [0..<4, 4..<6])
    }

    func testAnExactFitStaysOnThePage() throws {
        let backend = ScriptedBackend(script: [line(0..<1, 10), line(1..<2, 15)])

        let result = try TextPaginator.paginate(
            segment: segment("ab"),
            constraints: constraints(100, 25, 0),
            backend: backend
        )

        // 10 + 15 = 25, which is not "more than" 25.
        XCTAssertEqual(result.utf16Ranges, [0..<2])
    }

    /// Three lines of 10 with spacing 5 occupy 40 if a page carries two gaps
    /// and 45 if it carries three. The 40 case is the one that tells them apart.
    func testSpacingCountsBetweenLinesAndNotAfterTheLast() throws {
        let lines = [line(0..<1, 10), line(1..<2, 10), line(2..<3, 10)]

        let exact = ScriptedBackend(script: lines)
        XCTAssertEqual(
            try TextPaginator.paginate(
                segment: segment("abc"),
                constraints: constraints(100, 40, 5),
                backend: exact
            ).utf16Ranges,
            [0..<3]
        )

        let short = ScriptedBackend(script: lines)
        XCTAssertEqual(
            try TextPaginator.paginate(
                segment: segment("abc"),
                constraints: constraints(100, 39, 5),
                backend: short
            ).utf16Ranges,
            [0..<2, 2..<3]
        )
    }

    /// A page that begins after a break starts empty — it does not inherit a
    /// spacing from the line before it.
    ///
    /// The numbers are chosen so the two rules disagree: with no carried spacing
    /// the second page holds two lines, and with one carried it would hold one.
    func testSpacingIsNotCarriedAcrossAPageBreak() throws {
        let backend = ScriptedBackend(script: [
            line(0..<1, 25),
            line(1..<2, 2),
            line(2..<3, 20)
        ])

        let result = try TextPaginator.paginate(
            segment: segment("abc"),
            constraints: constraints(100, 27, 5),
            backend: backend
        )

        // page 0: 25, then 25+5+2 = 32 > 27 → break.
        // page 1: 2, then 2+5+20 = 27 ≤ 27 → stays. Carrying a spacing would
        // make it 32 and split it.
        XCTAssertEqual(result.utf16Ranges, [0..<1, 1..<3])
    }

    /// A line taller than the page is a legal input, not an error: the block
    /// extent bounds the page, not the line.
    func testALineTallerThanThePageOccupiesAPageAlone() throws {
        let backend = ScriptedBackend(script: [line(0..<1, 30), line(1..<2, 5)])

        let result = try TextPaginator.paginate(
            segment: segment("ab"),
            constraints: constraints(100, 10, 0),
            backend: backend
        )

        XCTAssertEqual(result.utf16Ranges, [0..<1, 1..<2])
    }

    // MARK: - Candidates the paginator must reject

    func testANilFromARealCallIsAStall() throws {
        let backend = ScriptedBackend(script: [nil])

        XCTAssertThrowsError(
            try TextPaginator.paginate(
                segment: segment("abc"),
                constraints: constraints(100, 100, 0),
                backend: backend
            )
        ) { thrown in
            XCTAssertEqual(
                thrown as? TextPaginationError,
                TextPaginationError.backendStalled(atUTF16Offset: 0)
            )
        }
    }

    func testAGapIsADiscontinuity() throws {
        let backend = ScriptedBackend(script: [line(0..<1, 10), line(2..<3, 10)])

        XCTAssertThrowsError(
            try TextPaginator.paginate(
                segment: segment("abc"),
                constraints: constraints(100, 100, 0),
                backend: backend
            )
        ) { thrown in
            XCTAssertEqual(
                thrown as? TextPaginationError,
                TextPaginationError.rangeDiscontinuity(
                    expectedUTF16Offset: 1,
                    foundUTF16Offset: 2
                )
            )
        }
    }

    func testAnOverlappingOrBackwardRangeIsADiscontinuity() throws {
        let backend = ScriptedBackend(script: [line(0..<2, 10), line(1..<3, 10)])

        XCTAssertThrowsError(
            try TextPaginator.paginate(
                segment: segment("abc"),
                constraints: constraints(100, 100, 0),
                backend: backend
            )
        ) { thrown in
            XCTAssertEqual(
                thrown as? TextPaginationError,
                TextPaginationError.rangeDiscontinuity(
                    expectedUTF16Offset: 2,
                    foundUTF16Offset: 1
                )
            )
        }
    }

    func testAnEmptyRangeIsNonAdvancing() throws {
        let backend = ScriptedBackend(script: [line(0..<0, 10)])

        XCTAssertThrowsError(
            try TextPaginator.paginate(
                segment: segment("abc"),
                constraints: constraints(100, 100, 0),
                backend: backend
            )
        ) { thrown in
            XCTAssertEqual(
                thrown as? TextPaginationError,
                TextPaginationError.nonAdvancingRange(atUTF16Offset: 0)
            )
        }
    }

    /// Out-of-range bounds are checked first, before anything looks at the
    /// values.
    ///
    /// No case here builds a reversed `Range`. `lowerBound <= upperBound` is
    /// `Range`'s contract; a value violating it is outside this API's domain,
    /// and whether a given configuration traps on one is a standard-library and
    /// optimisation detail. The test depends on neither.
    func testRangesOutsideTheSegmentAreOutOfBounds() throws {
        let cases: [Range<Int>] = [
            -1..<2,
            0..<4,
            0..<Int.max
        ]

        for bad in cases {
            let backend = ScriptedBackend(script: [line(bad, 10)])

            XCTAssertThrowsError(
                try TextPaginator.paginate(
                    segment: segment("abc"),
                    constraints: constraints(100, 100, 0),
                    backend: backend
                ),
                "expected \(bad) to be out of bounds"
            ) { thrown in
                XCTAssertEqual(thrown as? TextPaginationError, TextPaginationError.rangeOutOfBounds(bad))
            }
        }
    }

    /// A boundary that splits a surrogate pair is not a place the segment can be
    /// cut, even though it is perfectly in range.
    func testASliceThroughASurrogatePairIsNotAStorageBoundary() throws {
        let made = segment("\u{1D54F}")           // one scalar, two UTF-16 units
        let backend = ScriptedBackend(script: [line(0..<1, 10)])

        XCTAssertThrowsError(
            try TextPaginator.paginate(
                segment: made,
                constraints: constraints(100, 100, 0),
                backend: backend
            )
        ) { thrown in
            XCTAssertEqual(
                thrown as? TextPaginationError,
                TextPaginationError.rangeNotOnStorageBoundary(0..<1)
            )
        }
    }

    func testNaturalBlockExtentsThatAreNotUsableAreRejected() throws {
        for bad in [Double.nan, .infinity, 0, -1] {
            let backend = ScriptedBackend(script: [line(0..<1, bad)])

            XCTAssertThrowsError(
                try TextPaginator.paginate(
                    segment: segment("a"),
                    constraints: constraints(100, 100, 0),
                    backend: backend
                ),
                "expected \(bad) to be rejected"
            ) { thrown in
                XCTAssertEqual(
                    thrown as? TextPaginationError,
                    TextPaginationError.invalidNaturalBlockExtent(atUTF16Offset: 0)
                )
            }
        }
    }

    // MARK: - What the backend is asked for

    /// The extent is forwarded unchanged, the offsets are exactly each line's
    /// start, and the end of the segment does not produce a further call.
    func testTheBackendSeesEachLineStartAndTheOriginalInlineExtent() throws {
        let backend = ScriptedBackend(script: [
            line(0..<2, 5),
            line(2..<4, 5),
            line(4..<6, 5)
        ])

        _ = try TextPaginator.paginate(
            segment: segment("abcdef"),
            constraints: constraints(37.5, 100, 0),
            backend: backend
        )

        XCTAssertEqual(backend.session.requestedOffsets, [0, 2, 4])
        XCTAssertEqual(backend.session.inlineExtents, [37.5, 37.5, 37.5])
    }

    // MARK: - Backend errors

    /// A backend's own error is not this layer's to reinterpret: it arrives
    /// unchanged, not wrapped and not swallowed.
    func testAMakeSessionErrorPropagatesUnchanged() throws {
        let backend = ScriptedBackend(
            script: [line(0..<1, 10)],
            makeSessionError: TestError.backendRefusedToMakeASession
        )

        XCTAssertThrowsError(
            try TextPaginator.paginate(
                segment: segment("a"),
                constraints: constraints(100, 100, 0),
                backend: backend
            )
        ) { thrown in
            XCTAssertEqual(thrown as? TestError, TestError.backendRefusedToMakeASession)
            XCTAssertNil(thrown as? TextPaginationError)
        }
    }

    func testASuggestLineErrorPropagatesUnchanged() throws {
        let backend = ScriptedBackend(script: [line(0..<1, 10)])
        backend.session.errorToThrow = TestError.sessionBlewUp

        XCTAssertThrowsError(
            try TextPaginator.paginate(
                segment: segment("a"),
                constraints: constraints(100, 100, 0),
                backend: backend
            )
        ) { thrown in
            XCTAssertEqual(thrown as? TestError, TestError.sessionBlewUp)
            XCTAssertNil(thrown as? TextPaginationError)
        }
    }
}
