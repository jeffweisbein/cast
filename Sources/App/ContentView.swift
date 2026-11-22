import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @EnvironmentObject private var manager: WorkspaceManager
    @State private var showingPairing = false
    @State private var pairingWorkspaceID: String?

    var body: some View {
        Group {
            if let store = self.manager.selectedStoreIfConfigured {
                WorkspaceContentView(
                    store: store,
                    manager: self.manager,
                    showingPairing: self.$showingPairing)
                    .id(self.manager.selectedWorkspaceID)
            } else {
                UnconfiguredWorkspaceView {
                    self.manager.presentOnboarding()
                }
            }
        }
            .sheet(isPresented: self.$showingPairing, onDismiss: {
                self.pairingWorkspaceID = nil
            }) {
                PairWorkspaceView(
                    manager: self.manager,
                    initialConnectingWorkspaceID: self.pairingWorkspaceID)
                {
                    if self.pairingWorkspaceID != nil { self.manager.completeOnboarding() }
                }
            }
            .sheet(isPresented: Binding(
                get: { self.manager.isOnboardingPresented },
                set: { if !$0 { self.manager.dismissOnboarding() } }))
            {
                OnboardingView(manager: self.manager)
            }
            .alert("Couldn’t use that setup link", isPresented: Binding(
                get: { self.manager.pairingError != nil },
                set: { if !$0 { self.manager.pairingError = nil } }))
            {
                Button("Open Setup") {
                    self.manager.pairingError = nil
                    self.manager.presentOnboarding()
                }
                Button("OK", role: .cancel) { self.manager.pairingError = nil }
            } message: {
                Text(self.manager.pairingError ?? "Open Cast setup and try a fresh code.")
            }
            .alert("Shared item queued", isPresented: Binding(
                get: { self.manager.pendingShareError != nil },
                set: { if !$0 { self.manager.pendingShareError = nil } }))
            {
                Button("OK") { self.manager.pendingShareError = nil }
            } message: {
                Text(self.manager.pendingShareError ?? "The shared item could not be routed.")
            }
            .onOpenURL { self.handleURL($0) }
            #if os(macOS)
            .onAppear { self.updateDockBadge(self.manager.unreadSessionCount) }
            .onChange(of: self.manager.unreadSessionCount) { _, count in
                self.updateDockBadge(count)
            }
            #endif
    }

    #if os(macOS)
    private func updateDockBadge(_ count: Int) {
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }
    #endif

    private func handleURL(_ url: URL) {
        guard url.scheme == "cast", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if url.host == "pair",
           let code = components.queryItems?.first(where: { $0.name == "setup" || $0.name == "code" })?.value {
            do {
                self.pairingWorkspaceID = try self.manager.pair(name: "Workspace", setupCode: code)
                self.manager.dismissOnboarding()
                self.showingPairing = true
            }
            catch { self.manager.pairingError = PairingError.userFacingMessage(for: error) }
            return
        }
        #if os(iOS)
        if url.host == "share" {
            let requestID = components.queryItems?
                .first(where: { $0.name == "id" })?
                .value
                .flatMap(UUID.init(uuidString:))
            Task { await self.manager.consumePendingShares(requestID: requestID) }
            return
        }
        #endif
        if let workspace = components.queryItems?.first(where: { $0.name == "workspace" })?.value {
            self.manager.select(workspace)
        }
        if let key = components.queryItems?.first(where: { $0.name == "session" })?.value {
            self.manager.selectedStoreIfConfigured?.selectedSessionKey = key
        }
    }
}

struct UnconfiguredWorkspaceView: View {
    let startSetup: () -> Void
    @State private var showingDemo = false

    var body: some View {
        ContentUnavailableView {
            Label("Connect your OpenClaw", systemImage: "link.badge.plus")
        } description: {
            Text("Cast connects directly to an OpenClaw gateway you control. Add a workspace to begin.")
        } actions: {
            Button("Set Up Cast", action: self.startSetup)
                .buttonStyle(.borderedProminent)
            Button("Try Demo") { self.showingDemo = true }
                .buttonStyle(.bordered)
        }
        .sheet(isPresented: self.$showingDemo) { DemoWorkspaceView() }
    }
}

struct WorkspaceContentView: View {
    let store: ChatStore
    @ObservedObject var manager: WorkspaceManager
    @Binding var showingPairing: Bool
    private var sideChatPresentation: Binding<Bool> {
        Binding(get: { store.isSideChatPresented }, set: { store.isSideChatPresented = $0 })
    }
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var showingNotificationCenter = false
    @State private var showingActivity = false
    @State private var showingNeedsYou = false
    @State private var showingDeliverables = false
    @State private var showingDownloads = false
    @State private var showingStatus = false
    @State private var showingSearch = false
    @State private var showingTasks = false
    #if os(iOS)
    /// Always launches on Chats: the user's own list is the landing, never a greeting.
    @State private var tab: CastTab = .chats
    @State private var showingUnreadInbox = false
    /// Re-evaluates time-bound attention (question/approval expiry) for the tab badge.
    @State private var badgeClock = Date()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    #if os(macOS)
    @AppStorage("sidebar.tools.expanded") private var toolsExpanded = false

    private var workspaceTools: some View {
        DisclosureGroup(isExpanded: self.$toolsExpanded) {
            VStack(spacing: 0) {
                Button {
                    self.showingNeedsYou = true
                } label: {
                    HStack {
                        Label("All attention items", systemImage: "hand.raised")
                        Spacer()
                        Text("\(self.store.attentionItems.count)").monospacedDigit()
                    }.padding(.vertical, 9)
                }.buttonStyle(.plain)
                HStack {
                    Button("Search", systemImage: "magnifyingglass") { showingSearch = true }
                        .keyboardShortcut("k", modifiers: .command)
                    Spacer()
                    Button("Tasks", systemImage: "checklist") { showingTasks = true }
                }.buttonStyle(.plain).padding(.bottom, 9)
                Button("Activity", systemImage: "waveform.path.ecg") { showingActivity = true }
                    .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 9)
                Button("Deliverables", systemImage: "tray.full") { self.showingDeliverables = true }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 9)
                Button {
                    showingDownloads = true
                } label: {
                    HStack {
                        Label("Downloads", systemImage: "arrow.down.circle")
                        if store.downloads.activeCount > 0 { Text("\(store.downloads.activeCount)").monospacedDigit() }
                    }
                }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 9)
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Text("Tools").font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if !self.toolsExpanded, !self.store.attentionItems.isEmpty {
                    Label("\(self.store.attentionItems.count)", systemImage: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("\(self.store.attentionItems.count) items need you")
                }
                if !self.toolsExpanded, self.store.downloads.activeCount > 0 {
                    Label("\(self.store.downloads.activeCount)", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .accessibilityLabel("\(self.store.downloads.activeCount) active downloads")
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }
    #endif

    private var showsComposer: Bool {
        #if os(macOS) && DEBUG
        ProcessInfo.processInfo.environment["CAST_DISABLE_COMPOSER"] != "1"
        #else
        true
        #endif
    }

    var body: some View {
        #if os(iOS)
        let needsYouCount = CastNavigationCounts.needsYou(self.store.workAttentionItems(at: max(self.badgeClock, Date())))
        let resultsCount = CastNavigationCounts.results(self.store.resultArtifactCounts)
        TabView(selection: self.$tab) {
            Tab(CastTab.chats.title, systemImage: CastTab.chats.systemImage, value: CastTab.chats) {
                self.chatsSplitView
            }
            Tab(CastTab.needsYou.title, systemImage: CastTab.needsYou.systemImage, value: CastTab.needsYou) {
                NeedsYouTab(store: self.store, openConversation: self.openConversation, showResults: { self.tab = .results })
            }
            .badge(needsYouCount)
            Tab(CastTab.results.title, systemImage: CastTab.results.systemImage, value: CastTab.results) {
                ResultsLibraryView(store: self.store, openConversation: self.openConversation)
            }
            .badge(resultsCount)
        }
        // Any conversation request (Results, Needs You, notification routes) lands in Chats;
        // the split view below pushes the chat in the same update.
        .onChange(of: self.store.detailNavigationRequest) { _, _ in
            if self.tab != .chats { self.tab = .chats }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self.badgeClock = Date()
            }
        }
        .modifier(self.sheets)
        #else
        self.chatsSplitView
            .modifier(self.sheets)
        #endif
    }

    #if os(iOS)
    private func openConversation(_ key: String) {
        self.tab = .chats
        self.store.selectFromSidebar(key)
    }
    #endif

    private var chatsSplitView: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            Group {
                #if os(iOS)
                SessionListView(store: self.store,
                    showActivity: { self.showingActivity = true },
                    showNeedsYou: { self.tab = .needsYou }) {
                        EmptyView()
                    } navigationFooter: {
                        // Healthy connections stay quiet; problems and unconfirmed sends surface here.
                        ConnectionStatusView(store: store, showsWhenHealthy: false)
                    }
                #else
                VStack(spacing: 0) {
                    WorkspaceSwitcher(manager: self.manager, showingPairing: self.$showingPairing)
                    Divider()
                    self.workspaceTools
                    Divider()
                    SessionListView(store: self.store, showActivity: { self.showingActivity = true }, showNeedsYou: { self.showingNeedsYou = true })
                    Divider()
                    Button("Status & updates", systemImage: "info.circle") { self.showingStatus = true }
                        .buttonStyle(.plain).padding(10)
                }
                #endif
            }
                #if os(iOS)
                // One title, one place for workspace choice: the title menu replaces the old
                // workspace row + "Tools" disclosure + second "Chats" header.
                .navigationTitle(CastTab.chats.title)
                .navigationSubtitle(self.manager.selectedStore.profile.name)
                .toolbarTitleMenu { WorkspaceMenuItems(manager: self.manager, showingPairing: self.$showingPairing) }
                .toolbar {
                    if self.manager.unreadSessionCount > 0 {
                        ToolbarItem(placement: .topBarTrailing) {
                            AggregateUnreadButton(count: self.manager.unreadSessionCount) {
                                self.showingUnreadInbox = true
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) { self.moreMenu }
                }
                .sheet(isPresented: self.$showingUnreadInbox) {
                    UnreadInboxView(manager: self.manager, isPresented: self.$showingUnreadInbox)
                }
                .background { self.keyboardShortcuts }
                #else
                .navigationTitle("Cast")
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
                #endif
        } detail: {
            if self.store.selectedSessionKey != nil {
                #if os(iOS)
                ChatView(store: self.store, showsComposer: self.showsComposer, showingSideChat: self.sideChatPresentation)
                    // iPhone: the composer owns the bottom edge inside a chat; tabs return with Back.
                    .toolbar(self.horizontalSizeClass == .compact ? .hidden : .automatic, for: .tabBar)
                    .toolbar {
                        if self.horizontalSizeClass == .compact,
                           self.store.personalChats.contains(where: { self.store.isSessionPinned($0.key) }) {
                            ToolbarItem(placement: .topBarLeading) { PinnedSwitcherToolbarButton(store: self.store) }
                        }
                    }
                #else
                ChatView(store: self.store, showsComposer: self.showsComposer, showingSideChat: self.sideChatPresentation)
                #endif
            } else {
                #if os(iOS)
                ChatDetailPlaceholder(store: self.store)
                #else
                ContentUnavailableView(
                    "Pick a conversation",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Create a chat or keep an existing conversation from Manage Chats."))
                #endif
            }
        }
        .onChange(of: store.detailNavigationRequest) { _, _ in
            preferredCompactColumn = .detail
        }
        #if os(iOS)
        .onChange(of: preferredCompactColumn) { _, column in
            if column == .sidebar { store.selectFromSidebar(nil) }
        }
        #endif
        .modifier(SideChatInspector(store: self.store, isPresented: self.sideChatPresentation))
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    self.showingNotificationCenter = true
                } label: {
                    Label("Notification Center", systemImage: "bell")
                }
                .badge(self.store.notificationRecords.lazy.filter { $0.state == .failed }.count)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    self.showingActivity = true
                } label: {
                    Label("Activity", systemImage: "waveform.path.ecg")
                }
                .help("Recent tasks, failures, and scheduled run history")
            }
            ToolbarItem(placement: .automatic) {
                ConnectionBadge(workspaceName: self.store.profile.name, state: self.store.connectionState)
            }
            ToolbarItem(placement: .automatic) {
                PresenceMenu(store: self.store)
            }

        }
        #endif
    }

    #if os(iOS)
    /// Everything that used to live in the sidebar "Tools" disclosure, minus Needs You and
    /// Deliverables, which are now tabs.
    private var moreMenu: some View {
        Menu {
            Button("Search", systemImage: "magnifyingglass") { self.showingSearch = true }
            Button("Tasks", systemImage: "checklist") { self.showingTasks = true }
            Button("Activity", systemImage: "waveform.path.ecg") { self.showingActivity = true }
            Button(self.store.downloads.activeCount > 0 ? "Downloads (\(self.store.downloads.activeCount))" : "Downloads",
                   systemImage: "arrow.down.circle") { self.showingDownloads = true }
            Button("All files & links", systemImage: "tray.full") { self.showingDeliverables = true }
            Divider()
            let failed = self.store.notificationRecords.lazy.filter { $0.state == .failed }.count
            Button(failed > 0 ? "Notification Center (\(failed) failed)" : "Notification Center", systemImage: "bell") {
                self.showingNotificationCenter = true
            }
            Button("Status & updates", systemImage: "info.circle") { self.showingStatus = true }
        } label: {
            Label("More", systemImage: "ellipsis")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("chats-more-menu")
    }

    /// Hardware-keyboard shortcuts for items that moved into the More menu.
    private var keyboardShortcuts: some View {
        Group {
            Button("Search") { self.showingSearch = true }.keyboardShortcut("k", modifiers: .command)
            Button("Chats") { self.tab = .chats }.keyboardShortcut("1", modifiers: .command)
            Button("Needs You") { self.tab = .needsYou }.keyboardShortcut("2", modifiers: .command)
            Button("Results") { self.tab = .results }.keyboardShortcut("3", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
    #endif

    private var sheets: WorkspaceSheets {
        WorkspaceSheets(
            store: self.store,
            showingDownloads: self.$showingDownloads,
            showingSearch: self.$showingSearch,
            showingTasks: self.$showingTasks,
            showingNeedsYou: self.$showingNeedsYou,
            showingStatus: self.$showingStatus,
            showingDeliverables: self.$showingDeliverables,
            showingNotificationCenter: self.$showingNotificationCenter,
            showingActivity: self.$showingActivity)
    }
}

/// Every secondary screen stays one sheet away on both platforms.
private struct WorkspaceSheets: ViewModifier {
    let store: ChatStore
    @Binding var showingDownloads: Bool
    @Binding var showingSearch: Bool
    @Binding var showingTasks: Bool
    @Binding var showingNeedsYou: Bool
    @Binding var showingStatus: Bool
    @Binding var showingDeliverables: Bool
    @Binding var showingNotificationCenter: Bool
    @Binding var showingActivity: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingDownloads) { DeliverablesView(store: store, startsWithDownloads: true) }
            .sheet(isPresented: $showingSearch) { OperationsSearchView(store: store) }
            .sheet(isPresented: $showingTasks) { TasksView(store: store) }
            .sheet(isPresented: $showingNeedsYou) { NeedsYouView(store: store) }
            .sheet(isPresented: $showingStatus) { CastStatusView(store: store) }
            .sheet(isPresented: $showingDeliverables) { DeliverablesView(store: store) }
            .sheet(isPresented: $showingNotificationCenter) { OperationsNotificationCenterView(store: store) }
            .sheet(isPresented: $showingActivity) { AutomationRunsView(store: store) }
    }
}

#if os(iOS)
/// Regular-width empty detail (iPad, large landscape phones): quiet pinned shortcuts and New
/// chat instead of an empty greeting. Opening a chat stays an explicit tap, so read state is
/// never changed just by launching.
struct ChatDetailPlaceholder: View {
    let store: ChatStore

    var body: some View {
        let pinned = self.store.personalChats.filter { self.store.isSessionPinned($0.key) }.prefix(6)
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Choose a chat").font(.title3.weight(.semibold))
            if !pinned.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(pinned)) { row in
                        Button { self.store.selectFromSidebar(row.key) } label: {
                            HStack {
                                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                                Text(self.store.chatTitle(row)).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if row.key != pinned.last?.key { Divider().padding(.leading, 14) }
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: 360)
            }
            Button("New chat", systemImage: "square.and.pencil") { self.store.newPersonalChatPresented = true }
                .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Workspace choice, pairing, setup and diagnostics, shown from the Chats title menu.
private struct WorkspaceMenuItems: View {
    @ObservedObject var manager: WorkspaceManager
    @Binding var showingPairing: Bool

    var body: some View {
        ForEach(self.manager.profiles) { profile in
            Button {
                self.manager.select(profile.id)
            } label: {
                Label(profile.name, systemImage: profile.id == self.manager.selectedWorkspaceID ? "checkmark.circle.fill" : "circle")
            }
        }
        Divider()
        Button("Pair workspace…", systemImage: "qrcode.viewfinder") { self.showingPairing = true }
        Button("Cast setup & privacy…", systemImage: "questionmark.circle") { self.manager.presentOnboarding() }
        ShareLink(item: CastLifecycleDiagnostics.diagnosticsExportURL(), preview: SharePreview("Cast Diagnostics")) {
            Label("Export diagnostics…", systemImage: "square.and.arrow.up")
        }
    }
}
#endif

struct WorkspaceSwitcher: View {
    @ObservedObject var manager: WorkspaceManager
    @Binding var showingPairing: Bool
    @State private var showingUnreadInbox = false

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(self.manager.profiles) { profile in
                    Button {
                        self.manager.select(profile.id)
                    } label: {
                        Label(profile.name, systemImage: profile.id == self.manager.selectedWorkspaceID ? "checkmark.circle.fill" : "circle")
                    }
                }
                Divider()
                Button("Pair workspace…", systemImage: "qrcode.viewfinder") { self.showingPairing = true }
                Button("Cast setup & privacy…", systemImage: "questionmark.circle") {
                    self.manager.presentOnboarding()
                }
                ShareLink(
                    item: CastLifecycleDiagnostics.diagnosticsExportURL(),
                    preview: SharePreview("Cast Diagnostics"))
                {
                    Label("Export diagnostics…", systemImage: "square.and.arrow.up")
                }
            } label: {
                Label(self.manager.selectedStore.profile.name, systemImage: "square.stack.3d.up.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            Spacer()
            if self.manager.unreadSessionCount > 0 {
                AggregateUnreadButton(count: self.manager.unreadSessionCount) {
                    self.showingUnreadInbox = true
                }
                #if os(macOS)
                .popover(isPresented: self.$showingUnreadInbox, arrowEdge: .bottom) {
                    UnreadInboxView(manager: self.manager, isPresented: self.$showingUnreadInbox)
                }
                #else
                .sheet(isPresented: self.$showingUnreadInbox) {
                    UnreadInboxView(manager: self.manager, isPresented: self.$showingUnreadInbox)
                }
                #endif
            }
            if !self.manager.selectedStore.approvals.isEmpty {
                Label("\(self.manager.selectedStore.approvals.count)", systemImage: "checkmark.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("\(self.manager.selectedStore.approvals.count) pending approvals")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Opens the unread notifications panel, which lists every chat carrying unread state (across
/// workspaces) and lets the reader jump to one or mark everything read at once.
private struct AggregateUnreadButton: View {
    let count: Int
    let action: () -> Void
    #if os(macOS)
    @State private var isHovered = false
    #endif

    var body: some View {
        #if os(iOS)
        self.button
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
        #else
        self.button
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(self.isHovered ? Color.accentColor.opacity(0.12) : .clear)
            }
            .onHover { self.isHovered = $0 }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .help("Show unread notifications (⇧⌘U)")
        #endif
    }

    private var button: some View {
        Button(action: self.action) {
            Label("\(self.count)", systemImage: "bell.badge.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
                .monospacedDigit()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Unread conversations")
        .accessibilityValue("\(self.count)")
        .accessibilityHint("Opens the unread notifications panel.")
    }
}

struct ConnectionBadge: View {
    let workspaceName: String
    let state: GatewayConnectionState

    private var label: (text: String, color: Color) {
        switch self.state {
        case .connected: return (self.workspaceName, .green)
        case .connecting: return ("connecting…", .orange)
        case .waitingForApproval: return ("approve pairing", .orange)
        case .needsCredentials: return ("pair", .orange)
        case let .disconnected(reason): return (reason ?? "offline", .red)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(self.label.color)
                .frame(width: 8, height: 8)
            Text(self.label.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 220)
        .fixedSize()
    }
}

struct PresenceMenu: View {
    let store: ChatStore

    var body: some View {
        Menu {
            if self.store.presence.isEmpty {
                Text("No devices reporting presence")
            } else {
                ForEach(self.store.presence.prefix(12)) { entry in
                    Label(entry.host ?? entry.deviceFamily ?? "Device", systemImage: "circle.fill")
                }
            }
            Divider()
            Button("Rotate device token") { self.store.rotateDeviceToken() }
        } label: {
            Image(systemName: self.store.presence.isEmpty ? "person.crop.circle.badge.questionmark" : "person.2.circle.fill")
        }
        .accessibilityLabel("Connected devices and security")
    }
}
