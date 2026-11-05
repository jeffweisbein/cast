import Foundation

public struct AttentionItem: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case question, approval, blocked, failure, delivery, review }
    public let id: String
    public let kind: Kind
    public let sessionKey: String?
    public let title: String
    public let detail: String
    public let referenceID: String?
}

public struct ReviewedWorkLedger: Codable, Sendable {
    public var ids: Set<String> = []
    public init() {}
}

public enum AttentionReducer {
    public static func items(sessions: [SessionRow], approvals: [ExecApproval],
                             notifications: [NotificationDeliveryRecord], deliverables: [Deliverable],
                             reviewed: Set<String>, hidden: Set<String>, acknowledgedFailures: Set<String>,
                             now: Date) -> [AttentionItem] {
        var result: [AttentionItem] = []
        var covered = Set<String>()
        func canonical(_ key: String) -> String { SessionKeyMatcher.canonical(key) }
        func isHidden(_ key: String) -> Bool { hidden.contains { SessionKeyMatcher.matches($0, key) } }
        for approval in approvals where (approval.expiresAtMs ?? .greatestFiniteMagnitude) > now.timeIntervalSince1970 * 1000 {
            let key = approval.request.sessionKey
            // Approvals remain visible even for hidden conversations: hiding is not denial.
            if let key { covered.insert(canonical(key)) }
            result.append(AttentionItem(id: "approval:\(approval.kind.rawValue):\(approval.id)", kind: .approval,
                sessionKey: key, title: "Approval waiting", detail: approval.commandText, referenceID: approval.id))
        }
        for session in sessions where !isHidden(session.key) && !covered.contains(canonical(session.key)) {
            if let status = session.modelInfo?.agentStatus, status.attention != nil,
               status.expiresAt > now.timeIntervalSince1970 * 1000 {
                result.append(AttentionItem(id: "blocked:\(session.key)", kind: .blocked,
                    sessionKey: session.key, title: session.title, detail: status.note, referenceID: nil))
                covered.insert(canonical(session.key))
            } else if SidebarGrouper.hasFailureSignal(session), !acknowledgedFailures.contains(session.key) {
                result.append(AttentionItem(id: "failure:\(session.key)", kind: .failure,
                    sessionKey: session.key, title: session.title,
                    detail: "This session reported a failure. Open the conversation to inspect and respond.", referenceID: nil))
                covered.insert(canonical(session.key))
            }
        }
        for record in notifications where record.state == .failed {
            let key = record.linkage.sessionKey
            guard !isHidden(key), !covered.contains(canonical(key)) else { continue }
            result.append(AttentionItem(id: "delivery:\(record.id)", kind: .delivery, sessionKey: key,
                title: "Notification delivery failed", detail: "The reply is available in Cast. Open the conversation to read it.", referenceID: record.id))
            covered.insert(canonical(key))
        }
        for item in deliverables where !reviewed.contains(item.reviewID) && !isHidden(item.sessionKey) {
            guard !covered.contains(canonical(item.sessionKey)) else { continue }
            result.append(AttentionItem(id: "review:\(item.id)", kind: .review, sessionKey: item.sessionKey,
                title: item.title, detail: "\(item.kind) shared by your agent, ready for your review.", referenceID: item.id))
            covered.insert(canonical(item.sessionKey))
        }
        return result
    }
}
