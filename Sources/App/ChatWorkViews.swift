import ImageIO
import SwiftUI

// MARK: - State label

/// The small "Working / Needs you / Ready to review" line used by chat rows, the result card
/// and the review panel. Colour is never the only carrier: every state has a symbol and text.
struct ChatWorkStateLabel: View {
    let state: ChatWorkState
    var font: Font = .caption.weight(.medium)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label {
            Text(self.state.label).lineLimit(1)
        } icon: {
            Image(systemName: self.state.symbol)
                .symbolEffect(.pulse, options: .repeating, isActive: self.state == .working && !self.reduceMotion)
        }
        .font(self.font)
        .foregroundStyle(self.state.tint)
        .labelStyle(ChatWorkLabelStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.state.label)
    }
}

private struct ChatWorkLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

extension ChatWorkState {
    var symbol: String {
        switch self {
        case .needsYou(.question): return "questionmark.bubble.fill"
        case .needsYou(.approval): return "checkmark.shield.fill"
        case .needsYou(.blocked): return "person.fill"
        case .needsYou(.failure): return "exclamationmark.triangle.fill"
        case .needsYou(.delivery): return "bell.slash.fill"
        case .working: return "waveform.path"
        case .readyToReview: return "checkmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .needsYou(.failure): return .red
        case .needsYou: return .orange
        case .working: return .blue
        case .readyToReview: return .green
        }
    }
}

// MARK: - Chat row

/// Personal chat row: title and time, the latest preview the gateway already sent, then the
/// derived work state. Pure inputs, so the row never parses transcripts.
struct PersonalChatRowLabel: View {
    let title: String
    let preview: String?
    let updated: Date?
    let unread: Bool
    let state: ChatWorkState?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "bubble.left")
                .foregroundStyle(.secondary)
                .frame(minWidth: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(self.title)
                        .font(self.unread ? .body.weight(.semibold) : .body.weight(.medium))
                        .lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if self.unread {
                        Circle().fill(.blue).frame(width: 7, height: 7).accessibilityLabel("Unread")
                    }
                    if let updated, !self.dynamicTypeSize.isAccessibilitySize {
                        Text(updated, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if let preview, !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let state {
                    ChatWorkStateLabel(state: state).padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Filter bar

struct ChatFilterBar: View {
    @Binding var filter: ChatWorkFilter
    let counts: [ChatWorkFilter: Int]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ChatWorkFilter.allCases) { option in
                    let count = self.counts[option] ?? 0
                    if option == .all || count > 0 || self.filter == option {
                        self.chip(option, count: count)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter chats")
    }

    private func chip(_ option: ChatWorkFilter, count: Int) -> some View {
        let selected = self.filter == option
        return Button {
            self.filter = option
        } label: {
            HStack(spacing: 4) {
                Text(option.title)
                if option != .all, count > 0 {
                    Text("\(count)").monospacedDigit().foregroundStyle(selected ? .primary : .secondary)
                }
            }
            .font(.caption.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: selected ? 0 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
        .accessibilityLabel(option == .all ? "All chats" : "\(option.title), \(count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("chat-filter-" + option.rawValue)
    }
}

// MARK: - Result card (in the conversation)

/// Store-bound wrapper: its own view so deliverable/progress observation does not invalidate
/// the transcript body. Shows nothing until this chat has shared files or links.
struct ChatResultCard: View {
    let store: ChatStore
    let openReview: () -> Void

    var body: some View {
        if let key = self.store.selectedSessionKey {
            let summary = self.store.resultSummary(for: key)
            if !summary.isEmpty {
                ChatResultCardContent(
                    summary: summary,
                    state: self.store.chatWorkState(for: key),
                    openReview: self.openReview)
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.leading, 2)
            }
        }
    }
}

struct ChatResultCardContent: View {
    let summary: ChatResultSummary
    let state: ChatWorkState?
    let openReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    ResultStatusLine(summary: self.summary, state: self.state).fixedSize()
                    Spacer(minLength: 8)
                    self.sharedTime
                }
                VStack(alignment: .leading, spacing: 2) {
                    ResultStatusLine(summary: self.summary, state: self.state)
                    self.sharedTime
                }
            }
            if let latest = self.summary.latest {
                VStack(alignment: .leading, spacing: 3) {
                    Text(latest.title)
                        .font(.headline)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text(self.subtitle(latest))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            ResultEvidenceStrip(summary: self.summary)
            Button(action: self.openReview) {
                HStack {
                    Text(self.summary.unreviewedCount > 0 ? "Review result" : "Open result")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("result-card-review")
            .accessibilityHint("Shows files, progress and what is not yet verified")
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-result-card")
    }

    @ViewBuilder private var sharedTime: some View {
        if let ms = self.summary.latest?.sharedAt {
            Text(Date(timeIntervalSince1970: ms / 1000), format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func subtitle(_ latest: Deliverable) -> String {
        let others = self.summary.items.count - 1
        let count = others > 0 ? " · \(others) more from this chat" : ""
        return latest.kind + count
    }
}

/// "Ready to review" / "Reviewed" / live state. A reviewed result never reverts to
/// "ready" and an active run is not called finished.
struct ResultStatusLine: View {
    let summary: ChatResultSummary
    let state: ChatWorkState?

    var body: some View {
        if let state, state.filter != .review {
            // Live states (needs you / working) outrank a previously shared result.
            ChatWorkStateLabel(state: state)
        } else if self.summary.unreviewedCount > 0 {
            ChatWorkStateLabel(state: .readyToReview(count: self.summary.unreviewedCount))
        } else {
            self.reviewed
        }
    }

    private var reviewed: some View {
        Label("Reviewed by you", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

/// Compact provenance: only agent-reported progress is shown as progress; build/test/install
/// receipts are explicitly "not reported" because Cast has no source for them.
struct ResultEvidenceStrip: View {
    let summary: ChatResultSummary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                self.progress.fixedSize()
                if self.hasProgress { Text("·").foregroundStyle(.tertiary).accessibilityHidden(true) }
                self.checks.fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                self.progress
                self.checks
            }
        }
        .font(.caption)
    }

    private var hasProgress: Bool {
        if case .agentReported = self.summary.progress { return true }
        return false
    }

    @ViewBuilder private var progress: some View {
        if case let .agentReported(completed, total) = self.summary.progress {
            Label("\(completed) of \(total) steps · agent-reported",
                  systemImage: completed == total ? "checkmark.circle" : "circle.dotted")
                .foregroundStyle(.secondary)
        }
    }

    private var checks: some View {
        Label("Checks not reported", systemImage: "circle.dashed")
            .foregroundStyle(.tertiary)
            .accessibilityLabel("No build, test or installation receipt was reported")
    }
}

// MARK: - Review panel (inspector on wide layouts, sheet on iPhone)

struct ResultReviewInspector: View {
    let store: ChatStore
    @Binding var isPresented: Bool
    @State private var tab: ResultReviewTab = .files
    @State private var previewURL: URL?
    @State private var showingAllDeliverables = false

    var body: some View {
        #if os(iOS)
        NavigationStack {
            self.content
                .navigationTitle("Result")
                .navigationBarTitleDisplayMode(.inline)
        }
        #else
        self.content
        #endif
    }

    private var content: some View {
        Group {
            if let key = self.store.selectedSessionKey {
                let summary = self.store.resultSummary(for: key)
                let row = self.store.sessionRow(for: key)
                ResultReviewPanel(
                    title: row.map { self.store.chatTitle($0) } ?? "This chat",
                    summary: summary,
                    state: self.store.chatWorkState(for: key),
                    progressCard: self.store.progressCard(for: key),
                    facts: ResultRunFacts(row: row, agentName: self.store.agentIdentity?.name,
                                          isLiveTurn: self.store.isAgentTurnActive),
                    tab: self.$tab,
                    artifact: { item in self.artifactRow(item) },
                    markAllReviewed: {
                        for item in summary.items where !self.store.reviewedWork.ids.contains(item.reviewID) {
                            self.store.markDeliverableReviewed(item.reviewID)
                        }
                    },
                    showAll: { self.showingAllDeliverables = true })
                    .task(id: key) {
                        // Bounded refresh of this chat only; existing ledger stays visible offline.
                        try? await self.store.refreshArtifacts(sessionKey: key)
                    }
            } else {
                ContentUnavailableView("No chat selected", systemImage: "bubble.left")
            }
        }
        .quickLookPreview(self.$previewURL)
        .sheet(isPresented: self.$showingAllDeliverables) {
            DeliverablesView(store: self.store, sessionKey: self.store.selectedSessionKey)
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { self.isPresented = false } }
        }
        #endif
    }

    private func artifactRow(_ item: Deliverable) -> some View {
        StoreArtifactRow(store: self.store, item: item, preview: { self.previewURL = $0 })
    }
}

enum ResultReviewTab: String, CaseIterable, Identifiable {
    case files, progress, details
    var id: String { self.rawValue }
    var title: String {
        switch self {
        case .files: return "Files"
        case .progress: return "Progress"
        case .details: return "Details"
        }
    }
}

/// Facts about this chat's run that the gateway actually reports. Everything else is
/// listed by name in `notReported` so absence reads as "unknown", not "none".
struct ResultRunFacts: Equatable {
    struct Fact: Equatable, Identifiable { let label: String; let value: String; var id: String { label } }
    let facts: [Fact]
    let notReported: [String]

    init(facts: [Fact], notReported: [String]) {
        self.facts = facts
        self.notReported = notReported
    }

    init(row: SessionRow?, agentName: String?, isLiveTurn: Bool) {
        var facts: [Fact] = []
        var missing: [String] = []
        if let agentName, !agentName.isEmpty { facts.append(Fact(label: "Agent", value: agentName)) }
        if let model = row?.model, !model.isEmpty {
            let provider = row?.modelInfo?.modelProvider.map { " · \($0)" } ?? ""
            facts.append(Fact(label: "Chat model", value: model + provider))
        } else {
            missing.append("model")
        }
        if let thinking = row?.modelInfo?.thinkingLevel ?? row?.modelInfo?.thinkingDefault, !thinking.isEmpty {
            facts.append(Fact(label: "Reasoning", value: thinking.capitalized))
        }
        if let row {
            let active = ProjectSidebar.isWorking(row) || isLiveTurn
            facts.append(Fact(label: "Run", value: active ? "Active now" : (row.status?.capitalized ?? "Idle")))
        }
        if let fill = row?.contextFillFraction {
            facts.append(Fact(label: "Context", value: "\(Int((fill * 100).rounded()))% full"))
        }
        if let input = row?.inputTokens, let output = row?.outputTokens {
            facts.append(Fact(label: "Tokens", value: "\(Self.compact(input)) in · \(Self.compact(output)) out"))
        }
        if let cost = row?.estimatedCostUsd {
            facts.append(Fact(label: "Est. cost", value: cost.formatted(.currency(code: "USD"))))
        }
        if let updated = row?.updatedDate {
            facts.append(Fact(label: "Updated", value: updated.formatted(.relative(presentation: .named))))
        }
        missing.append(contentsOf: ["machine", "per-step model", "build and test results", "installation"])
        self.facts = facts
        self.notReported = missing
    }

    private static func compact(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0 ... 1)))
    }
}

struct ResultReviewPanel<ArtifactRow: View>: View {
    let title: String
    let summary: ChatResultSummary
    let state: ChatWorkState?
    let progressCard: ProgressCard?
    let facts: ResultRunFacts
    @Binding var tab: ResultReviewTab
    @ViewBuilder let artifact: (Deliverable) -> ArtifactRow
    var markAllReviewed: () -> Void = {}
    var showAll: () -> Void = {}
    /// Fixtures render the full height; the app scrolls.
    var scrolls = true
    /// Rich rows are bounded; the full ledger lives in Deliverables.
    static var visibleArtifactLimit: Int { 24 }

    var body: some View {
        if self.scrolls {
            ScrollView { self.stack }
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("result-review-panel")
        } else {
            self.stack
        }
    }

    private var stack: some View {
            VStack(alignment: .leading, spacing: 18) {
                self.header
                Picker("Section", selection: self.$tab) {
                    ForEach(ResultReviewTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch self.tab {
                case .files: self.files
                case .progress: self.progress
                case .details: self.details
                }
                self.evidence
            }
            .padding(16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RESULT")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Text(self.summary.latest?.title ?? "No shared result yet")
                .font(.title2.weight(.semibold))
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                ResultStatusLine(summary: self.summary, state: self.state)
                Text("· \(self.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var files: some View {
        if self.summary.items.isEmpty {
            ContentUnavailableView("Nothing shared yet", systemImage: "tray",
                description: Text("Files and links your agent shares in this chat appear here."))
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(self.summary.items.prefix(Self.visibleArtifactLimit)) { item in
                    self.artifact(item)
                }
            }
            HStack {
                if self.summary.items.count > Self.visibleArtifactLimit || self.summary.items.count > 1 {
                    Button("All files from this chat", action: self.showAll).buttonStyle(.borderless)
                }
                Spacer()
                if self.summary.unreviewedCount > 1 {
                    Button("Mark all reviewed", action: self.markAllReviewed).buttonStyle(.bordered)
                        .accessibilityIdentifier("result-mark-all-reviewed")
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder private var progress: some View {
        if let steps = self.progressCard?.steps, !steps.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        ResultStepGlyph(status: step.status)
                        Text(step.step)
                            .font(.callout)
                            .foregroundStyle(step.status == .completed ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Self.stepStatus(step.status))
                            .font(.caption)
                            .foregroundStyle(step.status == .inProgress ? Color.blue : Color.secondary)
                    }
                    .padding(.vertical, 9)
                    if index < steps.count - 1 { Divider() }
                }
            }
            if let updated = self.progressCard?.updatedDate {
                Text("Reported by the agent's progress card, updated \(updated.formatted(.relative(presentation: .named))). Cast does not verify these steps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ContentUnavailableView("No progress reported", systemImage: "checklist",
                description: Text("This chat has no progress card. Steps appear here when the agent publishes one."))
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(self.facts.facts) { fact in
                HStack(alignment: .firstTextBaseline) {
                    Text(fact.label).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(fact.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                }
                .font(.callout)
                .padding(.vertical, 7)
            }
            if !self.facts.notReported.isEmpty {
                Label {
                    Text("Not reported for this chat: " + ListFormatter.localizedString(byJoining: self.facts.notReported) + ".")
                } icon: {
                    Image(systemName: "questionmark.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .accessibilityIdentifier("result-details-not-reported")
            }
        }
    }

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WHAT CAST KNOWS")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            EvidenceRow(symbol: self.summary.items.isEmpty ? "circle.dashed" : "checkmark.circle.fill",
                        tint: self.summary.items.isEmpty ? .secondary : .green,
                        title: "Shared",
                        detail: self.summary.items.isEmpty ? "Nothing shared in this chat yet"
                            : "\(self.summary.items.count) file\(self.summary.items.count == 1 ? "" : "s") or link\(self.summary.items.count == 1 ? "" : "s") in this chat")
            EvidenceRow(symbol: self.summary.allReviewed ? "checkmark.circle.fill" : "eye",
                        tint: self.summary.allReviewed ? .green : .blue,
                        title: "Reviewed by you",
                        detail: self.summary.items.isEmpty ? "—"
                            : "\(self.summary.items.count - self.summary.unreviewedCount) of \(self.summary.items.count)")
            switch self.summary.progress {
            case let .agentReported(completed, total):
                EvidenceRow(symbol: completed == total ? "checkmark.circle" : "circle.dotted", tint: .secondary,
                            title: "Progress", detail: "\(completed) of \(total) steps, reported by the agent")
            case .notReported:
                EvidenceRow(symbol: "circle.dashed", tint: .secondary, title: "Progress", detail: "Not reported")
            }
            EvidenceRow(symbol: "circle.dashed", tint: .secondary, title: "Build and tests",
                        detail: "Not reported — no check receipt in this chat")
            EvidenceRow(symbol: "circle.dashed", tint: .secondary, title: "Installed",
                        detail: "Not reported", showsDivider: false)
            Text("Shared, reviewed, checked and installed are separate states. Cast shows only what this conversation reported.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .accessibilityIdentifier("result-evidence")
    }

    private static func stepStatus(_ status: ProgressStepStatus) -> String {
        switch status {
        case .completed: return "Done"
        case .inProgress: return "Running"
        case .pending, .unknown: return "Queued"
        }
    }
}

private struct EvidenceRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var showsDivider = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: self.symbol).foregroundStyle(self.tint).frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.title).font(.callout.weight(.medium))
                    Text(self.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            if self.showsDivider { Divider().padding(.leading, 28) }
        }
    }
}

private struct ResultStepGlyph: View {
    let status: ProgressStepStatus
    var body: some View {
        switch self.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
        case .inProgress:
            Image(systemName: "waveform.path").foregroundStyle(.blue).accessibilityLabel("Running")
        case .pending, .unknown:
            Image(systemName: "clock").foregroundStyle(.secondary).accessibilityLabel("Queued")
        }
    }
}

// MARK: - Artifact rows

enum ResultArtifactAvailability: Equatable {
    case web(URL)
    case cached(URL)
    case downloading(received: Int, total: Int?)
    case failed(String)
    case remote(canDownload: Bool)
}

struct ResultArtifactRowContent: View {
    let item: Deliverable
    let availability: ResultArtifactAvailability
    let reviewed: Bool
    var thumbnail: CGImage? = nil
    var open: () -> Void = {}
    var download: () -> Void = {}
    var markReviewed: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 2)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Preview of \(self.item.title)")
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Self.symbol(for: self.item))
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.item.title).font(.callout.weight(.semibold)).lineLimit(2)
                    Text(self.meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if self.reviewed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityLabel("Reviewed")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { self.actions }
                VStack(alignment: .leading, spacing: 6) { self.actions }
            }
            .font(.caption)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
        .accessibilityElement(children: .contain)
    }

    private var meta: String {
        var parts = [self.item.kind]
        if let size = self.item.sizeBytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let ms = self.item.sharedAt {
            parts.append(Date(timeIntervalSince1970: ms / 1000).formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        switch self.availability {
        case .web:
            Button("Open", systemImage: "arrow.up.right.square", action: self.open).buttonStyle(.bordered)
        case .cached:
            Button("Preview", systemImage: "eye", action: self.open).buttonStyle(.bordered)
        case let .downloading(received, total):
            if let total, total > 0 {
                ProgressView(value: Double(min(received, total)), total: Double(total)).frame(maxWidth: 160)
            } else {
                ProgressView().controlSize(.small)
            }
        case let .failed(message):
            Text(message).foregroundStyle(.red).lineLimit(2)
            Button("Retry", systemImage: "arrow.clockwise", action: self.download).buttonStyle(.bordered)
        case let .remote(canDownload):
            Button("Get file", systemImage: "arrow.down.circle", action: self.download)
                .buttonStyle(.bordered).disabled(!canDownload)
            if !canDownload { Text("Reconnect to download").foregroundStyle(.secondary) }
        }
        if !self.reviewed {
            Button("Mark reviewed", systemImage: "checkmark", action: self.markReviewed)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("result-mark-reviewed")
        }
    }

    static func symbol(for item: Deliverable) -> String {
        switch item.kind {
        case "Pull request": return "arrow.triangle.branch"
        case "Release", "Package": return "shippingbox"
        case "Image": return "photo"
        case "Document": return "doc.text"
        default: return item.webURL != nil ? "link" : "doc"
        }
    }
}

private struct StoreArtifactRow: View {
    let store: ChatStore
    let item: Deliverable
    let preview: (URL) -> Void
    @Environment(\.openURL) private var openURL
    @State private var thumbnail: CGImage?

    private var availability: ResultArtifactAvailability {
        if let url = self.item.webURL { return .web(url) }
        switch self.store.downloads.entry(for: self.item)?.phase {
        case let .saved(url): return .cached(url)
        case .downloading:
            let entry = self.store.downloads.entry(for: self.item)
            return .downloading(received: entry?.received ?? 0, total: entry?.total)
        case let .failed(message): return .failed(message)
        case .cancelled, .none:
            let connected: Bool = { if case .connected = self.store.connectionState { return true }; return false }()
            let method = self.item.artifactID == nil ? "sessions.files.get" : "artifacts.download"
            return .remote(canDownload: connected && self.store.gatewayMethods.contains(method))
        }
    }

    var body: some View {
        let availability = self.availability
        ResultArtifactRowContent(
            item: self.item,
            availability: availability,
            reviewed: self.store.reviewedWork.ids.contains(self.item.reviewID),
            thumbnail: self.thumbnail,
            open: {
                switch availability {
                case let .web(url): self.openURL(url)
                case let .cached(url): self.preview(url)
                default: break
                }
            },
            download: { self.store.startDownload(self.item) },
            markReviewed: { self.store.markDeliverableReviewed(self.item.reviewID) })
            .task(id: self.item.reviewID) { await self.store.inspectDownload(self.item) }
            .task(id: availability) {
                // Only images already cached on this device get a preview; nothing is fetched.
                guard self.item.kind == "Image", case let .cached(url) = availability else { return }
                self.thumbnail = await Task.detached(priority: .utility) { () -> CGImage? in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    return MediaThumbnailLoader.downsample(source: source, maxPixel: 900)
                }.value
            }
    }
}
