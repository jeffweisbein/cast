import Foundation
import XCTest
@testable import Cast

/// Replays a real OpenClaw 2026.9.5 turn (narration + tool call + final) with sanitized identifiers and the same shapes as the
/// gateway delivered it: the `session.message` rows a live subscriber receives, and the
/// `chat.history` page fetched after the final. Both orders must yield one row per message.
/// Since 2026.9.5 the gateway broadcasts the `chat` final before the stored row is published,
/// so the history reload the final triggers usually lands first; the live row for the same
/// reply then arrived with a different content-addressed id and was rendered twice.
final class LiveHistoryReconcileTests: XCTestCase {
    /// Captured from a live OpenClaw 2026.9.5 gateway on 2026-09-21 with a scratch session:
    /// `live-rows.json` holds every `session.message` payload a subscribed client received for
    /// the turn, `history-page.json` the `chat.history` page fetched after the `chat` final.
    private func fixture(_ name: String) throws -> Data {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/openclaw-2026.9.5-turn", isDirectory: true)
        return try Data(contentsOf: dir.appendingPathComponent(name))
    }

    private func liveMessages() throws -> [ChatMessage] {
        let rows = try JSONDecoder().decode([AnyCodable].self, from: fixture("live-rows.json"))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        return try rows.compactMap { payload in
            guard let messageValue = payload["message"] else { return nil }
            let data = try encoder.encode(messageValue)
            let decoded = try decoder.decode(ChatMessage.self, from: data)
            // Mirrors ChatStore.handleSessionMessage.
            return messageValue["id"]?.stringValue?.isEmpty == false ? decoded : decoded.identifiedByContent()
        }
    }

    private func describe(_ rows: [ChatMessage]) -> String {
        rows.map { "\($0.role):\($0.text.prefix(28)) [\($0.id.prefix(12))]" }.joined(separator: " | ")
    }

    func testLiveRowsThenHistoryReload() throws {
        var current: [ChatMessage] = []
        var echoes: [PendingEcho] = []
        for message in try liveMessages() {
            current = ChatStore.mergedMessages(current, incoming: message, pendingEchoes: &echoes)
        }
        let page = try ChatStore.decodeHistoryPage(fixture("history-page.json"))
        var echoes2: [PendingEcho] = []
        let reconciled = ChatStore.reconciledHistory(page.messages, current: current, pendingEchoes: &echoes2, position: .latest)
        let texts = reconciled.filter { $0.role == "assistant" && !$0.text.isEmpty }.map(\.text)
        XCTAssertEqual(reconciled.count, page.messages.count, "live-then-history rows: \(describe(reconciled))")
        XCTAssertEqual(texts.count, Set(texts).count, "duplicate assistant texts after history reload: \(describe(reconciled))")
    }

    func testHistoryReloadThenLiveRows() throws {
        let page = try ChatStore.decodeHistoryPage(fixture("history-page.json"))
        var echoes: [PendingEcho] = []
        var current = ChatStore.reconciledHistory(page.messages, current: [], pendingEchoes: &echoes, position: .latest)
        for message in try liveMessages() {
            current = ChatStore.mergedMessages(current, incoming: message, pendingEchoes: &echoes)
        }
        let texts = current.filter { $0.role == "assistant" && !$0.text.isEmpty }.map(\.text)
        XCTAssertEqual(current.count, page.messages.count, "history-then-live rows: \(describe(current))")
        XCTAssertEqual(texts.count, Set(texts).count, "duplicate assistant texts after live rows: \(describe(current))")
    }
}
