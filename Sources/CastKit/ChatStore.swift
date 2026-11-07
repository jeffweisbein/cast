// Cast — MainActor state hub: connection, session list, transcript, streaming, send.
import Foundation
import Observation
import SwiftUI

/// An optimistic local user bubble awaiting its gateway echo. `sentText` is the exact
/// `message` param sent over chat.send, which is what the echo carries back.
struct PendingEcho: Sendable {
    let id: String
    let sentText: String
}

/// The exact chat.send inputs a bubble needs to resend itself. Kept off the message row
/// because prepared attachment payloads (up to ~24 MB of base64 source bytes) are far too
/// heavy to persist per cached message; the row's echo text and placeholders cannot stand
/// in for them.
struct PendingSendContext: Sendable, Codable {
    let text: String
    let attachments: [PreparedAttachment]
    let deliver: Bool
}

/// Tracks locally accepted sends separately from gateway-confirmed runs. A history page can
/// legitimately be stale immediately after `chat.send`; its `hasActiveRun:false` must not
/// cancel the local pending state before the first event arrives.
struct AgentTurnActivityState: Sendable, Equatable {
    /// Locally accepted sends by the millisecond timestamp they began, so staleness of a
    /// history snapshot can be judged per run instead of assumed forever.
    private(set) var pendingRuns: [String: Double] = [:]
    private(set) var observedRunIds: Set<String> = []
    private(set) var answeredRunIds: Set<String> = []
    private(set) var historyHasActiveRun = false

    var isActive: Bool {
        self.historyHasActiveRun || !self.pendingRuns.isEmpty || !self.observedRunIds.isEmpty
    }

    func contains(_ runId: String) -> Bool {
        self.pendingRuns.keys.contains(runId) || self.observedRunIds.contains(runId)
    }

    /// A run is "answered" once it reaches a successful `final` chat state. The marker
    /// outlives `finish` so a late timeout/aborted/error terminal for the same run can be
    /// recognized as stale rather than a real failure.
    func hasAnswered(_ runId: String) -> Bool {
        self.answeredRunIds.contains(runId)
    }

    mutating func markAnswered(runId: String) {
        self.answeredRunIds.insert(runId)
    }

    mutating func beginLocal(runId: String, atMs: Double) {
        self.pendingRuns[runId] = atMs
    }

    mutating func acknowledge(localRunId: String, gatewayRunId: String) {
        if let beganAtMs = self.pendingRuns.removeValue(forKey: localRunId) {
            self.pendingRuns[gatewayRunId] = beganAtMs
        }
        if self.observedRunIds.remove(localRunId) != nil { self.observedRunIds.insert(gatewayRunId) }
    }

    mutating func observe(runId: String) {
        self.pendingRuns[runId] = nil
        self.observedRunIds.insert(runId)
    }

    mutating func finish(runId: String) {
        self.pendingRuns[runId] = nil
        self.observedRunIds.remove(runId)
        if self.observedRunIds.isEmpty { self.historyHasActiveRun = false }
    }

    mutating func applyHistory(
        hasActiveRun: Bool?,
        runIds: [String],
        newestMessageTimestampMs: Double? = nil)
    {
        if hasActiveRun == false { self.observedRunIds.removeAll() }
        self.observedRunIds.formUnion(runIds)
        self.historyHasActiveRun = hasActiveRun == true || !runIds.isEmpty
        // Deliberately retain pending runs on a bare `hasActiveRun:false`: the snapshot may
        // predate the send. But when the page also carries a message newer than a pending
        // send and still reports no active run, it demonstrably postdates that send — its
        // terminal event was lost (iOS suspends the socket without a disconnect callback),
        // and keeping the run would pin the thinking indicator and gate the transcript
        // watchdog off forever. The stale-page case is unaffected: a page that predates the
        // send cannot contain a message newer than it.
        guard hasActiveRun == false, let newestMessageTimestampMs else { return }
        self.pendingRuns = self.pendingRuns.filter { newestMessageTimestampMs <= $0.value }
    }

    /// Age-out backstop for a send that never produced a single event. Runs surface their
    /// first event within seconds of `chat.send` returning; a run still pending this long
    /// lost its events with the socket they would have arrived on.
    @discardableResult
    mutating func expirePendingRuns(before cutoffMs: Double) -> Bool {
        let survivors = self.pendingRuns.filter { $0.value >= cutoffMs }
        guard survivors.count != self.pendingRuns.count else { return false }
        self.pendingRuns = survivors
        return true
    }
}

/// Detects an open transcript that is missing the message the gateway's own sidebar preview
/// describes. `sessions.list` hands Cast the flattened text of the newest displayable
/// message; when none of the transcript's recent rows contain it, the open view is behind no
/// matter what the run state says — the case where the chat list shows a reply the message
/// window never received. Each distinct preview triggers at most one reload, so a preview
/// whose flattening differs from the raw text can never poll history forever.
struct TranscriptPreviewReconciler: Sendable, Equatable {
    static let probeLength = 48
    static let minimumReverseMatchLength = 12
    private(set) var attemptedPreview: String?

    mutating func transcriptIsMissingPreview(_ preview: String?, recentTexts: [String]) -> Bool {
        let normalizedPreview = Self.normalized(preview ?? "")
        guard !normalizedPreview.isEmpty else {
            self.attemptedPreview = nil
            return false
        }
        let probe = String(normalizedPreview.prefix(Self.probeLength))
        let held = recentTexts.contains { text in
            let normalizedText = Self.normalized(text)
            guard !normalizedText.isEmpty else { return false }
            if normalizedText.contains(probe) { return true }
            return normalizedText.count >= Self.minimumReverseMatchLength
                && normalizedPreview.contains(normalizedText)
        }
        if held {
            self.attemptedPreview = nil
            return false
        }
        guard self.attemptedPreview != normalizedPreview else { return false }
        self.attemptedPreview = normalizedPreview
        return true
    }

    /// Lowercased letters and digits only, so markdown syntax, whitespace, punctuation and
    /// emoji — everything the gateway's flattening may add or drop — cannot cause a mismatch.
    static func normalized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }
}

/// Coalesces history reloads without losing a refresh that arrives while an older snapshot
/// is in flight. This is especially important when another Cast device updates the session.
struct HistoryRefreshCoordinator: Sendable, Equatable {
    private(set) var inFlightKeys: Set<String> = []
    private(set) var pendingKeys: Set<String> = []

    mutating func begin(key: String) -> Bool {
        guard self.inFlightKeys.insert(key).inserted else {
            self.pendingKeys.insert(key)
            return false
        }
        return true
    }

    mutating func finish(key: String) -> Bool {
        self.inFlightKeys.remove(key)
        return self.pendingKeys.remove(key) != nil
    }
}

/// Hashes exactly the fields `isSameTranscriptEntry` compares. Legacy transcript caches used
/// random UUIDs, so id membership alone cannot recognize a gateway row that is already on
/// screen; this index keeps that compatibility path O(1) instead of scanning the transcript.
struct TranscriptEntryKey: Hashable, Sendable {
    let role: String
    let timestamp: Double
    let text: String
    let toolNames: [String]
    let mediaPaths: [String]
    let mediaTypes: [String]
    let attachments: [ManagedChatAttachment]

    init?(_ message: ChatMessage) {
        guard let timestamp = message.timestamp else { return nil }
        self.role = message.role
        self.timestamp = timestamp
        self.text = message.text
        self.toolNames = message.toolNames
        self.mediaPaths = message.mediaPaths
        self.mediaTypes = message.mediaTypes
        self.attachments = message.managedAttachments
    }
}

/// Collects older gateway pages without repeatedly reconciling or publishing the growing
/// transcript. Membership is updated once per row, and pages retain their natural boundaries
/// so they can be flattened oldest-first in one final publish.
struct HistoryBackfillAccumulator: Sendable {
    private var knownIDs: Set<String>
    private var knownEntries: Set<TranscriptEntryKey>
    private var newestToOldestPages: [[ChatMessage]] = []

    init(current: [ChatMessage]) {
        self.knownIDs = Set(current.map(\.id))
        self.knownEntries = Set(current.compactMap(TranscriptEntryKey.init))
    }

    @discardableResult
    mutating func ingest(_ page: [ChatMessage]) -> Int {
        var additions: [ChatMessage] = []
        additions.reserveCapacity(page.count)
        for message in page {
            let idWasNew = self.knownIDs.insert(message.id).inserted
            let key = TranscriptEntryKey(message)
            let entryWasNew = key.map { self.knownEntries.insert($0).inserted } ?? true
            guard idWasNew, entryWasNew else { continue }
            additions.append(message)
        }
        if !additions.isEmpty { self.newestToOldestPages.append(additions) }
        return additions.count
    }

    var olderMessagesInChronologicalOrder: [ChatMessage] {
        self.newestToOldestPages.reversed().flatMap { $0 }
    }
}

enum HistoryBackfillError: Error {
    case invalidNextOffset
}

/// Bounded most-recently-used cache of in-memory transcripts for instant session
/// switching. Unbounded, an afternoon of hopping across the fleet retained every
/// transcript ever opened for the process lifetime; a handful of sessions covers flipping
/// between active chats, and the disk cache remains the durable fallback for the rest.
struct TranscriptSnapshotStore: Sendable {
    static let defaultCapacity = 5

    private let capacity: Int
    private var recencyOrder: [String] = []
    private var snapshotsByKey: [String: [ChatMessage]] = [:]

    init(capacity: Int = Self.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Optimistic image bytes are stripped on the way in: the disk cache already persists
    /// them in side files and rehydrates on open, so keeping them here only let a few
    /// pasted screenshots dominate the working set.
    mutating func store(_ messages: [ChatMessage], for key: String) {
        self.snapshotsByKey[key] = messages.map { message in
            guard !message.localImageData.isEmpty else { return message }
            var stripped = message
            stripped.localImageData = []
            return stripped
        }
        self.touch(key)
        while self.recencyOrder.count > self.capacity, let oldest = self.recencyOrder.first {
            self.recencyOrder.removeFirst()
            self.snapshotsByKey[oldest] = nil
        }
    }

    mutating func snapshot(for key: String) -> [ChatMessage]? {
        guard let messages = self.snapshotsByKey[key] else { return nil }
        self.touch(key)
        return messages
    }

    private mutating func touch(_ key: String) {
        self.recencyOrder.removeAll { $0 == key }
        self.recencyOrder.append(key)
    }
}

@MainActor
@Observable
public final class ChatStore {
    /// How often the open transcript is checked against the gateway's own session
    /// timestamp. Short enough that a dropped event is not a visible outage, long enough
    /// that it costs one `sessions.list` call rather than a history page.
    static let transcriptWatchdogIntervalMs: UInt64 = 20_000

    /// How long a locally accepted send may wait for its first run event before the
    /// watchdog concludes the events were lost with the socket. Generous: even queued
    /// runs surface a lifecycle event within seconds of `chat.send` returning.
    static let pendingRunMaxAgeMs: Double = 300_000
    /// How many tail rows the sidebar preview is matched against; the preview names the newest
    /// message with text, which need not be the newest row.
    static let previewMatchDepth = 6
    private var previewReconciler = TranscriptPreviewReconciler()

    /// Shown when the bounded `sessions.subscribe` ladder is spent. The list on screen is
    /// still usable, it just will not update itself, so this is the same quiet notice the
    /// sidebar already uses for a failed refresh rather than an app-blocking alert.
    static let sessionsSubscribeNotice =
        "Conversations won\u{2019}t update on their own right now. Pull to refresh, or tap Retry."

    enum SessionsSubscriptionState: Sendable, Equatable {
        /// No answer yet — either never attempted on this socket, or still in flight.
        case idle
        case subscribed
        /// The bounded ladder was spent without an acknowledgement.
        case failed
    }

    public private(set) var profile: WorkspaceProfile

    // `@Observable` rewrites stored properties into computed ones, which rules out `didSet`.
    // Four of the values below — `connectionState`, `messages`, `searchQuery`, and
    // `selectedSessionKey` — carry side effects the rest of the store depends on, so each
    // keeps its storage explicitly and drives the registrar by hand: the getter registers
    // the read, `withMutation` brackets the write, and the body that used to be `didSet`
    // runs immediately after. Everything else is an ordinary tracked stored property, and
    // everything the old class did *not* publish stays `@ObservationIgnored` so no view
    // starts observing state that was never observable.

    @ObservationIgnored private var connectionStateStorage: GatewayConnectionState = .disconnected(nil)
    public private(set) var connectionState: GatewayConnectionState {
        get {
            self.access(keyPath: \.connectionState)
            return self.connectionStateStorage
        }
        set {
            self.withMutation(keyPath: \.connectionState) { self.connectionStateStorage = newValue }
            // When a connect attempt started, so activation can tell a live attempt from
            // one iOS suspended out from under us. Held across repeated `.connecting`
            // assignments on purpose: a stuck attempt must not keep resetting its own
            // clock and stay young forever.
            if case .connecting = self.connectionStateStorage {
                if self.connectingSince == nil { self.connectingSince = Date() }
            } else {
                self.connectingSince = nil
            }
        }
    }

    /// Entry time of the current `.connecting` state, or nil in any other state.
    @ObservationIgnored private var connectingSince: Date?
    public private(set) var sessions: [SessionRow] = []
    public private(set) var mainSessionKey: String?
    public private(set) var gatewayMethods: Set<String> = []
    public private(set) var gatewayVersion: String?
    public private(set) var deliverableLedger = DeliverableLedger()
    public private(set) var reviewedWork = ReviewedWorkLedger()
    @ObservationIgnored private let deliverableStore: AtomicJSONLedgerStore<DeliverableLedger>
    @ObservationIgnored private let reviewedWorkStore: AtomicJSONLedgerStore<ReviewedWorkLedger>
    @ObservationIgnored private var deliverableIndexTask: Task<Void, Never>?
    @ObservationIgnored private var deliverableIndexGeneration = 0
    public private(set) var modelCatalog: [GatewayModelChoice] = []
    public private(set) var modelCatalogAgentID: String?
    public private(set) var pendingModelChanges: [String: String] = [:]
    public private(set) var savingModelKeys: Set<String> = []
    public private(set) var agentIdentity: AgentIdentity?

    @ObservationIgnored private var messagesStorage: [ChatMessage] = []
    public private(set) var messages: [ChatMessage] {
        get {
            self.access(keyPath: \.messages)
            return self.messagesStorage
        }
        set {
            self.withMutation(keyPath: \.messages) { self.messagesStorage = newValue }
            // Only a tail-only write leaves the incremental builder's consumed prefix
            // intact. Anything else — a history reconcile, a session switch, an in-place
            // delivery-state edit — can rewrite rows the builder already folded into a
            // group, so its state is dropped and the next read rebuilds from scratch.
            if self.transcriptWriteIsAppendOnly {
                self.transcriptWriteIsAppendOnly = false
            } else {
                self.transcriptBuilder = nil
            }
            self.transcriptCacheIsStale = true
            self.transcriptRevision &+= 1
            CastLifecycleDiagnostics.transcriptPublished(count: self.messagesStorage.count)
            self.scheduleDeliverableIndex()
        }
    }

    /// Bumped by every transcript write, including the in-place reconciles that leave
    /// `messages.count` untouched. Views cannot observe "the transcript changed" through the
    /// count alone, which is why a history refresh never re-anchored the scroll position.
    public private(set) var transcriptRevision = 0
    public private(set) var streamingText: String = ""
    public private(set) var streamingReasoningText: String = ""
    public private(set) var activeToolName: String?
    public private(set) var activeWorkItems: [AgentWorkItem] = []
    public private(set) var isAgentTurnActive = false
    public private(set) var lastError: String?
    public private(set) var historySyncState: HistorySyncState = .idle
    public private(set) var sessionFailures: [String: SessionRunFailure] = [:]
    public private(set) var sessionCompactions: [String: SessionCompactionStatus] = [:]
    public private(set) var lastHistoryRefresh: [String: Date] = [:]
    @ObservationIgnored private var compactingSessionKeys: [String: UUID] = [:]
    public private(set) var sessionsSyncNotice: String?
    public private(set) var approvals: [ExecApproval] = []
    public var questionInbox = QuestionInbox()
    @ObservationIgnored private var questionExpiryTask: Task<Void, Never>?
    public private(set) var questionError: String?
    public var questionsEnabled: Bool { UserDefaults.standard.bool(forKey: "cast.questions." + profile.id) }
    public private(set) var secretRequests: [SecretRequest] = []
    public private(set) var secretRequestError: String?
    private var secretRevision = 0
    private var resolvedSecretIDs: Set<String> = []
    private var secretSubmissions: Set<String> = []
    public var secretEntryEnabled: Bool { UserDefaults.standard.bool(forKey: "cast.secretEntry." + profile.id) }

    public private(set) var presence: [PresenceEntry] = []
    public var searchFocusMessageID: String?
    public var searchFocusExcerpt: String?
    public var searchFocusSessionKey: String?
    public private(set) var searchHits: [CachedSearchHit] = []
    public private(set) var isSearching = false
    public private(set) var numericUnreadCount = 0
    public private(set) var unreadCountsBySession: [String: Int] = [:]
    public private(set) var notificationRecords: [NotificationDeliveryRecord] = []
    public private(set) var automationRuns: [CronRun] = []
    public private(set) var automationRunsState: AutomationRunsState = .idle
    public private(set) var mutedSessionKeys: Set<String> = []
    public private(set) var sidebarPreferences = SidebarPreferences()
    public private(set) var lastHiddenSessionKey: String?
    public var showHiddenSessions = false
    @ObservationIgnored private let sidebarPreferencesStore: AtomicJSONLedgerStore<SidebarPreferences>
    /// One-line, non-modal "a gateway update is available" notice; nil when current.
    public private(set) var updateNotice: String?
    /// Live progress cards keyed by sessionKey. Populated on session open and on
    /// `progressCard.changed` events. A missing key means the card has not been fetched yet;
    /// a nil value means the session has no card. `nil` card vs. absent key are both
    /// rendered as "no card" — only the keyed `ProgressCard` is shown.
    public private(set) var progressCards: [String: ProgressCard] = [:]
    /// Sessions whose progress card the user has collapsed. Reset is intentionally not
    /// per-session: the collapsed state follows the user's in-session choice.
    public private(set) var collapsedProgressCardSessions: Set<String> = []
    /// Session offered a one-tap `sessions.compact` because its run died on
    /// `errorKind:"context_length"`. Paired with the alert in `lastError`; cleared with it.
    public private(set) var contextCompactionOfferKey: String?
    public private(set) var isAbortingRun = false
    public var pendingAttachments: [PreparedAttachment] = []
    public var deliverExternally = false

    @ObservationIgnored private var searchQueryStorage = ""
    public var searchQuery: String {
        get {
            self.access(keyPath: \.searchQuery)
            return self.searchQueryStorage
        }
        set {
            self.withMutation(keyPath: \.searchQuery) { self.searchQueryStorage = newValue }
            self.scheduleSearch()
        }
    }

    @ObservationIgnored private var selectedSessionKeyStorage: String?
    public var selectedSessionKey: String? {
        get {
            self.access(keyPath: \.selectedSessionKey)
            return self.selectedSessionKeyStorage
        }
        set {
            let oldValue = self.selectedSessionKeyStorage
            self.withMutation(keyPath: \.selectedSessionKey) { self.selectedSessionKeyStorage = newValue }
            guard oldValue != self.selectedSessionKeyStorage else { return }
            self.beginOpeningSelectedSession(previous: oldValue)
            self.publishCachedAgentIdentityAndRefresh()
        }
    }

    @ObservationIgnored
    private var client: GatewayClient?
    @ObservationIgnored
    private var turnActivity = AgentTurnActivityState()
    @ObservationIgnored
    private var pendingEchoes: [PendingEcho] = []
    /// Live and failed sends by idempotency key. Entries are dropped once the gateway
    /// accepts the send; a failed entry stays so retry can resend the identical payload.
    @ObservationIgnored
    private var sendContexts: [String: PendingSendContext] = [:]
    @ObservationIgnored
    private var transcriptSnapshots = TranscriptSnapshotStore()
    @ObservationIgnored
    private var sessionsRefreshScheduled = false
    @ObservationIgnored
    private var sessionsNeedingHistoryRefresh: Set<String> = []
    @ObservationIgnored
    private let readReceiptQueue = ReadReceiptQueue()
    @ObservationIgnored
    private var pendingReadReceipts: [String: ReadReceiptSnapshot] = [:]

    private struct ReadReceiptSnapshot: Equatable {
        let id = UUID()
        let generation: Int
        let updatedAt: Double?
        let watermark: Int64?
    }
    @ObservationIgnored
    private var sessionsRequestInFlight = false
    /// Sessions whose `sessions.messages.subscribe` the gateway actually acknowledged.
    @ObservationIgnored
    private var subscribedSessionKeys: Set<String> = []
    /// Whether the workspace-wide `sessions.subscribe` is acknowledged, still unresolved, or
    /// gave up. Tri-state so the sidebar notice distinguishes "not answered yet" from
    /// "answered no": only the latter is worth telling the reader about.
    @ObservationIgnored
    private var sessionsSubscription: SessionsSubscriptionState = .idle
    @ObservationIgnored
    private var sessionsSubscribeTask: Task<Bool, Never>?
    /// Bumped whenever the ladder is (re)started or abandoned, so a task finishing late
    /// cannot clear the handle belonging to the one that replaced it.
    @ObservationIgnored
    private var sessionsSubscribeGeneration = 0
    @ObservationIgnored
    private var transcriptWatchdogTask: Task<Void, Never>?
    @ObservationIgnored
    private var historyRefreshCoordinator = HistoryRefreshCoordinator()
    /// Deep history is deliberately not part of the session-open task. The first 200-row
    /// page settles the open; this utility-priority task fills the in-memory Show Earlier
    /// backlog and publishes it once when complete.
    @ObservationIgnored
    private var historyBackfillTask: Task<Void, Never>?
    @ObservationIgnored
    private var historyBackfillGeneration = 0
    /// Sessions whose in-memory transcript is known to reach the gateway's beginning. A
    /// bounded disk snapshot is intentionally not inserted here.
    @ObservationIgnored
    private var completeHistorySessionKeys: Set<String> = []
    @ObservationIgnored
    private var historyRetryTask: Task<Void, Never>?
    @ObservationIgnored
    private var historyRetryAttempt = 0
    @ObservationIgnored
    private var sessionOpenTask: Task<Void, Never>?
    @ObservationIgnored
    private var sessionOpenGeneration = 0
    @ObservationIgnored
    private var searchTask: Task<Void, Never>?
    @ObservationIgnored
    private var searchGeneration = 0
    @ObservationIgnored
    private var transcriptCache: [TranscriptItem] = []
    @ObservationIgnored
    private var transcriptCacheShowsAgentWork: Bool?
    @ObservationIgnored
    private var transcriptCacheIsStale = true
    /// Retained across appends so a new message costs its own work instead of a full
    /// re-walk. Only ever holds the `showAgentWork: true` shape; `false` is a whole-history
    /// filter and cannot be extended incrementally. Nil means "rebuild from scratch".
    @ObservationIgnored
    private var transcriptBuilder: IncrementalTranscriptBuilder?
    /// Set for the duration of a `messages` write that only appends to the tail, so the
    /// setter can tell an append from a rewrite. See `appendingToTranscript`.
    @ObservationIgnored
    private var transcriptWriteIsAppendOnly = false
    @ObservationIgnored
    private var progressCardFetchTasks: [String: Task<Void, Never>] = [:]
    #if DEBUG
    @ObservationIgnored
    private var smokeSendStarted = false
    @ObservationIgnored
    private var smokeRotationStarted = false
    #endif
    @ObservationIgnored
    private let decoder = JSONDecoder()
    @ObservationIgnored
    private let encoder = JSONEncoder()
    @ObservationIgnored
    private let cache: TranscriptCache
    @ObservationIgnored private let deliverableFiles: DeliverableFileCache
    @ObservationIgnored private let sendOutbox: SendOutbox
    @ObservationIgnored
    private var unreadLedger: UnreadLedger
    @ObservationIgnored
    private var notificationLedger: NotificationDeliveryLedger
    @ObservationIgnored
    private var acknowledgementLedger: AcknowledgementLedger
    @ObservationIgnored
    private var draftLedger: DraftLedger
    @ObservationIgnored
    private var muteLedger: MuteLedger
    @ObservationIgnored
    private let operationsPersistence: OperationsLedgerPersistence
    /// While set (epoch ms), a socket disconnect is presented as the announced gateway
    /// restart it is, not a generic offline failure. Cleared on the next connect.
    @ObservationIgnored
    private var gatewayRestartDeadlineMs: Double?
    @ObservationIgnored
    private var agentIdentitiesByID: [String: AgentIdentity] = [:]
    @ObservationIgnored
    private var agentIdentityTask: Task<Void, Never>?
    @ObservationIgnored
    private(set) var isSuspendedForBackground = false
    @ObservationIgnored
    private(set) var clientGeneration = 0

    public init(
        profile: WorkspaceProfile = .unconfigured,
        transcriptCacheRoot: URL? = nil,
        operationsLedgerRoot: URL? = nil)
    {
        self.profile = profile
        self.cache = TranscriptCache(workspaceID: profile.id, root: transcriptCacheRoot)
        let operationsRoot: URL
        if let operationsLedgerRoot {
            operationsRoot = operationsLedgerRoot
        } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            operationsRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("CastTestOperations-\(UUID().uuidString)", isDirectory: true)
        } else {
            operationsRoot = Self.defaultOperationsRoot(workspaceID: profile.id)
        }
        // Explicit workspace component also isolates callers that share a custom root.
        let sidebarRoot = operationsRoot.appendingPathComponent("sidebar", isDirectory: true)
            .appendingPathComponent(Data(profile.id.utf8).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_"))
        self.sidebarPreferencesStore = AtomicJSONLedgerStore(
            fileURL: sidebarRoot.appendingPathComponent("preferences.json"))
        self.sidebarPreferences = (try? self.sidebarPreferencesStore.load(defaultValue: SidebarPreferences()))
            ?? SidebarPreferences()
        self.sendOutbox = SendOutbox(root: sidebarRoot.appendingPathComponent("Outbox"))
        self.deliverableFiles = DeliverableFileCache(root: sidebarRoot.appendingPathComponent("Downloads"))
        self.deliverableStore = AtomicJSONLedgerStore(fileURL: sidebarRoot.appendingPathComponent("deliverables.json"))
        self.reviewedWorkStore = AtomicJSONLedgerStore(fileURL: sidebarRoot.appendingPathComponent("reviewed-work.json"))
        self.deliverableLedger = (try? self.deliverableStore.load(defaultValue: DeliverableLedger())) ?? DeliverableLedger()
        self.reviewedWork = (try? self.reviewedWorkStore.load(defaultValue: ReviewedWorkLedger())) ?? ReviewedWorkLedger()
        let unreadStore = AtomicJSONLedgerStore<UnreadLedger>(
            fileURL: operationsRoot.appendingPathComponent("unread.json"))
        let notificationStore = AtomicJSONLedgerStore<NotificationDeliveryLedger>(
            fileURL: operationsRoot.appendingPathComponent("notifications.json"))
        let acknowledgementStore = AtomicJSONLedgerStore<AcknowledgementLedger>(
            fileURL: operationsRoot.appendingPathComponent("acknowledgements.json"))
        let draftStore = AtomicJSONLedgerStore<DraftLedger>(
            fileURL: operationsRoot.appendingPathComponent("drafts.json"))
        let muteStore = AtomicJSONLedgerStore<MuteLedger>(
            fileURL: operationsRoot.appendingPathComponent("mutes.json"))
        let unread = (try? unreadStore.load(defaultValue: UnreadLedger())) ?? UnreadLedger()
        var notifications = (try? notificationStore.load(defaultValue: NotificationDeliveryLedger()))
            ?? NotificationDeliveryLedger()
        notifications.pruneTerminalRecords(
            before: Date().addingTimeInterval(-NotificationDeliveryLedger.terminalRecordRetention))
        let acknowledgements = (try? acknowledgementStore.load(defaultValue: AcknowledgementLedger()))
            ?? AcknowledgementLedger()
        self.unreadLedger = unread
        self.notificationLedger = notifications
        self.acknowledgementLedger = acknowledgements
        self.draftLedger = (try? draftStore.load(defaultValue: DraftLedger())) ?? DraftLedger()
        self.muteLedger = (try? muteStore.load(defaultValue: MuteLedger())) ?? MuteLedger()
        self.operationsPersistence = OperationsLedgerPersistence(root: operationsRoot)
        self.mutedSessionKeys = self.muteLedger.mutedSessionKeys
        self.numericUnreadCount = (unread.workspaces[profile.id]?.sessions ?? [:])
            .filter { !self.sidebarPreferences.isHidden($0.key) }
            .values.reduce(0) { $0 + $1.count }
        self.unreadCountsBySession = unread.workspaces[profile.id]?.sessions.mapValues(\.count) ?? [:]
        self.notificationRecords = notifications.records
    }

    public var visibleSessions: [SessionRow] {
        let query = self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = self.sessions.filter { self.showHiddenSessions || !self.isSessionHidden($0.key) }
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            SidebarGrouper.matchesSearch($0, query: query, mainSessionKey: self.mainSessionKey)
        }
    }

    public var sidebarSections: [SidebarSection] {
        let failedNotificationSessionKeys = Set(self.notificationRecords.compactMap {
            $0.state == .failed ? $0.linkage.sessionKey : nil
        })
        return SidebarGrouper.sections(
            self.sessions.filter { !self.isSessionHidden($0.key) }.map { session in
                let needsAttention = self.unreadCount(for: session.key) > 0
                    || failedNotificationSessionKeys.contains(where: {
                        SessionKeyMatcher.matches($0, session.key)
                    })
                return needsAttention ? session.settingUnread(true) : session
            },
            mainSessionKey: self.mainSessionKey,
            now: Date(),
            pinnedSessionKeys: self.sidebarPreferences.pinnedKeys)
    }

    public var sidebarActivitySummary: SidebarActivitySummary {
        SidebarGrouper.activitySummary(
            for: self.sessions,
            mainSessionKey: self.mainSessionKey,
            now: Date(),
            acknowledgedFailures: self.acknowledgementLedger.identifiers(workspaceID: self.profile.id))
    }

    public var activitySessions: [SessionRow] {
        SidebarGrouper.activitySessions(self.sessions, mainSessionKey: self.mainSessionKey)
    }

    public var unreadSessionCount: Int {
        self.numericUnreadCount
    }

    public func unreadCount(for sessionKey: String) -> Int {
        self.isSessionHidden(sessionKey) ? 0 : (self.unreadCountsBySession[sessionKey] ?? 0)
    }

    /// The session the unread bell should land on: the first one carrying unread in sidebar
    /// order, so it matches the row the reader would have reached for themselves rather than
    /// some other definition of "first".
    public var firstUnreadSessionKey: String? {
        UnreadNavigation.firstSessionKey(
            in: self.sidebarSections,
            unreadCount: self.unreadCount(for:))
    }

    public func unreadCount(in sessions: [SessionRow]) -> Int {
        sessions.reduce(0) { $0 + self.unreadCount(for: $1.key) }
    }

    /// One row per chat carrying unread state, honest about what Cast actually knows: a count
    /// where real per-message events were observed, otherwise the lower bound the gateway's
    /// boolean snapshot established. Ordered most-recently-active first.
    public var unreadSummaries: [ChatUnreadSummary] {
        let rows = Dictionary(self.sessions.map { (SessionKeyMatcher.canonical($0.key), $0) },
                              uniquingKeysWith: { first, _ in first })
        return self.unreadCountsBySession
            .compactMap { sessionKey, count -> ChatUnreadSummary? in
                guard count > 0, !self.isSessionHidden(sessionKey),
                      let state = self.unreadLedger.state(
                          workspaceID: self.profile.id,
                          sessionKey: sessionKey)
                else { return nil }
                let session = rows[SessionKeyMatcher.canonical(sessionKey)]
                return ChatUnreadSummary(
                    sessionKey: session?.key ?? sessionKey,
                    title: session.map {
                        SidebarGrouper.displayTitle(for: $0, mainSessionKey: self.mainSessionKey)
                    } ?? sessionKey,
                    preview: SidebarGrouper.cleanPreview(session?.lastMessagePreview),
                    unreadCount: count,
                    accuracy: state.accuracy,
                    updatedAt: session?.updatedAt ?? state.highestObservedWatermark.map(Double.init))
            }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    /// Clears local unread state in one transaction and queues authoritative read receipts
    /// without blocking the UI. Failed gateway updates remain retryable after refresh/open.
    public func markAllRead() {
        var watermarks: [String: Int64] = [:]
        for session in self.sessions {
            if let watermark = Self.operationWatermark(session.updatedAt) {
                watermarks[session.key] = watermark
            }
        }
        self.unreadLedger.clearAll(workspaceID: self.profile.id, sessionWatermarks: watermarks)
        let clearedIDs = self.notificationLedger.markRead(workspaceID: self.profile.id, at: Date())
        self.publishOperationsState()
        self.removeNativeNotifications(identifiers: clearedIDs)
        for session in self.sessions where session.isUnread {
            self.enqueueReadReceipt(session)
        }
    }

    public func acknowledgeFailure(_ session: SessionRow) {
        guard SidebarGrouper.hasFailureSignal(session),
              self.acknowledgementLedger.acknowledge(
                  workspaceID: self.profile.id,
                  sessionKey: session.key,
                  updatedAt: session.updatedAt)
        else { return }
        self.publishOperationsState()
    }

    public func isFailureAcknowledged(_ session: SessionRow) -> Bool {
        self.acknowledgementLedger.isAcknowledged(
            workspaceID: self.profile.id,
            sessionKey: session.key,
            updatedAt: session.updatedAt)
    }

    public func sidebarSubtitle(for session: SessionRow) -> String? {
        SidebarGrouper.subtitle(
            for: session,
            mainSessionKey: self.mainSessionKey,
            allSessions: self.sessions)
    }

    /// Cached render list, invalidated by any `messages` write. `ChatView.body` re-evaluates
    /// on every streaming token, so building this inline made each layout pass cost
    /// O(messages) — with a few hundred messages the main thread stopped converging.
    ///
    /// Invalidation alone was not enough: a streamed reply appends one row, and rebuilding
    /// the cache still re-walked the entire history for it. When the previous write only
    /// appended, the retained `IncrementalTranscriptBuilder` is extended with just the new
    /// messages instead. Full replacements and reconciles still rebuild, and so does
    /// `showAgentWork: false`, whose `answers(from:)` filter is a whole-history decision.
    public func transcriptItems(showAgentWork: Bool) -> [TranscriptItem] {
        if !self.transcriptCacheIsStale, self.transcriptCacheShowsAgentWork == showAgentWork {
            return self.transcriptCache
        }
        let messages = self.messages
        // Whether this build re-walked the transcript or only extended it is the single
        // thing worth knowing when the main thread stalls here, so it is what the interval
        // records — `processed_messages` is the work actually done, not the history size.
        let extendable = showAgentWork
            && self.transcriptBuilder.map { $0.consumedMessageCount <= messages.count } == true
        let processed = extendable
            ? messages.count - (self.transcriptBuilder?.consumedMessageCount ?? 0)
            : messages.count
        let performanceInterval = CastPerformanceDiagnostics.begin(
            .transcriptCache,
            metadata: "mode=\(extendable ? "append" : "rebuild") "
                + "processed_messages=\(processed) source_messages=\(messages.count) "
                + "show_agent_work=\(showAgentWork)")
        var updatedItemCount = 0
        defer {
            CastPerformanceDiagnostics.end(
                performanceInterval,
                metadata: "output_items=\(self.transcriptCache.count) "
                    + "updated_items=\(updatedItemCount)")
        }

        if extendable, var builder = self.transcriptBuilder {
            builder.append(contentsOf: messages[builder.consumedMessageCount...])
            updatedItemCount = builder.materialize(into: &self.transcriptCache)
            self.transcriptBuilder = builder
        } else if showAgentWork {
            var builder = IncrementalTranscriptBuilder()
            builder.append(contentsOf: messages)
            self.transcriptCache = []
            updatedItemCount = builder.materialize(into: &self.transcriptCache)
            self.transcriptBuilder = builder
        } else {
            // `answers(from:)` decides what to keep by looking across the whole history, so
            // this shape can only ever be rebuilt. Drop the builder rather than let a stale
            // one be mistaken for an extendable prefix when the toggle flips back.
            self.transcriptBuilder = nil
            self.transcriptCache = TranscriptBuilder.items(from: messages, showAgentWork: false)
            updatedItemCount = self.transcriptCache.count
        }
        self.transcriptCacheShowsAgentWork = showAgentWork
        self.transcriptCacheIsStale = false
        return self.transcriptCache
    }

    /// Performs a `messages` write that only appends to the tail, so the write's observer
    /// can keep the incremental builder's consumed prefix instead of discarding it. The
    /// flag is cleared unconditionally: a `write` that turns out to be a no-op must not
    /// leave a later rewrite looking like an append.
    private func appendingToTranscript(_ write: () -> Void) {
        self.transcriptWriteIsAppendOnly = true
        write()
        self.transcriptWriteIsAppendOnly = false
    }

    #if DEBUG
    /// Test seam: how many source messages the retained incremental builder has folded in.
    /// Nil when no builder is live (a rewrite dropped it, or agent work is hidden).
    var transcriptBuilderConsumedMessageCount: Int? {
        self.transcriptBuilder?.consumedMessageCount
    }

    /// Installs deterministic in-memory data for the app-level layout stress mode. This
    /// path deliberately does not select a session, touch transcript persistence, or create
    /// a gateway client.
    public func installOfflineDiagnosticTranscript(_ messages: [ChatMessage]) {
        precondition(self.client == nil, "Offline diagnostics must run without a gateway client")
        self.messages = messages
        self.pendingAttachments = []
        self.streamingText = ""
        self.streamingReasoningText = ""
        self.activeToolName = nil
        self.activeWorkItems = []
        self.approvals = []
        self.historySyncState = .idle
    }

    /// Test seam: exercises the real send/failure paths against a client whose gateway is
    /// unreachable, without touching the Keychain-backed credential ladder in `start()`.
    func installClientForTesting(_ client: GatewayClient) {
        precondition(
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
            "installClientForTesting is for the test host only")
        self.client = client
    }
    #endif

    public var agentDisplayName: String {
        if let name = self.agentIdentity?.name { return name }
        guard let agentID = SessionKeyMatcher.agentID(from: self.selectedSessionKey),
              agentID != "main"
        else { return self.profile.name }
        return agentID
    }

    public var selectedAgentID: String {
        SessionKeyMatcher.agentID(from: self.selectedSessionKey) ?? "main"
    }

    // MARK: - Lifecycle

    public func start() {
        guard self.client == nil, !self.isSuspendedForBackground else { return }
        guard let credential = GatewayCredentialStore.preferred(workspaceID: self.profile.id) else {
            self.lastError = "Pair this workspace or add its gateway token."
            self.connectionState = .needsCredentials("pair workspace")
            return
        }
        #if os(macOS)
        let clientId = "openclaw-macos"
        let platform = "macOS"
        let family = "Mac"
        #else
        let clientId = "openclaw-ios"
        let platform = "iOS"
        let family = "iPhone"
        #endif
        let workspaceID = self.profile.id
        let config = GatewayClientConfig(
            url: self.profile.gatewayURL,
            workspaceID: workspaceID,
            credential: credential,
            deviceCredentialProvider: { GatewayCredentialStore.deviceCredential(workspaceID: workspaceID) },
            onDeviceToken: { token in
                try? GatewayCredentialStore.setDeviceToken(token, workspaceID: workspaceID)
            },
            clientId: clientId,
            platform: platform,
            deviceFamily: family,
            displayName: "Cast",
            secretEntryEnabled: self.secretEntryEnabled, questionsEnabled: self.questionsEnabled)
        self.clientGeneration &+= 1
        let generation = self.clientGeneration
        let client = GatewayClient(
            config: config,
            onEvent: { [weak self] event in
                Task { @MainActor in self?.receiveEvent(event, generation: generation) }
            },
            onState: { [weak self] state in
                Task { @MainActor in self?.receiveState(state, generation: generation) }
            })
        self.client = client
        Task { await client.start() }
    }

    public func update(profile: WorkspaceProfile) {
        guard self.profile != profile else { return }
        self.sessionFailures.removeAll()
        self.sessionCompactions.removeAll()
        self.lastHistoryRefresh.removeAll()
        self.compactingSessionKeys.removeAll()
        self.clearError()
        self.questionExpiryTask?.cancel()
        self.questionInbox = QuestionInbox()
        self.questionError = nil
        self.profile = profile
        self.restartWithStoredCredential()
    }

    public func restartWithStoredCredential() {
        self.interruptObservedCompactions()
        self.compactingSessionKeys.removeAll()
        self.secretRequests = []
        self.secretRevision += 1
        self.clientGeneration &+= 1
        let previous = self.client
        self.client = nil
        self.subscribedSessionKeys.removeAll()
        self.resetSessionsSubscription()
        self.transcriptWatchdogTask?.cancel()
        self.transcriptWatchdogTask = nil
        self.connectionState = .disconnected("reconnecting")
        Task { await previous?.shutdown() }
        self.start()
    }

    /// Close the active socket before iOS freezes the process. This prevents a suspended
    /// connection loop from waking into a reconnect storm; activation creates one fresh
    /// client and `handleState(.connected)` performs one authoritative refresh.
    public func suspendForBackground() {
        guard !self.isSuspendedForBackground else { return }
        self.interruptObservedCompactions()
        self.compactingSessionKeys.removeAll()
        self.isSuspendedForBackground = true
        self.secretRequests = []
        self.secretRevision += 1
        self.clientGeneration &+= 1
        CastLifecycleDiagnostics.gatewayTransition("suspend")
        self.agentIdentityTask?.cancel()
        self.transcriptWatchdogTask?.cancel()
        self.transcriptWatchdogTask = nil
        let previous = self.client
        self.client = nil
        self.subscribedSessionKeys.removeAll()
        self.resetSessionsSubscription()
        self.connectionState = .disconnected(nil)
        Task { await previous?.shutdown() }
    }

    nonisolated static func acceptsClientCallback(
        generation: Int,
        currentGeneration: Int,
        suspended: Bool) -> Bool
    {
        generation == currentGeneration && !suspended
    }

    func receiveState(_ state: GatewayConnectionState, generation: Int) {
        guard Self.acceptsClientCallback(
            generation: generation,
            currentGeneration: self.clientGeneration,
            suspended: self.isSuspendedForBackground)
        else { return }
        self.handleState(state)
    }

    func receiveEvent(_ event: EventFrame, generation: Int) {
        guard Self.acceptsClientCallback(
            generation: generation,
            currentGeneration: self.clientGeneration,
            suspended: self.isSuspendedForBackground)
        else { return }
        self.handleEvent(event)
    }

    private func handleState(_ state: GatewayConnectionState) {
        CastLifecycleDiagnostics.connectionState(Self.lifecycleStateLabel(state))
        self.connectionState = Self.presentedConnectionState(
            state,
            restartDeadlineMs: self.gatewayRestartDeadlineMs,
            nowMs: Date().timeIntervalSince1970 * 1000)
        guard case .connected = state else {
            self.interruptObservedCompactions()
            // A dropped socket invalidates every server-side subscription, so the next
            // connect has to re-establish them rather than trust this cache.
            self.subscribedSessionKeys.removeAll()
            self.resetSessionsSubscription()
            return
        }
        self.gatewayRestartDeadlineMs = nil
        self.startTranscriptWatchdog()
        Task { await self.refreshSessions() }
        Task { await self.resubscribeAndReloadOpenSession() }
        self.publishCachedAgentIdentityAndRefresh()
        Task { await self.refreshApprovals() }
        Task { await self.refreshSecretRequests() }
        Task { await self.refreshQuestions() }
        Task { await self.subscribeToSessions() }
        #if DEBUG
        self.startIsolatedSendSmokeIfRequested()
        self.startTokenRotationSmokeIfRequested()
        #endif
    }

    nonisolated private static func lifecycleStateLabel(_ state: GatewayConnectionState) -> String {
        switch state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .waitingForApproval: return "waiting-for-approval"
        case .needsCredentials: return "needs-credentials"
        case .connected: return "connected"
        }
    }

    /// The gateway announces restarts (`shutdown` event) before the socket dies. Inside
    /// that window a disconnect is expected downtime, and painting the raw socket error as
    /// a red "offline" reads as an outage. The deadline bounds the claim: a gateway that
    /// never comes back stops being "restarting" once its own estimate has lapsed.
    nonisolated static func presentedConnectionState(
        _ state: GatewayConnectionState,
        restartDeadlineMs: Double?,
        nowMs: Double) -> GatewayConnectionState
    {
        guard case .disconnected = state,
              let restartDeadlineMs, nowMs < restartDeadlineMs
        else { return state }
        return .disconnected("gateway restarting…")
    }

    /// iOS suspends socket delivery in the background without guaranteeing a disconnect
    /// callback. Reassert subscriptions and merge authoritative history whenever either app
    /// becomes active so messages received on another device cannot remain hidden.
    public func refreshAfterActivation() async {
        self.isSuspendedForBackground = false
        CastLifecycleDiagnostics.gatewayTransition("resume")
        guard self.client != nil else {
            self.start()
            return
        }
        // Returning here used to strand the open transcript: backgrounding is
        // exactly when the socket dies, so a resume that is not `.connected`
        // is the common case, not the edge case. Nothing else re-drives the
        // transcript on foreground, so bailing left an empty message list with
        // `historySyncState == .idle` — a blank view indistinguishable from an
        // empty conversation, until the user reselected the session.
        switch ActivationPolicy.action(
            for: self.connectionState,
            connectingSince: self.connectingSince)
        {
        case .refresh:
            break
        case .reconnect:
            // `handleState(.connected)` reloads the open session once this lands.
            self.restartWithStoredCredential()
            return
        case .wait:
            // Restarting here would cancel live progress and can loop on
            // repeated foregrounds.
            return
        }
        await self.subscribeToSessions()
        await self.refreshSessions()
        await self.resubscribeAndReloadOpenSession()
    }

    private func publishCachedAgentIdentityAndRefresh() {
        let agentID = self.selectedAgentID
        self.agentIdentity = self.agentIdentitiesByID[agentID]
        guard case .connected = self.connectionState else { return }
        self.agentIdentityTask?.cancel()
        self.agentIdentityTask = Task { [weak self] in
            await self?.refreshAgentIdentity(agentID: agentID)
        }
    }

    private func refreshAgentIdentity(agentID: String) async {
        guard let client = self.client else { return }
        do {
            let data = try await client.request(
                method: "agent.identity.get",
                params: ["agentId": agentID])
            let identity = try self.decoder.decode(AgentIdentity.self, from: data)
            guard !Task.isCancelled, agentID == self.selectedAgentID else { return }
            self.agentIdentitiesByID[agentID] = identity
            self.agentIdentity = identity
        } catch {
            // Identity is decorative. Keep the deterministic local fallback and never turn
            // a missing/older gateway method into a chat failure.
        }
    }

    #if DEBUG
    /// Deterministic end-to-end smoke hook used by local builds. It is deliberately
    /// hard-locked to the unrouted scratch session; the regular composer uses the
    /// same `send` path and `deliver:false` safeguard.
    private func startIsolatedSendSmokeIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard !self.smokeSendStarted,
              let smokeWorkspaceID = environment["CAST_SMOKE_WORKSPACE_ID"],
              self.profile.id == smokeWorkspaceID,
              let text = ProcessInfo.processInfo.environment["CAST_SMOKE_SEND_TEXT"],
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        self.smokeSendStarted = true
        self.selectedSessionKey = "agent:main:cast-dev"
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            var attachments: [PreparedAttachment] = []
            if let path = ProcessInfo.processInfo.environment["CAST_SMOKE_ATTACHMENT_PATH"],
               !path.isEmpty {
                do {
                    attachments = [try AttachmentProcessor.prepare(url: URL(fileURLWithPath: path))]
                } catch {
                    self.lastError = "Smoke attachment: \(error.localizedDescription)"
                    return
                }
            }
            self.send(text, attachments: attachments, deliver: false)
        }
    }

    private func startTokenRotationSmokeIfRequested() {
        guard !self.smokeRotationStarted,
              ProcessInfo.processInfo.environment["CAST_SMOKE_ROTATE_DEVICE_TOKEN"] == "1"
        else { return }
        self.smokeRotationStarted = true
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.rotateDeviceToken()
        }
    }
    #endif

    // MARK: - Sessions

    public var supportsModelControls: Bool {
        self.gatewayMethods.isSuperset(of: ["models.list", "sessions.patch"])
    }

    public func loadModelChoices(for key: String) async throws {
        guard self.supportsModelControls else { throw ModelControlError.unsupported }
        guard let client, case .connected = self.connectionState else { throw ModelControlError.disconnected }
        let agentID = SessionKeyMatcher.agentID(from: key) ?? "main"
        let data = try await client.request(method: "models.list", params: [
            "agentId": agentID, "includeProviderCapabilities": true,
        ])
        guard (SessionKeyMatcher.agentID(from: self.selectedSessionKey) ?? "main") == agentID else { return }
        self.modelCatalog = try self.decoder.decode(GatewayModelsResponse.self, from: data).models
        self.modelCatalogAgentID = agentID
    }

    public func changeSessionModel(key: String, reference: String, effort: String?) async throws {
        guard self.supportsModelControls else { throw ModelControlError.unsupported }
        guard let client, case .connected = self.connectionState else { throw ModelControlError.disconnected }
        guard !self.savingModelKeys.contains(key),
              self.modelCatalogAgentID == (SessionKeyMatcher.agentID(from: key) ?? "main"),
              let model = self.modelCatalog.first(where: { $0.reference == reference })
        else { throw ModelControlError.unavailable }
        let row = self.sessions.first { $0.key == key }
        let params = try SessionModelMutation.params(key: key, sessionID: row?.modelInfo?.sessionId,
                                                     model: model, effort: effort)
        self.savingModelKeys.insert(key)
        defer { self.savingModelKeys.remove(key) }
        _ = try await client.request(method: "sessions.patch", params: params.mapValues(\.value))
        self.pendingModelChanges[key] = model.reference
        // sessions.patch admin-scopes thinkingLevel, which paired-device tokens lack. The
        // `/think` command persists the same override through chat.send (operator.write); the
        // gateway acknowledges it in the conversation without running a model turn. It is sent
        // after the model patch so the gateway validates the level against the new model.
        if SessionModelMutation.needsThinkingCommand(effort: effort, currentOverride: row?.modelInfo?.thinkingLevel) {
            do {
                _ = try await client.sendChat(
                    sessionKey: key,
                    message: SessionModelMutation.thinkingCommand(effort: effort),
                    idempotencyKey: UUID().uuidString,
                    deliver: false,
                    attachments: [])
            } catch {
                await self.refreshSessions()
                throw ModelControlError.reasoningNotApplied(error.localizedDescription)
            }
        }
        await self.refreshSessions()
    }

    public func refreshSessions() async {
        guard let client = self.client, !self.sessionsRequestInFlight else { return }
        self.sessionsRequestInFlight = true
        defer { self.sessionsRequestInFlight = false }
        do {
            let data = try await client.request(method: "sessions.list", params: [
                "includeGlobal": true,
                "includeUnknown": false,
                "limit": 60,
                "includeDerivedTitles": true,
                "includeLastMessage": true,
            ])
            let list = try self.decoder.decode(SessionsListResponse.self, from: data)
            if let mainKey = list.defaults?.mainSessionKey { self.mainSessionKey = mainKey }
            let refreshed = Self.dedupedByID(
                list.sessions.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) })
            // The transcript watchdog polls this on a timer, so republishing an identical
            // list would rebuild the sidebar every cycle for nothing.
            if refreshed != self.sessions { self.sessions = refreshed }
            self.reconcileOperations(with: self.sessions)
            if let selectedSessionKey = self.selectedSessionKey,
               self.sessions.first(where: { $0.key == selectedSessionKey })?.isUnread == true
            {
                Task { await self.markSessionRead(selectedSessionKey) }
            }
            if let selectedKey = self.selectedSessionKey,
               self.sessions.first(where: { $0.key == selectedKey })?.hasActiveRun == true
            {
                self.turnActivity.applyHistory(hasActiveRun: true, runIds: [])
                self.updateAgentTurnActivity()
            }
            // A healthy list refresh clears its own notice, but not a spent subscribe
            // ladder's: the list is current as of this call and still will not update itself.
            self.sessionsSyncNotice = self.sessionsSubscription == .failed
                ? Self.sessionsSubscribeNotice
                : nil
            self.publishShareDestinations()
            #if os(macOS)
            if self.selectedSessionKey == nil {
                self.selectedSessionKey = self.sidebarSections.flatMap(\.sessions).first?.key
            }
            #endif
        } catch {
            // Session discovery is background synchronization. Keep the last
            // usable list and surface a quiet retry affordance instead of an
            // app-blocking alert during launch/reconnect.
            self.sessionsSyncNotice = "Couldn’t refresh conversations. Showing the last available list."
        }
    }

    /// `sessions.subscribe` is what routes the workspace-wide session list updates. Its
    /// result used to be discarded with `try?`, so a subscribe lost to a reconnect race or a
    /// transient gateway error left the sidebar list-dead: no retry, no banner, and no
    /// symptom until relaunch. Retry on the bounded ladder, remember what the gateway
    /// actually acknowledged, and say so when the ladder is spent.
    ///
    /// Connect and activation both drive this, and on iOS they routinely overlap. A single
    /// in-flight task is shared instead of started twice, so overlapping callers cannot
    /// stack duplicate retry ladders against the same socket.
    private func subscribeToSessions() async {
        if self.sessionsSubscription == .subscribed { return }
        if let inFlight = self.sessionsSubscribeTask {
            _ = await inFlight.value
            return
        }
        guard let client = self.client else { return }
        self.sessionsSubscribeGeneration &+= 1
        let generation = self.sessionsSubscribeGeneration
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            defer {
                if self.sessionsSubscribeGeneration == generation { self.sessionsSubscribeTask = nil }
            }
            return await self.runSessionsSubscribeLadder(client: client, generation: generation)
        }
        self.sessionsSubscribeTask = task
        _ = await task.value
    }

    private func runSessionsSubscribeLadder(client: GatewayClient, generation: Int) async -> Bool {
        let succeeded = await BoundedSubscribeRetry.sessions.run(
            isCurrent: { [weak self] in
                guard let self else { return false }
                return !Task.isCancelled && self.client === client && !self.isSuspendedForBackground
            },
            perform: { [weak self] _ in
                guard let self, self.client === client else { return false }
                do {
                    _ = try await client.request(method: "sessions.subscribe", params: [:])
                    return true
                } catch {
                    return false
                }
            })
        // A disconnect/reconnect can cancel this task while the request itself is still
        // settling. Generation is the authority: an old ladder must not overwrite the
        // fresh socket's `.idle`/`.subscribed` state with a late failure.
        guard self.sessionsSubscribeGeneration == generation,
              self.client === client,
              !self.isSuspendedForBackground
        else { return succeeded }
        if succeeded {
            self.sessionsSubscription = .subscribed
            if self.sessionsSyncNotice == Self.sessionsSubscribeNotice { self.sessionsSyncNotice = nil }
        } else {
            self.sessionsSubscription = .failed
            CastLifecycleDiagnostics.subscriptionFailed(
                scope: "sessions.subscribe",
                attempts: BoundedSubscribeRetry.sessions.attempts)
            // Reuse the sidebar's existing quiet notice + Retry affordance rather than
            // adding a second banner: from the reader's side both mean "this list is not
            // keeping itself current", and Retry now re-drives the subscribe too.
            self.sessionsSyncNotice = Self.sessionsSubscribeNotice
        }
        return succeeded
    }

    /// Drops the acknowledged-subscription state and abandons any ladder still running for
    /// the socket that is going away, so the next connect starts exactly one fresh attempt.
    private func resetSessionsSubscription() {
        self.sessionsSubscribeGeneration &+= 1
        self.sessionsSubscribeTask?.cancel()
        self.sessionsSubscribeTask = nil
        self.sessionsSubscription = .idle
        if self.sessionsSyncNotice == Self.sessionsSubscribeNotice { self.sessionsSyncNotice = nil }
    }

    // MARK: - Automation runs

    /// Scheduled work runs in short-lived isolated sessions that `sessions.list` drops once
    /// they finish, so a cron job that texted its result was invisible in Cast — the run
    /// happened, but nothing in the app could show it. `cron.runs` is the durable ledger of
    /// those runs, and each entry names the session key its transcript lives under, so a run
    /// can be opened long after the session stopped being listed.
    public func loadAutomationRuns(limit: Int = 60) async {
        guard let client = self.client else {
            self.automationRunsState = .failed("Connect this workspace to see scheduled runs.")
            return
        }
        if self.automationRuns.isEmpty { self.automationRunsState = .loading }
        do {
            let data = try await client.request(
                method: "cron.runs",
                params: ["scope": "all", "limit": limit],
                timeoutMs: 20_000)
            let page = try self.decoder.decode(CronRunsPage.self, from: data)
            self.automationRuns = page.entries
            self.automationRunsState = .loaded
        } catch {
            // Keep whatever is already listed: this is a read-only reporting surface, and a
            // failed refresh should not blank out the last known run history.
            self.automationRunsState = .failed(Self.automationRunsFailureMessage(for: error))
        }
    }

    nonisolated static func automationRunsFailureMessage(for error: Error) -> String {
        guard let request = error as? GatewayRequestError else {
            return "Couldn’t load scheduled runs."
        }
        if request.code?.uppercased() == "AUTH_SCOPE_MISMATCH" {
            return "This workspace token can’t read scheduled runs."
        }
        return request.message ?? "Couldn’t load scheduled runs."
    }

    /// Opens the transcript a run wrote. Run sessions age out of `sessions.list`, so this
    /// deliberately selects the key directly instead of looking it up in `sessions`.
    public func openAutomationRun(_ run: CronRun) {
        guard let key = run.sessionKey, !key.isEmpty else { return }
        self.selectedSessionKey = key
    }

    nonisolated static func sessionChangeAffectsSelectedHistory(
        changedSessionKey: String?,
        selectedSessionKey: String?) -> Bool
    {
        SessionKeyMatcher.matches(changedSessionKey, selectedSessionKey)
    }

    private func scheduleSessionsRefresh(changedSessionKey: String?) {
        if Self.sessionChangeAffectsSelectedHistory(
            changedSessionKey: changedSessionKey,
            selectedSessionKey: self.selectedSessionKey),
           let selectedSessionKey = self.selectedSessionKey
        {
            self.sessionsNeedingHistoryRefresh.insert(selectedSessionKey)
        }
        guard !self.sessionsRefreshScheduled else { return }
        self.sessionsRefreshScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.sessionsRefreshScheduled = false
            let historyKeys = self.sessionsNeedingHistoryRefresh
            self.sessionsNeedingHistoryRefresh.removeAll()
            await self.refreshSessions()
            guard let selectedSessionKey = self.selectedSessionKey,
                  historyKeys.contains(where: {
                      SessionKeyMatcher.matches($0, selectedSessionKey)
                  })
            else { return }
            self.cancelScheduledHistoryRetry(resetAttempt: true)
            await self.reloadHistory()
        }
    }

    // MARK: - Open session

    struct SessionOpenToken: Equatable, Sendable {
        let generation: Int
        let key: String?
    }

    nonisolated static func shouldApplySessionOpen(
        _ token: SessionOpenToken,
        generation: Int,
        selectedKey: String?) -> Bool
    {
        token.generation == generation && token.key == selectedKey
    }

    /// SwiftUI's selectable sidebar may transiently write nil while rows reorder after a
    /// `sessions.changed` refresh on macOS. On iOS, however, collapsing the detail with the
    /// Back button legitimately clears the selection so the same conversation can be opened
    /// again. Reject only the desktop churn case.
    nonisolated static func shouldAcceptSidebarSelection(
        candidate: String?,
        current: String?,
        allowsDeselection: Bool) -> Bool
    {
        allowsDeselection || candidate != nil || current == nil
    }

    public func selectFromSidebar(_ key: String?) {
        #if os(iOS)
        let allowsDeselection = true
        #else
        let allowsDeselection = false
        #endif
        guard Self.shouldAcceptSidebarSelection(
            candidate: key,
            current: self.selectedSessionKey,
            allowsDeselection: allowsDeselection)
        else { return }
        self.selectedSessionKey = key
    }

    private func markSessionRead(_ key: String) async {
        guard let session = self.sessions.first(where: { $0.key == key }) else { return }
        self.enqueueReadReceipt(session)
    }

    private func enqueueReadReceipt(_ session: SessionRow) {
        guard let client = self.client else { return }
        self.enqueueReadReceipt(session) { [weak self] in
            // Do not turn an offline backlog into thousands of connection attempts.
            guard let self, case .connected = self.connectionState else { throw CancellationError() }
            _ = try await client.request(method: "sessions.patch", params: [
                "key": session.key,
                "unread": false,
            ])
        }
    }

    /// Injectable transport boundary lets tests hold receipts across polling/new-reply races.
    func enqueueReadReceipt(_ session: SessionRow, request: @escaping () async throws -> Void) {
        guard session.isUnread else { return }
        let key = session.key
        let generation = self.clientGeneration
        let watermark = self.unreadLedger.state(
            workspaceID: self.profile.id, sessionKey: key)?.highestObservedWatermark
        let receipt = ReadReceiptSnapshot(generation: generation, updatedAt: session.updatedAt, watermark: watermark)
        self.pendingReadReceipts[key] = receipt
        self.readReceiptQueue.enqueue(key: key) { [weak self] in
            guard let self else { return }
            defer {
                if self.pendingReadReceipts[key] == receipt { self.pendingReadReceipts[key] = nil }
            }
            guard self.pendingReadReceipts[key] == receipt, self.clientGeneration == generation,
                  self.readReceiptIsCurrent(key: key, updatedAt: session.updatedAt, watermark: watermark)
            else { return }
            do {
                try await request()
                // New replies or a replacement connection must not be cleared by an old ack.
                guard self.pendingReadReceipts[key] == receipt, self.clientGeneration == generation,
                      self.readReceiptIsCurrent(key: key, updatedAt: session.updatedAt, watermark: watermark),
                      let index = self.sessions.firstIndex(where: { $0.key == key })
                else { return }
                self.sessions[index] = self.sessions[index].settingUnread(false)
            } catch {
                // Keep the gateway dot; refresh/reopen can retry. Never retry-loop a failed
                // receipt or hold up the local clear transaction on a disconnected gateway.
            }
        }
    }

    private func readReceiptIsCurrent(key: String, updatedAt: Double?, watermark: Int64?) -> Bool {
        guard let session = self.sessions.first(where: { $0.key == key }),
              session.isUnread, session.updatedAt == updatedAt
        else { return false }
        let state = self.unreadLedger.state(workspaceID: self.profile.id, sessionKey: key)
        return (state?.count ?? 0) == 0 && state?.highestObservedWatermark == watermark
    }

    private func beginOpeningSelectedSession(previous: String?) {
        self.sessionOpenTask?.cancel()
        self.historyBackfillGeneration &+= 1
        self.historyBackfillTask?.cancel()
        self.historyBackfillTask = nil
        self.sessionOpenGeneration &+= 1
        let token = SessionOpenToken(generation: self.sessionOpenGeneration, key: self.selectedSessionKey)

        if let key = token.key {
            let watermark = Self.operationWatermark(
                self.sessions.first(where: { $0.key == key })?.updatedAt)
            _ = self.unreadLedger.clearOnOpen(
                workspaceID: self.profile.id,
                sessionKey: key,
                throughWatermark: watermark)
            self.markNotificationRecordsRead(sessionKey: key)
            self.publishOperationsState()
            if self.sessions.first(where: { $0.key == key })?.isUnread == true {
                Task { await self.markSessionRead(key) }
            }
        }

        self.cancelScheduledHistoryRetry(resetAttempt: true)
        self.historySyncState = token.key == nil ? .idle : .loading
        if let previous, !self.messages.isEmpty {
            self.transcriptSnapshots.store(self.messages, for: previous)
        }
        self.messages = token.key.flatMap { self.transcriptSnapshots.snapshot(for: $0) } ?? []
        self.streamingText = ""
        self.streamingReasoningText = ""
        self.activeToolName = nil
        self.activeWorkItems = []
        self.turnActivity = AgentTurnActivityState()
        self.previewReconciler = TranscriptPreviewReconciler()
        let sessionReportsActive = token.key.flatMap { key in
            self.sessions.first(where: { $0.key == key })?.hasActiveRun
        } == true
        self.turnActivity.applyHistory(hasActiveRun: sessionReportsActive, runIds: [])
        self.updateAgentTurnActivity()
        self.pendingEchoes = []

        guard token.key != nil else { return }
        if let key = token.key { self.scheduleProgressCardFetch(for: key) }
        self.sessionOpenTask = Task { [weak self] in
            await self?.openSelectedSession(token: token, previous: previous)
        }
    }

    private func openSelectedSession(token: SessionOpenToken, previous: String?) async {
        guard let key = token.key else { return }
        let performanceInterval = CastPerformanceDiagnostics.begin(
            .openSelectedSession,
            metadata: "generation=\(token.generation) previous=\(previous ?? "-") key=\(key)")
        defer {
            CastPerformanceDiagnostics.end(
                performanceInterval,
                metadata: "messages=\(self.messages.count) state=\(String(describing: self.historySyncState))")
        }
        if let previous, let client = self.client {
            self.subscribedSessionKeys.remove(previous)
            _ = try? await client.request(method: "sessions.messages.unsubscribe", params: ["key": previous])
        }
        guard !Task.isCancelled,
              Self.shouldApplySessionOpen(
                  token,
                  generation: self.sessionOpenGeneration,
                  selectedKey: self.selectedSessionKey)
        else { return }

        let hadCompleteInMemorySnapshot = self.completeHistorySessionKeys.contains(key)
            && !self.messages.isEmpty
        // Connected opens can replace an oversized legacy blob with the 200-row live tail.
        // Offline, the cache is the only transcript available, so retain the old (slower)
        // decode instead of presenting a long saved conversation as empty.
        let cachedSnapshot = await self.cache.loadSnapshot(
            sessionKey: key,
            allowOversizedLegacyFile: self.client == nil)
        let cached = cachedSnapshot.messages
        guard !Task.isCancelled,
              Self.shouldApplySessionOpen(
                  token,
                  generation: self.sessionOpenGeneration,
                  selectedKey: self.selectedSessionKey)
        else { return }
        if !cached.isEmpty {
            self.messages = Self.reconciledHistory(
                cached,
                current: self.messages,
                pendingEchoes: &self.pendingEchoes)
        }
        if !hadCompleteInMemorySnapshot {
            if cachedSnapshot.isComplete {
                self.completeHistorySessionKeys.insert(key)
            } else {
                self.completeHistorySessionKeys.remove(key)
            }
        }
        guard self.client != nil else {
            // No transport yet, so history was never requested. Reporting `.idle`
            // rendered an empty transcript as a settled, genuinely-empty
            // conversation: no spinner, no banner, no retry. Keep `.loading`
            // while there is nothing to show, and record the pending load so the
            // post-connect refresh picks this session up.
            self.sessionsNeedingHistoryRefresh.insert(key)
            self.historySyncState = self.messages.isEmpty ? .loading : .idle
            return
        }
        await self.subscribeToOpenSession(key: key)
        guard !Task.isCancelled,
              Self.shouldApplySessionOpen(
                  token,
                  generation: self.sessionOpenGeneration,
                  selectedKey: self.selectedSessionKey)
        else { return }
        await self.reloadHistory()
    }

    private func resubscribeAndReloadOpenSession() async {
        guard self.client != nil, let key = self.selectedSessionKey else { return }
        let performanceInterval = CastPerformanceDiagnostics.begin(
            .resubscribeAndReloadOpenSession,
            metadata: "key=\(key)")
        defer { CastPerformanceDiagnostics.end(performanceInterval) }
        await self.subscribeToOpenSession(key: key)
        self.cancelScheduledHistoryRetry(resetAttempt: true)
        await self.reloadHistory()
    }

    /// `sessions.messages.subscribe` is the only thing that routes `session.message` events
    /// for a session. Its result used to be discarded with `try?`, so a subscribe lost to a
    /// reconnect race or a transient gateway error left the open transcript live-dead: no
    /// retry, no banner, and no symptom until the reader backed out and reselected the
    /// session. Retry with backoff and remember what the gateway actually acknowledged.
    @discardableResult
    private func subscribeToOpenSession(key: String, attempts: Int = 3) async -> Bool {
        guard let client = self.client else { return false }
        for attempt in 1...max(1, attempts) {
            do {
                _ = try await client.request(
                    method: "sessions.messages.subscribe",
                    params: ["key": key])
                self.subscribedSessionKeys.insert(key)
                return true
            } catch {
                self.subscribedSessionKeys.remove(key)
                guard attempt < attempts,
                      SessionKeyMatcher.matches(self.selectedSessionKey, key)
                else { return false }
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                guard !Task.isCancelled, self.client === client else { return false }
            }
        }
        return false
    }

    private func startTranscriptWatchdog() {
        guard self.transcriptWatchdogTask == nil else { return }
        self.transcriptWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.transcriptWatchdogIntervalMs * 1_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.reconcileOpenTranscript()
            }
        }
    }

    /// Safety net for the live tail. Everything a reader sees in an open transcript arrives
    /// as a `session.message` or `chat` event, and those can go missing: the gateway sheds
    /// events for slow consumers, iOS suspends socket delivery without always reporting a
    /// disconnect, and a failed subscribe leaves the session unrouted. Nothing else re-drove
    /// the open session, which is why backing out to the list and reopening was the only
    /// reliable refresh. `sessions.list` already carries `updatedAt`, so poll that cheap call
    /// and pull history only when the session moved past what is on screen.
    func reconcileOpenTranscript() async {
        guard self.client != nil,
              case .connected = self.connectionState,
              let key = self.selectedSessionKey
        else { return }
        let performanceInterval = CastPerformanceDiagnostics.begin(
            .reconcileOpenTranscript,
            metadata: "key=\(key) messages=\(self.messages.count)")
        defer { CastPerformanceDiagnostics.end(performanceInterval) }
        if !self.subscribedSessionKeys.contains(key) {
            await self.subscribeToOpenSession(key: key, attempts: 1)
        }
        // A pending run whose terminal event died with a suspended socket pins
        // `isAgentTurnActive`, and everything below is gated on the turn being inactive —
        // the wedge would disable the only self-heal path this session has.
        if self.turnActivity.expirePendingRuns(
            before: Date().timeIntervalSince1970 * 1000 - Self.pendingRunMaxAgeMs)
        {
            self.updateAgentTurnActivity()
        }
        await self.refreshSessions()
        guard SessionKeyMatcher.matches(self.selectedSessionKey, key) else { return }
        let row = self.sessions.first(where: { SessionKeyMatcher.matches($0.key, key) })
        // The sidebar preview is the gateway's own statement of the newest message. When it
        // names a message the open transcript does not hold, the transcript is behind
        // regardless of run state: a run whose events died with a suspended socket, or a
        // long-lived run that keeps `hasActiveRun` pinned, is exactly what the timestamp
        // gate below cannot see — and exactly why the chat list could show a reply that
        // the message window never received.
        let missingPreview = self.previewReconciler.transcriptIsMissingPreview(
            row?.lastMessagePreview,
            recentTexts: self.messages.suffix(Self.previewMatchDepth).map(\.text))
        guard missingPreview || Self.transcriptIsBehind(
            sessionUpdatedAt: row?.updatedAt,
            newestMessageTimestamp: self.messages.last?.timestamp,
            isAgentTurnActive: self.isAgentTurnActive)
        else { return }
        self.cancelScheduledHistoryRetry(resetAttempt: true)
        await self.reloadHistory()
    }

    /// True when the gateway reports activity newer than the last message Cast holds.
    /// The tolerance absorbs the ordinary skew between a message's own timestamp and the
    /// session row the gateway stamps just after it, so a settled transcript does not
    /// re-request history on every poll.
    nonisolated static func transcriptIsBehind(
        sessionUpdatedAt: Double?,
        newestMessageTimestamp: Double?,
        isAgentTurnActive: Bool,
        toleranceMs: Double = 2_000) -> Bool
    {
        // A live run already streams into the transcript and reloads history when it
        // finishes; polling over the top of it would fight the stream.
        guard !isAgentTurnActive, let sessionUpdatedAt else { return false }
        guard let newestMessageTimestamp else { return true }
        return sessionUpdatedAt > newestMessageTimestamp + toleranceMs
    }

    public func reloadHistory() async {
        guard let client = self.client, let key = self.selectedSessionKey else { return }
        // One request and one delayed retry at most for the selected session.
        // Event bursts (final + session.message + seq-gap + reconnect) collapse
        // into the work already in flight.
        guard self.historyRetryTask == nil else { return }
        guard self.historyRefreshCoordinator.begin(key: key) else { return }
        let performanceInterval = CastPerformanceDiagnostics.begin(
            .reloadHistory,
            metadata: "key=\(key) existing_messages=\(self.messages.count)")
        self.historySyncState = .loading
        defer {
            CastPerformanceDiagnostics.end(
                performanceInterval,
                metadata: "messages=\(self.messages.count) state=\(String(describing: self.historySyncState))")
            let shouldRepeat = self.historyRefreshCoordinator.finish(key: key)
            if shouldRepeat, SessionKeyMatcher.matches(self.selectedSessionKey, key) {
                self.cancelScheduledHistoryRetry(resetAttempt: true)
                Task { await self.reloadHistory() }
            }
        }
        do {
            let firstPage: DecodedHistoryPage
            do {
                firstPage = try await self.requestHistoryPage(client: client, key: key, offset: 0)
            } catch let error as GatewayRequestError where error.code?.uppercased() == "INVALID_REQUEST" {
                // Gateways predating offset pagination reject the extra property. Ask those
                // versions for their largest supported tail, while retaining any fuller cache.
                firstPage = try await self.requestHistoryPage(client: client, key: key, offset: nil)
            }
            guard self.selectedSessionKey == key else { return }
            self.applyHistoryPage(firstPage, key: key, position: .latest)
            if firstPage.payload.hasMore != true {
                self.completeHistorySessionKeys.insert(key)
            }
            self.historyRetryAttempt = 0
            self.historySyncState = .idle
            self.lastHistoryRefresh[key] = Date()
            self.trimSessionDiagnostics()
            let firstPageSnapshot = self.messages
            let firstPageIsComplete = self.completeHistorySessionKeys.contains(key)
            Task(priority: .utility) {
                await self.cache.save(
                    firstPageSnapshot,
                    sessionKey: key,
                    historyIsComplete: firstPageIsComplete)
            }

            // The session-open signpost ends after this first 200-row page. Deep history is
            // still hydrated so Show Earlier retains its existing in-memory behavior, but it
            // is no longer a precondition for reading, scrolling, or typing in the live tail.
            if !firstPageIsComplete,
               firstPage.payload.hasMore == true,
               let nextOffset = firstPage.payload.nextOffset,
               nextOffset > 0
            {
                self.scheduleHistoryBackfill(
                    client: client,
                    key: key,
                    nextOffset: nextOffset)
            }
        } catch {
            guard self.selectedSessionKey == key else { return }
            // Never clear cached/current messages on a failed refresh. History
            // synchronization is recoverable background work, not a modal user
            // action failure.
            let recoverable = GatewayFailurePolicy.isRecoverable(error)
            let willRetry = recoverable && self.scheduleHistoryRetry(for: key)
            self.historySyncState = .stale(
                message: "Couldn’t refresh this conversation. Showing saved messages.",
                retryScheduled: willRetry)
        }
    }

    private func scheduleHistoryBackfill(
        client: GatewayClient,
        key: String,
        nextOffset: Int)
    {
        guard self.historyBackfillTask == nil else { return }
        self.historyBackfillGeneration &+= 1
        let generation = self.historyBackfillGeneration
        self.historyBackfillTask = Task(priority: .utility) { [weak self] in
            await self?.runHistoryBackfill(
                client: client,
                key: key,
                nextOffset: nextOffset,
                generation: generation)
        }
    }

    private func runHistoryBackfill(
        client: GatewayClient,
        key: String,
        nextOffset initialOffset: Int,
        generation: Int) async
    {
        let performanceInterval = CastPerformanceDiagnostics.begin(
            .historyBackfill,
            metadata: "key=\(key) initial_offset=\(initialOffset)")
        var accumulator = HistoryBackfillAccumulator(current: self.messages)
        var nextOffset: Int? = initialOffset
        var seenOffsets = Set<Int>()
        var addedMessageCount = 0
        defer {
            CastPerformanceDiagnostics.end(
                performanceInterval,
                metadata: "pages=\(seenOffsets.count) added_messages=\(addedMessageCount)")
        }
        do {
            while let offset = nextOffset {
                guard seenOffsets.insert(offset).inserted else {
                    throw HistoryBackfillError.invalidNextOffset
                }
                try Task.checkCancellation()
                let page = try await self.requestHistoryPage(
                    client: client,
                    key: key,
                    offset: offset,
                    priority: .utility)
                guard !Task.isCancelled,
                      self.historyBackfillGeneration == generation,
                      SessionKeyMatcher.matches(self.selectedSessionKey, key)
                else { return }
                addedMessageCount += accumulator.ingest(page.messages)
                if page.payload.hasMore != true {
                    nextOffset = nil
                    break
                }
                guard let candidate = page.payload.nextOffset, candidate > offset else {
                    throw HistoryBackfillError.invalidNextOffset
                }
                nextOffset = candidate
            }

            guard !Task.isCancelled,
                  self.historyBackfillGeneration == generation,
                  SessionKeyMatcher.matches(self.selectedSessionKey, key)
            else { return }
            let olderMessages = await self.cache.rehydrateLocalMedia(
                in: accumulator.olderMessagesInChronologicalOrder,
                sessionKey: key)
            guard !Task.isCancelled,
                  self.historyBackfillGeneration == generation,
                  SessionKeyMatcher.matches(self.selectedSessionKey, key)
            else { return }
            if !olderMessages.isEmpty {
                while true {
                    let revision = self.transcriptRevision
                    let currentMessages = self.messages
                    let completedMessages = await Task.detached(priority: .utility) {
                        // Pending echoes belong to the live tail and cannot legitimately
                        // match an older page. Keeping them out of this worker also prevents
                        // a months-old user row with the same text from consuming today's send.
                        var noPendingEchoes: [PendingEcho] = []
                        return Self.reconciledHistory(
                            olderMessages,
                            current: currentMessages,
                            pendingEchoes: &noPendingEchoes,
                            position: .older)
                    }.value
                    guard !Task.isCancelled,
                          self.historyBackfillGeneration == generation,
                          SessionKeyMatcher.matches(self.selectedSessionKey, key)
                    else { return }
                    // A live event may append while the utility worker is sorting 10k rows.
                    // Retry against that new tail instead of publishing a stale snapshot that
                    // would make the just-arrived message disappear.
                    guard self.transcriptRevision == revision else { continue }
                    self.messages = completedMessages
                    break
                }
            }
            self.completeHistorySessionKeys.insert(key)
            self.historyBackfillTask = nil
            let completedSnapshot = self.messages
            await self.cache.save(
                completedSnapshot,
                sessionKey: key,
                historyIsComplete: true)
        } catch is CancellationError {
            if self.historyBackfillGeneration == generation { self.historyBackfillTask = nil }
        } catch {
            guard self.historyBackfillGeneration == generation,
                  SessionKeyMatcher.matches(self.selectedSessionKey, key)
            else { return }
            self.historyBackfillTask = nil
            let willRetry = GatewayFailurePolicy.isRecoverable(error)
                && self.scheduleHistoryRetry(for: key)
            self.historySyncState = .stale(
                message: "Couldn’t load older messages. Showing the recent conversation.",
                retryScheduled: willRetry)
        }
    }

    private func requestHistoryPage(
        client: GatewayClient,
        key: String,
        offset: Int?,
        priority: TaskPriority = .userInitiated) async throws -> DecodedHistoryPage
    {
        var params: [String: Any?] = [
            "sessionKey": key,
            "limit": offset == nil ? 1_000 : 200,
        ]
        if let offset { params["offset"] = offset }
        let data = try await client.request(
            method: "chat.history",
            params: params,
            timeoutMs: 30_000)
        return try await Task.detached(priority: priority) {
            try Self.decodeHistoryPage(data)
        }.value
    }

    private func acknowledgeOutbox(_ page: [ChatMessage], sessionKey: String) {
        let requests = Set(page.filter { $0.isUser }.compactMap(\.gatewayRequestID))
        guard !requests.isEmpty else { return }
        Task { await self.sendOutbox.acknowledge(requests, sessionKey: sessionKey) }
    }

    private func applyHistoryPage(
        _ page: DecodedHistoryPage,
        key: String,
        position: HistoryPagePosition)
    {
        guard self.selectedSessionKey == key else { return }
        let payload = page.payload
        self.acknowledgeOutbox(page.messages, sessionKey: key)
        self.messages = Self.reconciledHistory(
            page.messages,
            current: self.messages,
            pendingEchoes: &self.pendingEchoes,
            position: position)
        if position == .latest {
            let runIds = payload.sessionInfo?.activeRunIds ?? []
            self.turnActivity.applyHistory(
                hasActiveRun: payload.sessionInfo?.hasActiveRun,
                runIds: runIds,
                newestMessageTimestampMs: self.messages.last?.timestamp)
            if let inFlightRun = payload.inFlightRun {
                self.turnActivity.observe(runId: inFlightRun.runId)
                if self.streamingText.isEmpty { self.streamingText = inFlightRun.text ?? "" }
            }
            self.updateAgentTurnActivity()
            if !self.isAgentTurnActive,
               Self.transcriptContains(streamingText: self.streamingText, in: self.messages)
            {
                self.streamingText = ""
            }
        }
    }

    /// Checks only the bounded page. The old form rescanned the full accumulated transcript
    /// after every reconcile, turning a 53-page open into another growing O(total) pass.
    nonisolated static func transcriptGainedRows(knownIDs: Set<String>, in messages: [ChatMessage]) -> Bool {
        messages.contains { !knownIDs.contains($0.id) }
    }

    public func retryHistoryNow() {
        self.cancelScheduledHistoryRetry(resetAttempt: true)
        Task { await self.reloadHistory() }
    }

    private func scheduleHistoryRetry(for key: String) -> Bool {
        guard self.historyRetryTask == nil else { return true }
        let attempt = self.historyRetryAttempt + 1
        guard attempt <= GatewayFailurePolicy.maximumAutomaticHistoryRetries,
              let delay = GatewayFailurePolicy.historyRetryDelayNanoseconds(attempt: attempt)
        else { return false }
        self.historyRetryAttempt = attempt
        self.historyRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, self.selectedSessionKey == key else { return }
            self.historyRetryTask = nil
            await self.reloadHistory()
        }
        return true
    }

    private func cancelScheduledHistoryRetry(resetAttempt: Bool) {
        self.historyRetryTask?.cancel()
        self.historyRetryTask = nil
        if resetAttempt { self.historyRetryAttempt = 0 }
    }

    /// Opens a fresh isolated session (materializes on first send). Never touches live channels.
    public func openScratchSession() {
        self.selectedSessionKey = "agent:main:cast-dev"
    }

    // MARK: - Send

    @discardableResult
    public func send(
        _ text: String,
        attachments: [PreparedAttachment]? = nil,
        deliver: Bool? = nil,
        idempotencyKey providedIdempotencyKey: String? = nil,
        completion: ((Bool) -> Void)? = nil) -> Bool
    {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoing = attachments ?? self.pendingAttachments
        guard !trimmed.isEmpty || !outgoing.isEmpty, let client = self.client, let key = self.selectedSessionKey else { return false }
        do {
            try AttachmentProcessor.validateFrame(message: trimmed, attachments: outgoing)
        } catch {
            self.lastError = error.localizedDescription
            return false
        }
        let idempotencyKey = providedIdempotencyKey ?? UUID().uuidString
        // Images echo as real thumbnails; the text placeholder stays for non-image files only.
        let imageDatas = outgoing.filter { $0.type == "image" }.map(\.data)
        let filePlaceholders = outgoing.filter { $0.type != "image" }.map { "Attached \($0.fileName)" }
        let localText = trimmed.isEmpty ? filePlaceholders.joined(separator: "\n") : trimmed
        // Content-addressed rather than a random UUID: this row is cached immediately below,
        // and a later history reconcile has to recognise it as the same row it already
        // rendered instead of handing it a fresh identity (which resets the scroll offset).
        let localEcho = ChatMessage(
            role: "user",
            blocks: [ChatContentBlock(type: "text", text: localText, thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: Date().timeIntervalSince1970 * 1000,
            localImageData: imageDatas,
            localDeliveryState: .pending,
            localIdempotencyKey: idempotencyKey)
            .identifiedByContent()
        self.appendingToTranscript { self.messages.append(localEcho) }
        self.pendingEchoes.append(PendingEcho(id: localEcho.id, sentText: trimmed))
        self.turnActivity.beginLocal(
            runId: idempotencyKey,
            atMs: localEcho.timestamp ?? Date().timeIntervalSince1970 * 1000)
        self.updateAgentTurnActivity()
        self.pendingAttachments = []
        self.clearDraft(forSession: key)
        self.sendContexts[idempotencyKey] = PendingSendContext(
            text: trimmed,
            attachments: outgoing,
            deliver: deliver ?? self.deliverExternally)
        self.dispatchSend(
            client: client,
            sessionKey: key,
            echoID: localEcho.id,
            idempotencyKey: idempotencyKey,
            completion: completion)
        return true
    }

    /// Resends a failed bubble in place. The original idempotency key is reused so a first
    /// attempt that actually reached the gateway cannot post twice, and the existing row is
    /// flipped back to `.pending` instead of appending a second copy of the text.
    public func retrySend(messageID: String) {
        guard let client = self.client,
              let key = self.selectedSessionKey,
              let index = self.messages.firstIndex(where: { $0.id == messageID }),
              [.failed, .uncertain].contains(self.messages[index].localDeliveryState),
              let idempotencyKey = self.messages[index].localIdempotencyKey
        else { return }
        let message = self.messages[index]
        if self.sendContexts[idempotencyKey] == nil {
            Task {
                do {
                    let saved = try await self.sendOutbox.load(idempotencyKey, sessionKey: key)
                    guard SessionKeyMatcher.matches(self.selectedSessionKey, key) else { return }
                    self.sendContexts[idempotencyKey] = saved.context
                    self.retrySend(messageID: messageID)
                } catch {
                    self.lastError = "The original send payload is no longer available. Check the conversation before composing again; Cast will not retry with missing attachments or changed delivery settings."
                }
            }
            return
        }
        guard let context = self.sendContexts[idempotencyKey] else { return }
        self.messages[index].localDeliveryState = .pending
        // Re-arm the echo bookkeeping so the gateway's session.message echo merges into
        // this same bubble rather than rendering beside it.
        self.pendingEchoes.append(PendingEcho(id: message.id, sentText: context.text))
        self.turnActivity.beginLocal(
            runId: idempotencyKey,
            atMs: Date().timeIntervalSince1970 * 1000)
        self.updateAgentTurnActivity()
        self.dispatchSend(
            client: client,
            sessionKey: key,
            echoID: message.id,
            idempotencyKey: idempotencyKey)
    }

    /// The network half of a send, shared by first attempts and retries. On failure the
    /// bubble is kept and marked `.failed` — deleting it would destroy the user's words,
    /// and the send context is retained so retry can reuse the identical payload and key.
    private func dispatchSend(
        client: GatewayClient,
        sessionKey: String,
        echoID: String,
        idempotencyKey: String,
        completion: ((Bool) -> Void)? = nil)
    {
        guard let context = self.sendContexts[idempotencyKey] else { return }
        let optimisticMessages = self.messages
        let optimisticHistoryIsComplete = self.completeHistorySessionKeys.contains(sessionKey)
        Task {
            // Persist the image + caption bubble before the network request so an app
            // background/termination or a slow gateway cannot make the sent message vanish.
            await self.cache.save(
                optimisticMessages,
                sessionKey: sessionKey,
                historyIsComplete: optimisticHistoryIsComplete)
            var persisted = false
            do {
                try await self.sendOutbox.save(StoredSend(sessionKey: sessionKey, idempotencyKey: idempotencyKey,
                    context: context, createdAt: Date()))
                persisted = true
                let data = try await client.sendChat(
                    sessionKey: sessionKey,
                    message: context.text,
                    idempotencyKey: idempotencyKey,
                    deliver: context.deliver,
                    attachments: context.attachments)
                self.pendingModelChanges.removeValue(forKey: sessionKey)
                if let response = try? self.decoder.decode(ChatSendResponse.self, from: data),
                   let runId = response.runId,
                   runId != idempotencyKey, SessionKeyMatcher.matches(self.selectedSessionKey, sessionKey)
                {
                    self.turnActivity.acknowledge(localRunId: idempotencyKey, gatewayRunId: runId)
                    self.updateAgentTurnActivity()
                }
                self.sendContexts[idempotencyKey] = nil
                await self.sendOutbox.remove(idempotencyKey)
                self.setLocalDeliveryState(.delivered, messageID: echoID, sessionKey: sessionKey)
                completion?(true)
            } catch {
                self.turnActivity.finish(runId: idempotencyKey)
                self.pendingEchoes.removeAll { $0.id == echoID }
                self.updateAgentTurnActivity()
                let state: LocalDeliveryState = persisted && (error as? SendAttemptError) == .uncertain ? .uncertain : .failed
                self.setLocalDeliveryState(state, messageID: echoID, sessionKey: sessionKey)
                self.lastError = state == .uncertain
                    ? "Delivery is unconfirmed. Cast will refresh the conversation when it reconnects. It will not automatically resend."
                    : (persisted ? GatewayFailurePolicy.messageSendAlert : "Couldn’t safely save this send on your device. This attempt was not submitted. Free some disk space and retry.")
                completion?(false)
            }
        }
    }

    /// Flips one local row's delivery state and re-persists that session's transcript, so
    /// a failed send survives relaunch as failed instead of silently reading as sent. The
    /// row may live in the open transcript or in a background session's snapshot when the
    /// user switched away mid-flight.
    private func setLocalDeliveryState(
        _ state: LocalDeliveryState,
        messageID: String,
        sessionKey: String)
    {
        if SessionKeyMatcher.matches(self.selectedSessionKey, sessionKey),
           let index = self.messages.firstIndex(where: { $0.id == messageID })
        {
            guard self.messages[index].localDeliveryState != state else { return }
            self.messages[index].localDeliveryState = state
            let snapshot = self.messages
            let historyIsComplete = self.completeHistorySessionKeys.contains(sessionKey)
            Task {
                await self.cache.save(
                    snapshot,
                    sessionKey: sessionKey,
                    historyIsComplete: historyIsComplete)
            }
            return
        }
        if var stored = self.transcriptSnapshots.snapshot(for: sessionKey),
           let index = stored.firstIndex(where: { $0.id == messageID }),
           stored[index].localDeliveryState != state
        {
            stored[index].localDeliveryState = state
            self.transcriptSnapshots.store(stored, for: sessionKey)
        }
        // Persist off the disk copy, not the snapshot: snapshots are image-stripped, and
        // saving one would garbage-collect the media side files the cache still holds.
        Task {
            let cacheSnapshot = await self.cache.loadSnapshot(sessionKey: sessionKey)
            var cached = cacheSnapshot.messages
            guard let index = cached.firstIndex(where: { $0.id == messageID }),
                  cached[index].localDeliveryState != state
            else { return }
            cached[index].localDeliveryState = state
            await self.cache.save(
                cached,
                sessionKey: sessionKey,
                historyIsComplete: cacheSnapshot.isComplete)
        }
    }

    public func addAttachment(url: URL) {
        Task.detached {
            do {
                let attachment = try AttachmentProcessor.prepare(url: url)
                await MainActor.run { self.pendingAttachments.append(attachment) }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    /// Raw image bytes (pasteboard, drag-and-drop) through the same downsampling pipeline.
    public func addAttachment(imageData: Data, fileName: String) {
        Task.detached {
            do {
                let attachment = try AttachmentProcessor.prepareImage(data: imageData, fileName: fileName)
                await MainActor.run { self.pendingAttachments.append(attachment) }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    public func addAttachments(_ attachments: [PreparedAttachment]) {
        self.pendingAttachments.append(contentsOf: attachments)
    }

    // MARK: - Drafts

    public func draft(forSession sessionKey: String) -> String {
        self.draftLedger.draft(forSession: sessionKey) ?? ""
    }

    /// Persists the composer text for a session so it survives switching sessions,
    /// backgrounding, and relaunch. Whitespace-only text clears the stored draft.
    public func setDraft(_ text: String, forSession sessionKey: String) {
        guard self.draftLedger.setDraft(text, forSession: sessionKey) else { return }
        self.persistDrafts()
    }

    public func clearDraft(forSession sessionKey: String) {
        guard self.draftLedger.clearDraft(forSession: sessionKey) else { return }
        self.persistDrafts()
    }

    private func persistDrafts() {
        let drafts = self.draftLedger
        Task { await self.operationsPersistence.save(drafts: drafts) }
    }

    public func removeAttachment(id: UUID) {
        self.pendingAttachments.removeAll { $0.id == id }
    }

    public func clearError() {
        self.lastError = nil
        self.contextCompactionOfferKey = nil
    }

    public func showError(_ message: String) { self.lastError = message }

    /// Manual compaction for a session whose run overflowed the context window. This runs
    /// a real agent turn server-side, so the generous timeout is deliberate, and history is
    /// reloaded afterwards because compaction rewrites the transcript Cast holds.
    public func compactSession(_ key: String) {
        guard let client = self.client, case .connected = self.connectionState,
              self.gatewayMethods.contains("sessions.compact"),
              self.compactingSessionKeys[key] == nil,
              self.sessionCompactions[key]?.phase != .running
        else { return }
        let requestID = UUID()
        self.compactingSessionKeys[key] = requestID
        self.sessionCompactions[key] = SessionCompactionStatus(
            operationID: requestID.uuidString, phase: .running, observedAt: Date())
        self.trimSessionDiagnostics()
        let generation = self.clientGeneration
        self.contextCompactionOfferKey = nil
        Task {
            defer {
                if self.compactingSessionKeys[key] == requestID { self.compactingSessionKeys.removeValue(forKey: key) }
            }
            do {
                let result = try await client.request(
                    method: "sessions.compact",
                    params: ["key": key],
                    timeoutMs: 120_000)
                guard generation == self.clientGeneration else { return }
                // A successful RPC can explicitly report a skipped/no-op compaction.
                let decoded = try? self.decoder.decode(AnyCodable.self, from: result)
                let completed = decoded?["compacted"]?.boolValue
                self.sessionCompactions[key] = SessionCompactionStatus(
                    operationID: self.sessionCompactions[key]?.operationID ?? UUID().uuidString,
                    phase: completed == true ? .completed : completed == false ? .notCompleted : .interrupted, observedAt: Date())
                self.trimSessionDiagnostics()
                if SessionKeyMatcher.matches(self.selectedSessionKey, key) {
                    self.cancelScheduledHistoryRetry(resetAttempt: true)
                    await self.reloadHistory()
                }
                await self.refreshSessions()
            } catch {
                guard generation == self.clientGeneration else { return }
                self.sessionCompactions[key] = SessionCompactionStatus(
                    operationID: self.sessionCompactions[key]?.operationID ?? UUID().uuidString,
                    phase: .interrupted, observedAt: Date())
                // A timeout is not proof the gateway stopped compacting. Never offer an
                // automatic repeat, and never leak raw provider errors into the modal.
                if SessionKeyMatcher.matches(self.selectedSessionKey, key) {
                    self.lastError = "Cast could not confirm compaction finished. Refresh the conversation and check OpenClaw before trying again. Your message has not been resent."
                }
            }
        }
    }

    private func trimSessionDiagnostics() {
        if self.sessionFailures.count > 100 {
            self.sessionFailures = Dictionary(uniqueKeysWithValues: self.sessionFailures.sorted { $0.value.observedAt > $1.value.observedAt }.prefix(100).map { ($0.key, $0.value) })
        }
        if self.sessionCompactions.count > 100 {
            self.sessionCompactions = Dictionary(uniqueKeysWithValues: self.sessionCompactions.sorted { $0.value.observedAt > $1.value.observedAt }.prefix(100).map { ($0.key, $0.value) })
        }
        if self.lastHistoryRefresh.count > 100 {
            self.lastHistoryRefresh = Dictionary(uniqueKeysWithValues: self.lastHistoryRefresh.sorted { $0.value > $1.value }.prefix(100).map { ($0.key, $0.value) })
        }
    }

    private func interruptObservedCompactions() {
        for (key, value) in self.sessionCompactions where value.phase == .running {
            self.sessionCompactions[key] = SessionCompactionStatus(
                operationID: value.operationID, phase: .interrupted, observedAt: Date(), gatewayTimestamp: value.gatewayTimestamp)
        }
    }

    private func handleSessionOperation(_ event: EventFrame) {
        guard let payload = event.payload,
              payload["operation"]?.stringValue == "compact",
              let key = payload["sessionKey"]?.stringValue, !key.isEmpty,
              let operationID = payload["operationId"]?.stringValue, !operationID.isEmpty
        else { return }
        let prior = self.sessionCompactions[key]
        let timestamp = payload["ts"]?.doubleValue.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if let timestamp, let previous = prior?.gatewayTimestamp, timestamp < previous { return }
        let phase: SessionCompactionStatus.Phase
        switch payload["phase"]?.stringValue {
        case "start":
            // Duplicate/late starts cannot reopen an operation already observed ending.
            if prior?.operationID == operationID { return }
            phase = .running
        case "end":
            // An old terminal must not finish a newer operation on this conversation.
            if let prior, prior.operationID != operationID {
                guard let timestamp, let previous = prior.gatewayTimestamp, timestamp > previous else { return }
            }
            phase = payload["completed"]?.boolValue == true ? .completed : .notCompleted
        default: return
        }
        self.sessionCompactions[key] = SessionCompactionStatus(operationID: operationID, phase: phase, observedAt: Date(), gatewayTimestamp: timestamp)
        self.trimSessionDiagnostics()
        if phase == .completed {
            self.scheduleSessionsRefresh(changedSessionKey: key)
        }
    }

    /// Stop button. Aborting without a runId cancels whatever is active for the session,
    /// which also settles the tap-versus-natural-finish race: if the run completed on its
    /// own in flight, the gateway reports "nothing aborted" as success and the terminal
    /// events that already arrived have cleared the local turn state.
    public func abortActiveRun() {
        guard let client = self.client,
              let key = self.selectedSessionKey,
              self.isAgentTurnActive,
              !self.isAbortingRun
        else { return }
        self.isAbortingRun = true
        Task {
            defer { self.isAbortingRun = false }
            do {
                _ = try await client.request(method: "chat.abort", params: ["sessionKey": key])
            } catch {
                // Only alert while the run is demonstrably still going; an error for a run
                // that finished by itself would be noise over a visible answer.
                guard self.isAgentTurnActive, SessionKeyMatcher.matches(self.selectedSessionKey, key)
                else { return }
                self.lastError = "Couldn’t stop the run: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Results and attention

    private func scheduleDeliverableIndex() {
        self.deliverableIndexTask?.cancel()
        self.deliverableIndexGeneration += 1
        guard let key = self.selectedSessionKey else { return }
        let generation = self.deliverableIndexGeneration
        self.deliverableIndexTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard let self, self.selectedSessionKey == key else { return }
            let messages = self.messages
            let ledger = self.deliverableLedger
            let updated = await Task.detached(priority: .utility) {
                var ledger = ledger
                ledger.ingest(messages: messages, sessionKey: key)
                return ledger
            }.value
            guard !Task.isCancelled, generation == self.deliverableIndexGeneration,
                  updated != self.deliverableLedger else { return }
            do {
                try self.deliverableStore.save(updated)
                self.deliverableLedger = updated
            } catch { self.showError("Couldn’t save the deliverables index. Your conversation is unchanged.") }
        }
    }

    public var attentionItems: [AttentionItem] {
        self.attentionItems(at: Date())
    }

    public func attentionItems(at date: Date) -> [AttentionItem] {
        let questions = questionInbox.sorted.filter { $0.request.isPending(at: date) }.map { entry in
            AttentionItem(id: "question:" + entry.id, kind: .question, sessionKey: entry.request.sessionKey,
                title: "Question waiting", detail: entry.request.questions.first?.question ?? "Answer requested", referenceID: entry.id)
        }
        return questions + AttentionReducer.items(sessions: self.sessions, approvals: self.approvals,
            notifications: self.notificationRecords, deliverables: self.deliverableLedger.items,
            reviewed: self.reviewedWork.ids, hidden: self.sidebarPreferences.hiddenKeys,
            acknowledgedFailures: Set(self.sessions.filter { self.isFailureAcknowledged($0) }.map(\.key)), now: date)
    }

    public func markDeliverableReviewed(_ id: String) {
        var ledger = self.reviewedWork
        ledger.ids.insert(id)
        do { try self.reviewedWorkStore.save(ledger); self.reviewedWork = ledger }
        catch { self.showError("Couldn’t save review status. Please try again.") }
    }

    public func localDeliverableURL(_ item: Deliverable) async -> URL? {
        let generation = clientGeneration
        let gatewayURL = profile.gatewayURL
        let fileCache = deliverableFiles.scoped(to: gatewayURL)
        let result = await Task.detached(priority: .utility) { () -> URL? in
            if let cached = fileCache.existing(item) { return cached }
            // A remote path matching a local filename does not prove they are the same file.
            guard ["localhost", "127.0.0.1", "::1"].contains(gatewayURL.host ?? ""),
                  item.target.hasPrefix("/") || item.target.hasPrefix("file://") else { return nil }
            let url = MediaThumbnailLoader.resolvedFileURL(for: item.target)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize,
                  (try? ArtifactTransferPolicy.validateSize(size, expected: item.sizeBytes)) != nil,
                  FileManager.default.isReadableFile(atPath: url.path) else { return nil }
            return url
        }.value
        guard !Task.isCancelled, generation == clientGeneration else { return nil }
        return result
    }

    public func refreshArtifacts(sessionKey: String) async throws {
        guard gatewayMethods.contains("artifacts.list"), let client, case .connected = connectionState else { return }
        let generation = clientGeneration
        let data = try await client.request(method: "artifacts.list", params: ["sessionKey": sessionKey])
        try assertTransferCurrent(generation)
        struct Response: Decodable { let artifacts: [GatewayArtifact] }
        let artifacts = try decoder.decode(Response.self, from: data).artifacts
        var ledger = deliverableLedger
        ledger.ingest(artifacts: artifacts, sessionKey: sessionKey)
        try deliverableStore.save(ledger)
        deliverableLedger = ledger
    }

    public func fetchDeliverable(_ item: Deliverable,
        progress: @escaping @Sendable (Int, Int?) async -> Void = { _, _ in }) async throws -> URL {
        try Task.checkCancellation()
        let generation = clientGeneration
        let gatewayURL = profile.gatewayURL
        let existing = await localDeliverableURL(item)
        try assertTransferCurrent(generation)
        if let existing { return existing }
        guard let client, case .connected = connectionState else { throw ModelControlError.disconnected }
        let bytes: Data
        if let id = item.artifactID {
            guard gatewayMethods.contains("artifacts.download") else { throw ArtifactTransferError.unavailable }
            let data = try await client.request(method: "artifacts.download", params: ["sessionKey": item.sessionKey, "artifactId": id], timeoutMs: 60000)
            try assertTransferCurrent(generation)
            let response = try decoder.decode(AnyCodable.self, from: data)
            guard response["artifact"]?["id"]?.stringValue == id else { throw ArtifactTransferError.invalid }
            if let key = response["artifact"]?["sessionKey"]?.stringValue,
               !SessionKeyMatcher.matches(key, item.sessionKey) { throw ArtifactTransferError.invalid }
            let expectedSize = try ArtifactTransferPolicy.downloadSize(response, listedSize: item.sizeBytes)
            if response["data"]?.stringValue != nil {
                bytes = try ArtifactTransferPolicy.bytes(response, expectedSize: expectedSize)
            } else if let raw = response["url"]?.stringValue {
                bytes = try await ArtifactDownloader.download(
                    url: ArtifactTransferPolicy.url(raw, gateway: gatewayURL), expectedSize: expectedSize, progress: progress)
            } else { throw ArtifactTransferError.unavailable }
        } else {
            guard gatewayMethods.contains("sessions.files.get") else { throw ArtifactTransferError.unavailable }
            let path = item.target.hasPrefix("file://") ? URL(string: item.target)?.path ?? item.target : item.target
            let data = try await client.request(method: "sessions.files.get", params: ["sessionKey": item.sessionKey, "path": path])
            try assertTransferCurrent(generation)
            let response = try decoder.decode(AnyCodable.self, from: data)
            if let key = response["sessionKey"]?.stringValue,
               !SessionKeyMatcher.matches(key, item.sessionKey) { throw ArtifactTransferError.invalid }
            bytes = try ArtifactTransferPolicy.fileBytes(response)
        }
        try assertTransferCurrent(generation)
        let fileCache = self.deliverableFiles.scoped(to: gatewayURL)
        let url = try await Task.detached(priority: .utility) { try fileCache.save(bytes, for: item) }.value
        try assertTransferCurrent(generation)
        return url
    }

    private func assertTransferCurrent(_ generation: Int) throws {
        try Task.checkCancellation()
        guard generation == clientGeneration else { throw ArtifactTransferError.connectionChanged }
    }

    func cachedSearch(_ query: String) async -> [CachedSearchHit] {
        await cache.search(query, includingSessionKey: selectedSessionKey, currentMessages: messages)
    }
    public func loadProgressForDetails(_ key: String) async { await fetchProgressCard(for: key) }

    func continuityRequest(_ method: String, params: [String: Any?]) async throws -> Data {
        guard gatewayMethods.contains(method) else { throw TaskControlError.unsupported }
        guard let client, case .connected = connectionState else { throw ModelControlError.disconnected }
        return try await client.request(method: method, params: params)
    }

    // MARK: - Sidebar visibility (local, reversible)

    public func isSessionHidden(_ key: String) -> Bool { self.sidebarPreferences.isHidden(key) }
    public func isSessionPinned(_ key: String) -> Bool { self.sidebarPreferences.isPinned(key) }

    public var hiddenSessions: [SessionRow] {
        self.sessions.filter { self.isSessionHidden($0.key) }
    }

    public var visibleSearchHits: [CachedSearchHit] {
        self.searchHits.filter { self.showHiddenSessions || !self.isSessionHidden($0.sessionKey) }
    }

    public func setSessionHidden(_ hidden: Bool, sessionKey: String) {
        var preferences = self.sidebarPreferences
        preferences.setHidden(hidden, key: sessionKey)
        guard self.saveSidebarPreferences(preferences) else { return }
        if hidden {
            self.lastHiddenSessionKey = sessionKey
            if SessionKeyMatcher.matches(self.selectedSessionKey, sessionKey) {
                self.selectedSessionKey = self.sidebarSections.flatMap(\.sessions).first?.key
            }
        } else if SessionKeyMatcher.matches(self.lastHiddenSessionKey, sessionKey) {
            self.lastHiddenSessionKey = nil
        }
    }

    public func toggleSessionPinned(_ key: String) {
        var preferences = self.sidebarPreferences
        preferences.setPinned(!preferences.isPinned(key), key: key)
        _ = self.saveSidebarPreferences(preferences)
    }

    public func undoHideSession() {
        guard let key = self.lastHiddenSessionKey else { return }
        self.setSessionHidden(false, sessionKey: key)
    }

    public func dismissHideUndo() { self.lastHiddenSessionKey = nil }

    private func saveSidebarPreferences(_ preferences: SidebarPreferences) -> Bool {
        // These tiny, user-initiated writes complete before publishing so a disk error
        // cannot silently lose the preference, and rapid hide/undo cannot reorder writes.
        do {
            try self.sidebarPreferencesStore.save(preferences)
            self.sidebarPreferences = preferences
            self.publishOperationsState()
            return true
        } catch {
            self.showError("Couldn’t save sidebar preferences. Please try again.")
            return false
        }
    }

    // MARK: - Mute

    public func isSessionMuted(_ sessionKey: String) -> Bool {
        self.muteLedger.isMuted(sessionKey: sessionKey)
    }

    /// Mutes suppress notification interruptions only; unread counts keep accruing so a
    /// muted session still shows the truth in the sidebar.
    public func setSessionMuted(_ muted: Bool, sessionKey: String) {
        guard self.muteLedger.setMuted(muted, sessionKey: sessionKey) else { return }
        self.mutedSessionKeys = self.muteLedger.mutedSessionKeys
        let mutes = self.muteLedger
        Task { await self.operationsPersistence.save(mutes: mutes) }
    }

    public func toggleSessionMuted(_ sessionKey: String) {
        self.setSessionMuted(!self.isSessionMuted(sessionKey), sessionKey: sessionKey)
    }

    public func retrySessionsNow() {
        // The notice covers both halves of a stale sidebar — a failed list refresh and a
        // spent subscribe ladder — so Retry has to re-drive both. A ladder that already
        // gave up is reset first; otherwise `.failed` would short-circuit nothing and a
        // still-running one would simply be joined.
        if self.sessionsSubscription == .failed { self.resetSessionsSubscription() }
        Task { await self.subscribeToSessions() }
        Task { await self.refreshSessions() }
    }

    public func rotateDeviceToken() {
        guard let client = self.client else { return }
        Task {
            do { try await client.rotateDeviceToken() }
            catch { self.lastError = "Token rotation: \(error.localizedDescription)" }
        }
    }

    public func resolveApproval(id: String, decision: String) {
        guard let client = self.client else { return }
        guard let approval = self.approvals.first(where: { $0.id == id }),
              !approval.isExpired, approval.allows(decision: decision) else {
            self.lastError = "That approval has expired, was resolved elsewhere, or does not allow this decision. Refresh Needs you."
            return
        }
        // The wire never carries the kind, so route by the tag stamped at receipt.
        let method = approval.kind == .plugin
            ? "plugin.approval.resolve"
            : "exec.approval.resolve"
        Task {
            do {
                _ = try await client.request(method: method, params: ["id": id, "decision": decision])
                self.approvals.removeAll { $0.id == id }
            } catch {
                self.lastError = "Approval: \(error.localizedDescription)"
            }
        }
    }

    public func refreshApprovals() async {
        guard let client = self.client else { return }
        // Replay both families; each list is `[{id, request, createdAtMs, expiresAtMs}]`.
        // Requiring one success preserves the old behavior of keeping the last known
        // prompts when the gateway cannot answer at all.
        var replayed: [ExecApproval] = []
        var anyListSucceeded = false
        for (method, kind) in [("exec.approval.list", ApprovalKind.exec), ("plugin.approval.list", .plugin)] {
            guard let data = try? await client.request(method: method, params: [:]) else { continue }
            anyListSucceeded = true
            let decoded = (try? self.decoder.decode([ExecApproval].self, from: data)) ?? []
            replayed.append(contentsOf: decoded.map { approval in
                var tagged = approval
                tagged.kind = kind
                return tagged
            })
        }
        guard anyListSucceeded else { return }
        self.approvals = Self.dedupedByID(replayed.filter { !$0.isExpired })
    }

    private func scheduleSearch() {
        self.searchTask?.cancel()
        self.searchGeneration += 1
        let generation = self.searchGeneration
        let query = self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            self.searchHits = []
            self.isSearching = false
            return
        }
        self.isSearching = true
        let selectedKey = self.selectedSessionKey
        let currentMessages = self.messages
        self.searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, !Task.isCancelled, generation == self.searchGeneration else { return }
            let results = await self.cache.search(
                query,
                includingSessionKey: selectedKey,
                currentMessages: currentMessages)
            guard !Task.isCancelled, generation == self.searchGeneration else { return }
            self.searchHits = results
            self.isSearching = false
        }
    }

    // MARK: - Events

    func handleEvent(_ event: EventFrame) {
        switch event.event {
        case "cast.hello":
            self.handleHello(event)
        case "chat":
            self.handleChatEvent(event)
        case "agent":
            self.handleAgentEvent(event)
        case "session.tool":
            self.handleAgentEvent(event)
        case "session.message":
            self.handleSessionMessage(event)
        case "sessions.changed":
            self.scheduleSessionsRefresh(changedSessionKey: event.payload?["sessionKey"]?.stringValue)
        case "question.requested":
            if let request = self.decodePayload(event, as: QuestionRequest.self) {
                self.questionInbox.receive(request)
                self.scheduleQuestionExpiry()
            }
            self.secretRevision += 1
            // The question-card opt-in also grants operator.questions, so secret-store
            // events can arrive without secure entry; never surface those.
            if self.secretEntryEnabled, let request = self.decodePayload(event, as: SecretRequest.self), request.isPendingSecret, !self.resolvedSecretIDs.contains(request.id) {
                self.secretRequests.removeAll { $0.id == request.id }
                self.secretRequests.append(request)
            }
        case "question.resolved":
            if let id = event.payload?["id"]?.stringValue, let status = event.payload?["status"]?.stringValue {
                self.questionInbox.resolve(id: id, status: status)
            }
            self.secretRevision += 1
            if let id = event.payload?["id"]?.stringValue {
                self.resolvedSecretIDs.insert(id)
                self.secretRequests.removeAll { $0.id == id }
            }
        case "exec.approval.requested":
            self.handleApprovalRequested(event, kind: .exec)
        case "plugin.approval.requested":
            self.handleApprovalRequested(event, kind: .plugin)
        case "exec.approval.resolved", "plugin.approval.resolved":
            // Same removal for both families: another operator surface decided, so the
            // card must leave every Cast screen regardless of which kind it was.
            if let id = event.payload?["id"]?.stringValue { self.approvals.removeAll { $0.id == id } }
        case "cron":
            self.handleCronEvent(event)
        case "task":
            // Tasks surface through session rows, so there is no in-place list to merge
            // into; the debounced refresh turns an upsert burst into one sessions.list.
            self.scheduleSessionsRefresh(
                changedSessionKey: event.payload?["task"]?["childSessionKey"]?.stringValue
                    ?? event.payload?["task"]?["sessionKey"]?.stringValue)
        case "shutdown":
            self.handleShutdown(event)
        case "update.available":
            self.updateNotice = Self.updateNoticeText(from: event.payload)
        case "presence":
            self.handlePresence(event)
        case "progressCard.changed":
            if let sessionKey = event.payload?["sessionKey"]?.stringValue {
                self.scheduleProgressCardFetch(for: sessionKey)
            }
        case "cast.seqGap":
            self.interruptObservedCompactions()
            Task { await self.reloadHistory() }
        case "session.operation":
            self.handleSessionOperation(event)
        default:
            // `talk.event` and `voicewake.changed` are deliberately unhandled: Cast has no
            // voice/talk surface, so there is nothing truthful to render for them yet.
            break
        }
    }

    private func decodePayload<T: Decodable>(_ event: EventFrame, as type: T.Type) -> T? {
        guard let payload = event.payload,
              let data = try? self.encoder.encode(payload)
        else { return nil }
        return try? self.decoder.decode(type, from: data)
    }

    private func handleChatEvent(_ event: EventFrame) {
        guard let payload = self.decodePayload(event, as: ChatEventPayload.self), let key = self.selectedSessionKey else { return }
        let ownsRun = payload.runId.map { self.turnActivity.contains($0) } ?? false
        guard SessionKeyMatcher.matches(payload.sessionKey, key) || ownsRun else { return }
        if let runId = payload.runId { self.turnActivity.observe(runId: runId) }
        switch payload.state {
        case "delta":
            self.updateAgentTurnActivity()
            if payload.replace == true {
                self.streamingText = payload.deltaText ?? ""
            } else if let delta = payload.deltaText {
                self.streamingText += delta
            }
        case "final", "aborted", "error":
            self.streamingReasoningText = ""
            self.activeToolName = nil
            self.activeWorkItems = []
            if let runId = payload.runId, payload.state == "final" {
                self.turnActivity.markAnswered(runId: runId)
            }
            let alreadyAnswered = payload.runId.map { self.turnActivity.hasAnswered($0) } ?? false
            if let runId = payload.runId { self.turnActivity.finish(runId: runId) }
            if payload.state != "final" { self.streamingText = "" }
            self.updateAgentTurnActivity()
            if let alert = GatewayFailurePolicy.agentRunAlertMessage(
                for: payload.state,
                errorKind: payload.errorKind,
                errorDetail: payload.errorDetail,
                runAlreadyAnswered: alreadyAnswered)
            {
                self.lastError = alert
                let category = RunFailureCategory.resolve(kind: payload.errorKind, detail: payload.errorDetail)
                self.sessionFailures[key] = SessionRunFailure(category: category, observedAt: Date())
                self.trimSessionDiagnostics()
                // context_length is the one failure kind Cast can fix in-app: pair the
                // alert with a one-tap sessions.compact for the session that overflowed.
                self.contextCompactionOfferKey = category == .contextLength && self.gatewayMethods.contains("sessions.compact")
                    ? (payload.sessionKey ?? key)
                    : nil
            }
            // History is the source of truth; streams are ephemeral (protocol-notes gotcha #4).
            Task { await self.reloadHistory() }
        default:
            break
        }
    }

    private func handleAgentEvent(_ event: EventFrame) {
        guard let payload = self.decodePayload(event, as: AgentEventPayload.self),
              let runId = payload.runId,
              let key = self.selectedSessionKey
        else { return }
        let ownsRun = self.turnActivity.contains(runId)
        guard ownsRun || SessionKeyMatcher.matches(payload.sessionKey, key) else { return }

        let phase = payload.data?["phase"]?.stringValue
        if payload.stream == "lifecycle" {
            if phase == "start" {
                self.turnActivity.observe(runId: runId)
            } else if phase == "end" || phase == "error" {
                self.turnActivity.finish(runId: runId)
                self.streamingReasoningText = ""
                self.activeToolName = nil
                self.activeWorkItems = []
                if phase == "error" { self.streamingText = "" }
            }
            self.updateAgentTurnActivity()
            return
        }

        self.turnActivity.observe(runId: runId)
        self.updateAgentTurnActivity()
        if payload.stream == "assistant" {
            self.streamingText = Self.mergedStreamText(current: self.streamingText, data: payload.data)
        } else if payload.stream == "thinking" {
            self.streamingReasoningText = Self.mergedStreamText(
                current: self.streamingReasoningText,
                data: payload.data)
        } else if payload.stream == "tool" {
            let name = payload.data?["name"]?.stringValue
            self.activeToolName = phase == "start" ? name : nil
        }
        self.activeWorkItems = AgentWorkProjector.reducing(
            self.activeWorkItems,
            runId: runId,
            stream: payload.stream,
            data: payload.data)
    }

    nonisolated static func mergedStreamText(current: String, data: AnyCodable?) -> String {
        if data?["replace"]?.boolValue == true, let text = data?["text"]?.stringValue {
            return text
        }
        if let text = data?["text"]?.stringValue { return text }
        if let delta = data?["delta"]?.stringValue { return current + delta }
        return current
    }

    private func updateAgentTurnActivity() {
        self.isAgentTurnActive = self.turnActivity.isActive
    }

    private func handleSessionMessage(_ event: EventFrame) {
        guard let payload = event.payload,
              let eventSessionKey = payload["sessionKey"]?.stringValue
        else { return }
        guard let messageValue = payload["message"],
              let data = try? self.encoder.encode(messageValue),
              let decoded = try? self.decoder.decode(ChatMessage.self, from: data)
        else { return }
        // The gateway does not label every event row. Falling back to a `UUID` gave this row
        // an identity the next history page could never reproduce, so each reconcile swapped
        // it out and SwiftUI rebuilt the transcript from scratch. Content-address it on the
        // same terms as a history row instead.
        let message = messageValue["id"]?.stringValue?.isEmpty == false
            ? decoded
            : decoded.identifiedByContent()
        if !message.isUser,
           !SessionKeyMatcher.matches(eventSessionKey, self.selectedSessionKey)
        {
            self.recordUnreadReply(
                sessionKey: eventSessionKey,
                eventID: message.id,
                watermark: Self.operationWatermark(message.timestamp))
        }
        guard let key = self.selectedSessionKey,
              SessionKeyMatcher.matches(eventSessionKey, key)
        else { return }
        if !message.isUser {
            self.streamingText = ""
            self.streamingReasoningText = ""
            self.activeToolName = nil
            self.activeWorkItems = []
        }
        self.acknowledgeOutbox([message], sessionKey: key)
        let merged = Self.mergedMessages(self.messages, incoming: message, pendingEchoes: &self.pendingEchoes)
        // `mergedMessages` either drops a duplicate, replaces an optimistic bubble in place,
        // or appends — and only the append leaves every earlier row untouched, which is the
        // one case the incremental transcript builder can extend through. A delivered
        // claude-cli reply also collapses the imported rows it duplicates, so the prefix is
        // compared rather than assumed from the count.
        if merged.count == self.messages.count + 1, merged.dropLast().elementsEqual(self.messages) {
            self.appendingToTranscript { self.messages = merged }
        } else {
            self.messages = merged
        }
        let snapshot = self.messages
        let historyIsComplete = self.completeHistorySessionKeys.contains(key)
        Task {
            await self.cache.save(
                snapshot,
                sessionKey: key,
                historyIsComplete: historyIsComplete)
        }
    }

    /// The gateway echoes every sent user message back as a `session.message` event, and history
    /// reloads can race those events — merge instead of appending so neither path double-renders.
    nonisolated static func mergedMessages(
        _ messages: [ChatMessage],
        incoming: ChatMessage,
        pendingEchoes: inout [PendingEcho]
    ) -> [ChatMessage] {
        guard !messages.contains(where: { $0.id == incoming.id }) else { return messages }
        var merged = messages
        if incoming.isUser, let requestID = incoming.gatewayRequestID,
           let index = merged.firstIndex(where: { $0.localIdempotencyKey == requestID || $0.gatewayRequestID == requestID }) {
            var replacement = incoming.withID(merged[index].id)
            replacement.localImageData = merged[index].localImageData
            pendingEchoes.removeAll { $0.id == merged[index].id }
            merged[index] = replacement
            return merged
        }
        if incoming.isUser,
           let pendingIndex = pendingEchoes.firstIndex(where: { $0.sentText == incoming.text }) {
            let pending = pendingEchoes.remove(at: pendingIndex)
            if let localIndex = merged.firstIndex(where: { $0.id == pending.id }) {
                // Keep the optimistic image bytes: on remote workspaces the echo's
                // MediaPath is a gateway-host path this machine cannot read.
                var replacement = incoming
                replacement.localImageData = merged[localIndex].localImageData
                merged[localIndex] = replacement
                return merged
            }
        }
        // A history reload can land before the live `session.message` for the same row: since
        // OpenClaw 2026.9.5 the gateway broadcasts the `chat` final before the stored row is
        // published, so the reload triggered by that final already contains the reply. History
        // rows carry position-salted content ids, so an id check alone cannot recognise them.
        // Match on transcript content and keep the id the transcript already renders instead
        // of appending a second copy of the same reply.
        if let existingIndex = merged.firstIndex(where: { Self.isSameTranscriptEntry($0, incoming) }) {
            var replacement = incoming.withID(merged[existingIndex].id)
            replacement.localImageData = merged[existingIndex].localImageData
            merged[existingIndex] = replacement
            return merged
        }
        merged.append(incoming)
        // The delivered reply of a claude-cli turn arrives after the imported transcript rows
        // it duplicates, so this is the moment the earlier rows can be collapsed.
        guard incoming.role == "assistant", incoming.transport == "cli" else { return merged }
        return ChatMessage.collapsingImportedDuplicates(merged)
    }

    /// Merges a bounded authoritative history page into the fuller transcript while retaining
    /// cached/live rows and transient optimistic image bytes. Remote gateway paths are not
    /// readable on iOS (or on another Mac), so throwing those bytes or older rows away during
    /// refresh makes valid transcript content disappear.
    enum HistoryPagePosition: Sendable, Equatable {
        case latest
        case older
    }

    struct DecodedHistoryPage: Sendable {
        let payload: ChatHistoryPayload
        let messages: [ChatMessage]
    }

    /// History pages can contain hundreds of loosely typed rows. Their defensive row-by-row
    /// projection and stable-ID hashing are CPU work, so keep them off the UI actor.
    nonisolated static func decodeHistoryPage(_ data: Data) throws -> DecodedHistoryPage {
        let payload = try JSONDecoder().decode(ChatHistoryPayload.self, from: data)
        return DecodedHistoryPage(payload: payload, messages: payload.decodedMessages())
    }

    nonisolated static func reconciledHistory(
        _ history: [ChatMessage],
        current: [ChatMessage],
        pendingEchoes: inout [PendingEcho],
        position: HistoryPagePosition = .latest) -> [ChatMessage]
    {
        var reconciled = Self.dedupedByID(current)
        var indexByID: [String: Int] = [:]
        var indexByRequest: [String: Int] = [:]
        var indicesByEntry: [TranscriptEntryKey: [Int]] = [:]

        func rebuildIndices() {
            indexByID.removeAll(keepingCapacity: true)
            indexByRequest.removeAll(keepingCapacity: true)
            indicesByEntry.removeAll(keepingCapacity: true)
            for (index, message) in reconciled.enumerated() {
                indexByID[message.id] = index
                if message.isUser, let requestID = message.localIdempotencyKey ?? message.gatewayRequestID { indexByRequest[requestID] = index }
                if let key = TranscriptEntryKey(message) {
                    indicesByEntry[key, default: []].append(index)
                }
            }
        }

        rebuildIndices()
        var additions: [ChatMessage] = []
        for var message in history {
            let incomingKey = TranscriptEntryKey(message)
            let existingIndex = indexByID[message.id]
                ?? (message.isUser ? message.gatewayRequestID.flatMap { indexByRequest[$0] } : nil)
                ?? incomingKey.flatMap { indicesByEntry[$0]?.first }
            if let existingIndex {
                let existing = reconciled[existingIndex]
                if !existing.localImageData.isEmpty {
                    message.localImageData = existing.localImageData
                }
                // Keep the identifier the transcript is already rendering. A row matched by
                // content carries a freshly derived id, and adopting it would churn the
                // `TranscriptGroup`/`ToolRun` identity SwiftUI keys the LazyVStack on — read
                // as a mass delete plus insert, which resets the scroll offset to the top.
                // This also retires the legacy `UUID` ids sitting in older transcript caches.
                reconciled[existingIndex] = message.withID(existing.id)
                let replacementKey = TranscriptEntryKey(reconciled[existingIndex])
                let existingKey = TranscriptEntryKey(existing)
                if existingKey != replacementKey {
                    if let existingKey {
                        indicesByEntry[existingKey]?.removeAll { $0 == existingIndex }
                    }
                    if let replacementKey {
                        indicesByEntry[replacementKey, default: []].append(existingIndex)
                        indicesByEntry[replacementKey]?.sort()
                    }
                }
                continue
            }
            if message.isUser,
               let pendingIndex = pendingEchoes.firstIndex(where: { $0.sentText == message.text })
            {
                let pending = pendingEchoes.remove(at: pendingIndex)
                if let localIndex = reconciled.firstIndex(where: { $0.id == pending.id }) {
                    message.localImageData = reconciled[localIndex].localImageData
                    reconciled.remove(at: localIndex)
                    // Removing shifts every following index. This path is bounded to the
                    // handful of optimistic sends; rebuild once instead of making the normal
                    // 10k-row history path pay linear scans for every incoming page row.
                    rebuildIndices()
                }
            }
            additions.append(message)
        }
        reconciled = position == .older ? additions + reconciled : reconciled + additions
        return ChatMessage.collapsingImportedDuplicates(
            Self.chronologicallySorted(Self.dedupedByID(reconciled)))
    }

    nonisolated static func isSameTranscriptEntry(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        lhs.timestamp != nil
            && rhs.timestamp != nil
            && lhs.role == rhs.role
            && lhs.timestamp == rhs.timestamp
            && lhs.text == rhs.text
            && lhs.toolNames == rhs.toolNames
            && lhs.mediaPaths == rhs.mediaPaths
            && lhs.mediaTypes == rhs.mediaTypes
            && lhs.managedAttachments == rhs.managedAttachments
    }

    nonisolated static func chronologicallySorted(_ messages: [ChatMessage]) -> [ChatMessage] {
        let timestamped = messages.enumerated().compactMap { index, message -> (Int, ChatMessage, Double)? in
            guard let timestamp = message.timestamp, timestamp.isFinite else { return nil }
            return (index, message, timestamp)
        }.sorted { lhs, rhs in
            lhs.2 == rhs.2 ? lhs.0 < rhs.0 : lhs.2 < rhs.2
        }
        var timestampedIndex = 0
        return messages.map { message in
            guard message.timestamp?.isFinite == true else { return message }
            defer { timestampedIndex += 1 }
            // Sort only dated rows, refilling their original slots. Undated/corrupt rows keep
            // their exact position, without mixing timestamp and offset comparisons into the
            // cyclic comparator previously passed to Swift's sorting implementation.
            return timestamped[timestampedIndex].1
        }
    }

    /// Deltas stream into one flat buffer for the whole turn, but history stores that same text
    /// split up — several assistant messages when the turn interleaves tool calls, and blank-line
    /// joined blocks within a message. Comparing a single message against the raw buffer therefore
    /// never matched a multi-block turn, so the finished stream was never cleared and rendered a
    /// second time above the stored reply. Grow the comparison over the transcript tail instead,
    /// on whitespace-stripped text so the differing block separators don't matter.
    nonisolated static func transcriptContains(streamingText: String, in messages: [ChatMessage]) -> Bool {
        let needle = Self.streamComparisonKey(streamingText)
        guard !needle.isEmpty else { return false }
        var tail = ""
        var considered = 0
        for message in messages.reversed() where message.role == "assistant" {
            let text = Self.streamComparisonKey(message.text)
            guard !text.isEmpty else { continue }
            tail = text + tail
            if tail == needle || tail.hasSuffix(needle) || needle.hasSuffix(tail) { return true }
            considered += 1
            if considered >= Self.streamMatchLookback { break }
        }
        return false
    }

    /// How many trailing assistant messages one streamed buffer may span.
    static let streamMatchLookback = 12

    nonisolated static func streamComparisonKey(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    /// Duplicate identifiers in a selectable List/ForEach abort deep in AppKit, so every
    /// wholesale publish (sessions, history, presence, approvals) dedupes first; the
    /// incremental event path already dedupes in `mergedMessages`.
    nonisolated static func dedupedByID<T: Identifiable>(_ rows: [T]) -> [T] where T.ID: Hashable {
        var seen = Set<T.ID>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    private func handleHello(_ event: EventFrame) {
        self.gatewayMethods = Set(event.payload?["features"]?["methods"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        if !self.gatewayMethods.contains("sessions.compact") { self.contextCompactionOfferKey = nil }
        self.gatewayVersion = event.payload?["server"]?["version"]?.stringValue
        self.modelCatalog = []
        self.modelCatalogAgentID = nil
        guard let values = event.payload?["snapshot"]?["presence"]?.arrayValue,
              let data = try? self.encoder.encode(AnyCodable(values)),
              let entries = try? self.decoder.decode([PresenceEntry].self, from: data)
        else { return }
        self.presence = Self.dedupedByID(entries)
    }

    private func handlePresence(_ event: EventFrame) {
        if let entry = self.decodePayload(event, as: PresenceEntry.self) {
            self.presence.removeAll { $0.id == entry.id }
            self.presence.append(entry)
        }
    }

    private func handleApprovalRequested(_ event: EventFrame, kind: ApprovalKind) {
        guard var approval = self.decodePayload(event, as: ExecApproval.self), !approval.isExpired else { return }
        approval.kind = kind
        self.approvals.removeAll { $0.id == approval.id }
        self.approvals.append(approval)
    }

    private func handleShutdown(_ event: EventFrame) {
        // Payload is `{reason, restartExpectedMs?}` (ShutdownEventSchema). Bound the
        // window: below a floor the disconnect would outrun the label, above a cap a stale
        // announcement could claim "restarting" through a real outage.
        let expectedMs = event.payload?["restartExpectedMs"]?.doubleValue
        let graceMs = GatewayClient.clampedMs(expectedMs ?? 30_000, min: 5_000, max: 180_000) ?? 30_000
        self.gatewayRestartDeadlineMs = Date().timeIntervalSince1970 * 1000 + graceMs
        self.connectionState = Self.presentedConnectionState(
            .disconnected(nil),
            restartDeadlineMs: self.gatewayRestartDeadlineMs,
            nowMs: Date().timeIntervalSince1970 * 1000)
    }

    /// `update.available` carries `{updateAvailable: {currentVersion, latestVersion,
    /// channel} | null}`; null retracts the notice (the check ran clean or the update
    /// applied). Decoded loosely — a reshaped payload downgrades to the generic line.
    nonisolated static func updateNoticeText(from payload: AnyCodable?) -> String? {
        guard let payload else { return nil }
        let update = payload["updateAvailable"]
        if update == nil || update?.value == nil { return nil }
        if let version = update?["latestVersion"]?.stringValue, !version.isEmpty {
            return "Gateway update available: \(version)"
        }
        return "A gateway update is available."
    }

    private func handleCronEvent(_ event: EventFrame) {
        guard let payload = self.decodePayload(event, as: CronEventPayload.self) else { return }
        self.automationRuns = CronRun.merging(self.automationRuns, event: payload)
    }

    // MARK: - Operations ledgers

    nonisolated static func operationWatermark(_ value: Double?) -> Int64? {
        guard let value, value.isFinite,
              value >= Double(Int64.min), value <= Double(Int64.max)
        else { return nil }
        return Int64(value.rounded(.down))
    }

    private static func defaultOperationsRoot(workspaceID: String) -> URL {
        let component = workspaceID.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "-"
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Cast", isDirectory: true)
            .appendingPathComponent("Operations", isDirectory: true)
            .appendingPathComponent(String(component), isDirectory: true)
    }

    private func reconcileOperations(with sessions: [SessionRow]) {
        for session in sessions {
            let watermark = Self.operationWatermark(session.updatedAt)
            if SessionKeyMatcher.matches(session.key, self.selectedSessionKey) {
                _ = self.unreadLedger.clearOnOpen(
                    workspaceID: self.profile.id,
                    sessionKey: session.key,
                    throughWatermark: watermark)
                self.markNotificationRecordsRead(sessionKey: session.key)
            } else if session.isUnread,
                      let receipt = self.pendingReadReceipts[session.key],
                      receipt.generation == self.clientGeneration,
                      receipt.updatedAt == session.updatedAt,
                      self.unreadLedger.state(workspaceID: self.profile.id, sessionKey: session.key)?.highestObservedWatermark == receipt.watermark,
                      self.unreadLedger.state(workspaceID: self.profile.id, sessionKey: session.key)?.count == 0
            {
                // An unchanged poll while its read receipt is queued is not a new reply.
                // Failures release this suppression; a newer cursor is never suppressed.
                continue
            } else if session.isUnread {
                // `sessions.list` is polled, and `updatedAt` keeps advancing while a run is
                // streaming even though the reader has seen nothing new yet. Treating each poll
                // as a discrete unread event (as `recordUnreadReply`/`observeUnread` do for real
                // push messages) turned every tick of an in-flight reply into another increment,
                // producing runaway counts. `reconcileAuthoritativeUnread` is the honest
                // operation for a boolean snapshot: it raises to a lower bound of one and never
                // manufactures a count beyond what real per-message events have established.
                _ = self.unreadLedger.reconcileAuthoritativeUnread(
                    workspaceID: self.profile.id,
                    sessionKey: session.key,
                    isUnread: true,
                    watermark: watermark)
            } else {
                _ = self.unreadLedger.reconcileAuthoritativeUnread(
                    workspaceID: self.profile.id,
                    sessionKey: session.key,
                    isUnread: false,
                    watermark: watermark)
            }
        }
        self.publishOperationsState()
    }

    #if DEBUG
    /// Focused test seam for the state transition normally owned by `refreshSessions`.
    func installSessionSnapshotForTesting(_ sessions: [SessionRow]) {
        precondition(
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
            "installSessionSnapshotForTesting is for the test host only")
        self.sessions = sessions
        self.reconcileOperations(with: sessions)
    }
    #endif

    private func recordUnreadReply(
        sessionKey: String,
        eventID: String,
        watermark: Int64?)
    {
        guard self.unreadLedger.observeUnread(
            workspaceID: self.profile.id,
            sessionKey: sessionKey,
            eventID: eventID,
            watermark: watermark) == .incremented
        else { return }

        let dedupeID = "\(self.profile.id):\(eventID)"
        let now = Date()
        let linkage = NotificationLinkage(
            workspaceID: self.profile.id,
            sessionKey: sessionKey,
            sourceEventID: eventID,
            messageID: eventID)
        guard self.notificationLedger.observe(
            dedupeID: dedupeID,
            linkage: linkage,
            at: now) == .inserted
        else {
            self.publishOperationsState()
            return
        }

        // Mute wins over delivery but never over unread accounting (recorded above): it
        // suppresses the interruption, not the truth. Checked before the test-host guard so
        // tests can observe the "muted" suppression reason.
        let muted = self.muteLedger.isMuted(sessionKey: sessionKey)
        let hidden = self.isSessionHidden(sessionKey)
        let shouldDeliverNatively = !muted && !hidden
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        if shouldDeliverNatively {
            _ = self.notificationLedger.markEligible(
                dedupeID: dedupeID,
                at: now,
                detail: "unread-agent-reply")
        } else {
            let reason = hidden ? "hidden" : (muted ? "muted" : "test-host")
            _ = self.notificationLedger.markSuppressed(
                dedupeID: dedupeID,
                at: now,
                reason: reason)
        }
        self.publishOperationsState()
        guard shouldDeliverNatively else { return }

        let row = self.sessions.first(where: { $0.key == sessionKey })
        let title = row.map {
            SidebarGrouper.displayTitle(for: $0, mainSessionKey: self.mainSessionKey)
        } ?? "Agent reply"
        let body = SidebarGrouper.cleanPreview(row?.lastMessagePreview) ?? "A new reply needs your attention."
        Task {
            let outcome = await NativeNotificationDelivery.shared.deliver(
                identifier: dedupeID,
                workspaceID: self.profile.id,
                sessionKey: sessionKey,
                title: title,
                body: body)
            self.completeNativeNotification(dedupeID: dedupeID, outcome: outcome)
        }
    }

    private func completeNativeNotification(
        dedupeID: String,
        outcome: NativeNotificationOutcome)
    {
        if self.notificationLedger.record(dedupeID: dedupeID)?.state == .read {
            self.removeNativeNotifications(identifiers: [dedupeID])
            return
        }
        switch outcome {
        case .delivered:
            _ = self.notificationLedger.markDelivered(
                dedupeID: dedupeID,
                at: Date(),
                detail: "local-notification")
        case let .suppressed(reason):
            _ = self.notificationLedger.markSuppressed(
                dedupeID: dedupeID,
                at: Date(),
                reason: reason)
        case let .failed(errorCode):
            _ = self.notificationLedger.markFailed(
                dedupeID: dedupeID,
                at: Date(),
                errorCode: errorCode)
        }
        self.publishOperationsState()
    }

    private func markNotificationRecordsRead(sessionKey: String) {
        let ids = self.notificationLedger.markRead(
            workspaceID: self.profile.id, sessionKey: sessionKey, at: Date())
        self.removeNativeNotifications(identifiers: ids)
    }

    private func removeNativeNotifications(identifiers: [String]) {
        guard !identifiers.isEmpty,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        else { return }
        Task { await NativeNotificationDelivery.shared.remove(identifiers: identifiers) }
    }

    private func publishOperationsState() {
        self.numericUnreadCount = (self.unreadLedger.workspaces[self.profile.id]?.sessions ?? [:])
            .filter { !self.isSessionHidden($0.key) }
            .values.reduce(0) { $0 + $1.count }
        self.unreadCountsBySession =
            self.unreadLedger.workspaces[self.profile.id]?.sessions.mapValues(\.count) ?? [:]
        self.notificationRecords = self.notificationLedger.records.filter {
            $0.linkage.workspaceID == self.profile.id
        }
        let unread = self.unreadLedger
        let notifications = self.notificationLedger
        let acknowledgements = self.acknowledgementLedger
        Task {
            await self.operationsPersistence.save(
                unread: unread,
                notifications: notifications,
                acknowledgements: acknowledgements)
        }
    }

    public func requestNotificationAuthorization() async -> Bool {
        await NativeNotificationDelivery.shared.requestAuthorization()
    }

    // MARK: - Progress card

    /// Cancels any pending fetch for `sessionKey` and schedules a new one after a short
    /// debounce. Safe to call from the main actor (sync).
    private func scheduleProgressCardFetch(for sessionKey: String) {
        self.progressCardFetchTasks[sessionKey]?.cancel()
        self.progressCardFetchTasks[sessionKey] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await self?.fetchProgressCard(for: sessionKey)
        }
    }

    private func fetchProgressCard(for sessionKey: String) async {
        guard let client = self.client else { return }
        do {
            let card = try await client.getProgressCard(sessionKey: sessionKey)
            guard !Task.isCancelled else { return }
            if let card {
                self.progressCards[sessionKey] = card
            } else {
                self.progressCards.removeValue(forKey: sessionKey)
            }
        } catch {
            // Older gateway (no progressCard method) or network error: keep feature hidden.
        }
    }

    public func toggleProgressCardCollapsed(for sessionKey: String) {
        if self.collapsedProgressCardSessions.contains(sessionKey) {
            self.collapsedProgressCardSessions.remove(sessionKey)
        } else {
            self.collapsedProgressCardSessions.insert(sessionKey)
        }
    }

    public func progressCard(for sessionKey: String) -> ProgressCard? {
        self.progressCards[sessionKey]
    }

    private func publishShareDestinations() {
        guard let store = ShareDestinationStore.appGroup else { return }
        var snapshot = store.load()
        let destination = ShareWorkspaceDestination(
            id: self.profile.id,
            name: self.profile.name,
            sessions: self.sessions.map {
                ShareSessionDestination(
                    key: $0.key,
                    name: SidebarGrouper.displayTitle(for: $0, mainSessionKey: self.mainSessionKey),
                    channel: $0.channel)
            },
            preferredSessionKey: self.selectedSessionKey ?? self.mainSessionKey)
        if let index = snapshot.workspaces.firstIndex(where: { $0.id == destination.id }) {
            snapshot.workspaces[index] = destination
        } else {
            snapshot.workspaces.append(destination)
        }
        store.save(snapshot)
    }
}


extension ChatStore {
    public func setSecretEntryEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "cast.secretEntry." + profile.id)
        secretRequests = []
        secretRequestError = nil
        restartWithStoredCredential()
    }

    public func refreshSecretRequests() async {
        guard secretEntryEnabled, let client, case .connected = connectionState else { return }
        let generation = clientGeneration
        let revision = secretRevision
        do {
            let data = try await client.request(method: "question.list", params: [:])
            let list = try JSONDecoder().decode(SecretRequestList.self, from: data)
            guard generation == clientGeneration, revision == secretRevision else { return }
            secretRequests = list.questions.filter { $0.isPendingSecret && !resolvedSecretIDs.contains($0.id) }
            secretRequestError = nil
        } catch {
            guard generation == clientGeneration else { return }
            // Server errors are not safe to echo for a credential-bearing feature.
            secretRequestError = "Secure requests unavailable. Your Gateway may need to approve operator.questions for this device."
        }
    }

    public func resolveSecretRequest(_ request: SecretRequest, value: String?) async -> String? {
        guard secretEntryEnabled, let client, case .connected = connectionState,
              request.isPendingSecret, request.belongs(to: selectedSessionKey),
              secretRequests.contains(where: { $0.id == request.id }),
              !secretSubmissions.contains(request.id), value == nil || !(value?.isEmpty ?? true)
        else { return "This request is unavailable or expired. Refresh secure requests." }
        let generation = clientGeneration
        secretSubmissions.insert(request.id)
        defer { secretSubmissions.remove(request.id) }
        do {
            let data = try await client.request(method: "question.resolve", params: request.resolution(value: value))
            let response = try JSONDecoder().decode(SecretResolution.self, from: data)
            guard generation == clientGeneration else { return "Connection changed. Check Secret Store in the Gateway before retrying." }
            guard response.status == (value == nil ? "cancelled" : "answered") else {
                return "The Gateway did not confirm this request. Refresh before retrying."
            }
            secretRevision += 1
            resolvedSecretIDs.insert(request.id)
            secretRequests.removeAll { $0.id == request.id }
            return nil
        } catch {
            // The write may have committed before a lost response. Never retry a secret automatically.
            await refreshSecretRequests()
            return "Save was not confirmed. Check the Gateway Secret Store before retrying."
        }
    }
}


extension ChatStore {
    private func scheduleQuestionExpiry() {
        questionExpiryTask?.cancel()
        questionInbox.expire()
        guard let deadline = questionInbox.sorted.filter({ $0.request.isPending() }).map({ $0.request.expiresAtMs }).min() else { return }
        let delay = max(0.01, deadline / 1000 - Date().timeIntervalSince1970)
        questionExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.scheduleQuestionExpiry()
        }
    }

    public func setQuestionsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "cast.questions." + profile.id)
        questionError = nil
        restartWithStoredCredential()
    }

    public func refreshQuestions() async {
        guard questionsEnabled || secretEntryEnabled, let client, case .connected = connectionState else { return }
        let generation = clientGeneration
        do {
            let data = try await client.request(method: "question.list", params: [:])
            let list = try JSONDecoder().decode(QuestionRequestList.self, from: data)
            guard generation == clientGeneration else { return }
            // Merge rather than replace: terminal tombstones prevent stale pending
            // records from reviving, without dropping other replayed questions when
            // an unrelated live event arrives while question.list is in flight.
            for request in list.questions { questionInbox.receive(request) }
            scheduleQuestionExpiry()
            questionError = nil
            // A request may have aged out of the transient list while disconnected.
            // Reconcile it individually; absence is never interpreted as success.
            let listed = Set(list.questions.map(\.id))
            for entry in questionInbox.sorted where questionInbox.needsReconciliation(id: entry.id) && !listed.contains(entry.id) {
                await refreshQuestion(id: entry.id)
            }
        } catch {
            guard generation == clientGeneration else { return }
            questionError = "Questions unavailable. Your Gateway may need to approve operator.questions for this device, or support question.list."
        }
    }

    public func refreshQuestion(id: String) async {
        guard let client, case .connected = connectionState else { return }
        let generation = clientGeneration
        do {
            let data = try await client.request(method: "question.get", params: ["id": id])
            let result = try JSONDecoder().decode(QuestionRequestResult.self, from: data)
            guard generation == clientGeneration, result.question.id == id else { return }
            questionInbox.receive(result.question)
            scheduleQuestionExpiry()
            if result.question.isPending() { questionInbox.confirmPending(id: id) }
        } catch {
            guard generation == clientGeneration else { return }
            if (error as? GatewayRequestError)?.reason == "QUESTION_NOT_FOUND" {
                questionInbox.resolve(id: id, status: "unavailable")
                return
            }
            // Don't echo gateway errors; an expired/not-found request is not a send receipt.
            questionError = "Could not refresh this question. It may have expired or become unavailable."
        }
    }

    public func submitQuestion(id: String, sessionKey: String?) async {
        guard questionsEnabled || secretEntryEnabled, let client, case .connected = connectionState,
              let current = questionInbox.entries[id], current.request.sessionKey == sessionKey,
              let attempt = questionInbox.begin(id: id), let answers = attempt.attemptedAnswers else { return }
        let generation = clientGeneration
        let workspaceID = profile.id
        do {
            let data = try await client.request(method: "question.resolve", params: [
                "id": id, "resolutionId": attempt.resolutionID, "answers": ["answers": answers]])
            let response = try JSONDecoder().decode(QuestionRequestResolution.self, from: data)
            guard workspaceID == profile.id else { return }
            guard generation == clientGeneration else { questionInbox.failed(id: id); return }
            if response.status == "answered" { questionInbox.resolve(id: id, status: "answered") }
            else { questionInbox.failed(id: id); await refreshQuestion(id: id) }
        } catch {
            guard workspaceID == profile.id else { return }
            guard generation == clientGeneration else { questionInbox.failed(id: id); return }
            questionInbox.failed(id: id)
            await refreshQuestion(id: id)
        }
    }
}
