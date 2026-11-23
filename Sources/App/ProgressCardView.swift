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

/// Renders card markdown, replacing `<progress …>` tags (any attribute order) with native
/// bars labelled by their `aria-label`.
private struct ProgressCardMarkdownView: View {
    let markdown: String

    var body: some View {
        let parsed = ProgressMarkup.parse(self.markdown)
        VStack(alignment: .leading, spacing: 8) {
            if !parsed.stripped.isEmpty {
                Markdown(parsed.stripped)
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
            ForEach(Array(parsed.bars.enumerated()), id: \.offset) { _, bar in
                VStack(alignment: .leading, spacing: 3) {
                    if let label = bar.label {
                        Text(label).font(.caption2).foregroundStyle(.secondary)
                    }
                    ProgressView(value: bar.value, total: bar.max)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(bar.label ?? "Progress")
                .accessibilityValue("\(Int(bar.value)) of \(Int(bar.max))")
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
            .background(Capsule().fill(.tint))
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
