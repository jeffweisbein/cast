import Foundation

public enum NotificationDeliveryState: String, Codable, CaseIterable, Sendable {
    case observed
    case eligible
    case delivered
    case suppressed
    case failed
    case read
}

public struct NotificationLinkage: Codable, Equatable, Sendable {
    public let workspaceID: String
    public let sessionKey: String
    public let sourceEventID: String?
    public let messageID: String?
    public let runID: String?

    public init(
        workspaceID: String,
        sessionKey: String,
        sourceEventID: String? = nil,
        messageID: String? = nil,
        runID: String? = nil)
    {
        self.workspaceID = workspaceID
        self.sessionKey = sessionKey
        self.sourceEventID = sourceEventID
        self.messageID = messageID
        self.runID = runID
    }
}

public struct NotificationDeliveryTransition: Codable, Equatable, Sendable {
    public let state: NotificationDeliveryState
    public let timestamp: Date
    /// Stable policy/error token suitable for diagnostics; never user-authored content.
    public let detail: String?

    public init(state: NotificationDeliveryState, timestamp: Date, detail: String? = nil) {
        self.state = state
        self.timestamp = timestamp
        self.detail = detail
    }
}

public struct NotificationDeliveryRecord: Codable, Equatable, Identifiable, Sendable {
    /// Stable, integration-provided ID shared by all callbacks for one notification decision.
    public var id: String { self.dedupeID }
    public let dedupeID: String
    public let linkage: NotificationLinkage
    public let transitions: [NotificationDeliveryTransition]

    public init(
        dedupeID: String,
        linkage: NotificationLinkage,
        transitions: [NotificationDeliveryTransition])
    {
        self.dedupeID = dedupeID
        self.linkage = linkage
        self.transitions = transitions
    }

    public var state: NotificationDeliveryState {
        self.transitions.last?.state ?? .observed
    }

    public func firstTimestamp(for state: NotificationDeliveryState) -> Date? {
        self.transitions.first(where: { $0.state == state })?.timestamp
    }

    public var observedAt: Date? { self.firstTimestamp(for: .observed) }
    public var eligibleAt: Date? { self.firstTimestamp(for: .eligible) }
    public var deliveredAt: Date? { self.firstTimestamp(for: .delivered) }
    public var suppressedAt: Date? { self.firstTimestamp(for: .suppressed) }
    public var failedAt: Date? { self.firstTimestamp(for: .failed) }
    public var readAt: Date? { self.firstTimestamp(for: .read) }

    fileprivate func appending(_ transition: NotificationDeliveryTransition) -> Self {
        Self(
            dedupeID: self.dedupeID,
            linkage: self.linkage,
            transitions: self.transitions + [transition])
    }
}

public enum NotificationObservationResult: Equatable, Sendable {
    case inserted
    case duplicate
}

public enum NotificationTransitionResult: Equatable, Sendable {
    case transitioned
    case unchanged
    case missing
    case invalidTransition
}

/// Append-only audit state for notification policy and delivery parity.
///
/// The ledger deliberately does not schedule native notifications. Integrations first call
/// `observe`, evaluate policy, record `eligible` or `suppressed`, and then record the native
/// delivery callback as `delivered` or `failed`. All timestamps are caller-supplied so tests,
/// replay, and macOS/iOS behavior remain deterministic.
public struct NotificationDeliveryLedger: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public private(set) var recordsByDedupeID: [String: NotificationDeliveryRecord]

    public init(recordsByDedupeID: [String: NotificationDeliveryRecord] = [:]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.recordsByDedupeID = recordsByDedupeID
    }

    public var records: [NotificationDeliveryRecord] {
        self.recordsByDedupeID.values.sorted {
            let lhs = $0.observedAt ?? .distantPast
            let rhs = $1.observedAt ?? .distantPast
            if lhs != rhs { return lhs > rhs }
            return $0.dedupeID < $1.dedupeID
        }
    }

    public func record(dedupeID: String) -> NotificationDeliveryRecord? {
        self.recordsByDedupeID[dedupeID]
    }

    @discardableResult
    public mutating func observe(
        dedupeID: String,
        linkage: NotificationLinkage,
        at timestamp: Date) -> NotificationObservationResult
    {
        guard self.recordsByDedupeID[dedupeID] == nil else { return .duplicate }
        self.recordsByDedupeID[dedupeID] = NotificationDeliveryRecord(
            dedupeID: dedupeID,
            linkage: linkage,
            transitions: [
                NotificationDeliveryTransition(state: .observed, timestamp: timestamp),
            ])
        return .inserted
    }

    @discardableResult
    public mutating func markEligible(
        dedupeID: String,
        at timestamp: Date,
        detail: String? = nil) -> NotificationTransitionResult
    {
        self.transition(dedupeID: dedupeID, to: .eligible, at: timestamp, detail: detail)
    }

    @discardableResult
    public mutating func markDelivered(
        dedupeID: String,
        at timestamp: Date,
        detail: String? = nil) -> NotificationTransitionResult
    {
        self.transition(dedupeID: dedupeID, to: .delivered, at: timestamp, detail: detail)
    }

    @discardableResult
    public mutating func markSuppressed(
        dedupeID: String,
        at timestamp: Date,
        reason: String) -> NotificationTransitionResult
    {
        self.transition(dedupeID: dedupeID, to: .suppressed, at: timestamp, detail: reason)
    }

    @discardableResult
    public mutating func markFailed(
        dedupeID: String,
        at timestamp: Date,
        errorCode: String) -> NotificationTransitionResult
    {
        self.transition(dedupeID: dedupeID, to: .failed, at: timestamp, detail: errorCode)
    }

    @discardableResult
    public mutating func markRead(
        dedupeID: String,
        at timestamp: Date) -> NotificationTransitionResult
    {
        self.transition(dedupeID: dedupeID, to: .read, at: timestamp, detail: nil)
    }

    /// One unsorted pass, regardless of the number of chats being cleared. Retain records
    /// and dedupe IDs so delayed delivery callbacks cannot resurrect cleared notifications.
    @discardableResult
    public mutating func markRead(
        workspaceID: String,
        sessionKey: String? = nil,
        at timestamp: Date) -> [String]
    {
        let canonicalKey = sessionKey.map { SessionKeyMatcher.canonical($0) }
        let ids = self.recordsByDedupeID.values.compactMap { record -> String? in
            guard record.linkage.workspaceID == workspaceID, record.state != .read,
                  canonicalKey == nil || SessionKeyMatcher.canonical(record.linkage.sessionKey) == canonicalKey
            else { return nil }
            return record.dedupeID
        }
        for id in ids { _ = self.markRead(dedupeID: id, at: timestamp) }
        return ids
    }

    private mutating func transition(
        dedupeID: String,
        to next: NotificationDeliveryState,
        at timestamp: Date,
        detail: String?) -> NotificationTransitionResult
    {
        guard let record = self.recordsByDedupeID[dedupeID] else { return .missing }
        if record.state == next { return .unchanged }
        guard Self.canTransition(from: record.state, to: next) else {
            return .invalidTransition
        }
        self.recordsByDedupeID[dedupeID] = record.appending(
            NotificationDeliveryTransition(
                state: next,
                timestamp: timestamp,
                detail: detail))
        return .transitioned
    }

    /// How long a settled record stays before load-time pruning. The ledger is append-only
    /// in normal operation, so without an eviction horizon it grows by one record per
    /// agent reply forever.
    public static let terminalRecordRetention: TimeInterval = 30 * 24 * 60 * 60

    /// Drops records whose story has ended — delivered, suppressed, read, or failed — with
    /// no transition since `cutoff`. `failed` counts as ended here: its retry transitions
    /// only fire from a fresh delivery attempt under the same dedupe ID, which nothing
    /// issues for month-old events. `observed`/`eligible` records are kept regardless; a
    /// decision that never resolved is exactly what the parity audit exists to surface.
    @discardableResult
    public mutating func pruneTerminalRecords(before cutoff: Date) -> Int {
        let prunable = self.recordsByDedupeID.filter { _, record in
            switch record.state {
            case .delivered, .suppressed, .read, .failed:
                return (record.transitions.last?.timestamp ?? .distantPast) < cutoff
            case .observed, .eligible:
                return false
            }
        }
        for dedupeID in prunable.keys {
            self.recordsByDedupeID[dedupeID] = nil
        }
        return prunable.count
    }

    public static func canTransition(
        from current: NotificationDeliveryState,
        to next: NotificationDeliveryState) -> Bool
    {
        switch (current, next) {
        case (.observed, .eligible),
             (.observed, .suppressed),
             (.observed, .failed),
             (.observed, .read),
             (.eligible, .delivered),
             (.eligible, .suppressed),
             (.eligible, .failed),
             (.eligible, .read),
             (.failed, .eligible),
             (.failed, .delivered),
             (.failed, .suppressed),
             (.failed, .read),
             (.delivered, .read),
             (.suppressed, .read):
            return true
        default:
            return false
        }
    }
}
