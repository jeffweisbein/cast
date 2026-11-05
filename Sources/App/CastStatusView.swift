import SwiftUI

struct CastStatusView: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var diagnosisDraft: String?
    private var activeSessions: [SessionRow] {
        self.store.sessions.filter { $0.hasActiveRun == true || $0.status == "running" }
    }
    private var blockedSessions: [SessionRow] {
        self.store.sessions.filter { ["blocked", "failed", "error"].contains($0.status ?? "") }
    }
    private var currentCard: ProgressCard? {
        self.store.progressCards.first { SessionKeyMatcher.matches($0.key, self.store.selectedSessionKey) }?.value
    }
    private var selectedModel: String {
        guard let model = self.selectedRow?.model else { return "Not reported" }
        return [self.selectedRow?.modelInfo?.modelProvider, model].compactMap { $0 }.joined(separator: "/")
    }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown" }
    private var state: String {
        switch self.store.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .needsCredentials: return "Pair this device with your gateway in Cast setup."
        case .waitingForApproval: return "Approve this device on your OpenClaw gateway."
        case .disconnected: return "Offline. Check that your gateway is running and this device can reach its network or VPN."
        }
    }
    private var selectedRow: SessionRow? {
        self.store.sessions.first { SessionKeyMatcher.matches($0.key, self.store.selectedSessionKey) }
    }
    private var failure: SessionRunFailure? {
        self.store.sessionFailures.first { SessionKeyMatcher.matches($0.key, self.store.selectedSessionKey) }?.value
    }
    private var compaction: SessionCompactionStatus? {
        self.store.sessionCompactions.first { SessionKeyMatcher.matches($0.key, self.store.selectedSessionKey) }?.value
    }
    private var historyState: String {
        switch self.store.historySyncState {
        case .idle: return "Idle"
        case .loading: return "Refreshing conversation"
        case .stale(_, let scheduled): return scheduled ? "Showing saved messages; refresh retry scheduled" : "Showing saved messages; refresh needed"
        }
    }
    private var unconfirmedSends: Int { self.store.messages.filter { $0.localDeliveryState == .uncertain }.count }
    private var isConnected: Bool {
        if case .connected = self.store.connectionState { return true }
        return false
    }
    /// Intentionally excludes addresses, tokens, session titles, and transcript content.
    private var summary: String {
        "Cast \(self.version) (\(self.build))\nConnection: \(self.state)\nGateway: \(self.store.gatewayVersion ?? "not reported")\nModel controls: \(self.store.supportsModelControls ? "advertised" : "not advertised")\nArtifact downloads: \(self.store.gatewayMethods.contains("artifacts.download") ? "advertised" : "not advertised")\nContext (last reported): \(self.selectedRow?.contextUsageSummary ?? "Not reported")\nHistory: \(self.historyState)\nUnconfirmed sends in loaded conversation: \(self.unconfirmedSends)\nLast observed failure: \(self.failure?.category.title ?? "None observed in this app session")\nCompaction: \(self.compaction?.label ?? "No operation observed in this app session")"
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("This build") {
                    LabeledContent("Version", value: "\(self.version) (\(self.build))")
                    LabeledContent("Source", value: Bundle.main.object(forInfoDictionaryKey: "CastGitSHA") as? String ?? "Unknown")
                    #if os(macOS)
                    CheckForUpdatesButton()
                    UpdatePreferencesView()
                    if !CastUpdates.shared.configured {
                        Text("Automatic updates are not configured. Pull the latest source and use the signed install script, or install a signed release from your administrator.").foregroundStyle(.secondary)
                    }
                    #else
                    Text("Use TestFlight or the App Store to update this device.").foregroundStyle(.secondary)
                    #endif
                }
                Section("Connection health") {
                    Text(self.state)
                    LabeledContent("Gateway version", value: self.store.gatewayVersion ?? "Not reported")
                    Text("Model controls: \(self.store.supportsModelControls ? "supported by this gateway" : "not advertised by this gateway")")
                    Text("Remote files: \(self.store.gatewayMethods.contains("sessions.files.get") ? "supported types only" : "not advertised by this gateway")")
                    Text("Artifact downloads: \(self.store.gatewayMethods.contains("artifacts.download") ? "supported by this gateway" : "not advertised by this gateway")")
                    Text("If a supported action is denied, check this device’s permissions in OpenClaw. Re-pair only when the gateway requests it.").foregroundStyle(.secondary)
                    ShareLink("Share safe connection summary", item: self.summary)
                    Button("Prepare diagnosis") { self.diagnosisDraft = DiagnosisRequest.draft(safeSummary: self.summary) }
                    Text("Review and copy a bounded investigation request. Nothing is sent or changed automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("This workspace") {
                    LabeledContent("Host", value: self.store.profile.name)
                    LabeledContent("Active · loaded sessions", value: "\(self.activeSessions.count)")
                    LabeledContent("Blocked or failed · loaded sessions", value: "\(self.blockedSessions.count)")
                    ForEach(self.blockedSessions.prefix(5)) { row in
                        VStack(alignment: .leading) {
                            Text(row.title).lineLimit(1)
                            Text(row.modelInfo?.agentStatus?.note ?? "Open this conversation for its last reported blocker.")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    Text("These are reported session states, not proof that jobs produced their expected output.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if self.store.selectedSessionKey != nil {
                    Section("Model and usage") {
                        LabeledContent("Selected · last reported", value: self.selectedModel)
                        if let key = self.store.selectedSessionKey, let pending = self.store.pendingModelChanges[key] {
                            LabeledContent("Requested change", value: pending)
                        }
                        LabeledContent("Actual running model", value: "Not separately reported by this gateway")
                        LabeledContent("Reasoning", value: self.selectedRow?.modelInfo?.thinkingLevel ?? self.selectedRow?.modelInfo?.thinkingDefault ?? "Not reported")
                        LabeledContent("Session estimate", value: self.selectedRow?.estimatedCostSummary ?? "Not reported")
                        Text("Estimates are not invoices. Zero reported API cost does not mean a subscription is free. Provider quota and cross-host spending are not reported here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Current conversation") {
                        if let card = self.currentCard {
                            LabeledContent("Agent progress", value: "\(card.completedStepCount) / \(card.totalStepCount) steps")
                            LabeledContent("Progress updated", value: card.updatedDate.formatted(date: .abbreviated, time: .standard))
                        }
                        Text("Runtime verification is not reported as structured evidence by this gateway; a completed progress card alone is not verification.")
                            .font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Context · last reported", value: self.selectedRow?.contextUsageSummary ?? "Not reported by this gateway")
                        Text("These are gateway-reported context counts, not a bill or subscription-quota estimate. Counts may lag while a run is active or this device is offline.").foregroundStyle(.secondary)
                        LabeledContent("History", value: self.historyState)
                        if let key = self.store.selectedSessionKey, let date = self.store.lastHistoryRefresh[key] {
                            LabeledContent("Last successful refresh", value: date.formatted(date: .abbreviated, time: .standard))
                        }
                        LabeledContent("Unconfirmed sends in loaded messages", value: "\(self.unconfirmedSends)")
                        Text("Unconfirmed sends are never replayed automatically. Review the conversation and Needs you before retrying; actions may already have completed.").foregroundStyle(.secondary)
                        Button("Refresh conversation") { Task { await self.store.reloadHistory(); await self.store.refreshSessions() } }
                            .disabled(!self.isConnected)
                        if let compaction = self.compaction {
                            LabeledContent("Compaction", value: compaction.label)
                            Text("Observed \(compaction.observedAt.formatted(date: .abbreviated, time: .standard))").foregroundStyle(.secondary)
                        } else {
                            Text("No compaction operation observed in this app session.").foregroundStyle(.secondary)
                        }
                        if let failure = self.failure {
                            LabeledContent("Most recent observed failure", value: failure.category.title)
                            Text(failure.category.message)
                            Text("Observed \(failure.observedAt.formatted(date: .abbreviated, time: .standard)). This is a past event, not proof the conversation is still failing.").foregroundStyle(.secondary)
                        }
                    }
                }
                Section("What’s new") {
                    Text("Pin or hide chats. Change the model and reasoning for a conversation. Review approvals, blockers, and failures in Needs you. Keep reports and packages in Deliverables.")
                    Text("Hidden chats are a local sidebar preference, not deletion. Pending approvals still appear in Needs you.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Cast status & updates")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.dismiss() } } }
        }
        .sheet(isPresented: Binding(
            get: { self.diagnosisDraft != nil },
            set: { if !$0 { self.diagnosisDraft = nil } })) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("No transcript, addresses, credentials or raw provider errors are included.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: Binding(get: { self.diagnosisDraft ?? "" }, set: { self.diagnosisDraft = $0 }))
                        ShareLink("Copy or share request", item: self.diagnosisDraft ?? "")
                    }.padding()
                    .navigationTitle("Review diagnosis request")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.diagnosisDraft = nil } } }
                }
                .frame(minWidth: 360, minHeight: 360)
            }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 560)
        #endif
    }
}
