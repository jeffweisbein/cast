import SwiftUI

/// Needs You as a primary destination: only live requests (questions, approvals, blockers,
/// failures, failed deliveries). Unreviewed results are owned by the Results tab and only
/// summarised here, so nothing is counted twice.
struct NeedsYouTab: View {
    let store: ChatStore
    let openConversation: (String) -> Void
    let showResults: () -> Void
    @State private var detailItem: AttentionItem?
    @State private var showingQuestions = false
    @State private var showingHistory = false
    @State private var refreshing = false
    @State private var lastAutomaticRefreshAt: Date?

    private var isConnected: Bool { if case .connected = self.store.connectionState { return true }; return false }

    private func refresh(automatic: Bool = false) async {
        guard !self.refreshing else { return }
        guard self.isConnected else { self.lastAutomaticRefreshAt = nil; return }
        if automatic, let last = self.lastAutomaticRefreshAt, Date().timeIntervalSince(last) < 60 { return }
        self.refreshing = true; defer { self.refreshing = false }
        await self.store.refreshSessions()
        guard !Task.isCancelled else { return }
        await self.store.refreshApprovals()
        guard !Task.isCancelled else { return }
        await self.store.refreshQuestions()
        if !Task.isCancelled { self.lastAutomaticRefreshAt = Date() }
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let items = self.store.workAttentionItems(at: context.date)
                let results = CastNavigationCounts.results(self.store.resultArtifactCounts)
                List {
                    if !self.isConnected {
                        Label("Offline — showing requests from the last connection.", systemImage: "wifi.exclamationmark")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = self.store.approvalRefreshError {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                    if results > 0 {
                        Button(action: self.showResults) {
                            HStack {
                                Label(results == 1 ? "1 result ready to review" : "\(results) results ready to review",
                                      systemImage: "square.grid.2x2")
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("needs-you-results-link")
                    }
                    if items.isEmpty {
                        ContentUnavailableView("Nothing needs you", systemImage: "checkmark.circle",
                            description: Text("Questions, approvals, blockers and failed runs from your chats appear here."))
                            .listRowSeparator(.hidden)
                    } else {
                        Section {
                            ForEach(items) { item in self.card(item) }
                        }
                    }
                }
                .animation(nil, value: items.map(\.id))
            }
            .navigationTitle("Needs You")
            .task(id: self.isConnected) { await self.refresh(automatic: true) }
            .refreshable { await self.refresh() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(self.refreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise") {
                            Task { await self.refresh() }
                        }
                        .disabled(self.refreshing || !self.isConnected)
                        Button("Questions & settings", systemImage: "questionmark.bubble") { self.showingQuestions = true }
                        Button("Request history", systemImage: "clock.arrow.circlepath") { self.showingHistory = true }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .accessibilityIdentifier("needs-you-more")
                }
            }
            .sheet(isPresented: self.$showingQuestions) { QuestionInboxView(store: self.store) }
            .sheet(isPresented: self.$showingHistory) { NeedsYouView(store: self.store) }
            .sheet(item: self.$detailItem) { item in TaskDetailView(store: self.store, taskID: nil, sessionKey: item.sessionKey) }
        }
    }

    @ViewBuilder private func card(_ item: AttentionItem) -> some View {
        if item.kind == .question, let id = item.referenceID {
            VStack(alignment: .leading, spacing: 8) {
                QuestionCardView(store: self.store, requestID: id, showsConversation: true)
                self.openChatButton(item)
            }
        } else if item.kind == .approval,
                  let approval = self.store.approvals.first(where: { $0.id == item.referenceID }) {
            VStack(alignment: .leading, spacing: 8) {
                ApprovalCardView(approval: approval, store: self.store)
                self.openChatButton(item)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label(item.title, systemImage: Self.symbol(item.kind)).font(.headline)
                Text(item.detail).font(.callout).foregroundStyle(.secondary)
                HStack {
                    if let key = item.sessionKey {
                        Button { self.openConversation(key) } label: {
                            Text("Open chat").frame(minWidth: 44, minHeight: 44)
                        }
                        Button { self.detailItem = item } label: {
                            Text("Details").frame(minWidth: 44, minHeight: 44)
                        }
                    }
                    if item.kind == .failure,
                       let session = self.store.sessions.first(where: { $0.key == item.sessionKey }) {
                        Button { self.store.acknowledgeFailure(session) } label: {
                            Text("Dismiss failure").frame(minWidth: 44, minHeight: 44)
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private func openChatButton(_ item: AttentionItem) -> some View {
        if let key = item.sessionKey {
            Button { self.openConversation(key) } label: {
                Label("Open chat", systemImage: "bubble.left").frame(minWidth: 44, minHeight: 44)
            }
                .buttonStyle(.borderless)
                .font(.callout)
        }
    }

    static func symbol(_ kind: AttentionItem.Kind) -> String {
        switch kind {
        case .question: return "questionmark.bubble"
        case .approval: return "checkmark.shield"
        case .blocked: return "hand.raised"
        case .failure: return "exclamationmark.triangle"
        case .delivery: return "bell.slash"
        case .review: return "doc.badge.ellipsis"
        }
    }
}
