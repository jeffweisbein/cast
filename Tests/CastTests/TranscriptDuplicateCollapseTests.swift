import Foundation
import XCTest
@testable import Cast

/// The claude-cli backend writes each turn twice into gateway history: the imported CLI
/// transcript (`__openclaw.importedFrom = "claude-cli"`) and the reply the gateway delivered
/// (`api = "cli"`). These pin the collapse that keeps the reader from seeing every reply twice.
final class TranscriptDuplicateCollapseTests: XCTestCase {
    private static func text(_ type: String?, _ text: String) -> ChatContentBlock {
        ChatContentBlock(type: type, text: text, thinking: nil, name: nil, mimeType: nil, fileName: nil)
    }

    private static func toolCall(_ name: String) -> ChatContentBlock {
        ChatContentBlock(type: "toolCall", text: nil, thinking: nil, name: name, mimeType: nil, fileName: nil, id: UUID().uuidString)
    }

    private static func user(_ prose: String, ts: Double) -> ChatMessage {
        ChatMessage(id: "user-\(ts)", role: "user", blocks: [text("text", prose)], timestamp: ts)
    }

    private static func imported(_ blocks: [ChatContentBlock], ts: Double, id: String = UUID().uuidString) -> ChatMessage {
        ChatMessage(id: id, role: "assistant", blocks: blocks, timestamp: ts, transport: "anthropic-messages", importedFrom: "claude-cli")
    }

    private static func delivered(_ prose: String, ts: Double, id: String = UUID().uuidString) -> ChatMessage {
        ChatMessage(id: id, role: "assistant", blocks: [text("text", prose)], timestamp: ts, transport: "cli")
    }

    func testDeliveredReplyDropsTheImportedProseItRepeats() {
        let narration = "Three threads here. I'll start with the Cast side."
        let final = "Both Cast bugs are fixed and merged to main."
        let messages = [
            Self.user("fix cast", ts: 1000),
            Self.imported([Self.text("text", narration)], ts: 1010, id: "narration"),
            Self.imported([Self.toolCall("Bash")], ts: 1020, id: "tool"),
            Self.imported([Self.text("text", final)], ts: 1030, id: "final"),
            Self.delivered(narration + "\n\n" + final, ts: 1031, id: "delivered"),
        ]

        let collapsed = ChatMessage.collapsingImportedDuplicates(messages)

        XCTAssertEqual(collapsed.map(\.id), ["user-1000.0", "tool", "delivered"])
        XCTAssertEqual(collapsed.filter { $0.role == "assistant" }.map(\.text), ["", narration + "\n\n" + final])
    }

    func testImportedRowKeepsItsToolCallsWhenOnlyItsProseIsRepeated() {
        let prose = "Checking the build first."
        let messages = [
            Self.user("go", ts: 1000),
            Self.imported([Self.text("text", prose), Self.toolCall("Read")], ts: 1010, id: "mixed"),
            Self.delivered(prose + "\n\nDone.", ts: 1020, id: "delivered"),
        ]

        let collapsed = ChatMessage.collapsingImportedDuplicates(messages)

        XCTAssertEqual(collapsed.map(\.id), ["user-1000.0", "mixed", "delivered"])
        XCTAssertEqual(collapsed[1].text, "")
        XCTAssertEqual(collapsed[1].toolNames, ["Read"])
    }

    func testImportedProseTheDeliveredReplyDoesNotContainSurvives() {
        let messages = [
            Self.user("go", ts: 1000),
            Self.imported([Self.text("text", "Something the gateway never delivered.")], ts: 1010, id: "orphan"),
            Self.delivered("A different final answer.", ts: 1020, id: "delivered"),
        ]

        let collapsed = ChatMessage.collapsingImportedDuplicates(messages)

        XCTAssertEqual(collapsed.map(\.id), ["user-1000.0", "orphan", "delivered"])
    }

    func testTurnsWithoutADeliveredReplyAreUntouched() {
        let messages = [
            Self.user("go", ts: 1000),
            Self.imported([Self.text("text", "Only the import exists.")], ts: 1010, id: "import"),
            ChatMessage(id: "plain", role: "assistant", blocks: [Self.text("text", "Only the import exists.")], timestamp: 1020),
        ]

        XCTAssertEqual(ChatMessage.collapsingImportedDuplicates(messages).map(\.id), messages.map(\.id))
    }

    func testCollapseIsScopedToTheTurnAfterTheLastUserMessage() {
        let repeated = "Same words in two turns."
        let messages = [
            Self.user("first", ts: 1000),
            Self.imported([Self.text("text", repeated)], ts: 1010, id: "earlier-turn"),
            Self.user("second", ts: 2000),
            Self.imported([Self.text("text", repeated)], ts: 2010, id: "this-turn"),
            Self.delivered(repeated, ts: 2020, id: "delivered"),
        ]

        let collapsed = ChatMessage.collapsingImportedDuplicates(messages)

        XCTAssertEqual(collapsed.map(\.id), ["user-1000.0", "earlier-turn", "user-2000.0", "delivered"])
    }

    func testUntypedTextBlocksCountAsProse() {
        let messages = [
            Self.user("go", ts: 1000),
            Self.imported([Self.text(nil, "bare text block")], ts: 1010, id: "bare"),
            Self.delivered("bare text block", ts: 1020, id: "delivered"),
        ]

        XCTAssertEqual(ChatMessage.collapsingImportedDuplicates(messages).map(\.id), ["user-1000.0", "delivered"])
    }

    func testGatewayRowsDecodeTransportAndImportOrigin() throws {
        let json = """
        [
          {"role":"assistant","api":"anthropic-messages","stopReason":"end_turn","timestamp":1,
           "content":[{"type":"text","text":"hi"}],
           "__openclaw":{"id":"abc","importedFrom":"claude-cli","cliSessionId":"s","externalId":"abc"}},
          {"role":"assistant","api":"cli","stopReason":"stop","timestamp":2,
           "content":[{"type":"text","text":"hi"}],
           "__openclaw":{"id":"def","idempotencyKey":"cli-assistant:X","seq":7}},
          {"role":"user","timestamp":3,"content":"hello"}
        ]
        """
        let rows = try JSONDecoder().decode([ChatMessage].self, from: Data(json.utf8))

        XCTAssertEqual(rows.map(\.transport), ["anthropic-messages", "cli", nil])
        XCTAssertEqual(rows.map(\.importedFrom), ["claude-cli", nil, nil])
    }

    func testTransportAndImportOriginSurviveTheTranscriptCacheRoundTrip() throws {
        let original = Self.imported([Self.text("text", "cached")], ts: 5, id: "row")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.transport, "anthropic-messages")
        XCTAssertEqual(decoded.importedFrom, "claude-cli")

        let plain = ChatMessage(id: "plain", role: "user", blocks: [Self.text("text", "x")], timestamp: 1)
        let plainJSON = try XCTUnwrap(String(data: try JSONEncoder().encode(plain), encoding: .utf8))
        XCTAssertFalse(plainJSON.contains("__openclaw"), "rows the gateway did not import must not grow an import marker")
    }

    func testHistoryReconcileCollapsesTheDuplicateReply() {
        let prose = "Merged to main."
        let history = [
            Self.user("merge", ts: 1000),
            Self.imported([Self.text("text", prose)], ts: 1010, id: "import"),
            Self.delivered(prose, ts: 1011, id: "delivered"),
        ]
        var echoes: [PendingEcho] = []

        let reconciled = ChatStore.reconciledHistory(history, current: [], pendingEchoes: &echoes)

        XCTAssertEqual(reconciled.map(\.id), ["user-1000.0", "delivered"])
    }

    func testLiveDeliveredReplyCollapsesTheImportedRowsAlreadyShown() {
        let prose = "Merged to main."
        let shown = [
            Self.user("merge", ts: 1000),
            Self.imported([Self.text("text", prose)], ts: 1010, id: "import"),
        ]
        var echoes: [PendingEcho] = []

        let merged = ChatStore.mergedMessages(shown, incoming: Self.delivered(prose, ts: 1011, id: "delivered"), pendingEchoes: &echoes)

        XCTAssertEqual(merged.map(\.id), ["user-1000.0", "delivered"])
    }

    func testTranscriptItemsCompareByContent() {
        let message = Self.delivered("same", ts: 1, id: "row")
        let lhs = TranscriptBuilder.items(from: [message], showAgentWork: true)
        let rhs = TranscriptBuilder.items(from: [message], showAgentWork: true)
        let changed = TranscriptBuilder.items(from: [Self.delivered("different", ts: 1, id: "row")], showAgentWork: true)

        XCTAssertEqual(lhs, rhs)
        XCTAssertNotEqual(lhs, changed)
    }
}
