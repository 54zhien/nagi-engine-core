import Foundation

/// The identity of one `DocumentUnit` within a manifest.
///
/// Identity is a bare string compared by Swift's own `String` equality. It is
/// **not** an href, and the two must not be normalised the same way: hrefs are
/// routing information, compared the way Readium compares them (normalised, then
/// with query and fragment stripped), while two IDs differing by a fragment are
/// two different units. Keeping those two comparisons apart is why this is a
/// distinct type rather than a `String`.
///
/// `Codable` is written out by hand below, as a **single value**: an identity
/// encodes as a bare JSON string. Declaring the conformance is already a decision
/// about the wire shape — and the synthesised form, the keyed
/// `{ "rawValue": … }`, would be the encoding of a record that happens to hold a
/// string rather than of an identity.
public struct DocumentUnitID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One content unit: an independently addressable piece of the publication, in
/// reading order. `CONTEXT.md` calls this the **identity domain** — a shard is a
/// scheduling decision and must never appear in a position.
///
/// No text, no length, no canonical form. The manifest is the light inventory;
/// `Document Store` materialises content by position. A length here would be a
/// second source of truth about text this type does not hold.
public struct DocumentUnit: Codable, Hashable, Sendable {
    /// Unique within the manifest that holds it. Enforced there, not here — a
    /// unit cannot see its siblings.
    public let id: DocumentUnitID

    /// Where the content is fetched from. Routing information, **not** identity:
    /// two units may share an href and remain two units.
    public let href: String

    public let mediaType: String

    public init(id: DocumentUnitID, href: String, mediaType: String) {
        self.id = id
        self.href = href
        self.mediaType = mediaType
    }
}

/// The one way constructing a manifest can fail.
public enum DocumentManifestError: Error, Equatable, Sendable {
    /// Two units in the same reading order carried the same `DocumentUnitID`.
    /// The payload is the ID that repeated.
    case duplicateUnitID(DocumentUnitID)
}

/// A book's light inventory: its units, in publication reading order.
///
/// Immutable and safe to pass across threads. Holds no content and cannot reach
/// any — see `DocumentUnit`.
///
/// Deliberately **not** `Codable`, and deliberately without an `href` lookup: the
/// serialised shape and the routing lookup each belong to a consumer that does
/// not exist yet, and guessing either now would fix a shape nobody has asked a
/// question about.
public struct DocumentManifest: Sendable {
    /// The units, in publication reading order. Read-only because the index
    /// below is built once, at construction; a mutable array would silently
    /// invalidate it.
    public let readingOrder: [DocumentUnit]

    /// The ordinal, built in one pass at construction rather than re-derived per
    /// lookup. Private: exposing it would invite callers to depend on the
    /// container rather than on the question it answers.
    private let readingOrderIndices: [DocumentUnitID: Int]

    /// Builds the manifest, or refuses to.
    ///
    /// - Throws: `DocumentManifestError.duplicateUnitID` at the first repeated
    ///   ID. There is no last-one-wins and no first-one-wins: a manifest whose
    ///   ordering key is ambiguous is not a manifest, and the failure is the
    ///   point.
    public init(readingOrder: [DocumentUnit]) throws {
        var indices: [DocumentUnitID: Int] = [:]
        indices.reserveCapacity(readingOrder.count)

        for (index, unit) in readingOrder.enumerated() {
            // Tested against `nil`, not against a sentinel value: index 0 is a
            // legitimate stored value, so any check that treats it as "absent"
            // would let a duplicate of the first unit through.
            if indices[unit.id] != nil {
                throw DocumentManifestError.duplicateUnitID(unit.id)
            }
            indices[unit.id] = index
        }

        self.readingOrder = readingOrder
        self.readingOrderIndices = indices
    }

    /// The unit's zero-based position in `readingOrder`, or `nil` when no unit
    /// carries that ID.
    ///
    /// `nil` is a defined answer rather than a fallback. An ID that is not in
    /// this manifest has no position; it does not mean "last", and it does not
    /// mean the lookup failed.
    public func readingOrderIndex(of unitID: DocumentUnitID) -> Int? {
        readingOrderIndices[unitID]
    }
}
