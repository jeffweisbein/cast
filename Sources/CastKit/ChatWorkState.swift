import Foundation

/// Glanceable state for a chat row, derived only from signals Cast already receives:
/// pending questions/approvals, agent attention notes, failure flags, active-run flags and
/// unreviewed gateway artifacts. Absence of a signal yields no state, never a guess.
public enum ChatWorkState: Equatable, Sendable {
    case needsYou(NeedsYouReason)
    case working
    /// The last snapshot said a run was active, but Cast is not connected, so this is stale.
    case workingLastKnown
    case readyToReview(count: Int)

    public enum NeedsYouReason: String, Sendable, Equatable {
        case question, approval, blocked
        /// Typed terminal status: failed, killed or timeout.
        case failure
        /// Only `abortedLastRun`: the previous run stopped (possibly by the user).
        case stopped
        /// Older gateways without `status`: the preview text looks like an error. Heuristic.
        case checkReply
        case delivery
    }

    public var filter: ChatWorkFilter {
        switch self {
        case .needsYou: return .needsYou
        case .working, .workingLastKnown: return .working
        case .readyToReview: return .review
        }
    }

    public var label: String {
        switch self {
        case .needsYou(.question): return "Question for you"
        case .needsYou(.approval): return "Approval needed"
        case .needsYou(.blocked): return "Needs you"
        case .needsYou(.failure): return "Run failed"
        case .needsYou(.stopped): return "Last run stopped"
        case .needsYou(.checkReply): return "Check the last reply"
        case .needsYou(.delivery): return "Reply not delivered"
        case .working: return "Working"
        case .workingLastKnown: return "Working · last known"
        case .readyToReview: return "Ready to review"
        }
    }

    /// Spoken form; carries the count the compact visual label omits.
    public var accessibilityLabel: String {
        switch self {
        case let .readyToReview(count) where count > 1: return "Ready to review, \(count) files"
        case .workingLastKnown: return "Working when last connected; current state unknown"
        default: return self.label
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

/// Per-chat count of gateway artifacts (managed attachments / `artifacts.list`). Ordinary
/// links in assistant text are deliberately excluded: they stay in Deliverables only.
public struct ResultArtifactCounts: Equatable, Sendable {
    public var total: Int
    public var unreviewed: Int

    /// One pass over the ledger, keyed by canonical session key. Called only when the ledger
    /// or the reviewed set changes, never from view bodies.
    public static func index(ledger: [Deliverable], reviewed: Set<String>) -> [String: ResultArtifactCounts] {
        var result: [String: ResultArtifactCounts] = [:]
        var seen = Set<String>()
        for item in ledger where item.isGatewayArtifact && seen.insert(item.reviewID).inserted {
            let key = SessionKeyMatcher.canonical(item.sessionKey)
            var counts = result[key] ?? ResultArtifactCounts(total: 0, unreviewed: 0)
            counts.total += 1
            if !reviewed.contains(item.reviewID) { counts.unreviewed += 1 }
            result[key] = counts
        }
        return result
    }
}

extension Deliverable {
    /// Backed by a gateway artifact id, not inferred from a link in prose.
    public var isGatewayArtifact: Bool { !(self.artifactID ?? "").isEmpty }
}

public enum ChatWorkStateReducer {
    /// - Parameters:
    ///   - rows: chats to classify.
    ///   - attention: questions, approvals, blockers, failures and delivery failures. Review
    ///     items are ignored; review state comes from `artifactCounts`.
    ///   - artifactCounts: cached per-session gateway-artifact counts (canonical keys).
    ///   - liveSessionKey/liveTurnActive: the selected chat's locally observed turn, which can
    ///     be ahead of the last `sessions.list` snapshot.
    ///   - connected: when false, "working" is reported as last known, not live.
    /// - Returns: states keyed by canonical session key; chats without a signal are absent.
    public static func states(
        rows: [SessionRow],
        attention: [AttentionItem],
        artifactCounts: [String: ResultArtifactCounts],
        liveSessionKey: String?,
        liveTurnActive: Bool,
        connected: Bool = true) -> [String: ChatWorkState]
    {
        var hardAttention: [String: ChatWorkState.NeedsYouReason] = [:]
        var softAttention: [String: AttentionItem.Kind] = [:]
        for item in attention {
            guard let key = item.sessionKey.map({ SessionKeyMatcher.canonical($0) }) else { continue }
            switch item.kind {
            case .question: hardAttention[key] = hardAttention[key] ?? .question
            case .approval: hardAttention[key] = hardAttention[key] ?? .approval
            case .blocked: hardAttention[key] = hardAttention[key] ?? .blocked
            // A failure or undelivered notification from an earlier run is superseded once a
            // new run is underway; questions and approvals are not.
            case .failure, .delivery: softAttention[key] = softAttention[key] ?? item.kind
            case .review: break
            }
        }
        let live = liveTurnActive ? liveSessionKey.map { SessionKeyMatcher.canonical($0) } : nil

        var result: [String: ChatWorkState] = [:]
        for row in rows {
            let key = SessionKeyMatcher.canonical(row.key)
            if let reason = hardAttention[key] {
                result[key] = .needsYou(reason)
            } else if ProjectSidebar.isWorking(row) || key == live {
                result[key] = connected ? .working : .workingLastKnown
            } else if let kind = softAttention[key] {
                result[key] = .needsYou(kind == .delivery ? .delivery : Self.failureReason(for: row))
            } else if let count = artifactCounts[key]?.unreviewed, count > 0 {
                result[key] = .readyToReview(count: count)
            }
        }
        return result
    }

    /// Splits the flattened failure attention back into what the gateway actually said.
    static func failureReason(for row: SessionRow) -> ChatWorkState.NeedsYouReason {
        let signal = SidebarGrouper.failureSignal(for: row)
        if signal.abortedOnly { return .stopped }
        if row.status == nil { return .checkReply }
        return .failure
    }

    /// Filters while preserving the incoming (pinned-first, user-ordered) sequence.
    public static func filter(_ rows: [SessionRow], by filter: ChatWorkFilter,
                              states: [String: ChatWorkState]) -> [SessionRow] {
        guard filter != .all else { return rows }
        return rows.filter { states[SessionKeyMatcher.canonical($0.key)]?.filter == filter }
    }
}

/// What a chat's result surface can truthfully say. Only gateway artifacts count as results;
/// build/test/install facts are explicitly `.notReported` rather than inferred from prose.
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
    /// Every known artifact carries this device's local review mark. The ledger is partial,
    /// so this is never a claim that nothing exists to review.
    public var nothingLeftMarkedHere: Bool { !self.items.isEmpty && self.unreviewedCount == 0 }

    public init(sessionKey: String, ledger: [Deliverable], reviewed: Set<String>, progressCard: ProgressCard?,
                limit: Int = 200) {
        self.sessionKey = sessionKey
        // Ledger order is newest-first; keep it and bound the review surface.
        // Explicit loop: a stateful de-duplication inside a lazy filter re-runs when the
        // lazy collection is materialized and drops every item on the second pass.
        var seen = Set<String>()
        var items: [Deliverable] = []
        for item in ledger where item.isGatewayArtifact && SessionKeyMatcher.matches(item.sessionKey, sessionKey) {
            guard seen.insert(item.reviewID).inserted else { continue }
            items.append(item)
            if items.count >= max(limit, 1) { break }
        }
        self.items = items
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

// MARK: - Progress card markup

/// Parses `<progress …>` tags in progress-card markdown with attributes in any order
/// (the gateway's documented example puts `aria-label` first).
public enum ProgressMarkup {
    public struct Bar: Equatable, Sendable {
        public let value: Double
        public let max: Double
        public let label: String?
    }

    private static let tagRegex = try! NSRegularExpression(
        pattern: #"<progress\b([^>]*?)/?>(?:[^<]*</progress\s*>)?"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let attributeRegex = try! NSRegularExpression(
        pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>/]+))"#)

    public static func parse(_ markdown: String) -> (stripped: String, bars: [Bar]) {
        let ns = markdown as NSString
        var bars: [Bar] = []
        for match in self.tagRegex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            let attributes = self.attributes(ns.substring(with: match.range(at: 1)))
            let max = attributes["max"].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
            guard let raw = attributes["value"].flatMap(Double.init), raw.isFinite else { continue }
            let label = attributes["aria-label"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            bars.append(Bar(value: min(Swift.max(raw, 0), max), max: max, label: label?.isEmpty == false ? label : nil))
        }
        let stripped = self.tagRegex.stringByReplacingMatches(
            in: markdown, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped, bars)
    }

    static func attributes(_ text: String) -> [String: String] {
        let ns = text as NSString
        var result: [String: String] = [:]
        for match in self.attributeRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let value = (2 ... 4).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }
                .map { ns.substring(with: $0) } ?? ""
            if result[name] == nil { result[name] = self.decodeEntities(value) }
        }
        return result
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
