import Foundation

/// Local presentation only. The containing file is scoped to a workspace; no gateway
/// session or unread ledger is mutated when a conversation is hidden or restored.
public struct SidebarPreferences: Codable, Equatable, Sendable {
    public private(set) var hiddenKeys: Set<String> = []
    public private(set) var pinnedKeys: Set<String> = []

    // Optional fields preserve old preference files and explicitly chosen pins/hides.
    public var chats: [String: ChatSidebarPreference]?
    public var pendingChats: [String: ChatSidebarPreference]?
    public var syncAccount: String?
    public var migratedChats: Bool?
    public static let chatPreferenceKey = "cast.chats.sidebar.v1"

    public init() {}

    public func chat(_ key: String) -> ChatSidebarPreference {
        chats?[SessionKeyMatcher.canonical(key)] ?? ChatSidebarPreference(
            kept: isPinned(key), pinned: isPinned(key), hidden: isHidden(key))
    }

    public mutating func updateChat(_ key: String, _ edit: (inout ChatSidebarPreference) -> Void) {
        let key = SessionKeyMatcher.canonical(key)
        var value = chat(key)
        edit(&value)
        if chats == nil { chats = [:] }
        if pendingChats == nil { pendingChats = [:] }
        chats?[key] = value
        pendingChats?[key] = value
        setHidden(value.hidden, key: key)
        setPinned(value.pinned, key: key)
    }

    public func mergedChats(_ remote: [String: ChatSidebarPreference]) -> [String: ChatSidebarPreference] {
        var merged = remote
        if migratedChats != true {
            for key in pinnedKeys where merged[key] == nil { merged[key] = chat(key) }
            for (key, value) in chats ?? [:] where merged[key] == nil { merged[key] = value }
        }
        for (key, value) in pendingChats ?? [:] { merged[key] = value }
        return merged.filter { $0.key.hasPrefix("agent:") }
    }

    public mutating func receiveChats(_ remote: [String: ChatSidebarPreference], sent: [String: ChatSidebarPreference]) {
        for (key, value) in sent where pendingChats?[key] == value { pendingChats?.removeValue(forKey: key) }
        if chats == nil { chats = [:] }
        for (key, value) in remote where pendingChats?[key] == nil {
            chats?[key] = value
            setHidden(value.hidden, key: key)
            setPinned(value.pinned, key: key)
        }
        migratedChats = true
    }

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

/// Personal presentation state; never changes a gateway chat's identity or cancels work.
public struct ChatSidebarPreference: Codable, Equatable, Sendable {
    public var kept = false
    public var pinned = false
    public var hidden = false
    public var archived = false
    public var title: String?
    public var rank: Double?

    public init(kept: Bool = false, pinned: Bool = false, hidden: Bool = false, archived: Bool = false, title: String? = nil, rank: Double? = nil) {
        self.kept = kept; self.pinned = pinned; self.hidden = hidden; self.archived = archived; self.title = title; self.rank = rank
    }
    private enum CodingKeys: String, CodingKey { case kept, pinned, hidden, archived, title, rank }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kept = try c.decodeIfPresent(Bool.self, forKey: .kept) ?? false
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title)
        rank = try c.decodeIfPresent(Double.self, forKey: .rank)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if kept { try c.encode(true, forKey: .kept) }
        if pinned { try c.encode(true, forKey: .pinned) }
        if hidden { try c.encode(true, forKey: .hidden) }
        if archived { try c.encode(true, forKey: .archived) }
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(rank, forKey: .rank)
    }
}
