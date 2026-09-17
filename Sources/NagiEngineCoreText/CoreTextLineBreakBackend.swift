import Foundation
import CoreText

import NagiEngineCore

/// What a session refuses when it is called directly.
///
/// The paginator validates its own inputs before it ever reaches a session, so
/// these exist for the other caller: someone driving a session by hand gets a
/// named reason instead of an exception from CoreText or a silent bad range.
///
/// No case carries a `Double`, for the same reason `TextPaginationError` has
/// none: the value that would arrive here is usually NaN, and an `Equatable`
/// enum holding NaN is not reflexive.
public enum CoreTextLineBreakError: Error, Equatable, Sendable {
    /// `inlineExtent` was not a finite number greater than zero.
    case invalidInlineExtent

    /// The requested offset was negative or past the end of the segment.
    ///
    /// Landing exactly on the end is not an error — it is how a session says it
    /// has nothing more to give, and it answers `nil`.
    case utf16OffsetOutOfBounds(Int)

    /// CoreText suggested more text than the segment has left.
    case suggestedLengthOutOfBounds(atUTF16Offset: Int, length: Int)
}

/// One line exactly as a session measured it.
///
/// Module-internal, and immutable. This is what a page scene is built from, so
/// nothing downstream shapes or suggests a line a second time: it keeps the very
/// `CTLine` the session created, alongside the measurement that session
/// returned and the numbers the scene's geometry and hit testing are computed
/// from — the same `ascent + descent + leading` the paginator counted.
///
/// The measurement counts as **accepted** only once the whole pagination has
/// succeeded. A session cannot know, at the moment it measures a line, whether
/// the core will take it, and a call that fails publishes no value at all.
///
/// Not `Sendable`: it holds a `CTLine`, which carries no documented thread
/// safety guarantee to appeal to.
struct CoreTextLineArtifact {
    let measurement: LineMeasurement
    let line: CTLine
    let ascent: CGFloat
    let descent: CGFloat
    let leading: CGFloat
    let typographicWidth: CGFloat
}

/// A line-breaking backend built on CoreText.
///
/// It suggests candidate lines and reports their natural metrics. It does not
/// decide where pages end, does not group lines into pages, and does not render:
/// that division is this repository's **ADR-0004**, which absorbed the evidence
/// repository's CoreText boundary and names `CTTypesetterSuggestLineBreak` and
/// `CTLine` as permitted while forbidding only that they become the final
/// decider of page geometry.
///
/// **Not `Sendable`.** It holds a `CTFont` and hands out sessions holding a
/// `CTTypesetter`, and neither carries a documented thread-safety guarantee.
/// Claiming otherwise — with `@unchecked` in particular — would be an assertion
/// this code has no evidence for.
public struct CoreTextLineBreakBackend: LineBreakBackend {
    private let font: CTFont
    private let languageTag: String?

    /// - Parameters:
    ///   - font: injected, not chosen here. The core never sees a `CTFont`.
    ///   - languageTag: passed through as `kCTLanguageAttributeName` when it is
    ///     not `nil`; `nil` leaves the run untagged.
    public init(font: CTFont, languageTag: String? = nil) {
        self.font = font
        self.languageTag = languageTag
    }

    /// A session that measures lines and keeps nothing.
    ///
    /// This is the ranges-only path: it exists to feed `TextPaginator`, and a
    /// long unit must not hold every one of its `CTLine`s merely because it was
    /// paginated. Retention is opened deliberately, through
    /// `makeRecordingSession(for:)`.
    public func makeSession(for segment: PrimaryTextSegment) throws -> CoreTextLineBreakSession {
        CoreTextLineBreakSession(
            segment: segment,
            font: font,
            languageTag: languageTag,
            recordsLineArtifacts: false
        )
    }

    /// The same session, with line retention opened.
    ///
    /// Module-internal: the page scene is the one caller that needs the lines,
    /// and it reaches them through `CoreTextRecordingBackend`. This is not a
    /// public entry point. What it measures is identical to the session above —
    /// only what it keeps differs.
    func makeRecordingSession(for segment: PrimaryTextSegment) throws -> CoreTextLineBreakSession {
        CoreTextLineBreakSession(
            segment: segment,
            font: font,
            languageTag: languageTag,
            recordsLineArtifacts: true
        )
    }

    /// Paginates a whole segment and keeps the lines, so that a page can be both
    /// drawn and hit-tested.
    ///
    /// **The core still decides where pages end.** This makes one recording
    /// backend for this call, hands it to the existing
    /// `TextPaginator.paginate(segment:constraints:backend:)`, and only then
    /// groups the lines that session actually produced. Nothing here suggests a
    /// line break twice, and nothing here can pair one call's page ranges with
    /// another call's lines: the ranges come back from the core, the lines come
    /// from the session the core made during that same call.
    ///
    /// The recorder and the session are temporaries of this one call. What
    /// outlives it is the returned value, which holds the artifacts that were
    /// validated on the way out.
    ///
    /// An empty segment reaches no session at all — the paginator returns before
    /// asking for one — so the value carries no pages and nothing to draw. The
    /// shape of the call is **checked**, by segment length, rather than inferred
    /// from an empty range list.
    public func makePaginatedPlainText(
        segment: PrimaryTextSegment,
        nodeID: NodeID,
        constraints: TextPaginationConstraints
    ) throws -> CoreTextPaginatedPlainText {
        let recorder = CoreTextRecordingBackend(backend: self)
        let pageRanges = try TextPaginator.paginate(
            segment: segment,
            constraints: constraints,
            backend: recorder
        )

        try CoreTextPaginationInvariant.validate(
            segment: segment,
            makeSessionCallCount: recorder.makeSessionCallCount,
            madeASession: recorder.session != nil,
            pageRanges: pageRanges
        )

        guard let session = recorder.session else {
            // Only an empty segment can arrive here, and the invariant above has
            // already confirmed there are no ranges and no session: nothing to
            // draw.
            return CoreTextPaginatedPlainText(
                nodeID: nodeID,
                pageRanges: pageRanges,
                scenes: []
            )
        }

        let scenes = try CoreTextPageSceneBuilder.buildScenes(
            artifacts: session.artifacts,
            pageRanges: pageRanges,
            segment: segment,
            nodeID: nodeID,
            constraints: constraints
        )

        return CoreTextPaginatedPlainText(
            nodeID: nodeID,
            pageRanges: pageRanges,
            scenes: scenes
        )
    }
}

/// One segment's line-breaking session.
///
/// The initializer is not public: a session is bound to a whole
/// `PrimaryTextSegment`, and the backend is what pairs them.
///
/// A session keeps the lines it has measured — in call order, so that the page
/// scene can be built from the exact `CTLine`s this session produced rather than
/// from a second round of shaping — **but only when retention was opened**. The
/// store is module-internal, and it stays empty on the ranges-only path, which
/// must not hold a whole unit's lines merely because it was paginated.
public final class CoreTextLineBreakSession: LineBreakSession {
    private let segment: PrimaryTextSegment
    private let typesetter: CTTypesetter
    private let total: Int
    private let recordsLineArtifacts: Bool

    /// The lines this session has produced, in the order it produced them.
    ///
    /// **Empty unless retention was opened.** A session handed out by
    /// `makeSession(for:)` never fills this; one from
    /// `makeRecordingSession(for:)` fills it exactly as it measures.
    private(set) var artifacts: [CoreTextLineArtifact] = []

    init(
        segment: PrimaryTextSegment,
        font: CTFont,
        languageTag: String?,
        recordsLineArtifacts: Bool
    ) {
        self.segment = segment
        self.total = segment.utf16Count
        self.recordsLineArtifacts = recordsLineArtifacts

        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            // Lets the caller's context fill colour be the foreground. Without
            // it an attributed string with no colour attribute is black, and
            // CoreText sets that colour on the context itself — so a plain
            // `setFillColor` at draw time could not take over. With it, the flag
            // is fixed here, once, and recolouring later rebuilds nothing: the
            // string, the typesetter and every measurement stay exactly as they
            // are. It is a non-metric attribute; it moves no break and no bound.
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): kCFBooleanTrue as Any
        ]
        if let languageTag {
            attributes[NSAttributedString.Key(kCTLanguageAttributeName as String)] = languageTag
        }

        let attributed = NSAttributedString(string: segment.string, attributes: attributes)
        self.typesetter = CTTypesetterCreateWithAttributedString(attributed)
    }

    /// The next candidate at `fromUTF16Offset` under `inlineExtent`.
    ///
    /// Answers `nil` at the end of the segment, and also when CoreText suggests
    /// nothing — the paginator classifies the latter as a stall, which is its
    /// judgement to make rather than this layer's.
    ///
    /// The extent and the offset are checked here, and the suggested length is
    /// compared against what is left **before** anything is added to the offset,
    /// so no arithmetic can wrap and no `CFRange` is ever built from an
    /// unchecked sum.
    public func suggestLine(
        fromUTF16Offset offset: Int,
        inlineExtent: Double
    ) throws -> LineMeasurement? {
        guard inlineExtent.isFinite, inlineExtent > 0 else {
            throw CoreTextLineBreakError.invalidInlineExtent
        }
        guard offset >= 0, offset <= total else {
            throw CoreTextLineBreakError.utf16OffsetOutOfBounds(offset)
        }
        guard offset < total else { return nil }

        let suggested = CTTypesetterSuggestLineBreak(typesetter, offset, inlineExtent)
        guard suggested > 0 else { return nil }

        let remaining = total - offset
        guard suggested <= remaining else {
            throw CoreTextLineBreakError.suggestedLengthOutOfBounds(
                atUTF16Offset: offset,
                length: suggested
            )
        }

        let line = CTTypesetterCreateLine(
            typesetter,
            CFRange(location: offset, length: suggested)
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

        // Safe to add now: `suggested <= total - offset`.
        let measurement = LineMeasurement(
            consumedUTF16Range: offset..<(offset + suggested),
            naturalBlockExtent: Double(ascent + descent + leading)
        )

        // Measuring is the same on both paths; only what is kept differs. The
        // line kept here is the one measured just above — nothing is shaped a
        // second time.
        if recordsLineArtifacts {
            artifacts.append(
                CoreTextLineArtifact(
                    measurement: measurement,
                    line: line,
                    ascent: ascent,
                    descent: descent,
                    leading: leading,
                    typographicWidth: CGFloat(width)
                )
            )
        }

        return measurement
    }
}

/// A per-call backend that keeps the one session the core makes.
///
/// Module-internal, and **not part of the core's public API**: it is how a
/// pagination call can be observed without adding an entry point to
/// `TextPaginator`. The core is handed this backend and calls `makeSession` on
/// it at the single moment ADR-0004 fixes — after the three constraints are
/// validated, and only for a non-empty segment. The core keeps no reference to
/// it, and one instance serves exactly one call.
///
/// It is also what **opens line retention**: the session it hands back keeps its
/// `CTLine`s, while one from the public `makeSession(for:)` keeps none. That is
/// the whole difference between the two paths, and the reason the ranges-only
/// one does not grow a unit's worth of lines.
///
/// `makeSessionCallCount` counts successful sessions, so `session != nil` and
/// `makeSessionCallCount == 1` hold together. The **first** session is the one
/// kept: a second call would show up as a count of two rather than quietly
/// replacing the session whose lines the caller is about to read.
final class CoreTextRecordingBackend: LineBreakBackend {
    private let backend: CoreTextLineBreakBackend

    private(set) var makeSessionCallCount = 0
    private(set) var session: CoreTextLineBreakSession?

    init(backend: CoreTextLineBreakBackend) {
        self.backend = backend
    }

    func makeSession(for segment: PrimaryTextSegment) throws -> CoreTextLineBreakSession {
        let made = try backend.makeRecordingSession(for: segment)
        makeSessionCallCount += 1
        if session == nil {
            session = made
        }
        return made
    }
}
