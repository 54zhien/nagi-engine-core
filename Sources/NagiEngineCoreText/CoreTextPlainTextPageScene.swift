import CoreGraphics
import CoreText
import Foundation

import NagiEngineCore

/// What the page-scene layer refuses before it publishes a value.
///
/// Module-internal on purpose: the public factory throws an ordinary error and
/// this stays an implementation detail, so the public error surface does not
/// grow. It is `Equatable` so a test can name the reason instead of matching on
/// a string.
///
/// No case carries a `Double`, for the same reason `TextPaginationError` and
/// `CoreTextLineBreakError` carry none: the value that would arrive is usually
/// NaN, and an enum holding NaN is not reflexive.
enum CoreTextPageSceneError: Error, Equatable {
    /// A retained line's own string range is not the range that was accepted.
    case artifactStringRangeMismatch(atIndex: Int)

    /// A retained line's metrics are not finite numbers.
    case artifactMetricsNotFinite(atIndex: Int)

    /// A retained line's typographic width is negative.
    case artifactWidthNegative(atIndex: Int)

    /// A retained line consumed an empty range.
    case artifactRangeEmpty(atIndex: Int)

    /// A retained line's natural block extent is not the sum of its own
    /// `ascent`, `descent` and `leading`.
    ///
    /// The paginator grouped pages by that number, and the scene places lines by
    /// it too; if it were not the sum, those would be two different truths.
    case artifactNaturalExtentMismatch(atIndex: Int)

    /// A retained line does not begin where the previous one ended: a line was
    /// lost, duplicated or reordered.
    case artifactNotContiguous(atIndex: Int, expectedUTF16Offset: Int, foundUTF16Offset: Int)

    /// The retained lines do not cover the whole segment.
    case artifactCoverageIncomplete(expectedUTF16Count: Int, foundUTF16Count: Int)

    /// A page's range cannot be tiled by whole lines — the boundary falls inside
    /// one.
    case pageRangeSplitsALine(pageIndex: Int)

    /// Lines are left over once the last page has been filled.
    case artifactsBeyondLastPage(count: Int)

    /// The page ranges belong to a different unit than the segment.
    case pageRangesUnitMismatch(expected: DocumentUnitID, found: DocumentUnitID)

    /// An empty segment came back with something other than "no session, no
    /// ranges".
    case emptySegmentInconsistent(makeSessionCallCount: Int, madeASession: Bool, pageCount: Int)

    /// A non-empty segment came back without exactly one session.
    case nonEmptySegmentInconsistent(makeSessionCallCount: Int, madeASession: Bool)
}

/// The two arithmetic rules hit testing follows, on their own.
///
/// Module-internal and pure, so their ends can be exercised directly instead of
/// only through whatever a real font happens to measure: a line of zero width,
/// the index one past the end, and the "not found" answer all live here. The
/// scene's hit testing calls these rather than repeating them, so the rule that
/// is tested is the rule that runs.
enum CoreTextHitRules {

    /// The advance test, **closed at both ends**.
    ///
    /// The end-of-line insertion point sits at exactly the width, so only what
    /// is past the width is blank. A line of zero width is not excluded here:
    /// what such a line can produce is settled by CoreText and by the storage
    /// boundary, not by its width.
    static func acceptsAdvance(x: CGFloat, typographicWidth: CGFloat) -> Bool {
        x >= 0 && x <= typographicWidth
    }

    /// The index test, against the line's consumed range, **closed at both
    /// ends**: the index one past the end is a legal insertion point, so it is
    /// accepted here. The "not found" answer (−1) and anything past the line
    /// fall out.
    static func acceptsIndex(_ index: Int, consumed: Range<Int>) -> Bool {
        index >= consumed.lowerBound && index <= consumed.upperBound
    }
}

/// The one shape a successful pagination call can have.
///
/// Module-internal and pure, so the combinations that must be refused can be
/// handed to it directly: no arrangement of the real thing would produce them,
/// and "the core is assumed to behave" is exactly the assumption worth testing.
enum CoreTextPaginationInvariant {

    /// Checks the call by **segment length**, not by an empty range list.
    ///
    /// An empty segment must come back with no session call at all and no
    /// ranges; a non-empty one must come back with exactly one session. Anything
    /// else is an internal inconsistency, not a legitimate empty result.
    static func validate(
        segment: PrimaryTextSegment,
        makeSessionCallCount: Int,
        madeASession: Bool,
        pageRanges: UnitPageRanges
    ) throws {
        guard pageRanges.unitID == segment.unitID else {
            throw CoreTextPageSceneError.pageRangesUnitMismatch(
                expected: segment.unitID,
                found: pageRanges.unitID
            )
        }

        if segment.utf16Count == 0 {
            guard makeSessionCallCount == 0,
                  !madeASession,
                  pageRanges.utf16Ranges.isEmpty else {
                throw CoreTextPageSceneError.emptySegmentInconsistent(
                    makeSessionCallCount: makeSessionCallCount,
                    madeASession: madeASession,
                    pageCount: pageRanges.utf16Ranges.count
                )
            }
        } else {
            guard makeSessionCallCount == 1, madeASession else {
                throw CoreTextPageSceneError.nonEmptySegmentInconsistent(
                    makeSessionCallCount: makeSessionCallCount,
                    madeASession: madeASession
                )
            }
        }
    }
}

/// One line as it sits on a page.
///
/// Module-internal: the page's geometry, in the page's own coordinates.
struct CoreTextPlacedLine {
    /// The line and the measurement the session returned for it.
    let artifact: CoreTextLineArtifact

    /// The top of this line's band, in page-local coordinates.
    let top: CGFloat

    /// Where this line's baseline sits, in page-local coordinates.
    let baseline: CGFloat
}

/// Validates the lines a pagination call retained, then groups them into pages.
///
/// Module-internal. Every number a scene's geometry and hit testing will use is
/// checked here first: a scene is never built on an unverified measurement, and
/// a mismatched pairing of page ranges and lines is refused rather than drawn.
enum CoreTextPageSceneBuilder {

    /// Validates, groups, and places.
    ///
    /// The lines come from the session the core made during this very call, and
    /// the ranges come back from that same call, so the two are expected to
    /// agree exactly. They are checked rather than assumed: a gap, a repeat, a
    /// reordering, or a page boundary that falls inside a line all mean the two
    /// no longer describe the same pagination, and none of them is something a
    /// scene could honestly draw.
    static func buildScenes(
        artifacts: [CoreTextLineArtifact],
        pageRanges: UnitPageRanges,
        segment: PrimaryTextSegment,
        nodeID: NodeID,
        constraints: TextPaginationConstraints
    ) throws -> [CoreTextPlainTextPageScene] {
        try validate(artifacts: artifacts, segment: segment)

        let pageSize = CGSize(
            width: CGFloat(constraints.inlineExtent),
            height: CGFloat(constraints.blockExtent)
        )
        let spacing = CGFloat(constraints.lineSpacing)

        var scenes: [CoreTextPlainTextPageScene] = []
        var next = 0

        for (pageIndex, range) in pageRanges.utf16Ranges.enumerated() {
            // The page's first line has to start exactly where the page starts.
            // A line beginning later would leave the page's opening unaccounted
            // for; one beginning earlier means the boundary fell inside a line.
            guard next < artifacts.count,
                  artifacts[next].measurement.consumedUTF16Range.lowerBound == range.lowerBound else {
                throw CoreTextPageSceneError.pageRangeSplitsALine(pageIndex: pageIndex)
            }

            var placed: [CoreTextPlacedLine] = []
            var top: CGFloat = 0

            while next < artifacts.count {
                let artifact = artifacts[next]

                // A line that reaches past this page cannot belong to it.
                guard artifact.measurement.consumedUTF16Range.upperBound <= range.upperBound else {
                    break
                }

                // `lineSpacing` is added between adjacent lines on one page, and
                // never carried across a break: n lines on a page get n - 1 gaps.
                if !placed.isEmpty {
                    top += spacing
                }
                placed.append(
                    CoreTextPlacedLine(
                        artifact: artifact,
                        top: top,
                        baseline: top + artifact.ascent
                    )
                )

                // The same number the paginator grouped pages by, so the page's
                // geometry and the core's judgement cannot drift apart.
                top += CGFloat(artifact.measurement.naturalBlockExtent)
                next += 1
            }

            // The page has to end exactly where a line ends, or the ranges and
            // the lines are not describing the same pagination any more.
            guard let last = placed.last,
                  last.artifact.measurement.consumedUTF16Range.upperBound == range.upperBound else {
                throw CoreTextPageSceneError.pageRangeSplitsALine(pageIndex: pageIndex)
            }

            scenes.append(
                CoreTextPlainTextPageScene(
                    unitID: segment.unitID,
                    nodeID: nodeID,
                    pageIndex: pageIndex,
                    utf16Range: range,
                    size: pageSize,
                    lines: placed,
                    segment: segment
                )
            )
        }

        guard next == artifacts.count else {
            throw CoreTextPageSceneError.artifactsBeyondLastPage(
                count: artifacts.count - next
            )
        }

        return scenes
    }

    /// The per-line and whole-run checks.
    ///
    /// The page partition is checked where the grouping happens, so that the
    /// decision and the check are the same piece of code.
    private static func validate(
        artifacts: [CoreTextLineArtifact],
        segment: PrimaryTextSegment
    ) throws {
        for (index, artifact) in artifacts.enumerated() {
            let consumed = artifact.measurement.consumedUTF16Range

            // The `CTLine` must be over the very range that was accepted. This
            // is what catches a line kept beside the wrong measurement.
            let lineRange = CTLineGetStringRange(artifact.line)
            guard lineRange.location == consumed.lowerBound,
                  lineRange.length == consumed.count else {
                throw CoreTextPageSceneError.artifactStringRangeMismatch(atIndex: index)
            }

            guard artifact.ascent.isFinite,
                  artifact.descent.isFinite,
                  artifact.leading.isFinite,
                  artifact.typographicWidth.isFinite,
                  artifact.measurement.naturalBlockExtent.isFinite else {
                throw CoreTextPageSceneError.artifactMetricsNotFinite(atIndex: index)
            }

            guard artifact.typographicWidth >= 0 else {
                throw CoreTextPageSceneError.artifactWidthNegative(atIndex: index)
            }

            guard consumed.upperBound > consumed.lowerBound else {
                throw CoreTextPageSceneError.artifactRangeEmpty(atIndex: index)
            }

            // Exactly the sum, not merely close to it: the scene advances a
            // page by this number, and the paginator grouped pages by it. Two
            // slightly different numbers would be two truths about one page.
            guard artifact.measurement.naturalBlockExtent
                    == Double(artifact.ascent + artifact.descent + artifact.leading) else {
                throw CoreTextPageSceneError.artifactNaturalExtentMismatch(atIndex: index)
            }
        }

        // One line per measurement, in the order they were suggested, with no
        // gap and no overlap, covering the segment exactly.
        var expected = 0
        for (index, artifact) in artifacts.enumerated() {
            let consumed = artifact.measurement.consumedUTF16Range
            guard consumed.lowerBound == expected else {
                throw CoreTextPageSceneError.artifactNotContiguous(
                    atIndex: index,
                    expectedUTF16Offset: expected,
                    foundUTF16Offset: consumed.lowerBound
                )
            }
            expected = consumed.upperBound
        }

        guard expected == segment.utf16Count else {
            throw CoreTextPageSceneError.artifactCoverageIncomplete(
                expectedUTF16Count: segment.utf16Count,
                foundUTF16Count: expected
            )
        }
    }
}

/// One page of a paginated plain-text segment, as geometry.
///
/// Transient, like the value that produced it: it belongs to one pagination of
/// one segment, carries no layout identity, and is not comparable across layout
/// runs. It is not `Codable`, not `Hashable` and not `Sendable` — it holds
/// `CTLine`s, which carry no documented thread-safety guarantee.
///
/// Its coordinates are page-local: the origin is the page's top-left corner, x
/// grows right and y grows down. Every line's band and baseline live in those
/// coordinates, and hit testing reports positions in them, so what is drawn and
/// what is clicked cannot drift apart.
public struct CoreTextPlainTextPageScene {
    /// The unit this page belongs to.
    public let unitID: DocumentUnitID

    /// The injected node identity. It answers *which element*, and takes no part
    /// in geometry or line breaking.
    public let nodeID: NodeID

    /// This page's index within its own pagination. An output, not an identity.
    public let pageIndex: Int

    /// The page's half-open range in the segment's own coordinates.
    public let utf16Range: Range<Int>

    /// The page's size: the inline and block extents it was paginated under.
    public let size: CGSize

    /// How many lines this page holds.
    public let lineCount: Int

    /// The lines on this page, in page-local coordinates.
    let lines: [CoreTextPlacedLine]

    /// The text this page's positions are stated in.
    private let segment: PrimaryTextSegment

    init(
        unitID: DocumentUnitID,
        nodeID: NodeID,
        pageIndex: Int,
        utf16Range: Range<Int>,
        size: CGSize,
        lines: [CoreTextPlacedLine],
        segment: PrimaryTextSegment
    ) {
        self.unitID = unitID
        self.nodeID = nodeID
        self.pageIndex = pageIndex
        self.utf16Range = utf16Range
        self.size = size
        self.lineCount = lines.count
        self.lines = lines
        self.segment = segment
    }

    /// Draws the page's glyphs into `context`.
    ///
    /// The caller's user space must already put `(0, 0)` at the page's top-left
    /// corner, with x growing right and y growing down; placing the page on some
    /// larger canvas is the caller's business, not this method's. Everything
    /// here happens inside `(0, 0, size.width, size.height)`.
    ///
    /// No background is filled, and the drawing mode is set to fill explicitly
    /// rather than inherited: a caller that left a stroke or clip mode behind
    /// would otherwise change what this draws. The graphics state is saved and
    /// restored, so nothing leaks back.
    ///
    /// The foreground colour comes from the caller and is applied as the
    /// context's fill colour — the session fixed
    /// `kCTForegroundColorFromContextAttributeName` when it shaped the text, so
    /// changing it here rebuilds nothing and moves no measurement.
    public func draw(in context: CGContext, foregroundColor: CGColor) {
        context.saveGState()
        defer { context.restoreGState() }

        context.clip(to: CGRect(origin: .zero, size: size))
        context.setFillColor(foregroundColor)
        context.setTextDrawingMode(.fill)

        // The page's space is y-down and CoreText's text space is y-up, so the
        // flip is applied once, here, and undone by the restore above. The
        // caller only ever sees the page's own coordinates.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        for line in lines {
            context.textPosition = CGPoint(x: 0, y: line.baseline)
            CTLineDraw(line.artifact.line, context)
        }
    }

    /// The position for a point on this page, or `nil`.
    ///
    /// Synchronous, with no I/O, no `async` and no document materialisation:
    /// everything this needs is already on the page.
    ///
    /// `nil` is the answer for a point that is not finite, one outside the
    /// page's closed bounds, one in the `lineSpacing` gap between two lines, one
    /// to the right of a short line's advance, one whose index falls outside
    /// that line's consumed range, and one whose index is not a legal storage
    /// boundary in the segment. An index CoreText cannot place at all — the
    /// "not found" answer, −1 — is turned away by the same range check.
    ///
    /// This is not a `PositionResolver`: it says nothing about selection across
    /// pages, caret affinity, link or image hits, or accessibility. A corpus with
    /// combining marks is used only to show that no caret policy of our own is
    /// being invented here.
    public func nativePosition(at point: CGPoint) -> NativePosition? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        guard point.x >= 0, point.x <= size.width,
              point.y >= 0, point.y <= size.height else { return nil }

        for line in lines {
            let extent = CGFloat(line.artifact.measurement.naturalBlockExtent)

            // The band is half-open: adjacent bands share an edge when there is
            // no spacing, and a point on that edge belongs to exactly one line.
            guard point.y >= line.top, point.y < line.top + extent else { continue }

            guard CoreTextHitRules.acceptsAdvance(
                x: point.x,
                typographicWidth: line.artifact.typographicWidth
            ) else { return nil }

            // Relative to the line's own origin: the left edge of the page at
            // this line's baseline.
            let relative = CGPoint(x: point.x, y: line.baseline - point.y)
            let index = CTLineGetStringIndexForPosition(line.artifact.line, relative)
            let consumed = line.artifact.measurement.consumedUTF16Range

            guard CoreTextHitRules.acceptsIndex(index, consumed: consumed) else { return nil }
            guard segment.isStorageBoundary(at: index) else { return nil }

            return NativePosition(unitID: unitID, nodeID: nodeID, utf16Offset: index)
        }

        return nil
    }
}

/// One complete segment, paginated, with the lines kept so its pages can be
/// drawn and hit-tested.
///
/// Transient: it is one pagination of one segment, it carries no layout
/// signature and no generation, and two values with equal ranges are not the
/// same layout identity. Change the font, the language tag, or any of the three
/// constraints, and the host must discard it and its scenes and build again. It
/// is not `Codable`, not `Hashable` and not `Sendable`.
///
/// There is no public initializer, and in particular none taking an arbitrary
/// `UnitPageRanges`: the ranges and the lines are only ever paired by
/// `makePaginatedPlainText`, which takes both from one call on one session.
public struct CoreTextPaginatedPlainText {
    /// The injected node identity, reported by every position this value yields.
    public let nodeID: NodeID

    /// The page ranges the core decided.
    public let pageRanges: UnitPageRanges

    /// How many pages there are. Zero exactly when the segment was empty.
    public var pageCount: Int { pageRanges.utf16Ranges.count }

    private let scenes: [CoreTextPlainTextPageScene]

    init(
        nodeID: NodeID,
        pageRanges: UnitPageRanges,
        scenes: [CoreTextPlainTextPageScene]
    ) {
        self.nodeID = nodeID
        self.pageRanges = pageRanges
        self.scenes = scenes
    }

    /// The scene for a page, or `nil` when the index is not one of its pages.
    public func scene(at pageIndex: Int) -> CoreTextPlainTextPageScene? {
        guard scenes.indices.contains(pageIndex) else { return nil }
        return scenes[pageIndex]
    }
}
