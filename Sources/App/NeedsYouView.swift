import SwiftUI

struct NeedsYouView: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeliverables = false
    @State private var showingQuestions = false
    @State private var detailItem: AttentionItem?
    @State private var reviewSessionKey: String?
    @State private var showRecent = false
    @State private var refreshing = false
    private var isConnected: Bool { if case .connected = store.connectionState { return true }; return false }
    private func refresh() async {
        guard !refreshing, isConnected else { return }
        refreshing = true; defer { refreshing = false }
        await store.refreshSessions()
        await store.refreshApprovals()
        await store.refreshQuestions()
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let items = self.store.attentionItems(at: context.date)
                List {
                    Button("Questions and question-card settings", systemImage: "questionmark.bubble") { showingQuestions = true }
                    Picker("Requests", selection: $showRecent) {
                        Text("Needs attention").tag(false)
                        Text("Recent outcomes").tag(true)
                    }.pickerStyle(.segmented)
                    if let error = store.approvalRefreshError { Text(error).font(.caption).foregroundStyle(.secondary) }
                    if showRecent {
                        recentOutcomes(at: context.date)
                    } else {
                    if items.isEmpty {
                        ContentUnavailableView("Nothing needs you right now", systemImage: "checkmark.circle",
                            description: Text("Approvals, blockers, failures, and new results will appear here."))
                    }
                    ForEach(items) { item in
                        if item.kind == .question, let id = item.referenceID {
                            QuestionCardView(store: store, requestID: id, showsConversation: true)
                        } else if item.kind == .approval,
                           let approval = self.store.approvals.first(where: { $0.id == item.referenceID }) {
                            ApprovalCardView(approval: approval, store: self.store)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(item.title, systemImage: self.symbol(item.kind)).font(.headline)
                                Text(item.detail).font(.callout).foregroundStyle(.secondary)
                                HStack {
                                    if let key = item.sessionKey {
                                        Button("Details") { detailItem = item }
                                        Button("Open conversation") {
                                            self.store.selectedSessionKey = key
                                            self.dismiss()
                                        }
                                    }
                                    if item.kind == .review {
                                        Button("Review result") {
                                            self.reviewSessionKey = item.sessionKey
                                            self.showingDeliverables = true
                                        }
                                    }
                                    if item.kind == .failure,
                                       let session = self.store.sessions.first(where: { $0.key == item.sessionKey }) {
                                        Button("Dismiss failure") { self.store.acknowledgeFailure(session) }
                                    }
                                }.buttonStyle(.bordered)
                            }.padding(.vertical, 6)
                        }
                    }
                    }
                }
            }
            .navigationTitle("Needs you")
            .task { await refresh() }
            .refreshable { await refresh() }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(refreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .disabled(refreshing || !isConnected)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Done") { self.dismiss() } }
            }
            .sheet(isPresented: $showingQuestions) { QuestionInboxView(store: store) }
            .sheet(item: $detailItem) { item in TaskDetailView(store: store, taskID: nil, sessionKey: item.sessionKey) }
            .sheet(isPresented: self.$showingDeliverables) {
                DeliverablesView(store: self.store, sessionKey: self.reviewSessionKey)
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 500)
        #endif
    }

    @ViewBuilder private func recentOutcomes(at now: Date) -> some View {
        let questions = store.questionInbox.sorted.filter { !$0.request.isPending(at: now) }
        let outcomes = store.approvalActivity.values.filter { [.confirmed, .expired, .unavailable].contains($0.state) }.sorted { $0.updatedAt > $1.updatedAt }
        let expired = store.approvals.filter { approval in approval.isExpired && !outcomes.contains(where: { $0.id == approval.id }) }
        if questions.isEmpty && outcomes.isEmpty && expired.isEmpty {
            ContentUnavailableView("No recent outcomes", systemImage: "clock", description: Text("Confirmed, expired, and closed requests from this Cast session will appear here."))
        }
        ForEach(questions) { entry in QuestionCardView(store: store, requestID: entry.id, showsConversation: true) }
        ForEach(outcomes) { activity in
            VStack(alignment: .leading, spacing: 8) {
                Label(activity.state.rawValue, systemImage: activity.state == .confirmed ? "checkmark.circle" : "clock")
                    .font(.headline)
                Text(activity.approval.commandText).font(.callout).textSelection(.enabled)
                Text(activity.detail).font(.caption).foregroundStyle(.secondary)
                Button("Dismiss") { store.dismissApprovalActivity(activity.id) }
            }.padding(.vertical, 6)
        }
        ForEach(expired) { approval in ApprovalCardView(approval: approval, store: store) }
    }

    private func symbol(_ kind: AttentionItem.Kind) -> String {
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
