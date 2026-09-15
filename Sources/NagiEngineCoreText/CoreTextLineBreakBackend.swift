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

    public func makeSession(for segment: PrimaryTextSegment) throws -> CoreTextLineBreakSession {
        CoreTextLineBreakSession(segment: segment, font: font, languageTag: languageTag)
    }
}

/// One segment's line-breaking session.
///
/// The initializer is not public: a session is bound to a whole
/// `PrimaryTextSegment`, and the backend is what pairs them.
public final class CoreTextLineBreakSession: LineBreakSession {
    private let segment: PrimaryTextSegment
    private let typesetter: CTTypesetter
    private let total: Int

    init(segment: PrimaryTextSegment, font: CTFont, languageTag: String?) {
        self.segment = segment
        self.total = segment.utf16Count

        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font
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
    /// so no arithmetic can wrap.
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
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

        // Safe to add now: `suggested <= total - offset`.
        return LineMeasurement(
            consumedUTF16Range: offset..<(offset + suggested),
            naturalBlockExtent: Double(ascent + descent + leading)
        )
    }
}
