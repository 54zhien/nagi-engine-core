import XCTest
import NagiEngineCore

private func pageMapUnit(
    _ id: String,
    href: String = "OEBPS/chapter.xhtml",
    mediaType: String = "application/xhtml+xml"
) -> DocumentUnit {
    DocumentUnit(id: DocumentUnitID(rawValue: id), href: href, mediaType: mediaType)
}

private func unitID(_ raw: String) -> DocumentUnitID {
    DocumentUnitID(rawValue: raw)
}

final class PageMapTests: XCTestCase {

    private func manifest(_ ids: String...) throws -> DocumentManifest {
        try DocumentManifest(readingOrder: ids.map { pageMapUnit($0) })
    }

    // MARK: - Refusing to answer

    func testAUnitWithNoKnownPagesHasNoAnswer() throws {
        let map = try PageMap(manifest: try manifest("a"), pageBreaks: [:])

        XCTAssertNil(map.page(containingUnit: unitID("a"), at: 0))
        XCTAssertNil(map.page(containingUnit: unitID("a"), at: 500))
    }

    func testAnIDTheManifestDoesNotHaveHasNoAnswer() throws {
        let map = try PageMap(manifest: try manifest("a"), pageBreaks: [unitID("a"): []])

        XCTAssertNil(map.page(containingUnit: unitID("b"), at: 0))
    }

    func testAnEmptyManifestHasNoAnswers() throws {
        let map = try PageMap(manifest: try DocumentManifest(readingOrder: []), pageBreaks: [:])

        XCTAssertNil(map.page(containingUnit: unitID("a"), at: 0))
    }

    // MARK: - The ordinal

    func testAUnitWithNoBreaksIsExactlyOnePage() throws {
        let map = try PageMap(manifest: try manifest("a"), pageBreaks: [unitID("a"): []])

        XCTAssertEqual(map.page(containingUnit: unitID("a"), at: 0), 0)
        XCTAssertEqual(map.page(containingUnit: unitID("a"), at: 4_000), 0)
    }

    func testPagesAreZeroBasedAndFollowTheBreaks() throws {
        let map = try PageMap(manifest: try manifest("a"), pageBreaks: [unitID("a"): [10, 20]])

        XCTAssertEqual(map.page(containingUnit: unitID("a"), at: 0), 0)
        XCTAssertEqual(map.page(containingUnit: unitID("a"), at: 9), 0)
        XCTAssertEqual(map.page(containingUnit: unitID("a"), at: 10), 1)
        XCTAssertEqual(map.page(containingUnit: unitID("a"), at: 19), 1)
        XCTAssertEqual(map.page(containingUnit: unitID("a"), at: 20), 2)
    }

    func testManyBreaksAreFoundByTheSearchNotJustTheFirstAndLast() throws {
        let breaks = Array(stride(from: 10, through: 100, by: 10))
        let map = try PageMap(manifest: try manifest("a"), pageBreaks: [unitID("a"): breaks])

        for (page, start) in breaks.enumerated() {
            XCTAssertEqual(map.page(containingUnit: unitID("a"), at: start), page + 1)
            XCTAssertEqual(map.page(containingUnit: unitID("a"), at: start - 1), page)
        }
    }

    // MARK: - Containment

    /// A page starts where it starts. The spike's fixed-page metric reads a
    /// boundary the same way; the other rule in that same file — a boundary
    /// belongs to the *earlier* unit — answers a different question, about unit
    /// spans rather than pages.
    func testAnOffsetOnABreakBelongsToThePageThatBreakStarts() throws {
        let map = try PageMap(manifest: try manifest("a"), pageBreaks: [unitID("a"): [10]])

        XCTAssertEqual(map.page(containingUnit: unitID("a"), at: 10), 1)
    }

    /// A manifest carries no lengths, so the map cannot know where the text ends
    /// — and it does not need to: everything from the last break onwards is the
    /// last page. The spike needed an explicit end-of-text clause only because
    /// its container knew the length.
    func testAnOffsetPastTheLastBreakBelongsToTheLastPage() throws {
        let map = try PageMap(manifest: try manifest("a"), pageBreaks: [unitID("a"): [10]])

        XCTAssertEqual(map.page(containingUnit: unitID("a"), at: 11), 1)
        XCTAssertEqual(map.page(containingUnit: unitID("a"), at: 1_000_000), 1)
    }

    func testANegativeOffsetIsOnNoPage() throws {
        let map = try PageMap(manifest: try manifest("a"), pageBreaks: [unitID("a"): [10]])

        XCTAssertNil(map.page(containingUnit: unitID("a"), at: -1))
    }

    // MARK: - Two layers, not one coordinate

    func testTheSameOffsetInTwoUnitsIsAnsweredPerUnit() throws {
        let map = try PageMap(
            manifest: try manifest("a", "b"),
            pageBreaks: [unitID("a"): [], unitID("b"): [5]]
        )

        XCTAssertEqual(map.page(containingUnit: unitID("a"), at: 7), 0)
        XCTAssertEqual(map.page(containingUnit: unitID("b"), at: 7), 1)
    }

    func testTheUnitIsFoundByIDNotByPositionInTheBreaks() throws {
        let map = try PageMap(
            manifest: try manifest("first", "second"),
            pageBreaks: [unitID("second"): [5]]
        )

        XCTAssertNil(map.page(containingUnit: unitID("first"), at: 7))
        XCTAssertEqual(map.page(containingUnit: unitID("second"), at: 0), 0)
    }

    func testUnitsDifferingOnlyByAFragmentAreDifferentUnits() throws {
        let map = try PageMap(
            manifest: try manifest("OEBPS/chapter.xhtml", "OEBPS/chapter.xhtml#frag"),
            pageBreaks: [
                unitID("OEBPS/chapter.xhtml"): [],
                unitID("OEBPS/chapter.xhtml#frag"): [5]
            ]
        )

        XCTAssertEqual(map.page(containingUnit: unitID("OEBPS/chapter.xhtml"), at: 9), 0)
        XCTAssertEqual(map.page(containingUnit: unitID("OEBPS/chapter.xhtml#frag"), at: 9), 1)
    }

    // MARK: - Construction

    func testABreakEntryForAUnitTheManifestDoesNotHaveThrows() throws {
        let manifest = try manifest("a")

        XCTAssertThrowsError(try PageMap(manifest: manifest, pageBreaks: [unitID("b"): []])) { thrown in
            XCTAssertEqual(
                thrown as? PageMapError,
                PageMapError.unknownUnitID(unitID("b"))
            )
        }
    }

    // MARK: - Value semantics

    func testTheMapDoesNotFollowLaterChangesToTheManifestItWasBuiltFrom() throws {
        var units = [pageMapUnit("a")]
        let manifest = try DocumentManifest(readingOrder: units)
        let map = try PageMap(manifest: manifest, pageBreaks: [unitID("a"): []])

        units.append(pageMapUnit("b"))

        XCTAssertEqual(map.page(containingUnit: unitID("a"), at: 0), 0)
        XCTAssertNil(map.page(containingUnit: unitID("b"), at: 0))
    }
}
