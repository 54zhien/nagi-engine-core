import Foundation

/// The identity of an element inside a unit.
///
/// Opaque here: this module neither composes a `NodeID` nor looks inside one. It
/// is constructed from outside — by whatever ingest does — compared with Swift's
/// own string equality, and encoded as a bare JSON string.
///
/// **No normalisation.** Nothing folds case, trims, decodes percent escapes or
/// applies the href rules: those belong to routing, and an href is not an
/// identity. Equally, equality here is `String`'s equality and **not** a promise
/// of byte comparison — Swift may hold two canonically equivalent sequences
/// equal, and that is the string's own layer, not something this type redefines.
///
/// A `NodeID` answers *which element*, never *where in the document*. Ordering is
/// the offset's business and the manifest's.
public struct NodeID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    // MARK: - Codable, single value on purpose

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A precise coordinate inside Nagi's own layout: a unit, an element in it, and
/// an offset into that unit's canonical primary text.
///
/// All three fields are public and none is derived. Drop the node id and a
/// re-parse can only re-derive the position by offset, which shifts the moment
/// any text before it changes; drop the offset and a position can only name a
/// block.
///
/// **No `documentOrder` field, and no `Comparable`.** Order is a function of the
/// document rather than a constant the position carries, and the synthesised
/// equality includes the node id — so a `<` that ignored it would report
/// `a != b` while neither `a < b` nor `b < a` held. Ordering goes through
/// `DocumentManifest.compareInDocumentOrder(_:_:)` and nowhere else.
///
/// The initializer does not validate `utf16Offset`: legality is
/// `PositionResolver`'s question, and validating here would force a manifest that
/// deliberately carries no text to know every unit's length.
public struct NativePosition: Codable, Hashable, Sendable {
    public let unitID: DocumentUnitID
    public let nodeID: NodeID
    public let utf16Offset: Int

    public init(unitID: DocumentUnitID, nodeID: NodeID, utf16Offset: Int) {
        self.unitID = unitID
        self.nodeID = nodeID
        self.utf16Offset = utf16Offset
    }
}

/// Where a position sits in a document.
///
/// `(unitIndex, utf16Offset)` — the unit's index in the manifest reading order,
/// then the absolute offset inside that unit's canonical primary text.
///
/// **Internal, and not `Codable`, on purpose.** A key is only meaningful inside
/// the immutable manifest snapshot that produced it: the same `(3, 20)` in two
/// different manifests, or in one manifest before and after a reorder, is not the
/// same key. Nothing here crosses this module's boundary, so the manifest-scope
/// identity a public key would need is not required — and if one is ever exposed,
/// the bare pair is not enough to carry it.
///
/// The comparison is lexicographic: unit index first, offset second.
struct DocumentOrderKey: Hashable, Comparable, Sendable {
    let unitIndex: Int
    let utf16Offset: Int

    static func < (lhs: DocumentOrderKey, rhs: DocumentOrderKey) -> Bool {
        if lhs.unitIndex != rhs.unitIndex {
            return lhs.unitIndex < rhs.unitIndex
        }
        return lhs.utf16Offset < rhs.utf16Offset
    }
}

/// The result of comparing two positions.
///
/// Three values rather than a `<`, because the middle one is the reason: two
/// positions in one unit at one offset are **the same text coordinate**, not two
/// positions needing a stable order between them. A `Comparable` on
/// `NativePosition` could not say that — its equality includes the node id, so
/// positions differing only by node id would compare unequal while neither `<`
/// direction held.
///
/// Not `Codable` and not `Comparable`: this is the result of a comparison, not
/// something to store, and not a coordinate that can be ordered again.
public enum DocumentOrderComparison: Equatable, Sendable {
    case before
    case sameCoordinate
    case after
}

extension DocumentManifest {
    /// The order key for a position in this manifest, or `nil` when the ID names
    /// no unit here.
    ///
    /// `nil` is a defined answer — an ID that is not in this manifest has no
    /// position, so it has no key. It does not mean "last", and it is not a
    /// failure.
    ///
    /// The offset is deliberately **not** validated. A negative or
    /// past-the-end offset still forms a key: legality is `PositionResolver`'s
    /// question, while validating here would force a manifest that carries no
    /// text to know every unit's length.
    func orderKey(of unitID: DocumentUnitID, at utf16Offset: Int) -> DocumentOrderKey? {
        guard let unitIndex = readingOrderIndex(of: unitID) else { return nil }
        return DocumentOrderKey(unitIndex: unitIndex, utf16Offset: utf16Offset)
    }

    /// How `lhs` and `rhs` sit relative to each other in this document, or `nil`
    /// when either names a unit this manifest does not have.
    ///
    /// `nil` is an answer, not a failure: a position whose unit is not here has
    /// no order — not "last", not "equal", and not an error. Two positions that
    /// would be the same coordinate in some other document get `nil` too, because
    /// this is not that document.
    ///
    /// Within one unit the offset decides, and a differing `NodeID` does not
    /// break the tie: the node id answers which element, and the question here is
    /// where in the text. Across units the manifest's reading order decides — so
    /// reordering the manifest reorders the answers, which is correct: order is a
    /// function of the document, not a property of the position.
    public func compareInDocumentOrder(
        _ lhs: NativePosition,
        _ rhs: NativePosition
    ) -> DocumentOrderComparison? {
        guard let left = orderKey(of: lhs.unitID, at: lhs.utf16Offset),
              let right = orderKey(of: rhs.unitID, at: rhs.utf16Offset) else {
            return nil
        }

        if left == right {
            return .sameCoordinate
        }
        return left < right ? .before : .after
    }
}
