import Foundation
import XCTest
@testable import Cast

final class SessionDiagnosticsTests: XCTestCase {
    func testCostUnknownIsNotZeroAndUnreadProjectionPreservesEstimate() throws {
        let unknown = try decode(SessionRow.self, #"{"key":"a"}"#)
        XCTAssertEqual(unknown.estimatedCostSummary, "Not reported")
        let known = try decode(SessionRow.self, #"{"key":"a","estimatedCostUsd":1.25}"#)
        XCTAssertEqual(known.settingUnread(true).estimatedCostUsd, 1.25)
        let negative = try decode(SessionRow.self, #"{"key":"a","estimatedCostUsd":-5}"#)
        XCTAssertNil(negative.estimatedCostUsd)
        let malformed = try decode(SessionRow.self, #"{"key":"a","estimatedCostUsd":"private-error"}"#)
        XCTAssertNil(malformed.estimatedCostUsd)
    }

    func testDiagnosisRequestKeepsInvestigationReadOnlyAndDoesNotInventEvidence() {
        let request = DiagnosisRequest.draft(safeSummary: "History: refresh needed")
        XCTAssertTrue(request.contains("read-only"))
        XCTAssertTrue(request.contains("Do not restart"))
        XCTAssertTrue(request.hasSuffix("History: refresh needed"))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }
    private func event(_ name: String, _ payload: [String: Any]) throws -> EventFrame {
        try JSONDecoder().decode(EventFrame.self, from: JSONSerialization.data(withJSONObject: ["event": name, "payload": payload]))
    }

    func testStructuredModelFailureExplainsRepairWithoutLeakingProviderText() throws {
        let payload = try decode(ChatEventPayload.self, #"""
        {"state":"error","errorKind":"unknown","errorMessage":"PRIVATE RAW DIAGNOSTIC",
         "errorDetail":{"providerRuntimeFailureKind":"model_not_found","httpStatus":404,
          "providerErrorMessagePreview":"PRIVATE PREVIEW","provider":"PRIVATE PROVIDER"}}
        """#)
        let category = RunFailureCategory.resolve(kind: payload.errorKind, detail: payload.errorDetail)
        XCTAssertEqual(category, .modelUnavailable)
        XCTAssertTrue(category.message.contains("client version"))
        XCTAssertFalse(category.message.contains("PRIVATE"))
        XCTAssertFalse(category.title.contains("PRIVATE"))
    }

    func testFailurePrecedenceAndMalformedDiagnosticsRetainTerminalEvent() throws {
        let detail = try decode(GatewayChatErrorDetail.self, #"{"failoverReason":"model_not_found","httpStatus":429}"#)
        XCTAssertEqual(RunFailureCategory.resolve(kind: "context_length", detail: detail), .contextLength)
        let invalid = try decode(ChatEventPayload.self, #"{"state":"error","errorKind":"timeout","errorDetail":["malformed"]}"#)
        XCTAssertEqual(invalid.state, "error")
        XCTAssertNil(invalid.errorDetail)
        XCTAssertEqual(RunFailureCategory.resolve(kind: invalid.errorKind, detail: invalid.errorDetail), .timeout)
        let future = try decode(GatewayChatErrorDetail.self, #"{"failoverReason":"PRIVATE UNKNOWN","httpStatus":999}"#)
        XCTAssertEqual(RunFailureCategory.resolve(kind: nil, detail: future), .unknown)
        XCTAssertNil(future.httpStatus)
    }

    func testProviderAccessIsNotConfusedWithCastPairingAndRetryIsNotAutomatic() throws {
        let detail = try decode(GatewayChatErrorDetail.self, #"{"failoverReason":"auth_permanent"}"#)
        let category = RunFailureCategory.resolve(kind: nil, detail: detail)
        XCTAssertEqual(category, .authentication)
        XCTAssertTrue(category.message.contains("re-pairing Cast will not fix"))
        XCTAssertTrue(RunFailureCategory.unknown.message.contains("not automatically resent"))
        XCTAssertTrue(RunFailureCategory.timeout.message.contains("completed actions"))
        XCTAssertNil(GatewayFailurePolicy.agentRunAlertMessage(for: "error", errorDetail: detail, runAlreadyAnswered: true))
    }

    @MainActor
    func testFailureIsRecordedForSelectedSessionAndClearingModalRetainsDiagnostic() throws {
        let store = ChatStore(); store.selectedSessionKey = "agent:main:a"
        store.handleEvent(try event("chat", ["sessionKey": "agent:main:a", "runId": "failure", "state": "error",
                                           "errorDetail": ["failoverReason": "model_not_found"]]))
        XCTAssertEqual(store.sessionFailures["agent:main:a"]?.category, .modelUnavailable)
        XCTAssertNil(store.contextCompactionOfferKey)
        store.clearError()
        XCTAssertNil(store.lastError)
        XCTAssertNotNil(store.sessionFailures["agent:main:a"])
        store.handleEvent(try event("chat", ["sessionKey": "agent:main:b", "runId": "other", "state": "error", "errorKind": "timeout"]))
        XCTAssertNil(store.lastError)
        XCTAssertNil(store.sessionFailures["agent:main:b"])
        XCTAssertTrue(ChatStore().sessionFailures.isEmpty)
    }

    @MainActor
    func testCompactionOfferRequiresAdvertisedCapabilityEvenForStructuredOverflow() throws {
        let store = ChatStore(); store.selectedSessionKey = "agent:main:a"
        let failure: [String: Any] = ["sessionKey": "agent:main:a", "runId": "overflow", "state": "error",
                                      "errorDetail": ["failoverReason": "context_overflow"]]
        store.handleEvent(try event("chat", failure))
        XCTAssertNil(store.contextCompactionOfferKey)
        store.handleEvent(try event("cast.hello", ["features": ["methods": ["sessions.compact"]]]))
        store.handleEvent(try event("chat", failure))
        XCTAssertEqual(store.contextCompactionOfferKey, "agent:main:a")
        store.handleEvent(try event("cast.hello", [:]))
        XCTAssertNil(store.contextCompactionOfferKey)
    }

    @MainActor
    func testCompactionEventsAreSessionAndOperationScopedAndSkippedIsNotSuccess() throws {
        let store = ChatStore()
        func operation(_ key: String, _ id: String, _ phase: String, completed: Bool = false) throws -> EventFrame {
            try event("session.operation", ["sessionKey": key, "operationId": id, "operation": "compact", "phase": phase, "completed": completed])
        }
        store.handleEvent(try operation("a", "one", "start"))
        store.handleEvent(try operation("b", "other", "end", completed: true))
        XCTAssertEqual(store.sessionCompactions["a"]?.phase, .running)
        XCTAssertEqual(store.sessionCompactions["b"]?.phase, .completed)
        store.handleEvent(try operation("a", "two", "start"))
        store.handleEvent(try operation("a", "one", "end", completed: true))
        XCTAssertEqual(store.sessionCompactions["a"]?.phase, .running)
        store.handleEvent(try operation("a", "two", "end"))
        XCTAssertEqual(store.sessionCompactions["a"]?.phase, .notCompleted)
        store.handleEvent(try operation("a", "two", "start"))
        XCTAssertEqual(store.sessionCompactions["a"]?.phase, .notCompleted)
        store.handleEvent(try operation("a", "one", "end", completed: true))
        XCTAssertEqual(store.sessionCompactions["a"]?.phase, .notCompleted)
    }

    @MainActor
    func testGatewayTimestampRejectsStaleCompactionButAcceptsNewUnobservedCompletion() throws {
        let store = ChatStore()
        func operation(_ id: String, _ phase: String, _ ts: Double) throws -> EventFrame {
            try event("session.operation", ["sessionKey": "a", "operationId": id, "operation": "compact", "phase": phase, "completed": true, "ts": ts])
        }
        store.handleEvent(try operation("new", "start", 200))
        store.handleEvent(try operation("old", "start", 100))
        store.handleEvent(try operation("old", "end", 150))
        XCTAssertEqual(store.sessionCompactions["a"]?.operationID, "new")
        XCTAssertEqual(store.sessionCompactions["a"]?.phase, .running)
        store.handleEvent(try operation("later", "end", 300))
        XCTAssertEqual(store.sessionCompactions["a"]?.operationID, "later")
        XCTAssertEqual(store.sessionCompactions["a"]?.phase, .completed)
    }

    @MainActor
    func testGapAndBackgroundMakeCompactionUnconfirmedRatherThanCompleted() throws {
        let store = ChatStore()
        let start = try event("session.operation", ["sessionKey": "a", "operationId": "op", "operation": "compact", "phase": "start"])
        store.handleEvent(start)
        store.handleEvent(try event("cast.seqGap", [:]))
        XCTAssertEqual(store.sessionCompactions["a"]?.phase, .interrupted)
        store.handleEvent(try event("session.operation", ["sessionKey": "a", "operationId": "op2", "operation": "compact", "phase": "start"]))
        store.suspendForBackground()
        XCTAssertEqual(store.sessionCompactions["a"]?.phase, .interrupted)
    }

    func testStaleContextIsNotPresentedAsLiveAndSurvivesUnreadUpdatesAndPersistence() throws {
        let row = try decode(SessionRow.self, #"{"key":"a","totalTokens":90000,"contextTokens":100000,"totalTokensFresh":false}"#)
        XCTAssertNil(row.contextFillFraction)
        XCTAssertTrue(row.contextUsageSummary.contains("Stale"))
        let restored = try JSONDecoder().decode(SessionRow.self, from: JSONEncoder().encode(row.settingUnread(true)))
        XCTAssertEqual(restored.totalTokensFresh, false)
        XCTAssertNil(restored.contextFillFraction)
        let unknown = try decode(SessionRow.self, #"{"key":"a","totalTokens":-1,"contextTokens":100}"#)
        XCTAssertEqual(unknown.contextUsageSummary, "Not reported by this gateway")
    }
}
