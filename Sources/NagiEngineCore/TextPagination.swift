/// One candidate line, as a backend measured it.
///
/// **A candidate, not a page boundary.** The backend says how much text this
/// line consumed and how tall it naturally is; where pages end is decided
/// elsewhere. E3 accepts the candidate as it stands once it passes the
/// structural checks — no kinsoku adjustment, no 追い込み / 追い出し.
///
/// Not `Codable`, not `Hashable`, not persisted, and only interpretable inside
/// the session and segment that produced it: an offset means nothing once it
/// leaves that text.
public struct LineMeasurement: Equatable, Sendable {
    /// The UTF-16 range this line consumed, in the segment's own coordinates.
    public let consumedUTF16Range: Range<Int>

    /// The line's natural block-axis extent — `ascent + descent + leading` as
    /// `CTLine` reports them. `lineSpacing` is **not** part of it; spacing is a
    /// constraint added between adjacent lines on one page.
    public let naturalBlockExtent: Double

    public init(consumedUTF16Range: Range<Int>, naturalBlockExtent: Double) {
        self.consumedUTF16Range = consumedUTF16Range
        self.naturalBlockExtent = naturalBlockExtent
    }
}

/// A backend's line-breaking session for one segment.
///
/// The semantic contract is that `suggestLine` returns a candidate for the
/// requested offset under the given inline extent. The paginator can only check
/// the *structure* of what comes back — it cannot re-do shaping or measure
/// width, which is the whole reason this sits behind a backend.
public protocol LineBreakSession {
    /// The next candidate beginning at `fromUTF16Offset`, or `nil` when the
    /// backend has nothing to offer.
    ///
    /// `nil` is only ever acceptable where the paginator does not call it: the
    /// loop stops at the end of the segment, so a `nil` from a real call is a
    /// stall.
    func suggestLine(fromUTF16Offset: Int, inlineExtent: Double) throws -> LineMeasurement?
}

/// A source of line-breaking sessions.
public protocol LineBreakBackend {
    associatedtype Session: LineBreakSession

    func makeSession(for segment: PrimaryTextSegment) throws -> Session
}

/// What one pagination request needs to know about the page it is filling.
public struct TextPaginationConstraints: Equatable, Sendable {
    /// The horizontal room one line may occupy. Must be finite and `> 0`.
    public let inlineExtent: Double

    /// The vertical room one page may occupy. Must be finite and `> 0`.
    ///
    /// It bounds the **page**, not the line: a single line whose natural extent
    /// exceeds it is legal and occupies a page alone.
    public let blockExtent: Double

    /// Extra space added between adjacent lines on one page. Must be finite and
    /// `>= 0`; zero is legal. Not counted across a page break.
    public let lineSpacing: Double

    public init(inlineExtent: Double, blockExtent: Double, lineSpacing: Double) {
        self.inlineExtent = inlineExtent
        self.blockExtent = blockExtent
        self.lineSpacing = lineSpacing
    }
}

/// The page ranges of one complete unit under one set of constraints.
///
/// Ordered, unit-local, half-open, and seamless: together the ranges cover the
/// whole segment with no gaps and no overlaps. Pages do not cross units.
///
/// **Transient, and only meaningful for the call that produced it.** It carries
/// no `LayoutSignature` and no generation, so two coincidentally equal values
/// are not the same layout identity — a future `PageMap` must establish its own.
/// Not `Codable`, not `Hashable`, not persisted.
///
/// The initializer is internal: the invariant above is load-bearing, and
/// `internal` is what keeps construction out of other modules. Within this
/// module the constructor is trusted, and any new producer must preserve the
/// same invariant.
public struct UnitPageRanges: Equatable, Sendable {
    public let unitID: DocumentUnitID
    public let utf16Ranges: [Range<Int>]

    init(unitID: DocumentUnitID, utf16Ranges: [Range<Int>]) {
        self.unitID = unitID
        self.utf16Ranges = utf16Ranges
    }
}

/// What the paginator itself rejects.
///
/// **Only what this layer discovers.** Errors thrown by `makeSession` or
/// `suggestLine` are backend-specific and propagate unchanged — they are not
/// squeezed in here, which is also why this stays an ordinary `throws` and not
/// a typed one.
///
/// No case carries a `Double`: the value that trips `invalidNaturalBlockExtent`
/// is usually NaN, and `NaN != NaN`, so an `Equatable` enum holding it would not
/// be reflexive.
public enum TextPaginationError: Error, Equatable, Sendable {
    case invalidInlineExtent
    case invalidBlockExtent
    case invalidLineSpacing
    case backendStalled(atUTF16Offset: Int)
    case rangeDiscontinuity(expectedUTF16Offset: Int, foundUTF16Offset: Int)
    case nonAdvancingRange(atUTF16Offset: Int)
    case rangeOutOfBounds(Range<Int>)
    case rangeNotOnStorageBoundary(Range<Int>)
    case invalidNaturalBlockExtent(atUTF16Offset: Int)
}

/// Turns candidate lines into page ranges.
public enum TextPaginator {

    /// Paginates one segment.
    ///
    /// The order of operations is part of the contract:
    ///
    /// 1. the three constraints are validated first, so an invalid constraint is
    ///    reported even when the segment is empty;
    /// 2. an empty segment returns no ranges **without making a session** —
    ///    this is a text-only slice and does not invent a blank page;
    /// 3. only then is a session made;
    /// 4. candidates are requested while `currentOffset < utf16Count`;
    /// 5. reaching the end finishes, without a further call to confirm `nil`.
    ///
    /// Because of 4 and 5, any `nil` returned by a call that actually happened
    /// is a stall — there is no "the last one may be nil" case to remember.
    public static func paginate<Backend: LineBreakBackend>(
        segment: PrimaryTextSegment,
        constraints: TextPaginationConstraints,
        backend: Backend
    ) throws -> UnitPageRanges {
        guard constraints.inlineExtent.isFinite, constraints.inlineExtent > 0 else {
            throw TextPaginationError.invalidInlineExtent
        }
        guard constraints.blockExtent.isFinite, constraints.blockExtent > 0 else {
            throw TextPaginationError.invalidBlockExtent
        }
        guard constraints.lineSpacing.isFinite, constraints.lineSpacing >= 0 else {
            throw TextPaginationError.invalidLineSpacing
        }

        let total = segment.utf16Count
        if total == 0 {
            return UnitPageRanges(unitID: segment.unitID, utf16Ranges: [])
        }

        let session = try backend.makeSession(for: segment)

        var lines: [LineMeasurement] = []
        var currentOffset = 0

        while currentOffset < total {
            guard let measurement = try session.suggestLine(
                fromUTF16Offset: currentOffset,
                inlineExtent: constraints.inlineExtent
            ) else {
                throw TextPaginationError.backendStalled(atUTF16Offset: currentOffset)
            }

            try validate(
                measurement,
                requestedOffset: currentOffset,
                total: total,
                segment: segment
            )

            lines.append(measurement)
            currentOffset = measurement.consumedUTF16Range.upperBound
        }

        return UnitPageRanges(
            unitID: segment.unitID,
            utf16Ranges: pageRanges(of: lines, constraints: constraints)
        )
    }

    /// Checks one candidate, in the order the ADR fixes.
    ///
    /// The order matters twice over: bounds first so nothing downstream indexes
    /// with an out-of-range value, and each later check assumes the earlier ones
    /// already held, so a bad candidate is classified as the thing that is
    /// actually wrong with it rather than as whichever check happens to run
    /// first.
    private static func validate(
        _ measurement: LineMeasurement,
        requestedOffset: Int,
        total: Int,
        segment: PrimaryTextSegment
    ) throws {
        let range = measurement.consumedUTF16Range

        guard range.lowerBound >= 0, range.upperBound <= total else {
            throw TextPaginationError.rangeOutOfBounds(range)
        }
        guard range.lowerBound == requestedOffset else {
            throw TextPaginationError.rangeDiscontinuity(
                expectedUTF16Offset: requestedOffset,
                foundUTF16Offset: range.lowerBound
            )
        }
        guard range.upperBound > range.lowerBound else {
            throw TextPaginationError.nonAdvancingRange(atUTF16Offset: requestedOffset)
        }
        guard segment.isStorageBoundary(at: range.lowerBound),
              segment.isStorageBoundary(at: range.upperBound) else {
            throw TextPaginationError.rangeNotOnStorageBoundary(range)
        }
        guard measurement.naturalBlockExtent.isFinite,
              measurement.naturalBlockExtent > 0 else {
            throw TextPaginationError.invalidNaturalBlockExtent(atUTF16Offset: requestedOffset)
        }
    }

    /// Greedy page grouping.
    ///
    /// A page's occupancy is its lines' natural extents plus one `lineSpacing`
    /// between each pair of *adjacent* lines on it — `n` lines carry `n - 1`
    /// gaps, and nothing is carried across a break. A line that would overflow
    /// starts the next page; an exact fit stays; a line taller than the page
    /// occupies a page alone, which is what keeps the loop moving rather than an
    /// error case.
    private static func pageRanges(
        of lines: [LineMeasurement],
        constraints: TextPaginationConstraints
    ) -> [Range<Int>] {
        guard let first = lines.first else { return [] }

        var ranges: [Range<Int>] = []
        var pageStart = first.consumedUTF16Range.lowerBound
        var pageEnd = first.consumedUTF16Range.upperBound
        var occupied = first.naturalBlockExtent

        for line in lines.dropFirst() {
            let withSpacing = occupied + constraints.lineSpacing + line.naturalBlockExtent

            if withSpacing <= constraints.blockExtent {
                occupied = withSpacing
                pageEnd = line.consumedUTF16Range.upperBound
            } else {
                ranges.append(pageStart..<pageEnd)
                pageStart = line.consumedUTF16Range.lowerBound
                pageEnd = line.consumedUTF16Range.upperBound
                occupied = line.naturalBlockExtent
            }
        }

        ranges.append(pageStart..<pageEnd)
        return ranges
    }
}
