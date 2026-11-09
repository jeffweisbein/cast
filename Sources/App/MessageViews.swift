import MarkdownUI
import SwiftUI

enum Theme {
    #if os(macOS)
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let userBubble = Color.accentColor.opacity(0.14)
    #else
    static let canvas = Color(uiColor: .systemBackground)
    static let userBubble = Color.accentColor.opacity(0.16)
    #endif
}

struct MessageGroupView: View, Equatable {
    let group: TranscriptGroup
    let agentName: String
    let agentIdentity: AgentIdentity?
    let gatewayURL: URL
    let workspaceID: String
    let agentID: String
    let onOpenMedia: (URL) -> Void
    let onRetrySend: (String) -> Void
    var onAskAbout: ((String) -> Void)? = nil
    var downloadAttachment: (@MainActor (ManagedChatAttachment) async throws -> URL)? = nil
    @State private var showsTime = false
    @State private var retryUncertainID: String?

    /// Every streamed delta and every `@State` write in `ChatView` re-evaluates its body, and
    /// without this every visible row re-parsed its markdown for nothing. The closures are
    /// deliberately left out: they capture `ChatView` state, not what the row shows.
    static func == (lhs: MessageGroupView, rhs: MessageGroupView) -> Bool {
        lhs.group == rhs.group
            && lhs.agentName == rhs.agentName
            && lhs.agentIdentity == rhs.agentIdentity
            && lhs.gatewayURL == rhs.gatewayURL
            && lhs.workspaceID == rhs.workspaceID
            && lhs.agentID == rhs.agentID
            && (lhs.onAskAbout != nil) == (rhs.onAskAbout != nil)
    }

    var body: some View {
        Group {
            if self.group.isUser {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(self.group.messages) { message in
                        MessageMediaView(message: message, onOpen: self.onOpenMedia, downloadAttachment: downloadAttachment)
                        if !message.text.isEmpty {
                            UserBubble(text: message.text).equatable()
                        }
                        if message.localDeliveryState == .pending {
                            Label("Connecting / submitting…", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                        } else if message.localDeliveryState == .uncertain {
                            HStack {
                                Label("Delivery unconfirmed", systemImage: "questionmark.circle")
                                Button("Review retry") { self.retryUncertainID = message.id }
                            }.font(.caption).foregroundStyle(.orange)
                        } else if message.localDeliveryState == .delivered, message.localIdempotencyKey != nil {
                            Label("Accepted by gateway", systemImage: "checkmark").font(.caption2).foregroundStyle(.secondary)
                        }
                        if message.localDeliveryState == .failed {
                            FailedDeliveryLabel { self.onRetrySend(message.id) }
                        }
                    }
                    if let date = self.group.date {
                        // Reserve the footer: hovering while scrolling must not change
                        // row height and move every later message under the pointer.
                        TimestampLabel(date: date)
                            .opacity(self.showsTime ? 1 : 0)
                            .accessibilityHidden(!self.showsTime)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    AgentHeader(
                        name: self.agentName,
                        identity: self.agentIdentity,
                        gatewayURL: self.gatewayURL,
                        workspaceID: self.workspaceID,
                        agentID: self.agentID,
                        date: self.showsTime ? self.group.date : nil)
                        #if os(macOS)
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.12)) { self.showsTime = hovering }
                        }
                        #else
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.12)) { self.showsTime.toggle() }
                        }
                        #endif
                    ForEach(self.group.messages) { message in
                        MessageMediaView(message: message, onOpen: self.onOpenMedia, downloadAttachment: downloadAttachment)
                        if !message.text.isEmpty {
                            MarkdownBody(text: message.text).equatable()
                            if let onAskAbout {
                                Button("Ask in side chat", systemImage: "bubble.left.and.bubble.right") {
                                    onAskAbout(message.text)
                                }.font(.caption).buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // The assistant header still reveals its timestamp, but the response body owns no
        // gesture/state transition that can disturb native link or text selection.
        .confirmationDialog("Retry this unconfirmed send?", isPresented: Binding(
            get: { self.retryUncertainID != nil }, set: { if !$0 { self.retryUncertainID = nil } })) {
                Button("Retry original request") {
                    if let id = self.retryUncertainID { self.onRetrySend(id) }
                    self.retryUncertainID = nil
                }
                Button("Cancel", role: .cancel) { self.retryUncertainID = nil }
            } message: {
                Text("Check the conversation for a reply first. Cast reuses the original request ID and payload, but a gateway restart or expired deduplication window can still allow a duplicate. Nothing is retried automatically.")
            }
        .modifier(UserTimestampInteractionModifier(enabled: self.group.isUser, showsTime: self.$showsTime))
    }
}

private struct UserTimestampInteractionModifier: ViewModifier {
    let enabled: Bool
    @Binding var showsTime: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if self.enabled {
            #if os(macOS)
            content.onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) { self.showsTime = hovering }
            }
            #else
            // `simultaneousGesture`, not `onTapGesture`: an exclusive tap recognizer on the
            // bubble is what stops UIKit's text interaction from ever starting, which is the
            // same class of conflict d12aa2c fixed by lifting gestures off the assistant
            // body. Recognizing alongside keeps tap-for-timestamp and leaves long-press
            // selection and the Copy / Select All callout to the text.
            content.simultaneousGesture(TapGesture().onEnded {
                withAnimation(.easeInOut(duration: 0.12)) { self.showsTime.toggle() }
            })
            #endif
        } else {
            content
        }
    }
}

/// iMessage-shaped failure affordance: the bubble keeps the user's words, this row says
/// they never left the device, and the only action is the retry that reuses the original
/// send's idempotency key.
struct FailedDeliveryLabel: View {
    let onRetry: () -> Void

    var body: some View {
        Button(action: self.onRetry) {
            Label("Not Delivered · Tap to retry", systemImage: "exclamationmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .fontDesign(.rounded)
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Message not delivered. Retry send.")
    }
}

struct DaySeparatorView: View {
    let date: Date

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var body: some View {
        Text(Self.formatter.string(from: self.date))
            .font(.caption2.weight(.semibold))
            .fontDesign(.rounded)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(.quaternary.opacity(0.4)))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }
}

/// A collapsed run of consecutive tool calls: one subdued line, tap to expand in place.
struct ToolRunView: View, Equatable {
    let run: ToolRun
    let isExpanded: Bool
    let onToggle: () -> Void

    static func == (lhs: ToolRunView, rhs: ToolRunView) -> Bool {
        lhs.run == rhs.run && lhs.isExpanded == rhs.isExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: self.onToggle) {
                HStack(spacing: 5) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                    Text(self.run.headline)
                        .font(.caption)
                        .fontDesign(.rounded)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(self.isExpanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.35), in: Capsule())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tool activity: \(self.run.headline)")
            .accessibilityAddTraits(.isButton)
            if self.isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(self.run.steps) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(step.displayName)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if let summary = step.summary {
                                Text(summary)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .padding(.leading, 20)
                .transition(.opacity)
            }
        }
    }
}

struct AgentHeader: View {
    let name: String
    let identity: AgentIdentity?
    let gatewayURL: URL
    let workspaceID: String
    let agentID: String
    let date: Date?

    var body: some View {
        HStack(spacing: 8) {
            AgentAvatarView(
                identity: self.identity,
                fallbackName: self.name,
                gatewayURL: self.gatewayURL,
                workspaceID: self.workspaceID,
                agentID: self.agentID)
            .frame(width: 22, height: 22)
            Text(self.name)
                .font(.footnote.weight(.semibold))
                .fontDesign(.rounded)
                .foregroundStyle(.primary)
            if let date {
                TimestampLabel(date: date)
                    .transition(.opacity)
            }
        }
    }
}

struct TimestampLabel: View {
    let date: Date

    var body: some View {
        Text(self.date, format: .dateTime.hour().minute())
            .font(.caption2)
            .fontDesign(.rounded)
            .foregroundStyle(.tertiary)
    }
}

struct UserBubble: View, Equatable {
    let text: String

    var body: some View {
        Markdown(self.text)
            .markdownTheme(.castUser)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.userBubble))
            .frame(maxWidth: 560, alignment: .trailing)
            // The reader's own messages are quotable too — a prompt worth re-sending, a
            // pasted address. Selection was assistant-only until now.
            .textSelection(.enabled)
    }
}

struct MarkdownBody: View, Equatable {
    let text: String

    var body: some View {
        // Parse only when this leaf's text changes, not when its parent hover/follow state
        // changes. Equatable compares the source before entering this body.
        let content = AssistantResponseContent(markdown: self.text)
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 10) {
                let commits = CommitReference.references(in: self.text)
                if !commits.isEmpty { CommitReferencesView(references: commits) }
                ForEach(Array(content.blocks.enumerated()), id: \.0) { _, block in
                    switch block {
                    case let .markdown(markdown):
                        Markdown(markdown).markdownTheme(.castAssistant)
                    case let .disclosure(summary, body, startsExpanded):
                        DisclosureBlockView(
                            summary: summary, detail: body, startsExpanded: startsExpanded)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.quaternary.opacity(0.3)))
            .frame(maxWidth: .infinity, alignment: .leading)
            // Apply selection to the completed response container so MarkdownUI's
            // individual paragraphs, headings, lists, and links all participate.
            .textSelection(.enabled)

            CopyResponseButton(content: content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A `<details>` disclosure rendered natively. Collapsed by default, matching the
/// intent of the tag: the primary answer stays visible, the depth is opt-in.
private struct DisclosureBlockView: View {
    let summary: String
    let detail: MarkdownContent
    let startsExpanded: Bool

    @State private var isExpanded: Bool?

    var body: some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { self.isExpanded ?? self.startsExpanded },
                set: { self.isExpanded = $0 })
        ) {
            Markdown(self.detail)
                .markdownTheme(.castAssistant)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Text(self.summary)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct AssistantResponseContent: Equatable {
    enum Block: Equatable {
        case markdown(MarkdownContent)
        /// `startsExpanded` keeps a still-streaming disclosure open so its text stays
        /// readable until the closing tag arrives.
        case disclosure(summary: String, body: MarkdownContent, startsExpanded: Bool)
    }

    let blocks: [Block]

    /// Resolved on demand: rendering plain text for every message on screen would
    /// undo the laziness the copy button relies on.
    var copyText: String {
        self.blocks
            .map { block in
                switch block {
                case let .markdown(markdown):
                    return markdown.renderPlainText()
                case let .disclosure(summary, body, _):
                    return summary + "\n\n" + body.renderPlainText()
                }
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    init(markdown: String) {
        self.blocks = AssistantMarkdownParser.segments(markdown).map { segment in
            switch segment {
            case let .markdown(text):
                return .markdown(MarkdownContent(text))
            case let .disclosure(summary, body, isComplete):
                return .disclosure(
                    summary: summary, body: MarkdownContent(body), startsExpanded: !isComplete)
            }
        }
    }
}

private struct CopyResponseButton: View {
    let content: AssistantResponseContent

    var body: some View {
        CopyBlockButton(
            textProvider: { self.content.copyText },
            label: "Copy response",
            accessibilityName: "Copy response")
    }
}

extension MarkdownUI.Theme {
    /// Document-style assistant rendering: measured type, quiet code blocks, real tables.
    static let castAssistant = MarkdownUI.Theme.gitHub
        .text {
            ForegroundColor(.primary)
            BackgroundColor(nil)
            FontSize(16)
        }
        .link {
            ForegroundColor(.accentColor)
            UnderlineStyle(.single)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
            ForegroundColor(.accentColor)
            BackgroundColor(Color.accentColor.opacity(0.08))
        }
        .codeBlock { configuration in
            CodeBlockView(language: configuration.language, code: configuration.content)
                .markdownMargin(top: 6, bottom: 6)
        }
        // A blockquote is how an agent hands over text meant to be lifted verbatim, so it
        // carries its own copy button. The block content is MarkdownUI's parse of this
        // exact quote — no second pass over the message text.
        .blockquote { configuration in
            QuotedBlockView(
                copyText: CopyPayload.quote(configuration.content),
                label: configuration.label)
                .markdownMargin(top: 6, bottom: 6)
        }

    static let castUser = MarkdownUI.Theme.basic
        .text {
            ForegroundColor(.primary)
            BackgroundColor(nil)
            FontSize(15.5)
        }
        .link {
            ForegroundColor(.accentColor)
            UnderlineStyle(.single)
        }
}
