import Foundation
import CryptoKit

/// Locators and local delivery state, never a replacement for gateway history.
public struct SavedSideChat: Codable, Sendable, Identifiable {
    public var id: String { sessionKey }
    public var sessionKey: String
    public var sourceSessionKey: String
    public var context: String
    public var title: String
    public var created: Bool
    public var draft = ""
    public var hasSent = false
    public var sendID: String?
    public var pendingQuestion: String?
    public var pendingMessage: String?

    public static func isSideChatKey(_ key: String) -> Bool {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "agent", !parts[1].isEmpty,
              parts[2].hasPrefix("cast-side-") else { return false }
        return UUID(uuidString: String(parts[2].dropFirst("cast-side-".count))) != nil
    }
}

enum SideChatArchiveReason: String, Codable, Sendable { case manual, inactive }

/// Cached personal manual archives and device-local automatic cleanup, separate from delivery snapshots.
struct SideChatPresentation: Codable, Equatable, Sendable {
    var lastUsedAt: Double?
    var gatewayUpdatedAt: Double?
    var archived: SideChatArchiveReason?
    var hasActiveRun: Bool?
}

struct SideChatArchive: Codable, Sendable {
    var chats: [String: SavedSideChat] = [:]
    var selectedKey: String?
    var isPresented = false
    // Optional additions keep pre-archive recovery files decodable without rewriting them.
    var presentation: [String: SideChatPresentation]?
    var autoArchiveDays: Int?
    // Manual presentation sync only; drafts, quotes and automatic cleanup remain local.
    var archiveSyncProfileID: String?
    var archiveSyncMigrated: Bool?
    var archiveSyncPending: [String: Bool]?

    static let preferenceKey = "cast.sideChats.manualArchive.v1"

    mutating func queueArchiveSync(_ archived: Bool, key: String) {
        if archiveSyncPending == nil { archiveSyncPending = [:] }
        archiveSyncPending?[key] = archived
    }

    func mergedArchivePreferences(_ remote: [String: Bool]) -> [String: Bool] {
        var merged = remote
        if archiveSyncMigrated != true {
            for (key, state) in presentation ?? [:] where state.archived == .manual && merged[key] == nil {
                merged[key] = true
            }
        }
        for (key, archived) in archiveSyncPending ?? [:] { merged[key] = archived }
        return merged
    }

    mutating func applyArchivePreferences(_ remote: [String: Bool], sent: [String: Bool], now: Double) {
        for (key, archived) in sent where archiveSyncPending?[key] == archived {
            archiveSyncPending?.removeValue(forKey: key)
        }
        for (key, archived) in remote where SavedSideChat.isSideChatKey(key) && archiveSyncPending?[key] == nil {
            // Preserve local automatic cleanup when another device has only a restore tombstone.
            if archived { setArchived(.manual, key: key, now: now) }
            else if presentation?[key]?.archived == .manual { setArchived(nil, key: key, now: now) }
        }
        archiveSyncMigrated = true
    }

    func isArchived(_ key: String) -> Bool { presentation?[key]?.archived != nil }

    mutating func touch(_ key: String, now: Double, restore: Bool = false) {
        var state = presentation?[key] ?? SideChatPresentation()
        state.lastUsedAt = now
        if restore || state.archived == .inactive { state.archived = nil }
        if presentation == nil { presentation = [:] }
        presentation?[key] = state
    }

    mutating func observe(_ row: SessionRow, now: Double) {
        var state = presentation?[row.key] ?? SideChatPresentation(lastUsedAt: now)
        state.hasActiveRun = row.hasActiveRun
        if let updated = row.updatedAt, Self.trustedTime(updated, now: now) {
            if state.archived == .inactive, let previous = state.gatewayUpdatedAt, updated > previous {
                state.archived = nil
            }
            state.gatewayUpdatedAt = max(state.gatewayUpdatedAt ?? updated, updated)
        }
        if presentation == nil { presentation = [:] }
        presentation?[row.key] = state
    }

    mutating func setArchived(_ reason: SideChatArchiveReason?, key: String, now: Double) {
        var state = presentation?[key] ?? SideChatPresentation(lastUsedAt: now)
        state.archived = reason
        if reason == nil { state.lastUsedAt = now }
        if presentation == nil { presentation = [:] }
        presentation?[key] = state
    }

    static func trustedTime(_ time: Double, now: Double) -> Bool {
        time.isFinite && time > 0 && time <= now
    }

    /// Only fresh, fully fetched gateway rows establish inactivity. No absence-based cleanup.
    func inactiveKeys(rows: [SessionRow], now: Double, protectedKeys: Set<String>) -> Set<String> {
        guard let days = autoArchiveDays, [30, 60, 90].contains(days), now.isFinite else { return [] }
        let cutoff = now - Double(days) * 86_400_000
        // Pagination can observe the same key twice as the gateway list changes. Any
        // protected/newer/unknown observation wins over an earlier eligible snapshot.
        let blockedKeys = Set(rows.filter { row in
            guard row.hasActiveRun == false, row.pinned != true, row.unread != true,
                  row.status.map({ ["idle", "completed", "done"].contains($0.lowercased()) }) ?? true,
                  let updated = row.updatedAt, Self.trustedTime(updated, now: now), updated <= cutoff
            else { return true }
            return false
        }.map(\.key))
        return Set(rows.compactMap { row in
            guard SavedSideChat.isSideChatKey(row.key), let chat = chats[row.key],
                  chat.sessionKey == row.key, !isArchived(row.key), !protectedKeys.contains(row.key), !blockedKeys.contains(row.key),
                  chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  chat.sendID == nil, chat.pendingQuestion == nil, chat.pendingMessage == nil,
                  row.hasActiveRun == false, row.pinned != true, row.unread != true,
                  row.status.map({ ["idle", "completed", "done"].contains($0.lowercased()) }) ?? true,
                  let updated = row.updatedAt, Self.trustedTime(updated, now: now),
                  let local = presentation?[row.key]?.lastUsedAt, Self.trustedTime(local, now: now),
                  let observed = presentation?[row.key]?.gatewayUpdatedAt, Self.trustedTime(observed, now: now),
                  max(local, max(updated, observed)) <= cutoff else { return nil }
            return row.key
        })
    }

    static func store(root: URL, profile: WorkspaceProfile) -> AtomicJSONLedgerStore<Self> {
        // Exact endpoint and profile identity: renames are harmless; another gateway is not.
        let identity = profile.id + "\n" + profile.gatewayURL.absoluteString
        let component = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return AtomicJSONLedgerStore(fileURL: root.appendingPathComponent("side-chats")
            .appendingPathComponent(component).appendingPathComponent("index.json"), ownerOnly: true)
    }
}
