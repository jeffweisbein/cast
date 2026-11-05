import SwiftUI

/// Full machine-activity history. Live sessions provide task/subagent state while the cron
/// ledger preserves scheduled runs after their short-lived sessions are pruned.
struct AutomationRunsView: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var failuresOnly = false

    private var runs: [CronRun] {
        let trimmed = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.store.automationRuns.filter { run in
            if self.failuresOnly, !run.outcome.needsAttention { return false }
            guard !trimmed.isEmpty else { return true }
            return run.title.localizedCaseInsensitiveContains(trimmed)
                || (run.summary?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    private var sessions: [SessionRow] {
        let trimmed = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.store.activitySessions.filter { session in
            if self.failuresOnly, !SidebarGrouper.hasFailureSignal(session) { return false }
            guard !trimmed.isEmpty else { return true }
            return SidebarGrouper.displayTitle(
                for: session,
                mainSessionKey: self.store.mainSessionKey).localizedCaseInsensitiveContains(trimmed)
                || (session.lastMessagePreview?.localizedCaseInsensitiveContains(trimmed) ?? false)
                || session.key.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var digest: CronRunDigest { CronRunDigest(runs: self.store.automationRuns) }

    var body: some View {
        NavigationStack {
            List {
                if case let .failed(message) = self.store.automationRunsState {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if self.sessions.isEmpty, self.runs.isEmpty {
                    self.emptyState
                }
                if !self.sessions.isEmpty {
                    Section("Session history") {
                        ForEach(self.sessions) { session in
                            Button {
                                self.store.selectedSessionKey = session.key
                                self.dismiss()
                            } label: {
                                SessionRowView(
                                    session: session,
                                    category: SidebarGrouper.category(
                                        for: session,
                                        mainSessionKey: self.store.mainSessionKey),
                                    mainSessionKey: self.store.mainSessionKey,
                                    subtitle: self.store.sidebarSubtitle(for: session),
                                    unreadCount: self.store.unreadCount(for: session.key),
                                    failureAcknowledged: self.store.isFailureAcknowledged(session),
                                    acknowledgeFailure: { self.store.acknowledgeFailure(session) })
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !self.runs.isEmpty {
                    Section {
                        ForEach(self.runs) { run in
                            NavigationLink {
                                AutomationRunDetailView(run: run) {
                                    self.store.openAutomationRun(run)
                                    self.dismiss()
                                }
                            } label: {
                                AutomationRunRow(run: run)
                            }
                        }
                    } header: {
                        Text("Scheduled runs · \(self.digest.summaryText)")
                    }
                }
            }
            .searchable(text: self.$query, prompt: "Search activity")
            .refreshable { await self.store.loadAutomationRuns() }
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { self.dismiss() }
                }
                ToolbarItem(placement: .automatic) {
                    Toggle(isOn: self.$failuresOnly) {
                        Label("Failures only", systemImage: self.failuresOnly
                            ? "exclamationmark.triangle.fill"
                            : "exclamationmark.triangle")
                    }
                    .toggleStyle(.button)
                    .help("Show only failed tasks and runs")
                }
            }
            .overlay {
                if self.store.automationRunsState == .loading, self.store.automationRuns.isEmpty {
                    ProgressView("Loading runs…")
                }
            }
        }
        .task { await self.store.loadAutomationRuns() }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 480)
        #endif
    }

    @ViewBuilder
    private var emptyState: some View {
        if self.store.automationRunsState == .loading {
            EmptyView()
        } else if self.failuresOnly,
                  (!self.store.activitySessions.isEmpty || !self.store.automationRuns.isEmpty)
        {
            ContentUnavailableView(
                "No failed activity",
                systemImage: "checkmark.circle",
                description: Text("Every recorded task and run finished cleanly."))
        } else {
            ContentUnavailableView(
                self.query.isEmpty ? "No activity recorded" : "No matching activity",
                systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                description: Text("Tasks and scheduled jobs appear here as they run."))
        }
    }
}

private struct AutomationRunRow: View {
    let run: CronRun

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: self.run.outcome.symbol)
                .foregroundStyle(self.run.outcome.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(self.run.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(self.run.date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let preview = self.run.previewLine {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(self.run.metadataLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(self.run.title), \(self.run.outcome.label)")
    }
}

/// What the run actually said. Isolated cron sessions are pruned on a retention timer
/// (`cron.sessionRetention`, 24h by default), so the run-log summary — not the session
/// transcript — is the durable record and gets shown in full here.
private struct AutomationRunDetailView: View {
    let run: CronRun
    let openSession: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(self.run.outcome.label, systemImage: self.run.outcome.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(self.run.outcome.tint)
                    Text(self.run.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(self.run.metadataLine)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Divider()
                if let summary = self.run.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("This run recorded no output.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if self.run.sessionKey?.isEmpty == false {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Open Run Session", action: self.openSession)
                            .buttonStyle(.bordered)
                        Text("Run sessions are pruned on the gateway's retention schedule, so an older run may open empty.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        .navigationTitle(self.run.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private extension CronRun {
    var metadataLine: String {
        var parts: [String] = []
        if let duration = self.durationLabel { parts.append(duration) }
        if let model = self.model { parts.append(model) }
        if let delivery = self.deliveryStatus, delivery != "not-requested" {
            parts.append("delivery: \(delivery)")
        }
        return parts.isEmpty ? self.outcome.label : parts.joined(separator: " · ")
    }
}

private extension CronRunOutcome {
    var symbol: String {
        switch self {
        case .running: return "circle.dotted.circle"
        case .succeeded: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .timedOut: return "clock.badge.exclamationmark"
        case .skipped: return "minus.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        case .timedOut: return .orange
        case .skipped, .unknown: return .secondary
        }
    }
}
