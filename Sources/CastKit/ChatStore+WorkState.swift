import Foundation

extension ChatStore {
    /// Computed once per sidebar evaluation (not per row) from already-loaded state: no
    /// transcript parsing, no network. Keyed by canonical session key.
    public func chatWorkStates(for rows: [SessionRow], at date: Date = Date()) -> [String: ChatWorkState] {
        let reviewed = self.reviewedWork.ids
        return ChatWorkStateReducer.states(
            rows: rows,
            attention: self.attentionItems(at: date),
            unreviewedDeliverables: self.deliverableLedger.items.filter { !reviewed.contains($0.reviewID) },
            liveSessionKey: self.selectedSessionKey,
            liveTurnActive: self.isAgentTurnActive)
    }

    public func chatWorkState(for sessionKey: String) -> ChatWorkState? {
        guard let row = self.sessions.first(where: { SessionKeyMatcher.matches($0.key, sessionKey) })
            ?? self.personalChats.first(where: { SessionKeyMatcher.matches($0.key, sessionKey) })
        else {
            // No inventory row yet: only the live turn can be stated truthfully.
            return self.isAgentTurnActive && SessionKeyMatcher.matches(self.selectedSessionKey, sessionKey) ? .working : nil
        }
        return self.chatWorkStates(for: [row])[SessionKeyMatcher.canonical(row.key)]
    }

    public func resultSummary(for sessionKey: String) -> ChatResultSummary {
        ChatResultSummary(sessionKey: sessionKey, ledger: self.deliverableLedger.items,
                          reviewed: self.reviewedWork.ids, progressCard: self.progressCard(for: sessionKey))
    }

    public func sessionRow(for sessionKey: String?) -> SessionRow? {
        guard let sessionKey else { return nil }
        return self.sessions.first { SessionKeyMatcher.matches($0.key, sessionKey) }
    }
}
