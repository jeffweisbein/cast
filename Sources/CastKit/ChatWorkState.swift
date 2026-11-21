import Foundation

/// Glanceable state for a chat row, derived only from signals Cast already receives:
/// pending questions/approvals, agent attention notes, failure flags, active-run flags and
/// unreviewed deliverables. Absence of a signal yields no state, never a guess.
public enum ChatWorkState: Equatable, Sendable {
    case needsYou(NeedsYouReason)
    case working
    case readyToReview(count: Int)

    public enum NeedsYouReason: String, Sendable, Equatable {
        case question, approval, blocked, failure, delivery
    }

    public var filter: ChatWorkFilter {
        switch self {
        case .needsYou: return .needsYou
        case .working: return .working
        case .readyToReview: return .review
        }
    }

    public var label: String {
        switch self {
        case .needsYou(.question): return "Question for you"
        case .needsYou(.approval): return "Approval needed"
        case .needsYou(.blocked): return "Needs you"
        case .needsYou(.failure): return "Run failed"
        case .needsYou(.delivery): return "Reply not delivered"
        case .working: return "Working"
        case let .readyToReview(count): return count > 1 ? "\(count) results to review" : "Ready to review"
        }
    }
}

public enum ChatWorkFilter: String, CaseIterable, Identifiable, Sendable {
    case all, working, needsYou, review
    public var id: String { self.rawValue }
    public var title: String {
        switch self {
        case .all: return "All"
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .review: return "Review"
        }
    }
}

public enum ChatWorkStateReducer {
    /// - Parameters:
    ///   - rows: chats to classify.
    ///   - attention: the store's attention items (questions, approvals, blockers, failures,
    ///     delivery failures, review items).
    ///   - unreviewedDeliverables: deliverables not yet marked reviewed.
    ///   - liveSessionKey/liveTurnActive: the selected chat's locally observed turn, which can
    ///     be ahead of the last `sessions.list` snapshot.
    /// - Returns: states keyed by canonical session key; chats without a signal are absent.
    public static func states(
        rows: [SessionRow],
        attention: [AttentionItem],
        unreviewedDeliverables: [Deliverable],
        liveSessionKey: String?,
        liveTurnActive: Bool) -> [String: ChatWorkState]
    {
        var hardAttention: [String: ChatWorkState.NeedsYouReason] = [:]
        var softAttention: [String: ChatWorkState.NeedsYouReason] = [:]
        for item in attention {
            guard let key = item.sessionKey.map({ SessionKeyMatcher.canonical($0) }) else { continue }
            switch item.kind {
            case .question: hardAttention[key] = hardAttention[key] ?? .question
            case .approval: hardAttention[key] = hardAttention[key] ?? .approval
            case .blocked: hardAttention[key] = hardAttention[key] ?? .blocked
            // A failure or undelivered notification from an earlier run is superseded once a
            // new run is underway; questions and approvals are not.
            case .failure: softAttention[key] = softAttention[key] ?? .failure
            case .delivery: softAttention[key] = softAttention[key] ?? .delivery
            case .review: break
            }
        }
        var reviewCounts: [String: Int] = [:]
        var seenReviewIDs = Set<String>()
        for item in unreviewedDeliverables where seenReviewIDs.insert(item.reviewID).inserted {
            reviewCounts[SessionKeyMatcher.canonical(item.sessionKey), default: 0] += 1
        }
        let live = liveTurnActive ? liveSessionKey.map { SessionKeyMatcher.canonical($0) } : nil

        var result: [String: ChatWorkState] = [:]
        for row in rows {
            let key = SessionKeyMatcher.canonical(row.key)
            if let reason = hardAttention[key] {
                result[key] = .needsYou(reason)
            } else if ProjectSidebar.isWorking(row) || key == live {
                result[key] = .working
            } else if let reason = softAttention[key] {
                result[key] = .needsYou(reason)
            } else if let count = reviewCounts[key], count > 0 {
                result[key] = .readyToReview(count: count)
            }
        }
        return result
    }

    /// Filters while preserving the incoming (pinned-first, user-ordered) sequence.
    public static func filter(_ rows: [SessionRow], by filter: ChatWorkFilter,
                              states: [String: ChatWorkState]) -> [SessionRow] {
        guard filter != .all else { return rows }
        return rows.filter { states[SessionKeyMatcher.canonical($0.key)]?.filter == filter }
    }
}

/// What a chat's result surface can truthfully say. Fields Cast has no source for are
/// explicitly `.notReported` rather than inferred from prose or completion.
public struct ChatResultSummary: Equatable, Sendable {
    public enum Evidence: Equatable, Sendable {
        /// Cast has no structured receipt for this fact.
        case notReported
        /// The agent's own progress card reported these steps; not independently verified.
        case agentReported(completed: Int, total: Int)
    }

    public let sessionKey: String
    public let items: [Deliverable]
    public let unreviewedCount: Int
    public let latest: Deliverable?
    public let progress: Evidence
    public let progressUpdatedAt: Date?
    /// Build/test/install receipts are not part of the gateway session schema today.
    public let checks: Evidence = .notReported
    public let installation: Evidence = .notReported

    public var isEmpty: Bool { self.items.isEmpty }
    public var allReviewed: Bool { !self.items.isEmpty && self.unreviewedCount == 0 }

    public init(sessionKey: String, ledger: [Deliverable], reviewed: Set<String>, progressCard: ProgressCard?,
                limit: Int = 200) {
        self.sessionKey = sessionKey
        // Ledger order is newest-first; keep it and bound the review surface.
        let items = ledger.lazy.filter { SessionKeyMatcher.matches($0.sessionKey, sessionKey) }.prefix(max(limit, 1))
        self.items = Array(items)
        self.unreviewedCount = self.items.filter { !reviewed.contains($0.reviewID) }.count
        self.latest = self.items.first { !reviewed.contains($0.reviewID) } ?? self.items.first
        if let card = progressCard, SessionKeyMatcher.matches(card.sessionKey, sessionKey) || card.sessionKey.isEmpty,
           card.totalStepCount > 0 {
            self.progress = .agentReported(completed: card.completedStepCount, total: card.totalStepCount)
            self.progressUpdatedAt = card.updatedDate
        } else {
            self.progress = .notReported
            self.progressUpdatedAt = progressCard?.updatedDate
        }
    }
}
