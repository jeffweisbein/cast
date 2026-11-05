import Foundation
import XCTest
@testable import Cast

final class CommandCenterTests: XCTestCase {
    @MainActor
    func testHelloCapabilitiesDoNotRequirePresenceAndLegacyHelloClearsThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ChatStore(profile: WorkspaceProfile(id: "command-test", name: "Test",
            gatewayURL: URL(string: "ws://127.0.0.1:1")!, accent: "orange"), transcriptCacheRoot: root)
        store.handleEvent(try self.decode(EventFrame.self,
            #"{"event":"cast.hello","payload":{"server":{"version":"test-version"},"features":{"methods":["models.list","sessions.patch","sessions.files.get"]}}}"#))
        XCTAssertTrue(store.supportsModelControls)
        XCTAssertEqual(store.gatewayVersion, "test-version")
        store.handleEvent(try self.decode(EventFrame.self, #"{"event":"cast.hello","payload":{"snapshot":{}}}"#))
        XCTAssertFalse(store.supportsModelControls)
        XCTAssertTrue(store.gatewayMethods.isEmpty)
    }
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
    private func message(_ text: String, role: String = "assistant", timestamp: Double = 1000) -> ChatMessage {
        ChatMessage(role: role, blocks: [ChatContentBlock(type: "text", text: text, thinking: nil,
            name: nil, mimeType: nil, fileName: nil)], timestamp: timestamp)
    }
    private func attention(_ rows: [SessionRow] = [], approvals: [ExecApproval] = [],
                           deliverables: [Deliverable] = [], reviewed: Set<String> = [],
                           hidden: Set<String> = [], acknowledged: Set<String> = []) -> [AttentionItem] {
        AttentionReducer.items(sessions: rows, approvals: approvals, notifications: [],
            deliverables: deliverables, reviewed: reviewed, hidden: hidden, acknowledgedFailures: acknowledged,
            now: Date(timeIntervalSince1970: 100))
    }

    func testModelMutationStaysWriteScopedAndFencesSessionIdentity() throws {
        let model = try self.decode(GatewayModelChoice.self,
            #"{"id":"test","name":"Test","provider":"local","available":true,"thinkingLevels":[{"id":"high","label":"High"}]}"#)
        for effort in [nil, "high"] {
            let params = try SessionModelMutation.params(key: "agent:a:main", sessionID: "old", model: model, effort: effort)
            let data = try JSONEncoder().encode(params)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["model"] as? String, "local/test")
            XCTAssertEqual(object["expectedSessionId"] as? String, "old")
            // thinkingLevel would make the whole patch require operator.admin.
            XCTAssertEqual(Set(object.keys), ["key", "model", "expectedSessionId"])
        }
        XCTAssertThrowsError(try SessionModelMutation.params(key: "k", sessionID: nil, model: model, effort: "invented"))
        XCTAssertNoThrow(try SessionModelMutation.params(key: "k", sessionID: nil, model: model, effort: "high"))
    }

    func testReasoningEffortTravelsThroughThinkCommand() {
        XCTAssertEqual(SessionModelMutation.thinkingCommand(effort: "high"), "/think high")
        XCTAssertEqual(SessionModelMutation.thinkingCommand(effort: nil), "/think default")
        XCTAssertTrue(SessionModelMutation.needsThinkingCommand(effort: "high", currentOverride: nil))
        XCTAssertTrue(SessionModelMutation.needsThinkingCommand(effort: nil, currentOverride: "low"))
        XCTAssertFalse(SessionModelMutation.needsThinkingCommand(effort: nil, currentOverride: nil))
    }

    func testUnavailableModelCannotBeSubmitted() throws {
        let model = try self.decode(GatewayModelChoice.self, #"{"id":"x","name":"X","provider":"p","available":false}"#)
        XCTAssertThrowsError(try SessionModelMutation.params(key: "k", sessionID: nil, model: model, effort: nil))
    }

    func testSessionProjectionSurvivesCacheAndUnreadChange() throws {
        let row = try self.decode(SessionRow.self,
            #"{"key":"agent:a:main","model":"x","modelProvider":"p","sessionId":"s","thinkingLevel":"high","agentStatus":{"note":"Need a decision","attention":"hand","expiresAt":200000}}"#)
        XCTAssertEqual(row.modelInfo?.modelProvider, "p")
        XCTAssertEqual(row.modelInfo?.sessionId, "s")
        XCTAssertEqual(try JSONDecoder().decode(SessionRow.self, from: JSONEncoder().encode(row)).modelInfo, row.modelInfo)
        XCTAssertEqual(row.settingUnread(true).modelInfo, row.modelInfo)
    }

    func testAssistantModelMetadataSurvivesIdentityAndCache() throws {
        let msg = try self.decode(ChatMessage.self, #"{"role":"assistant","content":"ok","model":"fallback","provider":"p"}"#)
        XCTAssertEqual(msg.responseModel, "fallback")
        XCTAssertEqual(msg.withID("stable").responseModel, "fallback")
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(msg)).responseProvider, "p")
    }

    func testDeliverablesAreScopedDeduplicatedAndRetainLabels() throws {
        let msg = self.message("[Review this](https://github.com/acme/app/pull/7) [QA report](</tmp/QA report.md:12>)")
        var ledger = DeliverableLedger()
        ledger.ingest(messages: [msg, self.message("[ignore](/tmp/private.pdf)", role: "user")], sessionKey: "a")
        ledger.ingest(messages: [msg], sessionKey: "a")
        XCTAssertEqual(ledger.items.count, 2)
        XCTAssertTrue(ledger.items.contains { $0.title == "Review this" })
        XCTAssertTrue(ledger.items.contains { $0.target == "/tmp/QA report.md" })
        ledger.ingest(messages: [msg], sessionKey: "b")
        XCTAssertEqual(ledger.items.count, 4)
        XCTAssertEqual(try JSONDecoder().decode(DeliverableLedger.self, from: JSONEncoder().encode(ledger)), ledger)
    }

    func testDeliverablesRejectUnsafeLinksAndOrdinaryReferences() {
        let items = DeliverableScanner.scan(messages: [self.message(
            "[bad](javascript:alert.pdf) [bad](https://user:password@example.com/a.zip) [source](/tmp/source.swift) [package](https://files.test/a.zip)")], sessionKey: "a")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, "Package")
    }

    func testExplicitBlockerWinsOverFailureAndReviewUntilExpired() throws {
        let active = try self.decode(SessionRow.self,
            #"{"key":"a","status":"failed","agentStatus":{"note":"Choose the scope","attention":"hand","expiresAt":200000}}"#)
        let expired = try self.decode(SessionRow.self,
            #"{"key":"a","agentStatus":{"note":"Old note","attention":"hand","expiresAt":99999}}"#)
        let docs = DeliverableScanner.scan(messages: [self.message("[report](/tmp/a.md)")], sessionKey: "a")
        XCTAssertEqual(self.attention([active], deliverables: docs).map(\.kind), [.blocked])
        XCTAssertEqual(self.attention([expired], deliverables: docs).map(\.kind), [.review])
        XCTAssertTrue(self.attention([active], deliverables: docs, hidden: ["a"]).isEmpty)
        XCTAssertTrue(self.attention(deliverables: docs, reviewed: Set(docs.map(\.reviewID))).isEmpty)
        let revised = DeliverableScanner.scan(messages: [self.message("[revised](/tmp/a.md)", timestamp: 2000)], sessionKey: "a")
        XCTAssertEqual(self.attention(deliverables: revised, reviewed: Set(docs.map(\.reviewID))).map(\.kind), [.review])
    }

    func testHiddenChatNeverSuppressesPendingApprovalAndExpiredApprovalDropsOut() throws {
        let active = try self.decode(ExecApproval.self,
            #"{"id":"1","request":{"command":"test","sessionKey":"a"},"expiresAtMs":200000}"#)
        let expired = try self.decode(ExecApproval.self,
            #"{"id":"2","request":{"command":"test","sessionKey":"a"},"expiresAtMs":99999}"#)
        XCTAssertEqual(self.attention(approvals: [active, expired], hidden: ["a"]).map(\.referenceID), ["1"])
    }

    func testUpdatesRequireRealHTTPSFeedAndPublicKey() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        XCTAssertTrue(ReleaseConfiguration.updatesConfigured(feed: "https://updates.cast.test/appcast.xml", publicKey: key))
        for feed in ["", "$(CAST_UPDATE_FEED_URL)", "http://cast.test/a", "https://x:y@cast.test/a", "https://cast.test/a?token=secret"] {
            XCTAssertFalse(ReleaseConfiguration.updatesConfigured(feed: feed, publicKey: key))
        }
        XCTAssertFalse(ReleaseConfiguration.updatesConfigured(feed: "https://cast.test/a", publicKey: "invalid"))
        XCTAssertFalse(ReleaseConfiguration.updatesConfigured(feed: nil, publicKey: nil))
    }
}
