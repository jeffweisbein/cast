import SwiftUI

/// A flat personal chat list. Gateway inventory belongs in Manage Chats, not navigation.
struct SessionListView<NavigationHeader: View, NavigationFooter: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let store: ChatStore
    var showActivity: (() -> Void)?
    var showNeedsYou: (() -> Void)?
    private let navigationHeader: NavigationHeader
    private let navigationFooter: NavigationFooter

    init(store: ChatStore, showActivity: (() -> Void)? = nil, showNeedsYou: (() -> Void)? = nil,
         @ViewBuilder navigationHeader: () -> NavigationHeader = { EmptyView() },
         @ViewBuilder navigationFooter: () -> NavigationFooter = { EmptyView() }) {
        self.store = store
        self.showActivity = showActivity
        self.showNeedsYou = showNeedsYou
        self.navigationHeader = navigationHeader()
        self.navigationFooter = navigationFooter()
    }

    @State private var managing = false
    @State private var renaming: SessionRow?
    @State private var renameText = ""
    @State private var query = ""
    @State private var workFilter: ChatWorkFilter = .all
    /// Re-evaluates time-bound states (question/approval/agent-note expiry) without a
    /// per-row timer; the sidebar is reduced once per tick.
    @State private var stateClock = Date()

    private var selection: Binding<String?> {
        Binding(get: { store.isSideChatPresented ? store.sideChat?.sessionKey : store.selectedSessionKey },
                set: { store.selectFromSidebar($0) })
    }
    private var rows: [SessionRow] {
        store.personalChats.filter { query.isEmpty || store.chatTitle($0).localizedCaseInsensitiveContains(query) }
    }
    static func emptyFilterMessage(_ filter: ChatWorkFilter) -> String {
        switch filter {
        case .working: return "No chats are working right now."
        case .needsYou: return "Nothing needs you right now."
        case .review: return "No shared files are waiting for review."
        case .all: return "No chats."
        }
    }
    /// One pass per sidebar evaluation; rows read the dictionary and never touch transcripts.
    private func workStates(for rows: [SessionRow]) -> [String: ChatWorkState] {
        store.chatWorkStates(for: rows, at: max(stateClock, Date()))
    }
    private func filterCounts(_ states: [String: ChatWorkState]) -> [ChatWorkFilter: Int] {
        var counts: [ChatWorkFilter: Int] = [:]
        for state in states.values { counts[state.filter, default: 0] += 1 }
        return counts
    }
    var body: some View {
        @Bindable var store = store
        sidebar
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                stateClock = Date()
            }
        }
        .task(id: store.lastChatCleanupKey) {
            guard store.lastChatCleanupKey != nil else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            store.dismissChatCleanup()
        }
        .sheet(isPresented: $managing) { ManagePersonalChatsView(store: store) }
        .sheet(isPresented: $store.newPersonalChatPresented) { NewPersonalChatView(store: store) }
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Chat name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let row = renaming { store.updatePersonalChat(row.key) { $0.title = renameText.trimmingCharacters(in: .whitespacesAndNewlines) } }
                renaming = nil
            }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renameText.count > 100)
        }
    }

    @ViewBuilder private var sidebar: some View {
        #if os(iOS)
        GeometryReader { geometry in
            // The keyboard reduces available height even on a wide/regular-width phone.
            // Keep one scroll owner: fixed chrome must never squeeze the chats to zero.
            let shortHeight = geometry.size.height < 420
            let states = workStates(for: store.personalChats)
            List(selection: selection) {
                if !shortHeight { navigationHeader.sidebarChromeRow() }
                chatControls(compact: shortHeight, states: states).sidebarChromeRow()
                chatRows(compact: shortHeight, states: states)
                notices.sidebarChromeRow()
                manageButton.sidebarChromeRow()
                if shortHeight { navigationHeader.sidebarChromeRow() }
                navigationFooter.sidebarChromeRow()
            }
            .listStyle(.sidebar)
            .contentMargins(.top, shortHeight ? 0 : nil, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            // Thumb-zone actions: pinned switcher + New chat. Dropped while the keyboard
            // leaves too little height, so rows always keep the scroll space.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !shortHeight { ChatsBottomControls(store: store) }
            }
            .refreshable { await store.refreshSessions(); await store.refreshSideChats(); await store.syncChatSidebar() }
        }
        #else
        let states = workStates(for: store.personalChats)
        VStack(spacing: 0) {
            chatControls(compact: false, states: states)
            List(selection: selection) { chatRows(compact: false, states: states) }
                .listStyle(.sidebar)
                .refreshable { await store.refreshSessions(); await store.refreshSideChats(); await store.syncChatSidebar() }
            notices
            manageButton
        }
        #endif
    }

    private func chatControls(compact: Bool, states: [String: ChatWorkState]) -> some View {
        VStack(spacing: 0) {
            #if os(macOS)
            if !compact {
                HStack {
                    Text("Chats").font(.headline)
                    Spacer()
                    newChatButton
                }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            }
            #endif
            // iOS: the navigation bar already says "Chats" and New chat lives in the bottom
            // controls, so the list starts directly with search.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chats", text: $query).textFieldStyle(.plain)
                    .accessibilityIdentifier("personal-chat-search")
                // Short heights (landscape phone, keyboard up) drop the bottom controls, so
                // New chat stays reachable inline instead.
                if compact { newChatButton }
            }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12).padding(.bottom, 8)
                #if os(iOS)
                .padding(.top, compact ? 0 : 4)
                #endif
            // Counts follow the search text so a chip never promises rows the list hides.
            let searchedKeys = Set(rows.map { SessionKeyMatcher.canonical($0.key) })
            let counts = filterCounts(states.filter { searchedKeys.contains($0.key) })
            if !compact, workFilter != .all || counts.values.contains(where: { $0 > 0 }) {
                ChatFilterBar(filter: $workFilter, counts: counts).padding(.bottom, 6)
            }
        }
    }

    private var newChatButton: some View {
        Button { store.newPersonalChatPresented = true } label: {
            #if os(iOS)
            Image(systemName: "square.and.pencil").frame(width: 44, height: 44).contentShape(Rectangle())
            #else
            Image(systemName: "square.and.pencil").frame(width: 28, height: 28)
            #endif
        }
        .buttonStyle(.plain).help("New chat")
        .accessibilityLabel("New chat").accessibilityIdentifier("personal-new-chat")
        .keyboardShortcut("n", modifiers: .command)
    }

    @ViewBuilder private func chatRows(compact: Bool, states: [String: ChatWorkState]) -> some View {
        let searched = self.rows
        // Filtering keeps the pinned-first, user-chosen order; it never re-sorts by state.
        let rows = ChatWorkStateReducer.filter(searched, by: compact ? .all : workFilter, states: states)
        let pinned = rows.filter { store.isSessionPinned($0.key) }
        let other = rows.filter { !store.isSessionPinned($0.key) }
        if compact {
            ForEach(pinned + other) { chatRow($0, state: states[SessionKeyMatcher.canonical($0.key)]) }
        } else {
            if !pinned.isEmpty {
                Section("Pinned") { ForEach(pinned) { chatRow($0, state: states[SessionKeyMatcher.canonical($0.key)]) } }
            }
            if !other.isEmpty {
                Section(pinned.isEmpty ? "Your chats" : "Other chats") { ForEach(other) { chatRow($0, state: states[SessionKeyMatcher.canonical($0.key)]) } }
            }
        }
        if rows.isEmpty {
            if !searched.isEmpty, workFilter != .all {
                VStack(alignment: .leading, spacing: 6) {
                    Text(query.isEmpty ? Self.emptyFilterMessage(workFilter) : "No matching chats in \(workFilter.title).")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Show all chats") { workFilter = .all }.buttonStyle(.borderless)
                }.padding(.vertical, 8)
            } else {
                Text(query.isEmpty ? "Create a chat or choose an existing one in Manage Chats." : "No matching chats.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if let notice = store.chatSidebarSyncNotice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(10) }
        if let update = store.updateNotice { Text(update).font(.caption).foregroundStyle(.secondary).padding(10) }
        if let notice = store.sessionsSyncNotice {
            HStack {
                Image(systemName: "wifi.exclamationmark")
                Text(notice).lineLimit(2)
                Button("Retry") { store.retrySessionsNow() }.buttonStyle(.borderless)
            }.font(.caption).foregroundStyle(.secondary).padding(10)
        }
        if store.lastChatCleanupKey != nil {
            HStack {
                Text("Chat removed from list").font(.caption)
                Spacer()
                Button("Undo") { store.undoChatCleanup() }.buttonStyle(.borderless)
                    .accessibilityIdentifier("chat-cleanup-undo")
            }.padding(10)
        }
    }

    private var manageButton: some View {
        VStack(spacing: 0) {
            Divider()
            Button { managing = true } label: {
                Label("Manage Chats", systemImage: "tray").frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("manage-chats")
        }
    }

    private func chatRow(_ row: SessionRow, state: ChatWorkState?) -> some View {
        HStack(spacing: 4) {
            Button { store.selectFromSidebar(row.key) } label: {
                PersonalChatRowLabel(
                    title: store.chatTitle(row),
                    preview: SidebarGrouper.cleanPreview(row.lastMessagePreview),
                    updated: row.updatedDate,
                    unread: store.unreadCount(for: row.key) > 0 || row.isUnread,
                    state: state)
            }.buttonStyle(.plain).accessibilityIdentifier("personal-chat-" + row.key)
            Menu { actions(row) } label: {
                Image(systemName: "ellipsis").foregroundColor(colorScheme == .dark ? Color.white.opacity(0.8) : Color.black.opacity(0.6)).frame(width: 44, height: 44).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                #if os(macOS)
                // AppKit's borderless menu ignores the SwiftUI label tint in a dark sidebar.
                .brightness(colorScheme == .dark ? 0.8 : 0)
                #endif
                .accessibilityLabel("Actions for " + store.chatTitle(row))
                .accessibilityIdentifier("personal-actions-" + row.key)
        }
        .tag(row.key)
        .padding(.horizontal, 6)
        .background(isSelected(row) ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
        .accessibilityAddTraits(isSelected(row) ? .isSelected : [])
        .contextMenu { actions(row) }
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Archive", systemImage: "archivebox") { store.cleanupPersonalChat(row.key, archive: true) }.tint(.orange)
        }
        #endif
    }
    private func isSelected(_ row: SessionRow) -> Bool {
        store.isSideChatPresented ? store.sideChat?.sessionKey == row.key : store.selectedSessionKey == row.key
    }
    @ViewBuilder private func actions(_ row: SessionRow) -> some View {
        Button(store.isSessionPinned(row.key) ? "Unpin" : "Pin", systemImage: "pin") { store.toggleSessionPinned(row.key) }
        if store.isSessionPinned(row.key) {
            // Moves act on the full pinned order; a filtered list would hide the neighbour.
            Button("Move up", systemImage: "arrow.up") { store.movePinnedChat(row.key, by: -1) }
                .disabled(workFilter != .all)
            Button("Move down", systemImage: "arrow.down") { store.movePinnedChat(row.key, by: 1) }
                .disabled(workFilter != .all)
        }
        Button("Rename", systemImage: "pencil") { renameText = store.chatTitle(row); renaming = row }
        Button(store.isSessionMuted(row.key) ? "Unmute" : "Mute", systemImage: "bell.slash") { store.setSessionMuted(!store.isSessionMuted(row.key), sessionKey: row.key) }
        Divider()
        Button("Archive", systemImage: "archivebox") { store.cleanupPersonalChat(row.key, archive: true) }
        Button("Hide", systemImage: "eye.slash") { store.cleanupPersonalChat(row.key, archive: false) }
    }
}

struct ManagePersonalChatsView: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var section = "Available"
    @State private var restoreError: String?
    @State private var restoring: String?
    private var rows: [SessionRow] {
        store.manageableChats.filter { row in
            let matches = query.isEmpty || store.chatTitle(row).localizedCaseInsensitiveContains(query)
            switch section {
            case "Archived": return matches && (store.isChatArchived(row.key) || row.archived == true)
            case "Hidden": return matches && store.isSessionHidden(row.key)
            default: return matches && !store.isChatArchived(row.key) && !store.isSessionHidden(row.key) && row.archived != true
            }
        }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Show", selection: $section) {
                    Text("Available").tag("Available"); Text("Archived").tag("Archived"); Text("Hidden").tag("Hidden")
                }.pickerStyle(.segmented).padding(.horizontal)
                TextField("Find an existing chat", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal)
                List(rows) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.chatTitle(row)).lineLimit(2)
                            if !store.isPersonalChat(row) { Text("Not in your sidebar").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if section != "Available" || !store.isPersonalChat(row) {
                            Button(section == "Available" ? "Keep" : "Restore") {
                                restoring = row.key; restoreError = nil
                                Task {
                                    do { try await store.restorePersonalChat(row) }
                                    catch { restoreError = error.localizedDescription }
                                    restoring = nil
                                }
                            }.disabled(restoring != nil)
                                .accessibilityIdentifier("keep-chat-" + row.key)
                        } else { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
                }
                if let restoreError { Text(restoreError).font(.callout).foregroundStyle(.red).padding(.horizontal) }
                if let notice = store.chatSidebarSyncNotice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                Picker("Automatically archive inactive side chats", selection: Binding(get: { store.sideChatAutoArchiveDays }, set: { store.setSideChatAutoArchiveDays($0) })) {
                    Text("Never").tag(0); Text("After 30 days").tag(30); Text("After 60 days").tag(60); Text("After 90 days").tag(90)
                }.font(.caption).padding(.horizontal)
                Text("Hiding or archiving keeps the conversation and its history. Background work is available in Activity.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            .padding(.vertical, 12).navigationTitle("Manage Chats")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.syncChatSidebar() }
        }
        #if os(macOS)
        .frame(width: 560, height: 520)
        #endif
    }
}

struct NewPersonalChatView: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var message = ""
    @State private var sending = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Chat name", text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("new-chat-name")
                HStack {
                    ForEach(["Cast", "Cackles", "RunPR", "General"], id: \.self) { title in
                        Button(title) { name = title }.buttonStyle(.borderless)
                    }
                }.font(.callout)
                Text("First message").font(.headline)
                TextEditor(text: $message).frame(minHeight: 140).accessibilityIdentifier("new-chat-message")
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                if !store.canCreatePersonalChat { Text(store.chatSidebarSyncNotice ?? "Connect to your gateway to send and create this chat.").font(.caption).foregroundStyle(.secondary) }
                Text("A chat is created only when you send. Cancelling creates nothing.").font(.caption).foregroundStyle(.secondary)
            }.padding(20).navigationTitle("New Chat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(sending) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Creating…" : "Send") {
                        sending = true; error = nil
                        Task {
                            do { _ = try await store.createNamedChat(title: name, firstMessage: message); dismiss() }
                            catch { self.error = error.localizedDescription }
                            sending = false
                        }
                    }.disabled(sending || !store.canCreatePersonalChat || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 100 || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(sending)
        #if os(macOS)
        .frame(width: 540, height: 420)
        #endif
    }
}

struct SessionRowView: View {
    let session: SessionRow
    let category: SessionCategory
    let mainSessionKey: String?
    let subtitle: String?
    let unreadCount: Int
    let failureAcknowledged: Bool
    let acknowledgeFailure: () -> Void
    // Defaulted so surfaces that reuse the row (Activity, search) can skip the mute
    // affordance until stage 3 decides their placement.
    var isMuted: Bool = false
    var toggleMute: (() -> Void)? = nil
    var isPinned: Bool = false
    var isHidden: Bool = false
    var togglePin: (() -> Void)? = nil
    var toggleHidden: (() -> Void)? = nil
    /// Non-nil when a progress card exists for this session with at least one step.
    var progressSteps: (completed: Int, total: Int)? = nil

    private var title: String {
        SidebarGrouper.displayTitle(for: self.session, mainSessionKey: self.mainSessionKey)
    }

    private var preview: String? {
        SidebarGrouper.cleanPreview(self.session.lastMessagePreview)
    }

    private var accent: SessionAccent {
        SidebarGrouper.accent(for: self.session, mainSessionKey: self.mainSessionKey)
    }

    private var operationalStatus: SessionOperationalStatus {
        SidebarGrouper.operationalStatus(
            for: self.session,
            mainSessionKey: self.mainSessionKey,
            now: Date(),
            acknowledgedFailures: self.failureAcknowledged
                ? Set([SessionAttentionIdentifier(
                    sessionKey: self.session.key,
                    updatedAt: self.session.updatedAt)].compactMap { $0 })
                : [])
    }

    private var icon: String {
        switch self.accent {
        case .spark: return "sparkle"
        case .channel: return self.channelIcon
        case .task: return "point.3.connected.trianglepath.dotted"
        case .cron: return "clock.arrow.circlepath"
        case .dreaming: return "moon.zzz.fill"
        case .terminal: return "terminal.fill"
        }
    }

    private var channelIcon: String {
        switch self.session.channel {
        case "imessage": return "message.fill"
        case "telegram", "signal", "whatsapp": return "paperplane.fill"
        case "discord": return "gamecontroller.fill"
        default: return "bubble.left.fill"
        }
    }

    /// One tint per session kind (spec 4): subtle tinted symbol on a soft circle,
    /// consistent across macOS and iOS.
    private var iconColor: Color {
        switch self.accent {
        case .spark: return .orange
        case .channel: return .blue
        case .task: return .purple
        case .cron: return .teal
        case .dreaming: return .indigo
        case .terminal: return .gray
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: self.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(self.iconColor)
                .frame(width: 26, height: 26)
                .background(Circle().fill(self.iconColor.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(self.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if self.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned chat")
                    }
                    if self.isHidden {
                        Image(systemName: "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Hidden chat")
                    }
                    if let subtitle = self.subtitle {
                        Text(subtitle)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary.opacity(0.6)))
                    }
                    if self.session.hasActiveRun == true {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                    }
                    if self.category == .task || self.category == .automation {
                        Text(self.operationalStatus.label)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(self.statusColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if self.unreadCount > 0 {
                        Text("\(self.unreadCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.blue))
                            .accessibilityLabel("Unread conversation")
                    }
                    if let steps = self.progressSteps, steps.total > 0 {
                        ProgressCardPill(completed: steps.completed, total: steps.total)
                    }
                    if let date = self.session.updatedDate {
                        Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let preview = self.preview {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(self.category == .automation ? 1 : 2)
                }
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if let togglePin = self.togglePin {
                Button(self.isPinned ? "Unpin Chat" : "Pin Chat",
                       systemImage: self.isPinned ? "pin.slash" : "pin", action: togglePin)
            }
            if let toggleHidden = self.toggleHidden {
                Button(self.isHidden ? "Show in Sidebar" : "Hide from Sidebar",
                       systemImage: self.isHidden ? "eye" : "eye.slash", action: toggleHidden)
            }
            if self.operationalStatus == .needsAttention,
               SidebarGrouper.hasFailureSignal(self.session)
            {
                Button("Dismiss Failure", systemImage: "checkmark.circle", action: self.acknowledgeFailure)
            }
            if let toggleMute = self.toggleMute {
                Button(
                    self.isMuted ? "Unmute Notifications" : "Mute Notifications",
                    systemImage: self.isMuted ? "bell" : "bell.slash",
                    action: toggleMute)
            }
            // Minimal context-fill surfacing (stage 3 owns the real treatment): a session
            // nearing its window is about to compact, which explains sudden memory loss.
            if let fill = self.session.contextFillFraction {
                Text("Context \(Int((fill * 100).rounded()))% full")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let toggleHidden = self.toggleHidden {
                Button(self.isHidden ? "Show" : "Hide",
                       systemImage: self.isHidden ? "eye" : "eye.slash", action: toggleHidden)
                    .tint(.gray)
            }
            if self.operationalStatus == .needsAttention,
               SidebarGrouper.hasFailureSignal(self.session)
            {
                Button("Dismiss", action: self.acknowledgeFailure)
                    .tint(.orange)
            }
        }
    }

    private var statusColor: Color {
        switch self.operationalStatus {
        case .needsAttention: return .orange
        case .running: return .green
        case .failed: return .red
        case .done, .healthy, .idle: return .secondary
        }
    }
}

#if os(iOS)
private extension View {
    func sidebarChromeRow() -> some View {
        self.listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
#endif
