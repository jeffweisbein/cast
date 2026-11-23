#if DEBUG
import SwiftUI

/// DEBUG-only offline fixture for visual review of the chat-state / result-review design.
/// Uses the production components with fictional, clearly labelled data; it has no store,
/// client, credentials or persistence. Launch with `CAST_RESULT_DESIGN_FIXTURE=<scene>`.
enum ResultDesignFixture {
    enum Scene: String, CaseIterable {
        case sidebar, chat, review, progress, details
    }

    static func scene(from environment: [String: String]) -> Scene? {
        environment["CAST_RESULT_DESIGN_FIXTURE"].flatMap(Scene.init(rawValue:))
    }

    static let now = Date()
    static func ms(minutesAgo: Double) -> Double { (now.timeIntervalSince1970 - minutesAgo * 60) * 1000 }

    struct Chat: Identifiable {
        let id: String
        let title: String
        let preview: String
        let minutesAgo: Double
        let unread: Bool
        let state: ChatWorkState?
        let pinned: Bool
    }

    static let chats: [Chat] = [
        Chat(id: "cast", title: "Cast", preview: "The chat list redesign is ready to look at.", minutesAgo: 1,
             unread: true, state: .readyToReview(count: 2), pinned: true),
        Chat(id: "cackles", title: "Cackles", preview: "Checking audio on iPad.", minutesAgo: 2,
             unread: false, state: .working, pinned: true),
        Chat(id: "runpr", title: "RunPR", preview: "Which headline should lead the launch?", minutesAgo: 18,
             unread: false, state: .needsYou(.question), pinned: true),
        Chat(id: "ops", title: "Gateway ops", preview: "Restart approval is waiting.", minutesAgo: 25,
             unread: false, state: .needsYou(.approval), pinned: false),
        Chat(id: "nightly", title: "Nightly build", preview: "Rebuilding the archive.", minutesAgo: 40,
             unread: false, state: .needsYou(.stopped), pinned: false),
        Chat(id: "weekend", title: "Weekend plans", preview: "A few places worth trying.", minutesAgo: 60,
             unread: false, state: nil, pinned: false),
        Chat(id: "general", title: "General", preview: "Picking up where we left off.", minutesAgo: 180,
             unread: false, state: nil, pinned: false),
    ]

    static let deliverables: [Deliverable] = [
        Deliverable(id: "f1", sessionKey: "agent:main:cast", messageID: "m3", title: "sidebar-states-dark.png",
                    target: "artifact:f1", kind: "Image", sharedAt: ms(minutesAgo: 2),
                    artifactID: "f1", sizeBytes: 482_113, mimeType: "image/png"),
        Deliverable(id: "f2", sessionKey: "agent:main:cast", messageID: "m3", title: "chat-states.patch",
                    target: "artifact:f2", kind: "Attachment", sharedAt: ms(minutesAgo: 3),
                    artifactID: "f2", sizeBytes: 18_330, mimeType: "text/x-diff"),
        Deliverable(id: "f3", sessionKey: "agent:main:cast", messageID: "m2", title: "verification-notes.md",
                    target: "artifact:f3", kind: "Attachment", sharedAt: ms(minutesAgo: 9),
                    artifactID: "f3", sizeBytes: 6_204, mimeType: "text/markdown"),
        // An ordinary link: excluded from the result surfaces by design.
        Deliverable(id: "l1", sessionKey: "agent:main:cast", messageID: "m3", title: "Pull request",
                    target: "https://github.com/example/cast/pull/42", kind: "Pull request", sharedAt: ms(minutesAgo: 2)),
    ]

    static var summary: ChatResultSummary {
        ChatResultSummary(sessionKey: "agent:main:cast", ledger: deliverables, reviewed: [deliverables[2].reviewID],
                          progressCard: progressCard)
    }

    static var progressCard: ProgressCard? {
        try? JSONDecoder().decode(ProgressCard.self, from: Data("""
        {"sessionKey":"agent:main:cast","revision":7,"updatedAt":\(ms(minutesAgo: 2)),
         "steps":[{"step":"Derive chat states from live signals","status":"completed"},
                  {"step":"Result card and review panel","status":"completed"},
                  {"step":"Focused regression tests","status":"completed"},
                  {"step":"Independent visual review","status":"in_progress"}]}
        """.utf8))
    }

    static let facts = ResultRunFacts(
        facts: [
            .init(label: "Agent", value: "Cast"),
            .init(label: "Model (last reported)", value: "claude-opus-5-5 · anthropic"),
            .init(label: "Reasoning", value: "High"),
            .init(label: "Run", value: "Idle"),
            .init(label: "Context", value: "38% full"),
            .init(label: "Tokens", value: "412K in · 61K out"),
            .init(label: "Updated", value: "2 min. ago"),
        ],
        notReported: ["machine", "per-step model", "build and test results", "installation"])

    static func availability(_ item: Deliverable) -> ResultArtifactAvailability {
        switch item.id {
        case "f1": return .downloading(received: 301_000, total: 482_113)
        default: return .remote(canDownload: true)
        }
    }
}

struct ResultDesignFixtureView: View {
    let scene: ResultDesignFixture.Scene
    @State private var filter: ChatWorkFilter = .all
    @State private var tab: ResultReviewTab = .files

    var body: some View {
        switch self.scene {
        case .sidebar:
            #if os(iOS)
            ScrollView { self.sidebar }
            #else
            self.sidebar
            #endif
        case .chat: self.chat
        case .review: self.review(.files)
        case .progress: self.review(.progress)
        case .details: self.review(.details)
        }
    }

    static func counts() -> [ChatWorkFilter: Int] {
        var counts: [ChatWorkFilter: Int] = [:]
        for state in ResultDesignFixture.chats.compactMap(\.state) { counts[state.filter, default: 0] += 1 }
        return counts
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chats").font(.largeTitle.bold())
                Spacer()
                Image(systemName: "square.and.pencil").font(.title3).foregroundStyle(.tint)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text("Search chats").foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12).padding(.bottom, 8)
            ChatFilterBar(filter: self.$filter, counts: Self.counts()).padding(.bottom, 10)
            let visible = ResultDesignFixture.chats.filter { self.filter == .all || $0.state?.filter == self.filter }
            self.section("PINNED", visible.filter(\.pinned))
            self.section("OTHER CHATS", visible.filter { !$0.pinned })
            Spacer(minLength: 0)
            Text("Offline fixture · fictional chats").font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity).padding(8)
        }
    }

    @ViewBuilder private func section(_ title: String, _ chats: [ResultDesignFixture.Chat]) -> some View {
        if !chats.isEmpty {
            Text(title).font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 2)
            ForEach(chats) { chat in
                PersonalChatRowLabel(
                    title: chat.title, preview: chat.preview,
                    updated: ResultDesignFixture.now.addingTimeInterval(-chat.minutesAgo * 60),
                    unread: chat.unread, state: chat.state)
                    .padding(.horizontal, 12)
                    .background(chat.id == "cast" ? Color.accentColor.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 6)
            }
        }
    }

    var chat: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Spacer(minLength: 60)
                    Text("Make it easier to see which chats need me.")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("Cast", systemImage: "bubble.left").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Each chat now shows whether it is working, needs you, or has something to review — and your pinned order stays exactly where you put it.")
                }
                ChatResultCardContent(summary: ResultDesignFixture.summary, state: nil, openReview: {})
                ChatResultCardContent(
                    summary: ChatResultSummary(sessionKey: "agent:main:cackles",
                        ledger: [Deliverable(id: "c1", sessionKey: "agent:main:cackles", messageID: "x",
                            title: "ipad-audio-log.txt", target: "artifact:c1", kind: "Attachment",
                            sharedAt: ResultDesignFixture.ms(minutesAgo: 40), artifactID: "c1")],
                        reviewed: [], progressCard: nil),
                    state: .working, openReview: {})
                Text("Offline fixture · fictional result data").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
        }
    }

    func review(_ initial: ResultReviewTab) -> some View {
        ResultReviewPanel(
            title: "Cast",
            summary: ResultDesignFixture.summary,
            state: nil,
            progressCard: ResultDesignFixture.progressCard,
            runIsActive: false,
            facts: ResultDesignFixture.facts,
            tab: Binding(get: { initial }, set: { _ in }),
            artifact: { item in
                ResultArtifactRowContent(item: item, availability: ResultDesignFixture.availability(item),
                                         reviewed: item.id == "f3")
            })
    }
}
#endif
