import Foundation

public enum UnreadCountAccuracy: String, Codable, Sendable {
    /// Cast has observed an exact-zero baseline and every later event.
    case exact
    /// The gateway only established that one or more unread items exist.
    case lowerBound
}

public struct SessionUnreadState: Codable, Equatable, Sendable {
    public private(set) var count: Int
    public private(set) var accuracy: UnreadCountAccuracy
    public private(set) var highestObservedWatermark: Int64?
    public private(set) var clearedThroughWatermark: Int64?
    public private(set) var recentEventIDs: [String]

    public init(
        count: Int = 0,
        accuracy: UnreadCountAccuracy = .lowerBound,
        highestObservedWatermark: Int64? = nil,
        clearedThroughWatermark: Int64? = nil,
        recentEventIDs: [String] = [])
    {
        self.count = max(0, count)
        self.accuracy = accuracy
        self.highestObservedWatermark = highestObservedWatermark
        self.clearedThroughWatermark = clearedThroughWatermark
        self.recentEventIDs = recentEventIDs
    }

    public var isUnread: Bool { self.count > 0 }

    fileprivate mutating func remember(
        eventID: String?,
        watermark: Int64?,
        dedupeCapacity: Int)
    {
        if let eventID, !eventID.isEmpty {
            self.recentEventIDs.append(eventID)
            if self.recentEventIDs.count > dedupeCapacity {
                self.recentEventIDs.removeFirst(self.recentEventIDs.count - dedupeCapacity)
            }
        }
        if let watermark {
            self.highestObservedWatermark = max(self.highestObservedWatermark ?? watermark, watermark)
        }
    }

    fileprivate mutating func establishExactZero(through watermark: Int64?) {
        self.count = 0
        self.accuracy = .exact
        if let watermark {
            self.highestObservedWatermark = max(self.highestObservedWatermark ?? watermark, watermark)
            self.clearedThroughWatermark = max(self.clearedThroughWatermark ?? watermark, watermark)
        }
    }

    fileprivate mutating func establishUnreadLowerBound() {
        if self.count == 0 {
            self.count = 1
            self.accuracy = .lowerBound
        }
    }

    fileprivate mutating func increment() {
        self.count += 1
    }
}

public struct WorkspaceUnreadState: Codable, Equatable, Sendable {
    public private(set) var sessions: [String: SessionUnreadState]

    public init(sessions: [String: SessionUnreadState] = [:]) {
        self.sessions = sessions
    }

    public var unreadCount: Int {
        self.sessions.values.reduce(0) { $0 + $1.count }
    }

    fileprivate mutating func set(_ state: SessionUnreadState, for sessionKey: String) {
        self.sessions[sessionKey] = state
    }
}

/// A single chat's unread state, ready to render as a notification-panel row.
public struct ChatUnreadSummary: Identifiable, Equatable, Sendable {
    public let sessionKey: String
    public let title: String
    public let preview: String?
    public let unreadCount: Int
    public let accuracy: UnreadCountAccuracy
    public let updatedAt: Double?

    public var id: String { self.sessionKey }

    public init(
        sessionKey: String,
        title: String,
        preview: String?,
        unreadCount: Int,
        accuracy: UnreadCountAccuracy,
        updatedAt: Double?)
    {
        self.sessionKey = sessionKey
        self.title = title
        self.preview = preview
        self.unreadCount = unreadCount
        self.accuracy = accuracy
        self.updatedAt = updatedAt
    }
}

public enum UnreadObservationResult: Equatable, Sendable {
    case incremented
    case duplicate
    case stale
}

public enum UnreadReconciliationResult: Equatable, Sendable {
    case changed
    case unchanged
    case stale
}

/// Durable, per-workspace/session unread state.
///
/// `watermark` is an integration-owned monotonically increasing source cursor (a gateway
/// sequence is preferable to a wall-clock timestamp). Supplying it is what lets a clear/read
/// survive a delayed event and a process restart. `eventID` is a bounded fallback for exact
/// duplicate delivery; integrations should provide both when the gateway has both.
public struct UnreadLedger: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let defaultDedupeCapacity = 512

    public let schemaVersion: Int
    public private(set) var workspaces: [String: WorkspaceUnreadState]
    public let dedupeCapacity: Int

    public init(
        workspaces: [String: WorkspaceUnreadState] = [:],
        dedupeCapacity: Int = UnreadLedger.defaultDedupeCapacity)
    {
        self.schemaVersion = Self.currentSchemaVersion
        self.workspaces = workspaces
        self.dedupeCapacity = max(1, dedupeCapacity)
    }

    public func state(workspaceID: String, sessionKey: String) -> SessionUnreadState? {
        self.workspaces[workspaceID]?.sessions[sessionKey]
    }

    public func unreadCount(workspaceID: String) -> Int {
        self.workspaces[workspaceID]?.unreadCount ?? 0
    }

    public var unreadCount: Int {
        self.workspaces.values.reduce(0) { $0 + $1.unreadCount }
    }

    @discardableResult
    public mutating func observeUnread(
        workspaceID: String,
        sessionKey: String,
        eventID: String?,
        watermark: Int64?) -> UnreadObservationResult
    {
        var workspace = self.workspaces[workspaceID] ?? WorkspaceUnreadState()
        var session = workspace.sessions[sessionKey] ?? SessionUnreadState()

        if let eventID, !eventID.isEmpty, session.recentEventIDs.contains(eventID) {
            return .duplicate
        }
        if let watermark {
            if let cleared = session.clearedThroughWatermark, watermark <= cleared {
                return .stale
            }
            if let observed = session.highestObservedWatermark, watermark <= observed {
                return .stale
            }
        }

        session.increment()
        session.remember(
            eventID: eventID,
            watermark: watermark,
            dedupeCapacity: self.dedupeCapacity)
        workspace.set(session, for: sessionKey)
        self.workspaces[workspaceID] = workspace
        return .incremented
    }

    /// Applies the gateway's boolean snapshot without manufacturing an exact numeric count.
    ///
    /// `isUnread == false` is authoritative and establishes exact zero. `true` only raises
    /// zero to a lower bound of one; it never replaces a locally known count with one.
    @discardableResult
    public mutating func reconcileAuthoritativeUnread(
        workspaceID: String,
        sessionKey: String,
        isUnread: Bool,
        watermark: Int64?) -> UnreadReconciliationResult
    {
        var workspace = self.workspaces[workspaceID] ?? WorkspaceUnreadState()
        var session = workspace.sessions[sessionKey] ?? SessionUnreadState()

        if let watermark, let observed = session.highestObservedWatermark, watermark < observed {
            return .stale
        }

        let previous = session
        if isUnread {
            session.establishUnreadLowerBound()
            session.remember(
                eventID: nil,
                watermark: watermark,
                dedupeCapacity: self.dedupeCapacity)
        } else {
            session.establishExactZero(through: watermark)
        }
        workspace.set(session, for: sessionKey)
        self.workspaces[workspaceID] = workspace
        return previous == session ? .unchanged : .changed
    }

    /// Clears the local badge as part of the open-chat transaction.
    ///
    /// The caller should pass the latest applied source cursor. Delayed events at or before
    /// that cursor will then be ignored rather than resurrecting unread state.
    @discardableResult
    public mutating func clearOnOpen(
        workspaceID: String,
        sessionKey: String,
        throughWatermark watermark: Int64?) -> Bool
    {
        var workspace = self.workspaces[workspaceID] ?? WorkspaceUnreadState()
        var session = workspace.sessions[sessionKey] ?? SessionUnreadState()
        let previous = session
        session.establishExactZero(through: watermark)
        workspace.set(session, for: sessionKey)
        self.workspaces[workspaceID] = workspace
        return previous != session
    }

    /// Clear a workspace in one mutation. Calling clearOnOpen in a loop copies the nested
    /// sessions dictionary once per chat because each call temporarily shares its storage.
    public mutating func clearAll(
        workspaceID: String,
        sessionWatermarks: [String: Int64])
    {
        let canonicalWatermarks = Dictionary(sessionWatermarks.map { (SessionKeyMatcher.canonical($0.key), $0.value) },
                                             uniquingKeysWith: max)
        var workspace = self.workspaces.removeValue(forKey: workspaceID) ?? WorkspaceUnreadState()
        for key in Set(workspace.sessions.keys).union(sessionWatermarks.keys) {
            var session = workspace.sessions[key] ?? SessionUnreadState()
            let watermark = [session.highestObservedWatermark, canonicalWatermarks[SessionKeyMatcher.canonical(key)]].compactMap { $0 }.max()
            session.establishExactZero(through: watermark)
            workspace.set(session, for: key)
        }
        self.workspaces[workspaceID] = workspace
    }
}

/// Identifies one exact failure observation. A later update to the same session produces a
/// different identifier so an acknowledged failure can never hide a new one.
public struct SessionAttentionIdentifier: Codable, Hashable, Sendable {
    public let sessionKey: String
    public let updatedAt: Double

    public init?(sessionKey: String, updatedAt: Double?) {
        guard let updatedAt, updatedAt.isFinite else { return nil }
        self.sessionKey = sessionKey
        self.updatedAt = updatedAt
    }
}

/// Durable local dismissals for read-only gateway failures.
///
/// Cast cannot mutate task or cron state. Acknowledging only suppresses the exact observed
/// failure locally; a new `updatedAt` for that session raises attention again.
public struct AcknowledgementLedger: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public private(set) var workspaces: [String: Set<SessionAttentionIdentifier>]

    public init(workspaces: [String: Set<SessionAttentionIdentifier>] = [:]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.workspaces = workspaces
    }

    public func identifiers(workspaceID: String) -> Set<SessionAttentionIdentifier> {
        self.workspaces[workspaceID] ?? []
    }

    public func isAcknowledged(
        workspaceID: String,
        sessionKey: String,
        updatedAt: Double?
    ) -> Bool {
        guard let identifier = SessionAttentionIdentifier(
            sessionKey: sessionKey,
            updatedAt: updatedAt)
        else { return false }
        return self.identifiers(workspaceID: workspaceID).contains(identifier)
    }

    @discardableResult
    public mutating func acknowledge(
        workspaceID: String,
        sessionKey: String,
        updatedAt: Double?
    ) -> Bool {
        guard let identifier = SessionAttentionIdentifier(
            sessionKey: sessionKey,
            updatedAt: updatedAt)
        else { return false }
        var identifiers = self.identifiers(workspaceID: workspaceID)
        let previous = identifiers
        identifiers = Set(identifiers.filter { $0.sessionKey != sessionKey })
        identifiers.insert(identifier)
        self.workspaces[workspaceID] = identifiers
        return identifiers != previous
    }
}
