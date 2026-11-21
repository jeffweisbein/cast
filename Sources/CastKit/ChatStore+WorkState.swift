import Foundation

extension ChatStore {
    public var isGatewayConnected: Bool {
        if case .connected = self.connectionState { return true }
        return false
    }

    /// Computed once per sidebar evaluation (not per row) from already-loaded state: no
    /// transcript parsing, no network, no ledger scan. Keyed by canonical session key.
    public func chatWorkStates(for rows: [SessionRow], at date: Date = Date()) -> [String: ChatWorkState] {
        ChatWorkStateReducer.states(
            rows: rows,
            attention: self.workAttentionItems(at: date),
            artifactCounts: self.resultArtifactCounts,
            liveSessionKey: self.selectedSessionKey,
            liveTurnActive: self.isAgentTurnActive,
            connected: self.isGatewayConnected)
    }

    /// Runs the attention reduction for one chat. Intended for the selected chat's card and
    /// inspector only; rows must read the dictionary from `chatWorkStates(for:)` instead.
    public func chatWorkState(for sessionKey: String) -> ChatWorkState? {
        let row = self.sessions.first(where: { SessionKeyMatcher.matches($0.key, sessionKey) })
            ?? self.personalChats.first(where: { SessionKeyMatcher.matches($0.key, sessionKey) })
        guard let row else {
            // No inventory row yet: only the live turn can be stated.
            guard self.isAgentTurnActive, SessionKeyMatcher.matches(self.selectedSessionKey, sessionKey) else { return nil }
            return self.isGatewayConnected ? .working : .workingLastKnown
        }
        return self.chatWorkStates(for: [row])[SessionKeyMatcher.canonical(row.key)]
    }

    public func resultArtifactCounts(for sessionKey: String) -> ResultArtifactCounts? {
        self.resultArtifactCounts[SessionKeyMatcher.canonical(sessionKey)]
    }

    /// Scans the ledger; call only after `resultArtifactCounts(for:)` shows artifacts exist.
    public func resultSummary(for sessionKey: String) -> ChatResultSummary {
        ChatResultSummary(sessionKey: sessionKey, ledger: self.deliverableLedger.items,
                          reviewed: self.reviewedWork.ids, progressCard: self.progressCard(for: sessionKey))
    }

    /// Timestamp (ms) of the newest loaded assistant message in the selected chat.
    public var latestAssistantTimestamp: Double? {
        self.messages.last(where: { $0.role == "assistant" })?.timestamp
    }

    public func sessionRow(for sessionKey: String?) -> SessionRow? {
        guard let sessionKey else { return nil }
        return self.sessions.first { SessionKeyMatcher.matches($0.key, sessionKey) }
    }

    public func presentResultReview(_ presented: Bool = true) {
        self.isResultReviewPresented = presented
    }
}
