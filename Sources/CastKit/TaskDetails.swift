import Foundation

public struct GatewayTask: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let title: String?
    public let sessionKey: String?
    public let childSessionKey: String?
    public let prompt: String?
    public let progressSummary: String?
    public let terminalSummary: String?
    public let result: String?
    public let error: String?
    public let deliveryStatus: String?
    public let terminalOutcome: String?
    public let lastActivity: String?
    public var conversationKey: String? { childSessionKey ?? sessionKey }
    public var isActive: Bool { ["queued", "running"].contains(status) }
    public var canRetryDelivery: Bool {
        ["completed", "failed", "cancelled", "timed_out"].contains(status) && ["failed", "parent_missing"].contains(deliveryStatus ?? "")
    }
    public var displayTitle: String { title?.isEmpty == false ? title! : "Agent task" }
}

public struct GatewayTaskPage: Decodable, Sendable {
    public let tasks: [GatewayTask]
    public let nextCursor: String?
}

public enum TaskControlError: Error, LocalizedError {
    case unsupported, notApplied
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "This gateway does not support that task action."
        case .notApplied: return "The gateway did not apply the action. Refresh the task before trying again."
        }
    }
}

extension ChatStore {
    public func taskDetail(_ id: String) async throws -> GatewayTask {
        let data = try await continuityRequest("tasks.get", params: ["taskId": id])
        struct Response: Decodable { let task: GatewayTask }
        let task = try JSONDecoder().decode(Response.self, from: data).task
        guard task.id == id else { throw TaskControlError.notApplied }
        return task
    }
    public func changeTask(_ task: GatewayTask, cancel: Bool) async throws {
        // Retry is completion DELIVERY recovery, never rerunning the original work.
        guard cancel ? task.isActive : task.canRetryDelivery else { throw TaskControlError.notApplied }
        let method = cancel ? "tasks.cancel" : "tasks.retry"
        let params: [String: Any?] = cancel ? ["taskId": task.id] : ["taskIds": [task.id]]
        let data = try await continuityRequest(method, params: params)
        let response = try JSONDecoder().decode(AnyCodable.self, from: data)
        if cancel {
            guard response["cancelled"]?.boolValue == true else { throw TaskControlError.notApplied }
        } else {
            guard let result = response["results"]?.arrayValue?.first,
                  result["taskId"]?.stringValue == task.id, result["ok"]?.boolValue == true else { throw TaskControlError.notApplied }
        }
    }
}
