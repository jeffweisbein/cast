import Foundation

public enum ActionPresentation: String, Sendable {
    case waiting = "Waiting for you", submitting = "Submitting", uncertain = "Not confirmed"
    case confirmed = "Confirmed", expired = "Expired", unavailable = "No longer pending"
    public static func question(_ entry: QuestionInbox.Entry, at now: Date) -> Self {
        if entry.request.status == "answered" { return .confirmed }
        if entry.request.status == "expired" || (entry.request.status == "pending" && !entry.request.isPending(at: now)) { return .expired }
        if entry.request.status != "pending" { return .unavailable }
        if entry.submitting { return .submitting }
        if entry.uncertain { return .uncertain }
        return .waiting
    }
}

public struct ApprovalActivity: Identifiable, Sendable {
    public var id: String { approval.id }
    public let approval: ExecApproval
    public var state: ActionPresentation
    public var detail: String
    public var updatedAt = Date()
}

public enum ConnectionPresentation {
    public static func title(_ state: GatewayConnectionState) -> String {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Reconnecting…"
        case .waitingForApproval: return "Pairing approval needed"
        case .needsCredentials: return "Sign in to reconnect"
        case .disconnected(let reason): return reason?.localizedCaseInsensitiveContains("restart") == true ? "Gateway restarting…" : "Offline"
        }
    }
    public static func detail(_ state: GatewayConnectionState, unconfirmed: Int) -> String {
        let pending = unconfirmed > 0 ? " \(unconfirmed) message\(unconfirmed == 1 ? "" : "s") still need gateway confirmation. Check their status before retrying." : ""
        switch state {
        case .connected: return "Connected to the gateway. Connection alone does not confirm a message was received." + pending
        case .connecting: return "Cast is reconnecting. Your saved text drafts and downloaded files stay on this device. Nothing is resent automatically." + pending
        case .waitingForApproval: return "Approve this device in OpenClaw to connect. Your local drafts stay here." + pending
        case .needsCredentials: return "Open workspace setup to restore access. Your local drafts stay here." + pending
        case .disconnected: return "Showing available local history. Saved text drafts and downloaded files stay here; pending attachments stay in memory until sent. Nothing is resent automatically." + pending
        }
    }
}
