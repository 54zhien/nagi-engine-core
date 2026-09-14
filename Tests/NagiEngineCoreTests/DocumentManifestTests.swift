import Foundation
import XCTest
import NagiEngineCore

private func unit(
    _ id: String,
    href: String = "OEBPS/chapter.xhtml",
    mediaType: String = "application/xhtml+xml"
) -> DocumentUnit {
    DocumentUnit(id: DocumentUnitID(rawValue: id), href: href, mediaType: mediaType)
}

private func id(_ raw: String) -> DocumentUnitID {
    DocumentUnitID(rawValue: raw)
}

final class DocumentManifestTests: XCTestCase {

    // MARK: - The empty manifest

    func testAnEmptyReadingOrderIsAValidManifestWithNoUnits() throws {
        let manifest = try DocumentManifest(readingOrder: [])

        XCTAssertTrue(manifest.readingOrder.isEmpty)
        XCTAssertNil(manifest.readingOrderIndex(of: id("anything")))
    }

    // MARK: - The ordinal

    func testIndicesAreZeroBasedAndFollowTheArrayOrder() throws {
        let manifest = try DocumentManifest(readingOrder: [unit("a"), unit("b"), unit("c")])

        XCTAssertEqual(manifest.readingOrder.map(\.id.rawValue), ["a", "b", "c"])
        XCTAssertEqual(manifest.readingOrderIndex(of: id("a")), 0)
        XCTAssertEqual(manifest.readingOrderIndex(of: id("b")), 1)
        XCTAssertEqual(manifest.readingOrderIndex(of: id("c")), 2)
    }

    func testAnUnknownIDHasNoIndexRatherThanALastPlaceOrAFailure() throws {
        let manifest = try DocumentManifest(readingOrder: [unit("a"), unit("b")])

        XCTAssertNil(manifest.readingOrderIndex(of: id("c")))
        XCTAssertNil(manifest.readingOrderIndex(of: id("")))
    }

    // MARK: - Duplicate identity

    func testADuplicateIDThrowsEvenWhenTheHrefsDiffer() throws {
        let units = [
            unit("a", href: "OEBPS/chapter.xhtml"),
            unit("a", href: "OEBPS/other.xhtml")
        ]

        XCTAssertThrowsError(try DocumentManifest(readingOrder: units)) { thrown in
            XCTAssertEqual(
                thrown as? DocumentManifestError,
                DocumentManifestError.duplicateUnitID(id("a"))
            )
        }
    }

    /// The duplicate is of the **first** unit, whose stored ordinal is `0`. A
    /// check that treated `0` as "absent" — or any sentinel-based one — would let
    /// this through, so it is worth a case of its own.
    func testADuplicateOfTheFirstUnitThrows() throws {
        let units = [unit("a"), unit("b"), unit("a")]

        XCTAssertThrowsError(try DocumentManifest(readingOrder: units)) { thrown in
            XCTAssertEqual(
                thrown as? DocumentManifestError,
                DocumentManifestError.duplicateUnitID(id("a"))
            )
        }
    }

    // MARK: - Href and ID are different questions

    func testTwoUnitsMayShareAnHrefAndKeepTheirOwnIndices() throws {
        let shared = "OEBPS/chapter.xhtml"
        let manifest = try DocumentManifest(readingOrder: [
            unit("front", href: shared),
            unit("back", href: shared)
        ])

        XCTAssertEqual(manifest.readingOrderIndex(of: id("front")), 0)
        XCTAssertEqual(manifest.readingOrderIndex(of: id("back")), 1)
    }

    /// Readium resolves `chapter.xhtml#frag` and `chapter.xhtml` to the same
    /// resource. IDs do not do that: two IDs that differ by a fragment are two
    /// units, and neither collapses into the other.
    func testIDsAreNotNormalisedTheWayHrefsAre() throws {
        let plain = id("OEBPS/chapter.xhtml")
        let withFragment = id("OEBPS/chapter.xhtml#frag")

        XCTAssertNotEqual(plain, withFragment)

        let manifest = try DocumentManifest(readingOrder: [
            unit("OEBPS/chapter.xhtml"),
            unit("OEBPS/chapter.xhtml#frag")
        ])

        XCTAssertEqual(manifest.readingOrderIndex(of: plain), 0)
        XCTAssertEqual(manifest.readingOrderIndex(of: withFragment), 1)
    }

    // MARK: - The wire shape

    /// A bare JSON string, not `{ "rawValue": … }`. The conformance is declared
    /// on the type, so leaving it to synthesis would have been a choice too — one
    /// made by accident.
    func testAnIDEncodesAsABareJSONStringAndDecodesBack() throws {
        let original = id("OEBPS/chapter.xhtml#frag")

        let data = try JSONEncoder().encode(original)

        // Decoding the top level as a `String` is what proves the shape: the
        // synthesised `{ "rawValue": … }` form would refuse this and need a keyed
        // container instead. The bytes are deliberately not asserted — whether an
        // encoder escapes a slash is the encoder's business, not this type's.
        let wireValue = try JSONDecoder().decode(String.self, from: data)
        XCTAssertEqual(wireValue, original.rawValue)

        let decoded = try JSONDecoder().decode(DocumentUnitID.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Value semantics

    func testTheManifestDoesNotFollowLaterChangesToTheArrayItWasBuiltFrom() throws {
        var units = [unit("a"), unit("b")]
        let manifest = try DocumentManifest(readingOrder: units)

        units.append(unit("c"))
        units.removeFirst()

        XCTAssertEqual(manifest.readingOrder.map(\.id.rawValue), ["a", "b"])
        XCTAssertEqual(manifest.readingOrderIndex(of: id("a")), 0)
        XCTAssertEqual(manifest.readingOrderIndex(of: id("b")), 1)
        XCTAssertNil(manifest.readingOrderIndex(of: id("c")))
    }
}
