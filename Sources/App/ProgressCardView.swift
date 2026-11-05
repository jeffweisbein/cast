import Combine
import MarkdownUI
import SwiftUI

/// Collapsible "Task progress" card shown above the composer for the selected session.
/// Reads `store.progressCards`; collapses per session key.
struct ProgressCardView: View {
    let store: ChatStore
    @State private var tick = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var sessionKey: String? { self.store.selectedSessionKey }
    private var card: ProgressCard? { self.sessionKey.flatMap { self.store.progressCard(for: $0) } }
    private var isCollapsed: Bool {
        self.sessionKey.map { self.store.collapsedProgressCardSessions.contains($0) } ?? false
    }

    var body: some View {
        if let card, let key = self.sessionKey {
            VStack(spacing: 0) {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    self.header(card: card, key: key)
                    if !self.isCollapsed {
                        Divider().padding(.horizontal, 12)
                        self.expandedBody(card: card)
                    }
                }
            }
            .onReceive(self.timer) { self.tick = $0 }
        }
    }

    @ViewBuilder
    private func header(card: ProgressCard, key: String) -> some View {
        Button { self.store.toggleProgressCardCollapsed(for: key) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Task progress")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if card.totalStepCount > 0 {
                    Text("\(card.completedStepCount)/\(card.totalStepCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.tint))
                        .accessibilityLabel("\(card.completedStepCount) of \(card.totalStepCount) steps complete")
                }
                Spacer(minLength: 4)
                Text(relativeTime(card.updatedDate, relativeTo: self.tick))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Image(systemName: self.isCollapsed ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func expandedBody(card: ProgressCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let markdown = card.markdown, !markdown.isEmpty {
                    ProgressCardMarkdownView(markdown: markdown)
                }
                if let steps = card.steps, !steps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(steps.enumerated()), id: \.0) { _, step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                self.stepGlyph(step.status)
                                Text(step.step)
                                    .font(.caption)
                                    .foregroundStyle(step.status == .completed ? .secondary : .primary)
                                    .strikethrough(step.status == .completed, color: .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: 200)
    }

    @ViewBuilder
    private func stepGlyph(_ status: ProgressStepStatus) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .inProgress:
            Image(systemName: "circle.dotted.and.circle")
                .font(.caption)
                .foregroundStyle(.tint)
        case .pending, .unknown:
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Markdown with progress bars

/// Renders card markdown, replacing `<progress value="N" max="M">` tags with native bars.
private struct ProgressCardMarkdownView: View {
    let markdown: String

    private static let progressRegex: NSRegularExpression = {
        // Matches <progress value="N" max="M" ...>...</progress>; options .dotMatchesLineSeparators
        // covers the rare case where content spans lines.
        try! NSRegularExpression(
            pattern: #"<progress\s+value="(\d+)"\s+max="(\d+)"[^>]*>.*?</progress>"#,
            options: [.dotMatchesLineSeparators])
    }()

    private struct ProgressBar { let value: Int; let max: Int }

    private var progressBars: [ProgressBar] {
        let range = NSRange(self.markdown.startIndex..., in: self.markdown)
        return Self.progressRegex.matches(in: self.markdown, range: range).compactMap { match in
            guard match.numberOfRanges == 3,
                  let vRange = Range(match.range(at: 1), in: self.markdown),
                  let mRange = Range(match.range(at: 2), in: self.markdown),
                  let v = Int(self.markdown[vRange]),
                  let m = Int(self.markdown[mRange])
            else { return nil }
            return ProgressBar(value: v, max: m)
        }
    }

    private var strippedMarkdown: String {
        let range = NSRange(self.markdown.startIndex..., in: self.markdown)
        return Self.progressRegex
            .stringByReplacingMatches(in: self.markdown, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let stripped = self.strippedMarkdown
            if !stripped.isEmpty {
                Markdown(stripped)
                    .markdownTheme(.gitHub)
                    // The gitHub theme paints its own surface color behind body text,
                    // which reads as a dark slab inside the card. Inherit the card's
                    // background instead and match the card's caption sizing.
                    .markdownTextStyle(\.text) {
                        ForegroundColor(.primary)
                        BackgroundColor(nil)
                        FontSize(12)
                    }
                    .textSelection(.enabled)
            }
            ForEach(Array(self.progressBars.enumerated()), id: \.0) { _, bar in
                ProgressView(value: Double(bar.value), total: Double(max(bar.max, 1)))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }
        }
    }
}

// MARK: - Sidebar pill

/// Compact "n/m" pill shown on a session list row when a card with steps exists.
struct ProgressCardPill: View {
    let completed: Int
    let total: Int

    var body: some View {
        Text("\(self.completed)/\(self.total)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(.tint.opacity(0.8)))
            .accessibilityLabel("\(self.completed) of \(self.total) progress steps done")
    }
}

// MARK: - Helpers

private func relativeTime(_ date: Date, relativeTo now: Date) -> String {
    let interval = now.timeIntervalSince(date)
    if interval < 60 { return "just now" }
    if interval < 3600 { return "\(Int(interval / 60))m ago" }
    if interval < 86400 { return "\(Int(interval / 3600))h ago" }
    return "\(Int(interval / 86400))d ago"
}
