import SwiftUI

struct NeedsYouView: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeliverables = false
    @State private var showingQuestions = false
    @State private var detailItem: AttentionItem?
    @State private var reviewSessionKey: String?

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let items = self.store.attentionItems(at: context.date)
                List {
                    Button("Questions and question-card settings", systemImage: "questionmark.bubble") { showingQuestions = true }
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
            .navigationTitle("Needs you")
            .refreshable {
                await self.store.refreshSessions()
                await self.store.refreshApprovals()
                await self.store.refreshQuestions()
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { self.dismiss() } } }
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
