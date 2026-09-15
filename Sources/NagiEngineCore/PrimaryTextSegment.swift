/// A complete `DocumentUnit`'s own primary text — the axis that unit's UTF-16
/// offsets are measured on.
///
/// **Unit-local, not publication-global.** The stream `CONTEXT.md` describes is
/// one logical stream assembled from each unit's text in reading order, and this
/// is one unit's contribution to it. A `ContentShard` is a scheduling decision
/// and is never one of these.
///
/// **The initializer neither parses, folds nor normalises.** It is handed a
/// string that is already canonical — dropping annotations, folding whitespace
/// and reading XHTML all happen in ingest. A constructor that quietly tidied its
/// input would make "who folded this whitespace" unanswerable, and would do it
/// silently.
///
/// No `Codable`, no `Hashable`, no element tree, no styles, no ruby annotations,
/// no geometry, and no `NodeID`: none of them has a consumer here, and a
/// conformance nothing exercises is an API with no purpose.
public struct PrimaryTextSegment: Sendable {
    public let unitID: DocumentUnitID
    public let string: String

    public init(unitID: DocumentUnitID, string: String) {
        self.unitID = unitID
        self.string = string
    }

    public var utf16Count: Int {
        string.utf16.count
    }

    /// Whether an offset is a legal **storage** boundary: a position in
    /// `0...utf16Count` that does not split a surrogate pair.
    ///
    /// Negative offsets, offsets past the end and `Int.min` / `Int.max` are all
    /// `false` — this answers `false` rather than trapping.
    ///
    /// Deliberately **not** a caret, shaping-cluster or line-break boundary. A
    /// combining mark is a legal storage boundary even though no caret belongs
    /// inside one; those are policies (`TextBoundaryPolicy`), and this is the
    /// fact they are built on.
    public func isStorageBoundary(at utf16Offset: Int) -> Bool {
        let units = string.utf16

        guard utf16Offset >= 0, utf16Offset <= units.count else { return false }

        // The two ends are boundaries of anything, including an empty string.
        guard utf16Offset > 0, utf16Offset < units.count else { return true }

        let before = units[units.index(units.startIndex, offsetBy: utf16Offset - 1)]
        let after = units[units.index(units.startIndex, offsetBy: utf16Offset)]

        return !(Self.isHighSurrogate(before) && Self.isLowSurrogate(after))
    }

    /// The exact text of a UTF-16 range, or `nil` when the range is not one this
    /// segment can answer for.
    ///
    /// The range is half-open, `[lowerBound, upperBound)`. It must sit inside
    /// `0...utf16Count` and have **both** ends on legal storage boundaries. A
    /// legal empty range answers `""`; a range failing any check answers `nil`.
    ///
    /// **Order is not checked here, and that is not an omission.** A `Range<Int>`
    /// that exists at all already satisfies `lowerBound <= upperBound`: a value
    /// violating `Range`'s initializer precondition cannot be constructed, so it
    /// is outside this API's domain rather than an input this method owes an
    /// answer to. A guard for it would be unreachable — defence no input can
    /// exercise. The first CI run proved the point the hard way: a test that
    /// tried to build a reversed `Range` was killed by
    /// `Swift/Range.swift:179` *before* entering this method.
    ///
    /// Non-negativity and the upper bound **are** checked, before any slicing or
    /// offset arithmetic, because those values are perfectly constructible.
    ///
    /// Half a surrogate is `nil`, never a replacement character: `U+FFFD` would
    /// be a well-formed string that is quietly the wrong text, which is worse
    /// than no answer at all.
    public func text(inUTF16 range: Range<Int>) -> String? {
        guard range.lowerBound >= 0 else { return nil }
        guard range.upperBound <= utf16Count else { return nil }
        guard isStorageBoundary(at: range.lowerBound),
              isStorageBoundary(at: range.upperBound) else { return nil }

        let units = string.utf16
        let start = units.index(units.startIndex, offsetBy: range.lowerBound)
        let end = units.index(units.startIndex, offsetBy: range.upperBound)

        // Both ends are storage boundaries, so this slice is well formed and the
        // decoding cannot introduce a replacement character.
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    private static func isHighSurrogate(_ unit: UInt16) -> Bool {
        (0xD800...0xDBFF).contains(unit)
    }

    private static func isLowSurrogate(_ unit: UInt16) -> Bool {
        (0xDC00...0xDFFF).contains(unit)
    }
}
