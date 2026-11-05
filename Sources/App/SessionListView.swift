import SwiftUI

struct SessionListView: View {
    let store: ChatStore
    /// Presented by the owning view so the activity sheet survives sidebar rebuilds.
    var showActivity: (() -> Void)?
    @AppStorage("sidebar.work.expanded") private var workExpanded = false

    private var sidebarSelection: Binding<String?> {
        Binding(
            get: { self.store.selectedSessionKey },
            set: { self.store.selectFromSidebar($0) })
    }

    var body: some View {
        // `searchable` needs a write path into the store's own query, which under
        // Observation comes from a local `@Bindable` rather than the view's storage. The
        // store stays a plain reference so nothing else here observes more than it reads.
        @Bindable var store = self.store
        List(selection: self.sidebarSelection) {
            if self.store.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                if let chats = self.section(.main) {
                    Section(chats.title) {
                        self.rows(chats)
                        if chats.sessions.isEmpty, !self.store.hiddenSessions.isEmpty,
                           !self.store.showHiddenSessions {
                            Button("Show hidden chats") { self.store.showHiddenSessions = true }
                                .font(.caption)
                        }
                    }
                }
                Section("Activity") {
                    self.activityStrip
                }
                if !self.workSections.isEmpty {
                    Section(isExpanded: self.$workExpanded) {
                        ForEach(self.workSections) { section in
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            self.rows(section)
                        }
                    } header: {
                        Text("Work (\(self.workSections.flatMap(\.sessions).count))")
                    }
                }
                if self.store.showHiddenSessions {
                    Section("Hidden chats (\(self.store.hiddenSessions.count))") {
                        if self.store.hiddenSessions.isEmpty {
                            Text("No hidden chats")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(self.store.hiddenSessions) { session in
                            self.row(session, category: SidebarGrouper.category(
                                for: session, mainSessionKey: self.store.mainSessionKey))
                        }
                    }
                }
            } else {
                self.searchResults
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $store.searchQuery, prompt: "Search chats and messages")
        .overlay {
            if self.store.sessions.isEmpty,
               self.store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text(self.statusText))
            }
        }
        .refreshable { await self.store.refreshSessions() }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Conversations")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Toggle("Show hidden chats", isOn: $store.showHiddenSessions)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Sidebar options")
                    .help("Show or restore hidden chats")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                if let notice = self.store.sessionsSyncNotice {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 2)
                        Button("Retry") { self.store.retrySessionsNow() }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(.regularMaterial)
                    .overlay(alignment: .bottom) { Divider() }
                }
                if let update = self.store.updateNotice {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                        Text(update)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                    }
                    .padding(8)
                    .background(.regularMaterial)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if self.store.lastHiddenSessionKey != nil {
                HStack {
                    Text("Chat hidden")
                        .font(.caption)
                    Spacer()
                    Button("Undo") { self.store.undoHideSession() }
                        .buttonStyle(.borderless)
                }
                .padding(10)
                .background(.regularMaterial)
            }
        }
        .task(id: self.store.lastHiddenSessionKey) {
            guard self.store.lastHiddenSessionKey != nil else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self.store.dismissHideUndo()
        }
    }

    private func section(_ category: SessionCategory) -> SidebarSection? {
        self.store.sidebarSections.first(where: { $0.category == category })
    }

    private var workSections: [SidebarSection] {
        [.task, .automation, .chat].compactMap(self.section)
    }

    private var activityStrip: some View {
        let summary = self.store.sidebarActivitySummary
        return Button {
            self.showActivity?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: summary.running > 0 ? "waveform.path.ecg" : "clock.arrow.circlepath")
                    .foregroundStyle(summary.failed > 0 ? .orange : .secondary)
                    .frame(width: 24)
                Text(summary.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if summary.failed > 0 {
                    Text("\(summary.failed)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.orange))
                        .accessibilityLabel("\(summary.failed) unacknowledged failures")
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Activity, \(summary.text)")
    }

    private func rows(_ section: SidebarSection) -> some View {
        ForEach(section.sessions) { session in
            self.row(session, category: section.category)
        }
    }

    private func row(_ session: SessionRow, category: SessionCategory) -> some View {
        SessionRowView(
            session: session,
            category: category,
            mainSessionKey: self.store.mainSessionKey,
            subtitle: self.store.sidebarSubtitle(for: session),
            unreadCount: self.store.unreadCount(for: session.key),
            failureAcknowledged: self.store.isFailureAcknowledged(session),
            acknowledgeFailure: { self.store.acknowledgeFailure(session) },
            isMuted: self.store.isSessionMuted(session.key),
            toggleMute: { self.store.toggleSessionMuted(session.key) },
            isPinned: self.store.isSessionPinned(session.key),
            isHidden: self.store.isSessionHidden(session.key),
            togglePin: { self.store.toggleSessionPinned(session.key) },
            toggleHidden: {
                self.store.setSessionHidden(!self.store.isSessionHidden(session.key), sessionKey: session.key)
            },
            progressSteps: self.store.progressCard(for: session.key).flatMap { card in
                card.totalStepCount > 0 ? (card.completedStepCount, card.totalStepCount) : nil
            })
            .tag(session.key)
    }

    @ViewBuilder
    private var searchResults: some View {
        let query = self.store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.count < 2 {
            Section {
                Label("Type at least two characters", systemImage: "text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if self.store.isSearching {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching saved messages…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if self.store.visibleSearchHits.isEmpty, self.store.visibleSessions.isEmpty {
            Section {
                Label("No chats or messages match “\(query)”", systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if !self.store.visibleSearchHits.isEmpty {
            Section("Messages") {
                ForEach(self.store.visibleSearchHits.prefix(30)) { hit in
                    Button {
                        self.store.selectedSessionKey = hit.sessionKey
                        self.store.searchQuery = ""
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(self.searchTitle(for: hit.sessionKey))
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(hit.role == "user" ? "You" : "Agent")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 4)
                                if let timestamp = hit.timestamp, timestamp.isFinite {
                                    Text(Date(timeIntervalSince1970: timestamp / 1000), style: .date)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            self.highlightedSnippet(hit)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !self.store.visibleSessions.isEmpty {
            Section("Matching conversations") {
                ForEach(self.store.visibleSessions) { session in
                    self.row(session, category: SidebarGrouper.category(
                        for: session, mainSessionKey: self.store.mainSessionKey))
                }
            }
        }
    }

    private func searchTitle(for key: String) -> String {
        guard let session = self.store.sessions.first(where: { $0.key == key }) else {
            return SidebarGrouper.humanize(SidebarGrouper.tailSegment(of: key))
        }
        return SidebarGrouper.displayTitle(for: session, mainSessionKey: self.store.mainSessionKey)
    }

    private func highlightedSnippet(_ hit: CachedSearchHit) -> Text {
        var attributed = AttributedString(hit.snippet)
        if let term = hit.matchedText,
           let range = attributed.range(
               of: term,
               options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
        {
            attributed[range].font = .caption.bold()
            attributed[range].foregroundColor = .accentColor
        }
        return Text(attributed)
    }

    private var statusText: String {
        if case let .disconnected(reason) = self.store.connectionState {
            return reason ?? "Disconnected"
        }
        if case .waitingForApproval = self.store.connectionState { return "Waiting for approval on the gateway…" }
        if case .needsCredentials = self.store.connectionState { return "Pair this workspace to continue." }
        return "Waiting for the gateway…"
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
                            .accessibilityLabel("\(self.unreadCount) unread agent replies")
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
