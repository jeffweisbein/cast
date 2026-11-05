import Foundation

extension ChatMessage {
    /// Collapses the claude-cli backend's double bookkeeping of one turn.
    ///
    /// For a turn run through the Claude CLI, gateway history holds the CLI transcript the
    /// gateway imported (assistant rows tagged `__openclaw.importedFrom = "claude-cli"`, one per
    /// model step, including the `end_turn` prose) *and* the reply the gateway delivered itself
    /// (`api = "cli"`: the turn's opening narration, its final text and any attachments). Rendered
    /// as-is, the reader sees the same reply twice, a few hundred milliseconds apart.
    ///
    /// The delivered row is authoritative for prose, so within one turn (the rows since the last
    /// user message) every imported row whose prose the delivered row already contains loses its
    /// text blocks. Imported tool calls, results and thinking stay: only they carry the agent
    /// work the transcript folds into `ToolRun`s. Rows left with nothing are dropped. Turns
    /// without a delivered row, and prose the delivered row does not contain, are untouched.
    public static func collapsingImportedDuplicates(_ messages: [ChatMessage]) -> [ChatMessage] {
        var strippedIndices = Set<Int>()
        var turnStart = 0
        for (index, message) in messages.enumerated() {
            if message.isUser {
                turnStart = index + 1
                continue
            }
            guard message.role == "assistant", message.transport == "cli" else { continue }
            let delivered = Self.proseKey(message.text)
            guard !delivered.isEmpty else { continue }
            for candidate in turnStart..<index where !strippedIndices.contains(candidate) {
                let row = messages[candidate]
                guard row.role == "assistant", row.importedFrom != nil else { continue }
                let prose = Self.proseKey(row.text)
                guard !prose.isEmpty, delivered.contains(prose) else { continue }
                strippedIndices.insert(candidate)
            }
        }
        guard !strippedIndices.isEmpty else { return messages }
        var collapsed: [ChatMessage] = []
        collapsed.reserveCapacity(messages.count - strippedIndices.count)
        for (index, message) in messages.enumerated() {
            guard strippedIndices.contains(index) else {
                collapsed.append(message)
                continue
            }
            let remaining = message.blocks.filter { !$0.isProse }
            guard !remaining.isEmpty else { continue }
            collapsed.append(message.withBlocks(remaining))
        }
        return collapsed
    }

    /// Prose compared without whitespace: history splits one turn's text across blocks and
    /// rows with differing separators, and the delivered row joins them its own way.
    static func proseKey(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }
}

extension ChatContentBlock {
    /// Exactly the blocks `ChatMessage.text` reads, so stripping prose keeps everything else.
    var isProse: Bool {
        self.normalizedType == "text" || (self.type == nil && self.text != nil)
    }
}
