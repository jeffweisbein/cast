import Foundation

/// Assistant text can carry `<details><summary>…</summary>…</details>` disclosures for
/// optional depth. MarkdownUI renders raw HTML as literal text, so the tags are split
/// out here and handed to a native disclosure view — the same lift-it-out-of-the-markdown
/// approach `<progress>` gets in the progress card.
public enum AssistantMarkdownSegment: Equatable {
    case markdown(String)
    /// `isComplete` is false while a disclosure is still streaming in without its
    /// closing tag, so the view can show it open rather than leaking raw HTML.
    case disclosure(summary: String, body: String, isComplete: Bool)
}

public enum AssistantMarkdownParser {
    /// Shown when a disclosure arrives without a usable `<summary>`.
    public static let fallbackSummary = "Details"

    private static let closedDetails = Self.regex(#"<details\b[^>]*>(.*?)</details\s*>"#)
    private static let openDetails = Self.regex(#"<details\b[^>]*>"#)
    private static let closedSummary = Self.regex(#"<summary\b[^>]*>(.*?)</summary\s*>"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Both tags routinely span lines, and agents write them in either case.
        try! NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
    }

    public static func segments(_ text: String) -> [AssistantMarkdownSegment] {
        var segments: [AssistantMarkdownSegment] = []
        var cursor = text.startIndex

        for match in self.closedDetails.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text),
                  let inner = Range(match.range(at: 1), in: text),
                  whole.lowerBound >= cursor
            else { continue }
            self.appendMarkdown(String(text[cursor ..< whole.lowerBound]), to: &segments)
            let (summary, body) = self.split(String(text[inner]))
            segments.append(.disclosure(summary: summary, body: body, isComplete: true))
            cursor = whole.upperBound
        }

        let tail = String(text[cursor...])
        // A disclosure that opened but has not closed yet: everything after the opening
        // tag belongs to it, not to the surrounding prose.
        if let opening = self.openDetails.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
           let openingRange = Range(opening.range, in: tail) {
            self.appendMarkdown(String(tail[..<openingRange.lowerBound]), to: &segments)
            let (summary, body) = self.split(String(tail[openingRange.upperBound...]))
            segments.append(.disclosure(summary: summary, body: body, isComplete: false))
        } else {
            self.appendMarkdown(tail, to: &segments)
        }

        return segments
    }

    /// Separates a disclosure's summary from its body. A summary still mid-stream leaves
    /// the fallback label in place rather than showing half a sentence.
    private static func split(_ inner: String) -> (summary: String, body: String) {
        guard let match = self.closedSummary.firstMatch(
                  in: inner, range: NSRange(inner.startIndex..., in: inner)),
              let whole = Range(match.range, in: inner),
              let captured = Range(match.range(at: 1), in: inner)
        else {
            return (self.fallbackSummary, inner.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let summary = String(inner[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
        var body = inner
        body.removeSubrange(whole)
        return (
            summary.isEmpty ? self.fallbackSummary : summary,
            body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func appendMarkdown(_ text: String, to segments: inout [AssistantMarkdownSegment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        segments.append(.markdown(trimmed))
    }
}
