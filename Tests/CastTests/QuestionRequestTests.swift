import XCTest
@testable import Cast

final class QuestionRequestTests: XCTestCase {
    static func fixture(id: String = "question-1", status: String = "pending", multi: Bool = false, other: Bool = true,
                        options: [String] = ["First", "Second"], secret: Bool = false, expires: Double? = nil) throws -> QuestionRequest {
        let object: [String: Any] = ["id": id, "sessionKey": "agent:main:one", "createdAtMs": 1,
            "expiresAtMs": expires ?? (Date().timeIntervalSince1970 * 1000 + 60000), "status": status,
            "questions": [["questionId": "choice", "header": "Choice", "question": "Which path?",
                           "options": options.map { ["label": $0] }, "multiSelect": multi, "isOther": other, "isSecret": secret]]]
        return try JSONDecoder().decode(QuestionRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testNoDefaultAndExactSingleSelection() throws {
        let request = try Self.fixture()
        var draft = QuestionDraft()
        XCTAssertNil(draft.answers(for: request), "Recommendations must never preselect or submit")
        draft.selections["choice"] = ["Second"]
        XCTAssertEqual(draft.answers(for: request), ["choice": ["Second"]])
        draft.selections["choice"] = ["First", "Second"]
        XCTAssertNil(draft.answers(for: request))
    }
    func testMultiSelectCustomAndFreeTextMatchProtocol() throws {
        var draft = QuestionDraft()
        draft.selections["choice"] = ["Second", "First"]
        draft.usingOther.insert("choice")
        draft.text["choice"] = "  Custom value  "
        XCTAssertEqual(draft.answers(for: try Self.fixture(multi: true)), ["choice": ["First", "Second", "Custom value"]])
        XCTAssertEqual(draft.answers(for: try Self.fixture()), ["choice": ["Custom value"]])
        XCTAssertNil(draft.answers(for: try Self.fixture(other: false)))
        draft = QuestionDraft()
        draft.text["choice"] = "Free text"
        XCTAssertEqual(draft.answers(for: try Self.fixture(other: false, options: [])), ["choice": ["Free text"]])
        draft.text["choice"] = " \n "
        XCTAssertNil(draft.answers(for: try Self.fixture(options: [])))
    }
    func testReplayExpiryRoutingAndSecretSeparation() throws {
        var inbox = QuestionInbox()
        let request = try Self.fixture()
        XCTAssertTrue(request.belongs(to: "agent:main:one"))
        XCTAssertFalse(request.belongs(to: "agent:main:two"))
        XCTAssertFalse(request.belongs(to: nil))
        inbox.receive(request); inbox.receive(request)
        XCTAssertEqual(inbox.entries.count, 1)
        inbox.resolve(id: request.id, status: "answered")
        inbox.receive(request)
        XCTAssertEqual(inbox.entries[request.id]?.request.status, "answered")
        XCTAssertFalse(try Self.fixture(expires: 1).isPending())
        inbox.receive(try Self.fixture(id: "secret", secret: true))
        XCTAssertNil(inbox.entries["secret"])
        inbox.resolve(id: "late-request", status: "cancelled")
        inbox.receive(try Self.fixture(id: "late-request"))
        XCTAssertNil(inbox.entries["late-request"])
    }
    func testLostAckRetryKeepsTokenAndPayloadAndPreventsDoubleSubmit() throws {
        var inbox = QuestionInbox()
        let request = try Self.fixture()
        inbox.receive(request)
        var draft = QuestionDraft(); draft.selections["choice"] = ["First"]
        inbox.updateDraft(id: request.id, draft: draft)
        let attempt = try XCTUnwrap(inbox.begin(id: request.id))
        XCTAssertNil(inbox.begin(id: request.id))
        inbox.failed(id: request.id)
        draft.selections["choice"] = ["Second"]
        inbox.updateDraft(id: request.id, draft: draft)
        XCTAssertEqual(inbox.entries[request.id]?.draft.selections["choice"], ["First"], "Uncertain acknowledgements lock the submitted payload")
        let retry = try XCTUnwrap(inbox.begin(id: request.id))
        XCTAssertEqual(attempt.resolutionID, retry.resolutionID)
        XCTAssertEqual(attempt.attemptedAnswers, retry.attemptedAnswers)
        inbox.failed(id: request.id)
        inbox.confirmPending(id: request.id)
        inbox.updateDraft(id: request.id, draft: draft)
        XCTAssertNotEqual(inbox.begin(id: request.id)?.resolutionID, attempt.resolutionID)
        inbox.resolve(id: request.id, status: "answered")
        XCTAssertEqual(inbox.entries[request.id]?.draft, QuestionDraft())
        XCTAssertNil(inbox.begin(id: request.id))
    }
    func testStaleListMergeRetainsOtherPendingQuestionsAfterLiveResolution() throws {
        var inbox = QuestionInbox()
        let first = try Self.fixture(id: "first")
        let second = try Self.fixture(id: "second")
        inbox.receive(first)
        inbox.resolve(id: first.id, status: "answered")
        // A list captured before the live resolution must not revive first or
        // discard an unrelated second question recovered during reconnect.
        inbox.receive(first); inbox.receive(second)
        XCTAssertEqual(inbox.entries[first.id]?.request.status, "answered")
        XCTAssertTrue(inbox.entries[second.id]?.request.isPending() ?? false)
    }
    func testReconnectListPreservesDraftAndTerminalStatusClearsIt() throws {
        var inbox = QuestionInbox(); let request = try Self.fixture()
        inbox.receive(request)
        var draft = QuestionDraft(); draft.text["choice"] = "typed answer"; draft.usingOther.insert("choice")
        inbox.updateDraft(id: request.id, draft: draft)
        inbox.receive(request)
        XCTAssertEqual(inbox.entries[request.id]?.draft, draft)
        inbox.receive(try Self.fixture(status: "cancelled"))
        XCTAssertEqual(inbox.entries[request.id]?.draft, QuestionDraft())
        XCTAssertEqual(inbox.entries[request.id]?.request.status, "cancelled")
    }
    func testExpiryClearsDraftWithoutOpeningQuestionAndCannotReplay() throws {
        var inbox = QuestionInbox()
        let request = try Self.fixture()
        inbox.receive(request)
        var draft = QuestionDraft(); draft.selections["choice"] = ["First"]
        inbox.updateDraft(id: request.id, draft: draft)
        inbox.expire(at: Date(timeIntervalSince1970: request.expiresAtMs / 1000 + 1))
        XCTAssertEqual(inbox.entries[request.id]?.request.status, "expired")
        XCTAssertEqual(inbox.entries[request.id]?.draft, QuestionDraft())
        inbox.dismiss(id: request.id); inbox.receive(request)
        XCTAssertNil(inbox.entries[request.id])
    }
    func testAuthoritativeTerminalRecordReconcilesLocalExpiryWithoutRevivingReplay() throws {
        var inbox = QuestionInbox()
        let request = try Self.fixture()
        inbox.receive(request)
        inbox.expire(at: Date(timeIntervalSince1970: request.expiresAtMs / 1000 + 1))
        inbox.receive(request)
        XCTAssertEqual(inbox.entries[request.id]?.request.status, "expired")
        XCTAssertTrue(inbox.needsReconciliation(id: request.id))
        inbox.receive(try Self.fixture(status: "answered"))
        XCTAssertEqual(inbox.entries[request.id]?.request.status, "answered")
        XCTAssertFalse(inbox.needsReconciliation(id: request.id))
        XCTAssertNil(inbox.begin(id: request.id))
        // Once authoritative, a stale terminal record cannot replace the answer.
        inbox.receive(try Self.fixture(status: "expired"))
        XCTAssertEqual(inbox.entries[request.id]?.request.status, "answered")
        inbox.dismiss(id: request.id)
        XCTAssertFalse(inbox.needsReconciliation(id: request.id))
        inbox.receive(try Self.fixture(status: "answered"))
        XCTAssertNil(inbox.entries[request.id])
    }
    func testDismissedLocalExpiryDoesNotReturnOnAuthoritativeRecord() throws {
        var inbox = QuestionInbox()
        let request = try Self.fixture()
        inbox.receive(request)
        inbox.expire(at: Date(timeIntervalSince1970: request.expiresAtMs / 1000 + 1))
        inbox.dismiss(id: request.id)
        XCTAssertFalse(inbox.needsReconciliation(id: request.id))
        inbox.receive(try Self.fixture(status: "answered"))
        XCTAssertNil(inbox.entries[request.id])
    }
    func testQuestionPermissionDoesNotEnableSecretEntryOrBootstrapElevation() {
        XCTAssertEqual(GatewayClient.connectionScopes(secretEntryEnabled: false, credentialKind: .bootstrapToken, questionsEnabled: true), GatewayClient.scopes)
        let scopes = GatewayClient.connectionScopes(secretEntryEnabled: false, credentialKind: .deviceToken, questionsEnabled: true)
        XCTAssertTrue(scopes.contains("operator.questions"))
        XCTAssertFalse(scopes.contains("operator.admin"))
        XCTAssertEqual(scopes.filter { $0 == "operator.questions" }.count, 1)
    }
}

@MainActor
final class QuestionEventTests: XCTestCase {
    private func event(_ name: String, payload: [String: Any]) throws -> EventFrame {
        try JSONDecoder().decode(EventFrame.self, from: JSONSerialization.data(withJSONObject: ["event": name, "payload": payload]))
    }
    func testOrdinaryQuestionRoutesToInboxNotSecretEntryOrTranscript() throws {
        let store = ChatStore()
        let count = store.messages.count
        let metadata: [String: Any] = ["id": "ask-1", "sessionKey": "agent:main:one", "status": "pending",
            "expiresAtMs": Date().timeIntervalSince1970 * 1000 + 60000,
            "questions": [["questionId": "reply", "question": "What next?", "options": []]]]
        let request = try event("question.requested", payload: metadata)
        store.handleEvent(request); store.handleEvent(request)
        XCTAssertEqual(store.questionInbox.entries.count, 1)
        XCTAssertTrue(store.secretRequests.isEmpty)
        XCTAssertEqual(store.attentionItems.filter { $0.kind == .question }.count, 1)
        store.handleEvent(try event("question.resolved", payload: ["id": "ask-1", "status": "answered"]))
        store.handleEvent(request)
        XCTAssertEqual(store.questionInbox.entries["ask-1"]?.request.status, "answered")
        XCTAssertTrue(store.attentionItems.filter { $0.kind == .question }.isEmpty)
        XCTAssertEqual(store.messages.count, count)
    }
    func testDisconnectedSubmitKeepsDraft() async throws {
        let store = ChatStore(); let request = try QuestionRequestTests.fixture()
        store.questionInbox.receive(request)
        var draft = QuestionDraft(); draft.selections["choice"] = ["First"]
        store.questionInbox.updateDraft(id: request.id, draft: draft)
        await store.submitQuestion(id: request.id, sessionKey: request.sessionKey)
        XCTAssertEqual(store.questionInbox.entries[request.id]?.draft, draft)
        XCTAssertFalse(store.questionInbox.entries[request.id]?.submitting ?? true)
    }
}
