import Foundation

/// Local presentation only. The containing file is scoped to a workspace; no gateway
/// session or unread ledger is mutated when a conversation is hidden or restored.
public struct SidebarPreferences: Codable, Equatable, Sendable {
    public private(set) var hiddenKeys: Set<String> = []
    public private(set) var pinnedKeys: Set<String> = []

    public init() {}

    public func isHidden(_ key: String) -> Bool {
        self.hiddenKeys.contains { SessionKeyMatcher.matches($0, key) }
    }

    public func isPinned(_ key: String) -> Bool {
        self.pinnedKeys.contains { SessionKeyMatcher.matches($0, key) }
    }

    public mutating func setHidden(_ hidden: Bool, key: String) {
        self.hiddenKeys = self.hiddenKeys.filter { !SessionKeyMatcher.matches($0, key) }
        if hidden { self.hiddenKeys.insert(SessionKeyMatcher.canonical(key)) }
    }

    public mutating func setPinned(_ pinned: Bool, key: String) {
        self.pinnedKeys = self.pinnedKeys.filter { !SessionKeyMatcher.matches($0, key) }
        if pinned { self.pinnedKeys.insert(SessionKeyMatcher.canonical(key)) }
    }
}
