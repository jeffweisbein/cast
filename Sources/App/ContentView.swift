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

    var body: some View {
        ContentUnavailableView {
            Label("Connect your OpenClaw", systemImage: "link.badge.plus")
        } description: {
            Text("Cast connects directly to an OpenClaw gateway you control. Add a workspace to begin.")
        } actions: {
            Button("Set Up Cast", action: self.startSetup)
                .buttonStyle(.borderedProminent)
        }
    }
}

struct WorkspaceContentView: View {
    let store: ChatStore
    @ObservedObject var manager: WorkspaceManager
    @Binding var showingPairing: Bool
    @State private var showingNotificationCenter = false
    @State private var showingActivity = false
    @State private var showingNeedsYou = false
    @State private var showingDeliverables = false
    @State private var showingDownloads = false
    @State private var showingStatus = false
    @State private var showingSearch = false
    @State private var showingTasks = false
    @AppStorage("sidebar.tools.expanded") private var toolsExpanded = false

    private var workspaceTools: some View {
        DisclosureGroup(isExpanded: self.$toolsExpanded) {
            VStack(spacing: 0) {
                Button {
                    self.showingNeedsYou = true
                } label: {
                    HStack {
                        Label("Needs you", systemImage: "hand.raised")
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

    private var showsComposer: Bool {
        #if os(macOS) && DEBUG
        ProcessInfo.processInfo.environment["CAST_DISABLE_COMPOSER"] != "1"
        #else
        true
        #endif
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                WorkspaceSwitcher(manager: self.manager, showingPairing: self.$showingPairing)
                Divider()
                self.workspaceTools
                Divider()
                SessionListView(store: self.store) { self.showingActivity = true }
                Divider()
                #if os(iOS)
                ConnectionStatusView(store: store)
                #endif
                Button("Status & updates", systemImage: "info.circle") { self.showingStatus = true }
                    .buttonStyle(.plain).padding(10)
            }
            .navigationTitle("Cast")
                #if os(iOS)
                // Compact iPhone collapses the split view, and `.automatic` items are then
                // hosted by the visible column's own bar — a toolbar declared on the split
                // view itself lands nowhere at all, which is why iOS had no bell and no New
                // Chat. Kept to two items so the iPhone bar does not crowd the title.
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            self.store.openScratchSession()
                        } label: {
                            Label("New Chat", systemImage: "square.and.pencil")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            self.showingNotificationCenter = true
                        } label: {
                            Label("Notification Center", systemImage: "bell")
                        }
                    }
                }
                #endif
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
                #endif
        } detail: {
            if self.store.selectedSessionKey != nil {
                ChatView(store: self.store, showsComposer: self.showsComposer)
            } else {
                ContentUnavailableView(
                    "Pick a conversation",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Sessions on this gateway appear in the sidebar."))
            }
        }
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
            ToolbarItem(placement: .automatic) {
                Button {
                    self.store.openScratchSession()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        #endif
        .sheet(isPresented: $showingDownloads) { DeliverablesView(store: store, startsWithDownloads: true) }
        .sheet(isPresented: $showingSearch) { OperationsSearchView(store: store) }
        .sheet(isPresented: $showingTasks) { TasksView(store: store) }
        .sheet(isPresented: self.$showingNeedsYou) { NeedsYouView(store: self.store) }
        .sheet(isPresented: self.$showingStatus) { CastStatusView(store: self.store) }
        .sheet(isPresented: self.$showingDeliverables) { DeliverablesView(store: self.store) }
        .sheet(isPresented: self.$showingNotificationCenter) {
            OperationsNotificationCenterView(store: self.store)
        }
        .sheet(isPresented: self.$showingActivity) {
            AutomationRunsView(store: self.store)
        }
    }
}

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
        .accessibilityLabel("Unread agent replies")
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
