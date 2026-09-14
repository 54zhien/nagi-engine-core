import Foundation
import XCTest
import NagiEngineCore

private func positionUnit(
    _ id: String,
    href: String = "OEBPS/chapter.xhtml",
    mediaType: String = "application/xhtml+xml"
) -> DocumentUnit {
    DocumentUnit(id: DocumentUnitID(rawValue: id), href: href, mediaType: mediaType)
}

private func positionUnitID(_ raw: String) -> DocumentUnitID {
    DocumentUnitID(rawValue: raw)
}

private func position(_ unit: String, _ utf16Offset: Int, node: String = "p1") -> NativePosition {
    NativePosition(
        unitID: positionUnitID(unit),
        nodeID: NodeID(rawValue: node),
        utf16Offset: utf16Offset
    )
}

final class NativePositionTests: XCTestCase {

    private func manifest(_ ids: String...) throws -> DocumentManifest {
        try DocumentManifest(readingOrder: ids.map { positionUnit($0, href: "OEBPS/\($0).xhtml") })
    }

    // MARK: - NodeID

    func testANodeIDEncodesAsABareJSONStringAndDecodesBack() throws {
        let original = NodeID(rawValue: "OEBPS/chapter.xhtml#p1")

        let data = try JSONEncoder().encode(original)

        // Decoding the top level as a `String` is what proves the shape; the
        // bytes are deliberately not asserted, because how an encoder escapes is
        // the encoder's business.
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: data), "OEBPS/chapter.xhtml#p1")
        XCTAssertEqual(try JSONDecoder().decode(NodeID.self, from: data), original)
    }

    func testNodeIDsUseStringEqualityWithNoNormalisation() throws {
        XCTAssertEqual(NodeID(rawValue: "chapter.xhtml"), NodeID(rawValue: "chapter.xhtml"))

        // None of the href rules apply: no fragment stripping, no case folding,
        // no trimming, no percent decoding.
        XCTAssertNotEqual(NodeID(rawValue: "chapter.xhtml"), NodeID(rawValue: "chapter.xhtml#frag"))
        XCTAssertNotEqual(NodeID(rawValue: "P1"), NodeID(rawValue: "p1"))
        XCTAssertNotEqual(NodeID(rawValue: " p1"), NodeID(rawValue: "p1"))
        XCTAssertNotEqual(NodeID(rawValue: "a%20b"), NodeID(rawValue: "a b"))
    }

    /// Swift's string equality holds canonically equivalent sequences equal, and
    /// this type inherits that rather than redefining it.
    ///
    /// The test earns its place by falsification: `é` as one scalar and as `e`
    /// plus a combining acute are the same string and different UTF-8 bytes, so
    /// an implementation that compared bytes would fail here and pass everywhere
    /// else in this file.
    func testNodeIDsFollowStringEqualityForCanonicallyEquivalentSequences() throws {
        XCTAssertEqual(NodeID(rawValue: "\u{00E9}"), NodeID(rawValue: "e\u{301}"))
    }

    // MARK: - NativePosition

    func testANativePositionRoundTripsThroughJSON() throws {
        let original = position("a", 22, node: "p4")

        let data = try JSONEncoder().encode(original)

        XCTAssertEqual(try JSONDecoder().decode(NativePosition.self, from: data), original)

        // **Exactly** three fields. A round trip alone cannot notice a fourth —
        // `documentOrder`, say — because it would encode and decode back just as
        // happily. Asserting the key set is what makes that addition fail.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["unitID", "nodeID", "utf16Offset"]))
    }

    func testPositionsDifferingOnlyByNodeIDAreNotEqual() throws {
        XCTAssertNotEqual(position("a", 22, node: "p1"), position("a", 22, node: "p2"))
    }

    // MARK: - One unit, ordered by offset

    func testPositionsInOneUnitAreOrderedByTheirOffsets() throws {
        let manifest = try manifest("a")

        XCTAssertEqual(manifest.compareInDocumentOrder(position("a", 5), position("a", 6)), DocumentOrderComparison.before)
        XCTAssertEqual(manifest.compareInDocumentOrder(position("a", 6), position("a", 5)), DocumentOrderComparison.after)
        XCTAssertEqual(manifest.compareInDocumentOrder(position("a", 6), position("a", 6)), DocumentOrderComparison.sameCoordinate)
    }

    /// The two positions are **not equal** — their node ids differ — and they are
    /// still one coordinate. This is the case a `Comparable` on `NativePosition`
    /// could not express, and the reason the answer is three-valued.
    func testADifferentNodeIDDoesNotBreakATie() throws {
        let manifest = try manifest("a")
        let left = position("a", 6, node: "p1")
        let right = position("a", 6, node: "p2")

        XCTAssertNotEqual(left, right)
        XCTAssertEqual(manifest.compareInDocumentOrder(left, right), DocumentOrderComparison.sameCoordinate)
        XCTAssertEqual(manifest.compareInDocumentOrder(right, left), DocumentOrderComparison.sameCoordinate)
    }

    // MARK: - Across units, ordered by the manifest

    func testUnitsAreOrderedByTheirPlaceInTheManifest() throws {
        let manifest = try manifest("a", "b")

        XCTAssertEqual(manifest.compareInDocumentOrder(position("a", 999), position("b", 0)), DocumentOrderComparison.before)
        XCTAssertEqual(manifest.compareInDocumentOrder(position("b", 0), position("a", 999)), DocumentOrderComparison.after)
    }

    /// Order is a function of the document, not a constant the position carries:
    /// the same two positions swap places when the manifest is reordered.
    func testReorderingTheManifestReordersTheSameTwoPositions() throws {
        let forwards = try manifest("a", "b")
        let backwards = try manifest("b", "a")

        XCTAssertEqual(forwards.compareInDocumentOrder(position("a", 5), position("b", 5)), DocumentOrderComparison.before)
        XCTAssertEqual(backwards.compareInDocumentOrder(position("a", 5), position("b", 5)), DocumentOrderComparison.after)
    }

    func testUnitsSharingAnHrefAreOrderedByTheirOwnIDs() throws {
        let shared = "OEBPS/chapter.xhtml"
        let manifest = try DocumentManifest(readingOrder: [
            positionUnit("front", href: shared),
            positionUnit("back", href: shared)
        ])

        XCTAssertEqual(manifest.compareInDocumentOrder(position("front", 9), position("back", 9)), DocumentOrderComparison.before)
        XCTAssertEqual(manifest.compareInDocumentOrder(position("back", 0), position("front", 0)), DocumentOrderComparison.after)
    }

    // MARK: - A unit that is not here has no order

    func testAPositionWhoseUnitIsMissingHasNoOrder() throws {
        let manifest = try manifest("a")

        XCTAssertNil(manifest.compareInDocumentOrder(position("a", 0), position("gone", 0)))
        XCTAssertNil(manifest.compareInDocumentOrder(position("gone", 0), position("a", 0)))
        XCTAssertNil(manifest.compareInDocumentOrder(position("gone", 0), position("also-gone", 0)))
    }

    /// Two positions that would be `.sameCoordinate` in a document that had the
    /// unit, and the **very same** position twice. Both answer `nil`.
    ///
    /// The second one is the one that earns the test: `lhs == rhs` is true there,
    /// so an implementation that short-circuited on equality — or on "the two
    /// coordinates match" — before checking whether the unit exists would return
    /// `.sameCoordinate` and pass every other test in this file.
    func testPositionsInAMissingUnitHaveNoOrderEvenWhenTheyAreTheSamePosition() throws {
        let manifest = try manifest("a")

        XCTAssertNil(manifest.compareInDocumentOrder(
            position("gone", 7, node: "p1"),
            position("gone", 7, node: "p2")
        ))

        let missing = position("gone", 7, node: "p1")
        XCTAssertNil(manifest.compareInDocumentOrder(missing, missing))
    }

    // MARK: - Offsets are ordered, not validated

    func testExtremeOffsetsAreOrderedRatherThanValidatedOrOverflowing() throws {
        let manifest = try manifest("a", "b")

        XCTAssertEqual(manifest.compareInDocumentOrder(position("a", .min), position("a", .max)), DocumentOrderComparison.before)
        XCTAssertEqual(manifest.compareInDocumentOrder(position("a", .max), position("a", .min)), DocumentOrderComparison.after)
        XCTAssertEqual(manifest.compareInDocumentOrder(position("a", -1), position("a", 0)), DocumentOrderComparison.before)
        XCTAssertEqual(manifest.compareInDocumentOrder(position("a", .max), position("a", .max)), DocumentOrderComparison.sameCoordinate)

        // A whole unit later still loses to a far smaller offset in an earlier
        // one: the unit index is compared first.
        XCTAssertEqual(manifest.compareInDocumentOrder(position("a", .max), position("b", .min)), DocumentOrderComparison.before)
        XCTAssertEqual(manifest.compareInDocumentOrder(position("b", .min), position("a", .max)), DocumentOrderComparison.after)
    }
}
