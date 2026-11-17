import Foundation

/// Product organization is Gateway category metadata, never an execution project/cwd.
public struct SidebarProject: Identifiable, Equatable, Sendable {
    public let name: String
    public var id: String { name }
    public var title: String { name }
    public init(name: String) { self.name = name }
}

public enum SidebarViewFilter: String, CaseIterable, Identifiable, Sendable {
    case all, needsYou, working, recent
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: return "All conversations"
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .recent: return "Recent"
        }
    }
}

struct SidebarProjectCatalog: Decodable {
    struct Group: Decodable { let name: String; let position: Int }
    let groups: [Group]
}

struct ProjectChatCreated: Decodable {
    let ok: Bool
    let key: String
    let sessionId: String?
}

public enum ProjectSidebarError: LocalizedError {
    case unavailable, connectionChanged, missingIdentity, invalidResponse, busy, invalidName
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Project organization is unavailable on this connection. Reconnect and try again."
        case .connectionChanged: return "The connection changed before confirmation. Refresh the original workspace before retrying."
        case .missingIdentity: return "Refresh this conversation before moving it; its current identity is not available."
        case .invalidResponse: return "The gateway did not confirm the expected conversation. Refresh before retrying."
        case .busy: return "A project change is already being confirmed."
        case .invalidName: return "Project names must contain 1 to 512 characters."
        }
    }
}

public enum ProjectSidebar {
    public static let offeredNames = ["Cackles", "RunPR", "Cast"]

    public static func isProjectChatKey(_ key: String) -> Bool {
        let pieces = key.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0] == "agent", !pieces[1].isEmpty,
              pieces[2].hasPrefix("cast-chat-") else { return false }
        return UUID(uuidString: String(pieces[2].dropFirst("cast-chat-".count))) != nil
    }

    public static func normalizedName(_ name: String?) -> String? {
        guard let value = name?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func validatedName(_ name: String?) throws -> String? {
        guard let name else { return nil }
        guard let normalized = normalizedName(name), normalized.utf16.count <= 512 else { throw ProjectSidebarError.invalidName }
        return normalized
    }

    public static func projects(catalog: [String], rows: [SessionRow]) -> [SidebarProject] {
        var seen = Set<String>()
        return (catalog + offeredNames + rows.compactMap(\.category).sorted()).compactMap { name in
            guard let normalized = normalizedName(name), seen.insert(normalized).inserted else { return nil }
            return SidebarProject(name: normalized)
        }
    }

    public static func isWorking(_ row: SessionRow) -> Bool {
        row.hasActiveRun == true || row.status == "running" || row.status == "queued"
    }

    /// Pin then title/key ordering does not jump on each token or activity update.
    public static func stableOrder(_ rows: [SessionRow], pinned: Set<String> = []) -> [SessionRow] {
        rows.sorted {
            let a = $0.pinned == true || pinned.contains($0.key)
            let b = $1.pinned == true || pinned.contains($1.key)
            if a != b { return a }
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.key < $1.key : comparison == .orderedAscending
        }
    }

    public static func filtered(_ rows: [SessionRow], by filter: SidebarViewFilter,
                                attentionKeys: Set<String>, now: Date = Date()) -> [SessionRow] {
        switch filter {
        case .all: return rows
        case .needsYou: return rows.filter { attentionKeys.contains(SessionKeyMatcher.canonical($0.key)) }
        case .working: return rows.filter(isWorking)
        case .recent:
            let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60).timeIntervalSince1970 * 1000
            // Prefer interaction over streaming activity. Missing timestamps are unknown.
            return rows.filter { ($0.lastInteractionAt ?? $0.updatedAt ?? 0) >= cutoff }.sorted {
                let lhs = $0.lastInteractionAt ?? $0.updatedAt ?? 0
                let rhs = $1.lastInteractionAt ?? $1.updatedAt ?? 0
                return lhs == rhs ? $0.key < $1.key : lhs > rhs
            }
        }
    }
}
