/// Where a position sits in a document.
///
/// `(unitIndex, utf16Offset)` — the unit's index in the manifest reading order,
/// then the absolute UTF-16 offset inside that unit's canonical primary text.
/// Both halves are obtainable from a position together with the manifest it was
/// resolved against; neither is stored on the position itself, and materialising
/// text is not needed to form one.
///
/// **Internal, and not `Codable`, on purpose.** A key is only meaningful inside
/// the immutable manifest snapshot that produced it: the same `(3, 20)` in two
/// different manifests, or in one manifest before and after a reorder, is not
/// the same key. Nothing here crosses this module's boundary, so the
/// manifest-scope identity that a public key would need is not required — and if
/// one is ever exposed, the bare pair is not enough to carry it.
///
/// The comparison is lexicographic: unit index first, offset second. Inside one
/// unit the first component is equal for every key and the comparison reduces to
/// the offset. That is the two-layer structure, not a redundant field — the unit
/// layer has already been answered by whoever selected the unit, and folding it
/// back into each comparison would be the same fact stated twice.
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
    /// question and containment is `PageMap`'s, while validating here would
    /// force a manifest that carries no text to know every unit's length — the
    /// materialisation dependency this design exists to avoid.
    func orderKey(of unitID: DocumentUnitID, at utf16Offset: Int) -> DocumentOrderKey? {
        guard let unitIndex = readingOrderIndex(of: unitID) else { return nil }
        return DocumentOrderKey(unitIndex: unitIndex, utf16Offset: utf16Offset)
    }
}
