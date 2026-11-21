import Foundation
import XCTest
@testable import Cast

final class ChatWorkStateTests: XCTestCase {
    private func row(_ key: String, active: Bool? = nil, status: String? = nil) -> SessionRow {
        SessionRow(key: key, kind: "direct", displayName: key, derivedTitle: nil, lastMessagePreview: nil,
                   channel: nil, updatedAt: 1_784_600_000_000, unread: nil, pinned: nil,
                   hasActiveRun: active, model: nil, status: status)
    }

    private func attention(_ kind: AttentionItem.Kind, _ key: String) -> AttentionItem {
        AttentionItem(id: "\(kind.rawValue):\(key)", kind: kind, sessionKey: key, title: "t", detail: "d", referenceID: nil)
    }

    private func deliverable(_ key: String, _ id: String, message: String = "m1") -> Deliverable {
        Deliverable(id: id, sessionKey: key, messageID: message, title: "Report \(id)", target: "https://example.com/\(id).pdf",
                    kind: "Document", sharedAt: 1_784_600_000_000)
    }

    func testNoSignalsProduceNoState() {
        let states = ChatWorkStateReducer.states(rows: [row("agent:main:a")], attention: [],
            unreviewedDeliverables: [], liveSessionKey: nil, liveTurnActive: false)
        XCTAssertTrue(states.isEmpty, "A quiet chat must not be given an invented state")
    }

    func testActiveRunAndQueuedStatusAreWorking() {
        let states = ChatWorkStateReducer.states(
            rows: [row("agent:main:a", active: true), row("agent:main:b", status: "queued"), row("agent:main:c", status: "done")],
            attention: [], unreviewedDeliverables: [], liveSessionKey: nil, liveTurnActive: false)
        XCTAssertEqual(states["agent:main:a"], .working)
        XCTAssertEqual(states["agent:main:b"], .working)
        XCTAssertNil(states["agent:main:c"])
    }

    func testLiveTurnOnSelectedChatIsWorkingBeforeInventoryCatchesUp() {
        let states = ChatWorkStateReducer.states(rows: [row("agent:main:a", active: false), row("agent:main:b")],
            attention: [], unreviewedDeliverables: [], liveSessionKey: "a", liveTurnActive: true)
        XCTAssertEqual(states["agent:main:a"], .working, "Short key must match canonical row key")
        XCTAssertNil(states["agent:main:b"])
        let idle = ChatWorkStateReducer.states(rows: [row("agent:main:a")], attention: [],
            unreviewedDeliverables: [], liveSessionKey: "a", liveTurnActive: false)
        XCTAssertNil(idle["agent:main:a"])
    }

    func testQuestionsAndApprovalsOutrankWorking() {
        let states = ChatWorkStateReducer.states(
            rows: [row("agent:main:a", active: true), row("agent:main:b", active: true)],
            attention: [attention(.question, "agent:main:a"), attention(.approval, "b")],
            unreviewedDeliverables: [], liveSessionKey: nil, liveTurnActive: false)
        XCTAssertEqual(states["agent:main:a"], .needsYou(.question))
        XCTAssertEqual(states["agent:main:b"], .needsYou(.approval))
    }

    func testEarlierFailureYieldsToNewRunButShowsWhenIdle() {
        let failure = [attention(.failure, "agent:main:a")]
        let running = ChatWorkStateReducer.states(rows: [row("agent:main:a", active: true)], attention: failure,
            unreviewedDeliverables: [], liveSessionKey: nil, liveTurnActive: false)
        XCTAssertEqual(running["agent:main:a"], .working)
        let idle = ChatWorkStateReducer.states(rows: [row("agent:main:a")], attention: failure,
            unreviewedDeliverables: [], liveSessionKey: nil, liveTurnActive: false)
        XCTAssertEqual(idle["agent:main:a"], .needsYou(.failure))
    }

    func testReviewCountsOnlyUnreviewedAndDeduplicates() {
        let items = [deliverable("agent:main:a", "1"), deliverable("agent:main:a", "2"),
                     deliverable("agent:main:a", "2"), deliverable("agent:main:z", "3")]
        let states = ChatWorkStateReducer.states(rows: [row("agent:main:a"), row("agent:main:b")], attention: [],
            unreviewedDeliverables: items, liveSessionKey: nil, liveTurnActive: false)
        XCTAssertEqual(states["agent:main:a"], .readyToReview(count: 2))
        XCTAssertNil(states["agent:main:b"])
        XCTAssertNil(states["agent:main:z"], "Rows not passed in are never classified")
        XCTAssertEqual(ChatWorkState.readyToReview(count: 2).label, "2 results to review")
        XCTAssertEqual(ChatWorkState.readyToReview(count: 1).label, "Ready to review")
    }

    func testWorkingOutranksReview() {
        let states = ChatWorkStateReducer.states(rows: [row("agent:main:a", active: true)], attention: [],
            unreviewedDeliverables: [deliverable("agent:main:a", "1")], liveSessionKey: nil, liveTurnActive: false)
        XCTAssertEqual(states["agent:main:a"], .working)
    }

    func testFilterPreservesPinnedUserOrder() {
        let rows = [row("agent:main:pinned-b"), row("agent:main:pinned-a", active: true),
                    row("agent:main:c", active: true), row("agent:main:d")]
        let states = ChatWorkStateReducer.states(rows: rows, attention: [attention(.blocked, "agent:main:d")],
            unreviewedDeliverables: [], liveSessionKey: nil, liveTurnActive: false)
        XCTAssertEqual(ChatWorkStateReducer.filter(rows, by: .working, states: states).map(\.key),
                       ["agent:main:pinned-a", "agent:main:c"])
        XCTAssertEqual(ChatWorkStateReducer.filter(rows, by: .needsYou, states: states).map(\.key), ["agent:main:d"])
        XCTAssertEqual(ChatWorkStateReducer.filter(rows, by: .all, states: states).map(\.key), rows.map(\.key))
    }

    // MARK: - Result provenance

    func testResultSummaryNeverClaimsChecksOrInstallation() throws {
        let card = try JSONDecoder().decode(ProgressCard.self, from: Data("""
        {"sessionKey":"agent:main:a","revision":2,"updatedAt":1784600000000,
         "steps":[{"step":"Build","status":"completed"},{"step":"Test","status":"in_progress"}]}
        """.utf8))
        let ledger = [deliverable("agent:main:a", "1"), deliverable("agent:main:b", "2"), deliverable("a", "3")]
        let summary = ChatResultSummary(sessionKey: "agent:main:a", ledger: ledger,
                                        reviewed: [ledger[0].reviewID], progressCard: card)
        XCTAssertEqual(summary.items.map(\.id), ["1", "3"], "Matches canonical keys, excludes other chats")
        XCTAssertEqual(summary.unreviewedCount, 1)
        XCTAssertEqual(summary.latest?.id, "3", "Newest unreviewed result leads")
        XCTAssertEqual(summary.progress, .agentReported(completed: 1, total: 2))
        XCTAssertEqual(summary.checks, .notReported)
        XCTAssertEqual(summary.installation, .notReported)
        XCTAssertFalse(summary.allReviewed)
    }

    func testResultSummaryWithoutProgressStepsIsNotReported() throws {
        let card = try JSONDecoder().decode(ProgressCard.self, from: Data("""
        {"sessionKey":"agent:main:a","revision":1,"updatedAt":1784600000000,"markdown":"Notes only"}
        """.utf8))
        let summary = ChatResultSummary(sessionKey: "agent:main:a", ledger: [], reviewed: [], progressCard: card)
        XCTAssertEqual(summary.progress, .notReported)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertFalse(summary.allReviewed, "Nothing shared is not the same as reviewed")
    }

    func testResultSummaryIsBounded() {
        let ledger = (0 ..< 500).map { deliverable("agent:main:a", "\($0)") }
        let summary = ChatResultSummary(sessionKey: "agent:main:a", ledger: ledger, reviewed: [], progressCard: nil)
        XCTAssertEqual(summary.items.count, 200)
    }

    func testRunFactsListUnknownsInsteadOfInventingThem() {
        let facts = ResultRunFacts(row: row("agent:main:a"), agentName: nil, isLiveTurn: false)
        XCTAssertFalse(facts.facts.contains { $0.label == "Machine" || $0.label == "Agent" })
        XCTAssertTrue(facts.notReported.contains("machine"))
        XCTAssertTrue(facts.notReported.contains("model"), "No session model reported means unknown, not a default")
        XCTAssertEqual(facts.facts.first { $0.label == "Run" }?.value, "Idle")
        let live = ResultRunFacts(row: row("agent:main:a"), agentName: "Cast", isLiveTurn: true)
        XCTAssertEqual(live.facts.first { $0.label == "Run" }?.value, "Active now")
        XCTAssertEqual(live.facts.first { $0.label == "Agent" }?.value, "Cast")
    }
}
