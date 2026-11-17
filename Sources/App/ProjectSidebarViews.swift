import SwiftUI

/// Unread and execution state are separate: a reply does not mean the agent needs an answer.
struct ProjectConversationLabel: View {
    let store: ChatStore
    let session: SessionRow

    private var title: String {
        store.savedSideChats.first(where: { $0.sessionKey == session.key })?.title
            ?? SidebarGrouper.displayTitle(for: session, mainSessionKey: store.mainSessionKey)
    }
    private var needsYou: Bool { store.needsProjectAttention(sessionKey: session.key) }
    private var state: (String, String, Color)? {
        if needsYou { return ("Needs you", "hand.raised", .orange) }
        if ProjectSidebar.isWorking(session) { return ("Working", "waveform.path.ecg", .accentColor) }
        if session.status == "killed" { return ("Stopped", "stop.circle", .secondary) }
        if ["failed", "timeout"].contains(session.status ?? ""), !store.isFailureAcknowledged(session) {
            return ("Failed", "exclamationmark.circle", .red)
        }
        if session.status == "done", session.spawnedBy != nil { return ("Finished", "checkmark.circle", .secondary) }
        return nil
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: SavedSideChat.isSideChatKey(session.key) ? "text.bubble" : "bubble.left")
                .foregroundStyle(.secondary).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                if let state {
                    Label(state.0, systemImage: state.1).font(.caption2).foregroundStyle(state.2)
                }
            }
            Spacer(minLength: 2)
            if store.unreadCount(for: session.key) > 0 || session.isUnread {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.blue)
                    .accessibilityLabel("Unread reply")
            }
            if store.isSessionPinned(session.key) { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A small project landing page, not a new conversation or a separate task database.
struct ProjectOverviewView: View {
    let store: ChatStore
    var showNeedsYou: (() -> Void)?
    @State private var error: String?

    private var title: String { store.selectedProjectName ?? "General" }
    private var rows: [SessionRow] { store.projectSessions(for: store.selectedProjectName) }
    private var attention: [AttentionItem] {
        store.attentionItems.filter { item in rows.contains { row in
            item.sessionKey.map { SessionKeyMatcher.matches($0, row.key) } == true
        } }
    }
    private var working: [SessionRow] { rows.filter { ProjectSidebar.isWorking($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(title, systemImage: store.selectedProjectName == nil ? "tray" : "folder")
                        .font(.largeTitle.bold())
                    Text(store.selectedProjectName == nil
                         ? "Your general and unassigned conversations."
                         : "Conversations and work for \(title).")
                        .foregroundStyle(.secondary)
                    Button("New chat in \(title)", systemImage: "square.and.pencil") {
                        Task {
                            do { _ = try await store.createProjectChat(in: store.selectedProjectName) }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.supportsProjectChats || store.projectMutationInFlight)
                    .accessibilityIdentifier("overview-new-chat")
                }
                if !attention.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Needs you").font(.title3.bold())
                        ForEach(attention) { item in
                            Button {
                                if let key = item.sessionKey { store.selectFromSidebar(key) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(item.title, systemImage: "hand.raised").font(.headline)
                                    Text(item.detail).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            }.buttonStyle(.plain).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                if !working.isEmpty { conversationSection("Working", rows: working) }
                let recent = rows.filter { row in !working.contains(where: { $0.key == row.key }) }
                    .sorted { ($0.lastInteractionAt ?? $0.updatedAt ?? 0) > ($1.lastInteractionAt ?? $1.updatedAt ?? 0) }
                if !recent.isEmpty { conversationSection("Recent conversations", rows: Array(recent.prefix(12))) }
                if rows.isEmpty {
                    ContentUnavailableView("Start something here", systemImage: "bubble.left.and.bubble.right",
                        description: Text("Create a chat, or move an existing conversation here from its menu. Nothing is moved automatically."))
                }
                if let notice = store.projectSyncNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("project-overview")
        .alert("Couldn’t create chat", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "Please try again.") }
    }

    private func conversationSection(_ title: String, rows: [SessionRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold())
            ForEach(rows) { session in
                Button { store.selectFromSidebar(session.key) } label: {
                    ProjectConversationLabel(store: store, session: session).padding(10)
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
