import XCTest
import NagiEngineCore

private func segment(_ string: String, unit: String = "unit") -> PrimaryTextSegment {
    PrimaryTextSegment(unitID: DocumentUnitID(rawValue: unit), string: string)
}

/// One Unicode scalar, two UTF-16 code units.
private let nonBMP = "\u{1D54F}"
private let cjk = "第一章"
/// `e` plus a combining acute — two scalars, two code units, one grapheme.
private let decomposed = "e\u{301}"

final class PrimaryTextSegmentTests: XCTestCase {

    // MARK: - The constructor keeps exactly what it was given

    func testTheConstructorKeepsTheUnitIDAndTheExactScalars() throws {
        let input = decomposed
        let made = segment(input, unit: "OEBPS/chapter.xhtml#frag")

        XCTAssertEqual(made.unitID, DocumentUnitID(rawValue: "OEBPS/chapter.xhtml#frag"))

        // Scalar by scalar, not string against string: `==` on `String` holds
        // canonically equivalent sequences equal, so a constructor that
        // normalised to NFC would pass a plain equality check. This is what
        // would fail instead.
        XCTAssertEqual(made.string.unicodeScalars.map(\.value), [0x65, 0x301])
        XCTAssertEqual(Array(made.string.utf8), Array(input.utf8))
    }

    // MARK: - Counting

    func testUTF16CountCountsCodeUnitsRatherThanCharacters() throws {
        XCTAssertEqual(segment("").utf16Count, 0)
        XCTAssertEqual(segment("abc").utf16Count, 3)
        XCTAssertEqual(segment(cjk).utf16Count, 3)
        XCTAssertEqual(segment(decomposed).utf16Count, 2)
        XCTAssertEqual(segment(nonBMP).utf16Count, 2)
    }

    // MARK: - Storage boundaries

    func testTheEndsAreBoundariesAndAnythingOutsideIsNot() throws {
        let made = segment("abc")

        XCTAssertTrue(made.isStorageBoundary(at: 0))
        XCTAssertTrue(made.isStorageBoundary(at: 3))

        XCTAssertFalse(made.isStorageBoundary(at: 4))
        XCTAssertFalse(made.isStorageBoundary(at: -1))
        XCTAssertFalse(made.isStorageBoundary(at: Int.min))
        XCTAssertFalse(made.isStorageBoundary(at: Int.max))
    }

    func testAnEmptySegmentHasExactlyOneBoundary() throws {
        let made = segment("")

        XCTAssertTrue(made.isStorageBoundary(at: 0))
        XCTAssertFalse(made.isStorageBoundary(at: 1))
        XCTAssertFalse(made.isStorageBoundary(at: -1))
    }

    func testTheInsideOfASurrogatePairIsNotABoundary() throws {
        let made = segment(nonBMP)

        XCTAssertTrue(made.isStorageBoundary(at: 0))
        XCTAssertFalse(made.isStorageBoundary(at: 1))
        XCTAssertTrue(made.isStorageBoundary(at: 2))
    }

    /// The rule here is about surrogate pairs and nothing else. A caret policy
    /// would refuse to sit inside a combining sequence; if this type did that
    /// too, it would have quietly become a caret policy.
    func testACombiningMarkStillHasAStorageBoundaryInsideIt() throws {
        let made = segment(decomposed)

        XCTAssertTrue(made.isStorageBoundary(at: 1))
        XCTAssertEqual(made.text(inUTF16: 0..<1), "e")
        XCTAssertEqual(made.text(inUTF16: 1..<2), "\u{301}")
    }

    // MARK: - Slicing

    func testSlicesOfASCIIAndCJKAreExact() throws {
        let ascii = segment("abc")

        XCTAssertEqual(ascii.text(inUTF16: 0..<3), "abc")
        XCTAssertEqual(ascii.text(inUTF16: 1..<2), "b")
        XCTAssertEqual(ascii.text(inUTF16: 0..<0), "")

        let cjkSegment = segment(cjk)

        XCTAssertEqual(cjkSegment.text(inUTF16: 0..<3), cjk)
        XCTAssertEqual(cjkSegment.text(inUTF16: 1..<2), "二")
    }

    func testAWholeNonBMPCharacterSlicesExactly() throws {
        let made = segment("a" + nonBMP + "b")

        XCTAssertEqual(made.utf16Count, 4)
        XCTAssertEqual(made.text(inUTF16: 1..<3), nonBMP)
        XCTAssertEqual(made.text(inUTF16: 0..<1), "a")
        XCTAssertEqual(made.text(inUTF16: 3..<4), "b")
        XCTAssertEqual(made.text(inUTF16: 0..<4), "a" + nonBMP + "b")
    }

    func testALegalEmptyRangeAnswersWithAnEmptyString() throws {
        let made = segment("abc")

        XCTAssertEqual(made.text(inUTF16: 0..<0), "")
        XCTAssertEqual(made.text(inUTF16: 1..<1), "")
        XCTAssertEqual(made.text(inUTF16: 3..<3), "")
    }

    /// The slice is the same scalars it was cut from, and that is proved by
    /// scalars and bytes rather than by `String ==`.
    ///
    /// `String` equality holds canonically equivalent sequences equal, so a
    /// slice that took a normalising round trip through `String` would still
    /// compare equal to the original — and pass a test written with `==`.
    func testASliceOfACombiningSequenceIsNotNormalised() throws {
        let made = segment(decomposed)

        let slice = try XCTUnwrap(made.text(inUTF16: 0..<2))

        XCTAssertEqual(slice.unicodeScalars.map(\.value), [0x65, 0x301])
        XCTAssertEqual(Array(slice.utf8), Array(decomposed.utf8))
    }

    // MARK: - Ranges that cut a character, or the rules

    /// Cutting a surrogate pair is refused from either side, and the answer is
    /// `nil` rather than a replacement character — a `U+FFFD` here would be a
    /// well-formed string carrying the wrong text.
    func testASliceThroughASurrogatePairIsRefusedFromEitherSide() throws {
        let made = segment(nonBMP)

        XCTAssertNil(made.text(inUTF16: 0..<1))
        XCTAssertNil(made.text(inUTF16: 1..<2))
    }

    /// An **empty** range at an illegal position is refused too, and the two
    /// empty ranges at legal positions beside it are not.
    ///
    /// This is what an implementation that short-circuits on `isEmpty` — or that
    /// slices first and inspects the boundaries afterwards — gets wrong: it
    /// answers `""` for `1..<1` and looks helpful while doing it.
    func testAnEmptyRangeInsideASurrogatePairIsStillRefused() throws {
        let made = segment(nonBMP)

        XCTAssertNil(made.text(inUTF16: 1..<1))

        XCTAssertEqual(made.text(inUTF16: 0..<0), "")
        XCTAssertEqual(made.text(inUTF16: 2..<2), "")
    }

    func testOffsetsOutsideTheSegmentAreRefusedRatherThanCrashing() throws {
        let made = segment("abc")

        XCTAssertNil(made.text(inUTF16: -1..<2))
        XCTAssertNil(made.text(inUTF16: 0..<4))
        XCTAssertNil(made.text(inUTF16: Int.min..<3))
        XCTAssertNil(made.text(inUTF16: 0..<Int.max))
        XCTAssertNil(made.text(inUTF16: Int.min..<Int.min))
        XCTAssertNil(made.text(inUTF16: Int.max..<Int.max))
    }

    /// `Range(uncheckedBounds:)` does not check the order, so this value exists
    /// and can reach the API. The `..<` precondition never ran for it, which is
    /// exactly why the method refuses it itself.
    func testAReversedRangeBuiltWithoutCheckingIsRefused() throws {
        let made = segment("abc")

        XCTAssertNil(made.text(inUTF16: Range(uncheckedBounds: (lower: 2, upper: 1))))
        XCTAssertNil(made.text(inUTF16: Range(uncheckedBounds: (lower: 3, upper: 0))))
    }
}
