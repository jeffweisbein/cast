import Foundation

public struct OperationsSearchResult: Identifiable, Sendable {
    public enum Kind: String, Sendable { case conversation = "Conversation", message = "Message", task = "Task", deliverable = "Deliverable", attention = "Needs you" }
    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String
    public let sessionKey: String
    public let messageID: String?
    public let referenceID: String?
    public let source: String
}

public struct RemoteSearchResponse: Decodable, Sendable {
    public struct Hit: Decodable, Sendable {
        public let sessionKey: String
        public let messageId: String
        public let snippet: String
        public let role: String
    }
    public let results: [Hit]
    public let indexing: Bool?
    public let truncated: Bool?
}

public enum OperationsSearch {
    public static func ranked(_ items: [OperationsSearchResult], query: String, hidden: Set<String>, includeHidden: Bool) -> [OperationsSearchResult] {
        var seen = Set<String>()
        return items.compactMap { item -> (OperationsSearchResult, Int)? in
            guard includeHidden || !hidden.contains(where: { SessionKeyMatcher.matches($0, item.sessionKey) }),
                  seen.insert(item.id).inserted,
                  let score = TranscriptSearchMatcher.relevance(of: item.title + " " + item.detail, query: query) else { return nil }
            let titleScore = TranscriptSearchMatcher.relevance(of: item.title, query: query) ?? 0
            return (item, score + titleScore * 2)
        }.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }.prefix(100).map(\.0)
    }
}

extension ChatStore {
    public func localOperationsSearch(_ query: String, includeHidden: Bool) async -> [OperationsSearchResult] {
        let hits = await cachedSearch(query)
        var results = hits.map { hit in
            OperationsSearchResult(id: "message:" + hit.id, kind: .message,
                title: self.sessions.first { SessionKeyMatcher.matches($0.key, hit.sessionKey) }?.title ?? "Conversation",
                detail: hit.snippet, sessionKey: hit.sessionKey,
                messageID: String(hit.id.dropFirst(hit.sessionKey.count + 1)), referenceID: nil, source: "Saved on this device")
        }
        results += sessions.map {
            OperationsSearchResult(id: "session:" + $0.key, kind: .conversation, title: $0.title,
                detail: $0.lastMessagePreview ?? "", sessionKey: $0.key, messageID: nil, referenceID: nil, source: "Session list")
        }
        results += deliverableLedger.items.map {
            OperationsSearchResult(id: "deliverable:" + $0.id, kind: .deliverable, title: $0.title,
                detail: $0.kind, sessionKey: $0.sessionKey, messageID: nil, referenceID: $0.id, source: "Deliverables")
        }
        results += attentionItems.compactMap {
            guard let key = $0.sessionKey else { return nil }
            return OperationsSearchResult(id: "attention:" + $0.id, kind: .attention, title: $0.title,
                detail: $0.detail, sessionKey: key, messageID: nil, referenceID: $0.referenceID, source: "Needs you")
        }
        return OperationsSearch.ranked(results, query: query, hidden: sidebarPreferences.hiddenKeys, includeHidden: includeHidden)
    }

    public func remoteOperationsSearch(_ query: String) async throws -> RemoteSearchResponse {
        // The protocol supports one agent per request and no more than 200 session keys.
        let groups = Dictionary(grouping: sessions.filter { $0.key.hasPrefix("agent:") }) {
            String($0.key.split(separator: ":", omittingEmptySubsequences: false)[1])
        }
        var hits: [RemoteSearchResponse.Hit] = []
        var indexing = false
        var truncated = groups.count > 8
        if groups.isEmpty {
            let data = try await continuityRequest("sessions.search", params: ["query": String(query.prefix(4096)), "limit": 25])
            return try JSONDecoder().decode(RemoteSearchResponse.self, from: data)
        }
        for agent in groups.keys.sorted().prefix(8) {
            try Task.checkCancellation()
            let rows = groups[agent] ?? []
            let data = try await continuityRequest("sessions.search", params: ["query": String(query.prefix(4096)), "limit": 25,
                "agentId": agent, "sessionKeys": rows.prefix(200).map(\.key)])
            let page = try JSONDecoder().decode(RemoteSearchResponse.self, from: data)
            hits += page.results
            indexing = indexing || page.indexing == true
            truncated = truncated || page.truncated == true || rows.count > 200
        }
        return RemoteSearchResponse(results: hits, indexing: indexing, truncated: truncated)
    }

    public func taskPage(cursor: String? = nil) async throws -> GatewayTaskPage {
        let data = try await continuityRequest("tasks.list", params: ["limit": 100, "cursor": cursor])
        return try JSONDecoder().decode(GatewayTaskPage.self, from: data)
    }
}
