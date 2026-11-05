import Foundation

public struct ThinkingOption: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
}

/// Optional projection from sessions.list; older gateways remain readable.
public struct SessionModelInfo: Codable, Sendable, Equatable {
    public let sessionId: String?
    public let modelProvider: String?
    public let thinkingLevel: String?
    public let thinkingDefault: String?
    public let agentStatus: AgentStatusNote?
}

public struct AgentStatusNote: Codable, Sendable, Equatable {
    public let note: String
    public let attention: String?
    public let expiresAt: Double
}

public struct GatewayModelChoice: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let provider: String
    public let available: Bool?
    public let thinkingLevels: [ThinkingOption]?
    public let thinkingDefault: String?
    public var reference: String { "\(self.provider)/\(self.id)" }
}

public struct GatewayModelsResponse: Decodable, Sendable {
    public let models: [GatewayModelChoice]
}

public enum ModelControlError: LocalizedError {
    case unsupported, unavailable, invalidEffort, disconnected
    case reasoningNotApplied(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "This gateway does not advertise session model controls."
        case .unavailable: return "That model is no longer available. Refresh and choose another."
        case .invalidEffort: return "Choose a reasoning level supported by this model."
        case .disconnected: return "Reconnect to change this conversation’s model."
        case let .reasoningNotApplied(detail):
            return "The model was saved, but the reasoning effort was not applied: \(detail)"
        }
    }
}

public enum SessionModelMutation {
    /// Fields an `operator.write` token may patch. `thinkingLevel` is deliberately absent: the
    /// gateway keeps it admin-scoped in `sessions.patch`, so a paired device (read, write,
    /// approvals) applies reasoning effort through the supported `/think` chat command instead.
    public static func params(key: String, sessionID: String?, model: GatewayModelChoice,
                              effort: String?) throws -> [String: AnyCodable] {
        guard model.available != false else { throw ModelControlError.unavailable }
        if let effort, !(model.thinkingLevels ?? []).contains(where: { $0.id == effort }) {
            throw ModelControlError.invalidEffort
        }
        var params: [String: AnyCodable] = ["key": AnyCodable(key), "model": AnyCodable(model.reference)]
        if let sessionID { params["expectedSessionId"] = AnyCodable(sessionID) }
        return params
    }

    /// Chat command that persists a reasoning override, or clears it with `default`. The gateway
    /// acknowledges the command in the conversation without running a model turn.
    public static func thinkingCommand(effort: String?) -> String {
        "/think \(effort ?? "default")"
    }

    /// Keeping the model default when no override exists changes nothing, so no command is sent.
    public static func needsThinkingCommand(effort: String?, currentOverride: String?) -> Bool {
        effort != nil || currentOverride != nil
    }
}
