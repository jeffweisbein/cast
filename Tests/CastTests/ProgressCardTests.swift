import Foundation
import XCTest
@testable import Cast

// MARK: - Model decode tests

final class ProgressCardModelTests: XCTestCase {

    private func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // Full card with markdown and steps
    func testDecodeFullCard() throws {
        let json = """
        {
            "sessionKey": "agent:main:foo",
            "revision": 3,
            "updatedAt": 1784600000000,
            "markdown": "All good.",
            "steps": [
                {"step": "Build", "status": "completed"},
                {"step": "Test", "status": "in_progress"},
                {"step": "Deploy", "status": "pending"}
            ]
        }
        """
        let card = try self.decode(json, as: ProgressCard.self)
        XCTAssertEqual(card.sessionKey, "agent:main:foo")
        XCTAssertEqual(card.revision, 3)
        XCTAssertEqual(card.updatedAt, 1_784_600_000_000)
        XCTAssertEqual(card.markdown, "All good.")
        XCTAssertEqual(card.steps?.count, 3)
        XCTAssertEqual(card.steps?[0].status, .completed)
        XCTAssertEqual(card.steps?[1].status, .inProgress)
        XCTAssertEqual(card.steps?[2].status, .pending)
    }

    // Card with no markdown (only steps)
    func testDecodeCardWithoutMarkdown() throws {
        let json = """
        {
            "sessionKey": "agent:main:bar",
            "revision": 1,
            "updatedAt": 1000000000000,
            "steps": [{"step": "Do thing", "status": "pending"}]
        }
        """
        let card = try self.decode(json, as: ProgressCard.self)
        XCTAssertNil(card.markdown)
        XCTAssertEqual(card.steps?.count, 1)
    }

    // Card with no steps (only markdown)
    func testDecodeCardWithoutSteps() throws {
        let json = """
        {
            "sessionKey": "agent:main:baz",
            "revision": 2,
            "updatedAt": 1000000000000,
            "markdown": "Just a note."
        }
        """
        let card = try self.decode(json, as: ProgressCard.self)
        XCTAssertEqual(card.markdown, "Just a note.")
        XCTAssertNil(card.steps)
    }

    // Null card response from progressCard.get (card field is null)
    func testDecodeNullCardResponse() throws {
        struct Resp: Decodable { let card: ProgressCard? }
        let json = "{\"card\": null}"
        let resp = try self.decode(json, as: Resp.self)
        XCTAssertNil(resp.card)
    }

    // Unknown step status falls back to .unknown
    func testUnknownStatusFallback() throws {
        let json = """
        {
            "sessionKey": "s",
            "revision": 1,
            "updatedAt": 0,
            "steps": [{"step": "x", "status": "future_status_value"}]
        }
        """
        let card = try self.decode(json, as: ProgressCard.self)
        XCTAssertEqual(card.steps?.first?.status, .unknown)
    }

    // Missing required steps field in a step object: lenient decode produces unknown status
    func testMissingStepStatusFallsBackLeniently() throws {
        let json = """
        {
            "sessionKey": "s",
            "revision": 1,
            "updatedAt": 0,
            "steps": [{"step": "x"}]
        }
        """
        // A missing status key makes ProgressStepStatus throw on decode.
        // The entire `steps` array decode fails leniently, so steps is nil.
        // This verifies the ProgressCard lenient decode doesn't crash.
        let card = try? self.decode(json, as: ProgressCard.self)
        // Card still decoded (lenient); steps may be nil or contain fallback.
        // Either outcome is acceptable — just must not throw.
        XCTAssertNotNil(card)
    }

    // updatedAt epoch ms → Date conversion
    func testUpdatedDateEpochMs() throws {
        let json = """
        {"sessionKey": "s", "revision": 1, "updatedAt": 1000000000000}
        """
        let card = try self.decode(json, as: ProgressCard.self)
        // 1_000_000_000_000 ms = 1_000_000_000 s = 2001-09-08T21:46:40Z
        let expected = Date(timeIntervalSince1970: 1_000_000_000)
        XCTAssertEqual(card.updatedDate.timeIntervalSince1970, expected.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    // Step counts
    func testStepCounts() throws {
        let json = """
        {
            "sessionKey": "s", "revision": 1, "updatedAt": 0,
            "steps": [
                {"step": "a", "status": "completed"},
                {"step": "b", "status": "completed"},
                {"step": "c", "status": "in_progress"},
                {"step": "d", "status": "pending"}
            ]
        }
        """
        let card = try self.decode(json, as: ProgressCard.self)
        XCTAssertEqual(card.completedStepCount, 2)
        XCTAssertEqual(card.totalStepCount, 4)
    }

    // Card with no steps: counts are zero
    func testStepCountsWhenNoSteps() throws {
        let json = #"{"sessionKey": "s", "revision": 1, "updatedAt": 0, "markdown": "hi"}"#
        let card = try self.decode(json, as: ProgressCard.self)
        XCTAssertEqual(card.completedStepCount, 0)
        XCTAssertEqual(card.totalStepCount, 0)
    }
}

// MARK: - Store tests

final class ProgressCardStoreTests: XCTestCase {

    @MainActor
    func testProgressCardInitiallyNil() {
        let store = ChatStore()
        XCTAssertNil(store.progressCard(for: "agent:main:foo"))
    }

    @MainActor
    func testToggleCollapsed() {
        let store = ChatStore()
        let key = "agent:main:foo"
        XCTAssertFalse(store.collapsedProgressCardSessions.contains(key))
        store.toggleProgressCardCollapsed(for: key)
        XCTAssertTrue(store.collapsedProgressCardSessions.contains(key))
        store.toggleProgressCardCollapsed(for: key)
        XCTAssertFalse(store.collapsedProgressCardSessions.contains(key))
    }

    @MainActor
    func testHandleProgressCardChangedEventDoesNotCrash() {
        // Verifies the event switch handles "progressCard.changed" without crashing.
        // The async fetch is a no-op (no connected client), so progressCards stays empty.
        let store = ChatStore()
        let event = EventFrame(
            event: "progressCard.changed",
            payload: AnyCodable(["sessionKey": AnyCodable("agent:main:x")]),
            seq: nil)
        store.handleEvent(event)
        // No crash; card stays nil because there's no connected client.
        XCTAssertNil(store.progressCard(for: "agent:main:x"))
    }

    @MainActor
    func testHandleUnknownEventDoesNotCrash() {
        let store = ChatStore()
        let event = EventFrame(event: "progressCard.changed", payload: nil, seq: nil)
        store.handleEvent(event)
        XCTAssertTrue(store.progressCards.isEmpty)
    }
}
