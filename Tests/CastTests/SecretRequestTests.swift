import XCTest
@testable import Cast

final class SecretRequestTests: XCTestCase {
    func fixture(status: String = "pending", session: String = "agent:main:one", secret: Bool = true, expires: Double = Date().timeIntervalSince1970 * 1000 + 60000) throws -> SecretRequest {
        let object: [String: Any] = ["id":"request-1", "sessionKey":session,"status":status,"expiresAtMs":expires,
            "questions":[["questionId":"secret_value","question":"Enter key","isSecret":secret,
                          "secretStore":["name":"EXAMPLE_API_KEY","kind":"secret","allowedHosts":["api.example.test"]]]]]
        return try JSONDecoder().decode(SecretRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testPendingMetadataAndHostPolicy() throws {
        let r = try fixture()
        XCTAssertTrue(r.isPendingSecret)
        XCTAssertEqual(r.questions[0].secretStore?.allowedHosts, ["api.example.test"])
        XCTAssertTrue(r.belongs(to: "agent:main:one"))
        XCTAssertFalse(r.belongs(to: "agent:main:other"))
        XCTAssertFalse(r.belongs(to: nil))
    }
    func testExpiredResolvedAndOrdinaryQuestionsAreNotSecretEntry() throws {
        XCTAssertFalse(try fixture(expires: 1).isPendingSecret)
        XCTAssertFalse(try fixture(status: "answered").isPendingSecret)
        XCTAssertFalse(try fixture(secret: false).isPendingSecret)
    }
    func testResolutionUsesDirectQuestionContractWithoutChatFields() throws {
        let r = try fixture()
        let p = r.resolution(value: "synthetic-test-value")
        XCTAssertEqual(p["id"] as? String, "request-1")
        let answers = p["answers"] as? [String: [String: [String]]]
        XCTAssertEqual(answers?["answers"]?["secret_value"], ["synthetic-test-value"])
        XCTAssertNil(p["message"])
        XCTAssertNil(p["secretStoreAllowedHosts"], "Preserve exactly the displayed host policy")
        XCTAssertEqual(r.resolution(value: nil)["cancel"] as? Bool, true)
    }
    func testBootstrapScopeCeilingAndExplicitOptIn() {
        XCTAssertEqual(GatewayClient.connectionScopes(secretEntryEnabled: true, credentialKind: .bootstrapToken), GatewayClient.scopes)
        XCTAssertEqual(GatewayClient.connectionScopes(secretEntryEnabled: false, credentialKind: .deviceToken), GatewayClient.scopes)
        XCTAssertTrue(GatewayClient.connectionScopes(secretEntryEnabled: true, credentialKind: .deviceToken).contains("operator.questions"))
        XCTAssertFalse(GatewayClient.connectionScopes(secretEntryEnabled: true, credentialKind: .deviceToken).contains("operator.admin"))
    }
    func testDecodedMetadataNeverRetainsResolvedAnswer() throws {
        let r = try fixture(status: "answered")
        XCTAssertFalse(String(reflecting: r).contains("synthetic-test-value"))
        // SecretRequest is deliberately Decodable-only; no secret value or answer storage.
        XCTAssertFalse(r.isPendingSecret)
    }
}

@MainActor
final class SecretRequestEventTests: XCTestCase {
    private func event(_ name: String, payload: [String: Any]) throws -> EventFrame {
        try JSONDecoder().decode(EventFrame.self, from: JSONSerialization.data(withJSONObject: ["event": name,"payload":payload]))
    }
    private var metadata: [String: Any] {
        ["id":"request-event", "sessionKey":"agent:main:one", "status":"pending", "expiresAtMs":Date().timeIntervalSince1970*1000+60000,
         "questions":[["questionId":"key","question":"Provide test credential","isSecret":true,"secretStore":["name":"TEST_KEY","kind":"secret"]]]]
    }
    /// Isolated workspace with secure entry opted in; never touches a real workspace's settings or caches.
    static func store(secretEntry: Bool, questions: Bool = false, testCase: XCTestCase) -> ChatStore {
        let profile = WorkspaceProfile(id: "test-" + UUID().uuidString, name: "Test",
                                       gatewayURL: URL(string: "ws://127.0.0.1:1")!, accent: "orange")
        let keys = ["cast.secretEntry." + profile.id, "cast.questions." + profile.id]
        UserDefaults.standard.set(secretEntry, forKey: keys[0])
        UserDefaults.standard.set(questions, forKey: keys[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(profile.id, isDirectory: true)
        testCase.addTeardownBlock {
            keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
            try? FileManager.default.removeItem(at: root)
        }
        return ChatStore(profile: profile, transcriptCacheRoot: root, operationsLedgerRoot: root)
    }
    func testEventsDeduplicateResolveAndDoNotCreateChatMessages() throws {
        let store = Self.store(secretEntry: true, testCase: self)
        let messages = store.messages.count
        let requested = try event("question.requested",payload: metadata)
        store.handleEvent(requested); store.handleEvent(requested)
        XCTAssertEqual(store.secretRequests.count,1)
        store.handleEvent(try event("question.resolved",payload:["id":"request-event","status":"answered","answers":["answers":["key":["stored"]]]]))
        XCTAssertTrue(store.secretRequests.isEmpty)
        store.handleEvent(requested)
        XCTAssertTrue(store.secretRequests.isEmpty, "Delayed requested events must not revive resolved secrets")
        XCTAssertEqual(store.messages.count,messages, "Secret lifecycle is not a transcript message")
    }
    func testQuestionCardOptInDoesNotSurfaceSecretRequests() throws {
        // operator.questions granted for ordinary cards also delivers secret-store events.
        let store = Self.store(secretEntry: false, questions: true, testCase: self)
        store.handleEvent(try event("question.requested", payload: metadata))
        XCTAssertTrue(store.secretRequests.isEmpty, "Secure entry stays off unless separately enabled")
        XCTAssertTrue(store.questionInbox.entries.isEmpty, "Secret requests never become ordinary cards")
    }
    func testDisconnectedSubmissionFailsWithoutEchoingValue() async throws {
        let store = Self.store(secretEntry: true, testCase: self)
        store.handleEvent(try event("question.requested",payload:metadata))
        let result = await store.resolveSecretRequest(store.secretRequests[0],value:"synthetic-test-value")
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.contains("synthetic-test-value") ?? true)
        XCTAssertFalse(store.messages.contains { String(reflecting:$0).contains("synthetic-test-value") })
    }
}
