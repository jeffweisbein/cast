import Foundation

/// Bounded navigation over already-loaded content; never expands the entire transcript.
public struct TranscriptNavigation: Equatable, Sendable {
    public enum Place: Equatable, Sendable { case latest, item(String) }
    public private(set) var returnPlace: Place?
    public init() {}
    public mutating func remember(_ place: Place) { if returnPlace == nil { returnPlace = place } }
    public mutating func takeReturn() -> Place? { defer { returnPlace = nil }; return returnPlace }
    public mutating func reset() { returnPlace = nil }
    public static func matches(_ items: [TranscriptItem], query: String, limit: Int = 200) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, limit > 0 else { return [] }
        return items.lazy.compactMap { item -> String? in
            guard case .group(let group) = item,
                  group.messages.contains(where: { $0.text.localizedCaseInsensitiveContains(query) }) else { return nil }
            return item.id
        }.prefix(limit).map { $0 }
    }
    public static func latestReply(_ items: [TranscriptItem]) -> String? {
        items.last { if case .group(let group) = $0 { return group.role == "assistant" }; return false }?.id
    }
}
