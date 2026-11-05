import Foundation

public enum SessionKeyMatcher {
    public static func canonical(_ key: String, defaultAgentID: String = "main") -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "main" { return "agent:\(defaultAgentID):main" }
        if trimmed.hasPrefix("agent:") { return trimmed }
        if !trimmed.contains(":") { return "agent:\(defaultAgentID):\(trimmed)" }
        return trimmed
    }

    public static func matches(_ lhs: String?, _ rhs: String?, defaultAgentID: String = "main") -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs == rhs || self.canonical(lhs, defaultAgentID: defaultAgentID) == self.canonical(rhs, defaultAgentID: defaultAgentID)
    }

    public static func agentID(from key: String?) -> String? {
        guard let key else { return nil }
        let parts = self.canonical(key).split(separator: ":", maxSplits: 2).map(String.init)
        return parts.count == 3 && parts[0] == "agent" ? parts[1] : nil
    }
}
