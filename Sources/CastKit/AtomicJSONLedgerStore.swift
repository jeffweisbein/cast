import Foundation

/// Small, synchronous persistence boundary for deterministic ledger values.
///
/// The ledgers themselves contain no clocks, tasks, or file-system behavior. Callers mutate
/// them with explicit timestamps/cursors, then persist the resulting value at an integration
/// boundary (for example, from a `@MainActor` store).
public struct AtomicJSONLedgerStore<Value: Codable & Sendable>: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load(defaultValue: Value) throws -> Value {
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
            return defaultValue
        }
        let data = try Data(contentsOf: self.fileURL)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        let parent = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: self.fileURL, options: .atomic)
    }
}

/// Serializes snapshots so an older detached write can never replace a newer ledger.
public actor OperationsLedgerPersistence {
    private let unreadStore: AtomicJSONLedgerStore<UnreadLedger>
    private let notificationStore: AtomicJSONLedgerStore<NotificationDeliveryLedger>
    private let acknowledgementStore: AtomicJSONLedgerStore<AcknowledgementLedger>
    private let draftStore: AtomicJSONLedgerStore<DraftLedger>
    private let muteStore: AtomicJSONLedgerStore<MuteLedger>
    // Last values each store persisted successfully. The transcript watchdog republishes
    // the operations snapshot every 20 seconds whether or not anything changed, so an
    // unconditional save rewrote three JSON files continuously for the app's lifetime.
    // A failed write clears its memo so the next snapshot retries it.
    private var lastSavedUnread: UnreadLedger?
    private var lastSavedNotifications: NotificationDeliveryLedger?
    private var lastSavedAcknowledgements: AcknowledgementLedger?

    public init(root: URL) {
        self.unreadStore = AtomicJSONLedgerStore(
            fileURL: root.appendingPathComponent("unread.json"))
        self.notificationStore = AtomicJSONLedgerStore(
            fileURL: root.appendingPathComponent("notifications.json"))
        self.acknowledgementStore = AtomicJSONLedgerStore(
            fileURL: root.appendingPathComponent("acknowledgements.json"))
        self.draftStore = AtomicJSONLedgerStore(
            fileURL: root.appendingPathComponent("drafts.json"))
        self.muteStore = AtomicJSONLedgerStore(
            fileURL: root.appendingPathComponent("mutes.json"))
    }

    public func save(
        unread: UnreadLedger,
        notifications: NotificationDeliveryLedger,
        acknowledgements: AcknowledgementLedger
    ) {
        if unread != self.lastSavedUnread {
            self.lastSavedUnread = (try? self.unreadStore.save(unread)) != nil ? unread : nil
        }
        if notifications != self.lastSavedNotifications {
            self.lastSavedNotifications =
                (try? self.notificationStore.save(notifications)) != nil ? notifications : nil
        }
        if acknowledgements != self.lastSavedAcknowledgements {
            self.lastSavedAcknowledgements =
                (try? self.acknowledgementStore.save(acknowledgements)) != nil ? acknowledgements : nil
        }
    }

    public func save(drafts: DraftLedger) {
        try? self.draftStore.save(drafts)
    }

    public func save(mutes: MuteLedger) {
        try? self.muteStore.save(mutes)
    }
}
