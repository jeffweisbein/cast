import Foundation

/// Durable per-session notification muting.
///
/// Keys are session keys; workspace scoping comes from the per-workspace operations root
/// the ledger file lives in, matching `DraftLedger`. Muting suppresses interruption only —
/// unread counts keep accumulating so the sidebar still tells the truth about a muted
/// session, it just stops pinging the operator about it.
public struct MuteLedger: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public private(set) var mutedSessionKeys: Set<String>

    public init(mutedSessionKeys: Set<String> = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.mutedSessionKeys = mutedSessionKeys
    }

    /// Events can carry canonical keys (`agent:main:main`) while the mute was set from a
    /// sidebar alias (`main`) or vice versa, so membership is alias-aware.
    public func isMuted(sessionKey: String) -> Bool {
        self.mutedSessionKeys.contains { SessionKeyMatcher.matches($0, sessionKey) }
    }

    /// Returns whether the ledger changed, so callers can skip a redundant persist.
    @discardableResult
    public mutating func setMuted(_ muted: Bool, sessionKey: String) -> Bool {
        if muted {
            return self.mutedSessionKeys.insert(sessionKey).inserted
        }
        // Remove alias-equivalent entries too, or a key muted under one spelling could
        // never be unmuted from a row that lists the other.
        let survivors = self.mutedSessionKeys.filter { !SessionKeyMatcher.matches($0, sessionKey) }
        guard survivors.count != self.mutedSessionKeys.count else { return false }
        self.mutedSessionKeys = survivors
        return true
    }
}
