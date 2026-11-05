import MarkdownUI
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Normalization for anything the transcript puts on the pasteboard.
///
/// cmark terminates every rendered block with a newline and a quote that starts on a
/// soft break picks up a leading blank line, so a raw render round-trips edge whitespace
/// the reader never sees. Trimming happens by line, not by character set: interior blank
/// lines separate paragraphs in a drafted email, and leading indentation is meaningful
/// inside code, so neither may be touched.
enum CopyPayload {
    static func normalized(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// The pasteboard text for a markdown blockquote.
    ///
    /// The block content comes from MarkdownUI's own cmark parse, so block boundaries —
    /// nested fences, unterminated fences, lazy continuation lines — are decided once, by
    /// the same parser that rendered the quote. Cast never re-parses the message text.
    static func quote(_ content: MarkdownContent) -> String {
        self.normalized(content.renderPlainText())
    }

    /// The pasteboard text for a fenced code block. MarkdownUI already drops the fence's
    /// single trailing newline; this also drops blank padding lines authors leave inside.
    static func code(_ code: String) -> String {
        self.normalized(code)
    }
}

/// The one place a transcript copy reaches the pasteboard, so every affordance shares the
/// same platform branch and the same confirmation. The iOS haptic matches `VoiceLimitNotice`:
/// a `UINotificationFeedbackGenerator` for a result the user's own thumb is covering.
enum TranscriptPasteboard {
    @MainActor
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}

/// The shared "Copy → Copied" control used by code blocks, quoted blocks, and whole
/// responses.
///
/// macOS reveals it on hover and iOS keeps it visible, but the button stays in the layout
/// either way: fading rather than inserting it means revealing a copy affordance can never
/// reflow the transcript under a reader who is mid-scroll. It also stays visible while it
/// reads "Copied" so the confirmation is never cut short by the pointer moving away.
struct CopyBlockButton: View {
    private let textProvider: () -> String
    var label = "Copy"
    var accessibilityName = "Copy"
    /// macOS only: whether the enclosing block currently has the pointer.
    var revealed = true

    @State private var copied = false

    init(
        text: @autoclosure @escaping () -> String,
        label: String = "Copy",
        accessibilityName: String = "Copy",
        revealed: Bool = true)
    {
        self.textProvider = text
        self.label = label
        self.accessibilityName = accessibilityName
        self.revealed = revealed
    }

    init(
        textProvider: @escaping () -> String,
        label: String = "Copy",
        accessibilityName: String = "Copy",
        revealed: Bool = true)
    {
        self.textProvider = textProvider
        self.label = label
        self.accessibilityName = accessibilityName
        self.revealed = revealed
    }

    private var isVisible: Bool {
        #if os(macOS)
        return self.revealed || self.copied
        #else
        return true
        #endif
    }

    var body: some View {
        Button(action: self.copy) {
            Label(
                self.copied ? "Copied" : self.label,
                systemImage: self.copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(self.copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .opacity(self.isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.12), value: self.isVisible)
        .accessibilityLabel(self.copied ? "Copied" : self.accessibilityName)
    }

    private func copy() {
        TranscriptPasteboard.copy(self.resolvedText())
        self.copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.copied = false
        }
    }

    /// Kept separate from the button body so constructing/re-rendering the affordance never
    /// asks MarkdownUI for plain text. Only the button action resolves the payload.
    func resolvedText() -> String {
        self.textProvider()
    }
}

/// A markdown blockquote with its own copy affordance.
///
/// Agents use a blockquote for text the reader is meant to lift verbatim — a drafted
/// tweet, an email body — and "Copy response" is the wrong tool for that: it brings the
/// surrounding commentary along. The button sits under the quote, mirroring where
/// "Copy response" sits under the message, and a message with no quoted block gains
/// nothing and renders exactly as before.
struct QuotedBlockView: View {
    let copyText: String
    let label: BlockConfiguration.Label
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: 3)
                self.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
                    .padding(.leading, 12)
            }
            .fixedSize(horizontal: false, vertical: true)
            CopyBlockButton(
                text: self.copyText,
                label: "Copy quote",
                accessibilityName: "Copy quoted text",
                revealed: self.hovering)
                .padding(.leading, 15)
        }
        #if os(macOS)
        .onHover { self.hovering = $0 }
        #endif
    }
}
