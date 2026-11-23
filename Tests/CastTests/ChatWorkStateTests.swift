import Foundation
import SwiftUI
import XCTest
@testable import Cast

final class ChatWorkStateTests: XCTestCase {
    private func row(_ key: String, active: Bool? = nil, status: String? = nil, aborted: Bool? = nil,
                     preview: String? = nil) -> SessionRow {
        SessionRow(key: key, kind: "direct", displayName: key, derivedTitle: nil, lastMessagePreview: preview,
                   channel: nil, updatedAt: 1_784_600_000_000, unread: nil, pinned: nil,
                   hasActiveRun: active, model: nil, status: status, abortedLastRun: aborted)
    }

    private func attention(_ kind: AttentionItem.Kind, _ key: String) -> AttentionItem {
        AttentionItem(id: "\(kind.rawValue):\(key)", kind: kind, sessionKey: key, title: "t", detail: "d", referenceID: nil)
    }

    private func artifact(_ key: String, _ id: String, message: String = "m1") -> Deliverable {
        Deliverable(id: id, sessionKey: key, messageID: message, title: "File \(id)", target: "artifact:\(id)",
                    kind: "Attachment", sharedAt: 1_784_600_000_000, artifactID: id)
    }

    private func link(_ key: String, _ id: String) -> Deliverable {
        Deliverable(id: id, sessionKey: key, messageID: "m1", title: "Report \(id)", target: "https://example.com/\(id).pdf",
                    kind: "Document", sharedAt: 1_784_600_000_000)
    }

    private func states(_ rows: [SessionRow], attention: [AttentionItem] = [], ledger: [Deliverable] = [],
                        reviewed: Set<String> = [], live: String? = nil, liveActive: Bool = false,
                        connected: Bool = true) -> [String: ChatWorkState] {
        ChatWorkStateReducer.states(rows: rows, attention: attention,
            artifactCounts: ResultArtifactCounts.index(ledger: ledger, reviewed: reviewed),
            liveSessionKey: live, liveTurnActive: liveActive, connected: connected)
    }

    func testNoSignalsProduceNoState() {
        XCTAssertTrue(self.states([row("agent:main:a")]).isEmpty, "A quiet chat must not be given an invented state")
    }

    func testOnlyLiveRunsAreWorking() {
        let states = self.states([row("agent:main:a", active: true), row("agent:main:b", status: "queued"),
                                  row("agent:main:c", status: "done"), row("agent:main:d", status: "running")])
        XCTAssertEqual(states["agent:main:a"], .working)
        XCTAssertNil(states["agent:main:b"], "Queued is waiting to start, not working")
        XCTAssertNil(states["agent:main:c"])
        XCTAssertEqual(states["agent:main:d"], .working)
    }

    func testDeliveryFailureDoesNotClaimTheReplyIsMissing() {
        let states = self.states([row("agent:main:a")], attention: [attention(.delivery, "agent:main:a")])
        XCTAssertEqual(states["agent:main:a"], .needsYou(.delivery))
        XCTAssertEqual(ChatWorkState.needsYou(.delivery).label, "Notification not delivered")
    }

    func testInChatCardBelongsToTheLatestTurnAndEndsWhenReviewed() {
        let shared = artifact("agent:main:a", "1")  // sharedAt 1_784_600_000_000
        let unreviewed = ChatResultSummary(sessionKey: "agent:main:a", ledger: [shared], reviewed: [], progressCard: nil)
        XCTAssertTrue(unreviewed.showsInChatCard(latestAssistantTimestamp: 1_784_600_000_000), "Shared by the latest reply")
        XCTAssertFalse(unreviewed.showsInChatCard(latestAssistantTimestamp: 1_784_600_060_000),
                       "A newer reply moves the card out of the transcript; the toolbar stays")
        XCTAssertFalse(unreviewed.showsInChatCard(latestAssistantTimestamp: nil), "No loaded turn, no card")
        let reviewed = ChatResultSummary(sessionKey: "agent:main:a", ledger: [shared], reviewed: [shared.reviewID],
                                         progressCard: nil)
        XCTAssertFalse(reviewed.showsInChatCard(latestAssistantTimestamp: 1_784_600_000_000), "Reviewed: no permanent card")
        let undated = Deliverable(id: "u", sessionKey: "agent:main:a", messageID: "m", title: "t", target: "artifact:u",
                              kind: "Attachment", sharedAt: nil, artifactID: "u")
        XCTAssertFalse(ChatResultSummary(sessionKey: "agent:main:a", ledger: [undated], reviewed: [], progressCard: nil)
            .showsInChatCard(latestAssistantTimestamp: 1), "Unknown share time is not attributed to a turn")
    }

    func testRunStatusWordsDoNotInventIdle() {
        XCTAssertEqual(ResultRunFacts.statusWord(nil), "Not reported")
        XCTAssertEqual(ResultRunFacts.statusWord("killed"), "Stopped")
        XCTAssertEqual(ResultRunFacts.statusWord("weird"), "Reported as “weird”")
        let facts = ResultRunFacts(row: row("agent:main:a", status: "done"), agentName: nil, isLiveTurn: false)
        XCTAssertTrue(facts.facts.contains { $0.label.hasPrefix("Est. cost") } == false)
        XCTAssertEqual(facts.facts.first { $0.label == "Run" }?.value, "Finished")
    }

    func testDisconnectedWorkingIsLastKnownButStillFilteredAsWorking() {
        let states = self.states([row("agent:main:a", active: true), row("agent:main:b")], live: "b",
                                 liveActive: true, connected: false)
        XCTAssertEqual(states["agent:main:a"], .workingLastKnown)
        XCTAssertEqual(states["agent:main:b"], .workingLastKnown)
        XCTAssertEqual(ChatWorkState.workingLastKnown.filter, .working)
        XCTAssertNotEqual(ChatWorkState.workingLastKnown.label, ChatWorkState.working.label)
    }

    func testLiveTurnOnSelectedChatIsWorkingBeforeInventoryCatchesUp() {
        let states = self.states([row("agent:main:a", active: false), row("agent:main:b")], live: "a", liveActive: true)
        XCTAssertEqual(states["agent:main:a"], .working, "Short key must match canonical row key")
        XCTAssertNil(states["agent:main:b"])
        XCTAssertNil(self.states([row("agent:main:a")], live: "a", liveActive: false)["agent:main:a"])
    }

    func testQuestionsAndApprovalsOutrankWorking() {
        let states = self.states([row("agent:main:a", active: true), row("agent:main:b", active: true)],
                                 attention: [attention(.question, "agent:main:a"), attention(.approval, "b")])
        XCTAssertEqual(states["agent:main:a"], .needsYou(.question))
        XCTAssertEqual(states["agent:main:b"], .needsYou(.approval))
    }

    func testEarlierFailureYieldsToNewRunButShowsWhenIdle() {
        let failure = [attention(.failure, "agent:main:a")]
        XCTAssertEqual(self.states([row("agent:main:a", active: true)], attention: failure)["agent:main:a"], .working)
        XCTAssertEqual(self.states([row("agent:main:a", status: "failed")], attention: failure)["agent:main:a"],
                       .needsYou(.failure))
    }

    func testFailureWordingFollowsTheActualSignal() {
        let rows = [row("agent:main:typed", status: "timeout"),
                    row("agent:main:stopped", aborted: true),
                    row("agent:main:heuristic", preview: "Deploy failed on step 3"),
                    row("agent:main:killed", status: "killed")]
        let states = self.states(rows, attention: rows.map { attention(.failure, $0.key) })
        XCTAssertEqual(states["agent:main:typed"], .needsYou(.failure))
        XCTAssertEqual(states["agent:main:killed"], .needsYou(.failure))
        XCTAssertEqual(states["agent:main:stopped"], .needsYou(.stopped), "A bare abort is not a failed run")
        XCTAssertEqual(states["agent:main:heuristic"], .needsYou(.checkReply), "Preview text is only a hint")
        XCTAssertEqual(ChatWorkState.needsYou(.stopped).label, "Last run stopped")
        XCTAssertFalse(ChatWorkState.needsYou(.checkReply).label.localizedCaseInsensitiveContains("failed"))
    }

    func testOnlyGatewayArtifactsProduceReviewState() {
        let ledger = [link("agent:main:links", "1"), link("agent:main:links", "2"),
                      artifact("agent:main:files", "3"), artifact("agent:main:files", "4"),
                      artifact("agent:main:files", "4"), artifact("agent:main:z", "5")]
        let states = self.states([row("agent:main:links"), row("agent:main:files"), row("agent:main:none")], ledger: ledger)
        XCTAssertNil(states["agent:main:links"], "Ordinary links in prose must not create a review state")
        XCTAssertEqual(states["agent:main:files"], .readyToReview(count: 2))
        XCTAssertNil(states["agent:main:none"])
        XCTAssertNil(states["agent:main:z"], "Rows not passed in are never classified")
        XCTAssertEqual(ChatWorkState.readyToReview(count: 2).label, "Ready to review")
        XCTAssertEqual(ChatWorkState.readyToReview(count: 2).accessibilityLabel, "Ready to review, 2 files")
    }

    func testReviewedArtifactsClearTheStateAndCountsIndexCanonically() {
        let items = [artifact("files", "1"), artifact("agent:main:files", "2")]
        let counts = ResultArtifactCounts.index(ledger: items + [link("files", "9")], reviewed: [items[0].reviewID])
        XCTAssertEqual(counts["agent:main:files"], ResultArtifactCounts(total: 2, unreviewed: 1))
        let all = self.states([row("agent:main:files")], ledger: items, reviewed: Set(items.map(\.reviewID)))
        XCTAssertNil(all["agent:main:files"], "No positive 'all clear' state is ever shown")
    }

    func testWorkingOutranksReview() {
        XCTAssertEqual(self.states([row("agent:main:a", active: true)], ledger: [artifact("agent:main:a", "1")])["agent:main:a"],
                       .working)
    }

    func testFilterPreservesPinnedUserOrder() {
        let rows = [row("agent:main:pinned-b"), row("agent:main:pinned-a", active: true),
                    row("agent:main:c", active: true), row("agent:main:d")]
        let states = self.states(rows, attention: [attention(.blocked, "agent:main:d")])
        XCTAssertEqual(ChatWorkStateReducer.filter(rows, by: .working, states: states).map(\.key),
                       ["agent:main:pinned-a", "agent:main:c"])
        XCTAssertEqual(ChatWorkStateReducer.filter(rows, by: .needsYou, states: states).map(\.key), ["agent:main:d"])
        XCTAssertEqual(ChatWorkStateReducer.filter(rows, by: .all, states: states).map(\.key), rows.map(\.key))
    }

    // MARK: - Result provenance

    func testResultSummaryUsesOnlyArtifactsAndNeverClaimsChecks() throws {
        let card = try JSONDecoder().decode(ProgressCard.self, from: Data("""
        {"sessionKey":"agent:main:a","revision":2,"updatedAt":1784600000000,
         "steps":[{"step":"Build","status":"completed"},{"step":"Test","status":"in_progress"}]}
        """.utf8))
        let ledger = [artifact("agent:main:a", "1"), link("agent:main:a", "L"), artifact("agent:main:b", "2"),
                      artifact("a", "3")]
        let summary = ChatResultSummary(sessionKey: "agent:main:a", ledger: ledger,
                                        reviewed: [ledger[0].reviewID], progressCard: card)
        XCTAssertEqual(summary.items.map(\.id), ["1", "3"], "Excludes links and other chats; matches canonical keys")
        XCTAssertEqual(summary.unreviewedCount, 1)
        XCTAssertEqual(summary.latest?.id, "3", "Newest unreviewed result leads")
        XCTAssertEqual(summary.progress, .agentReported(completed: 1, total: 2))
        XCTAssertEqual(summary.checks, .notReported)
        XCTAssertEqual(summary.installation, .notReported)
        XCTAssertFalse(summary.nothingLeftMarkedHere)
    }

    func testLinkOnlyChatHasNoResultSummary() {
        let summary = ChatResultSummary(sessionKey: "agent:main:a", ledger: [link("agent:main:a", "1")],
                                        reviewed: [], progressCard: nil)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertFalse(summary.nothingLeftMarkedHere, "Nothing shared is not the same as reviewed")
    }

    func testResultSummaryWithoutProgressStepsIsNotReported() throws {
        let card = try JSONDecoder().decode(ProgressCard.self, from: Data("""
        {"sessionKey":"agent:main:a","revision":1,"updatedAt":1784600000000,"markdown":"Notes only"}
        """.utf8))
        let summary = ChatResultSummary(sessionKey: "agent:main:a", ledger: [], reviewed: [], progressCard: card)
        XCTAssertEqual(summary.progress, .notReported)
    }

    func testResultSummaryIsBounded() {
        let ledger = (0 ..< 500).map { artifact("agent:main:a", "\($0)") }
        XCTAssertEqual(ChatResultSummary(sessionKey: "agent:main:a", ledger: ledger, reviewed: [], progressCard: nil).items.count, 200)
    }

    func testRunFactsListUnknownsInsteadOfInventingThem() {
        let facts = ResultRunFacts(row: row("agent:main:a"), agentName: nil, isLiveTurn: false)
        XCTAssertFalse(facts.facts.contains { $0.label == "Machine" || $0.label == "Agent" })
        XCTAssertTrue(facts.notReported.contains("machine"))
        XCTAssertTrue(facts.notReported.contains("model"), "No session model reported means unknown, not a default")
        XCTAssertEqual(facts.facts.first { $0.label == "Run" }?.value, "Not reported")
        let live = ResultRunFacts(row: row("agent:main:a"), agentName: "Cast", isLiveTurn: true)
        XCTAssertEqual(live.facts.first { $0.label == "Run" }?.value, "Active now")
        XCTAssertEqual(live.facts.first { $0.label == "Agent" }?.value, "Cast")
    }

    func testStepWordingSeparatesDeclaredPhaseFromLiveness() {
        XCTAssertEqual(ResultReviewPanel<EmptyView>.stepStatus(.pending, live: false), "Not started")
        XCTAssertEqual(ResultReviewPanel<EmptyView>.stepStatus(.inProgress, live: true), "In progress")
        XCTAssertEqual(ResultReviewPanel<EmptyView>.stepStatus(.inProgress, live: false), "In progress, not currently running")
    }

    // MARK: - Progress markup

    func testProgressMarkupAcceptsAnyAttributeOrderAndLabels() {
        let parsed = ProgressMarkup.parse("""
        Reviewing.
        <progress aria-label="PRs reviewed · 12/30" value="12" max="30">12/30</progress>
        <progress max='4' value='5'></progress>
        <progress value="2" max="5" />
        <progress aria-label="broken" max="9"></progress>
        """)
        XCTAssertEqual(parsed.stripped, "Reviewing.")
        XCTAssertEqual(parsed.bars, [
            ProgressMarkup.Bar(value: 12, max: 30, label: "PRs reviewed · 12/30"),
            ProgressMarkup.Bar(value: 4, max: 4, label: nil),
            ProgressMarkup.Bar(value: 2, max: 5, label: nil),
        ], "Attribute order is free, values clamp, and a tag without value is dropped, not printed")
        XCTAssertFalse(parsed.stripped.contains("<progress"))
    }

    func testProgressMarkupDecodesEntitiesAndLeavesPlainMarkdownAlone() {
        let parsed = ProgressMarkup.parse(#"<progress value="1" max="2" aria-label="A &amp; B"></progress>"#)
        XCTAssertEqual(parsed.bars.first?.label, "A & B")
        XCTAssertEqual(ProgressMarkup.parse("**plain** text").stripped, "**plain** text")
    }
}

@MainActor
final class ChatWorkStoreTests: XCTestCase {
    private func makeStore() -> ChatStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CastWorkState-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ChatStore(profile: .init(id: "work-state", name: "Test",
                                        gatewayURL: URL(string: "wss://example.invalid")!, accent: "blue"),
                         transcriptCacheRoot: root, operationsLedgerRoot: root.appendingPathComponent("operations"))
    }

    func testSideChatAndResultReviewAreMutuallyExclusive() {
        let store = self.makeStore()
        store.presentResultReview()
        XCTAssertTrue(store.isResultReviewPresented)
        store.isSideChatPresented = true
        XCTAssertFalse(store.isResultReviewPresented, "Opening Side chat closes Result review")
        store.presentResultReview()
        XCTAssertFalse(store.isSideChatPresented, "Opening Result review closes Side chat")
        XCTAssertTrue(store.isResultReviewPresented)
    }

    func testCachedCountsFollowLedgerAndLocalReviewMarks() {
        let store = self.makeStore()
        let items = [
            Deliverable(id: "1", sessionKey: "agent:main:x", messageID: "m", title: "a", target: "artifact:1",
                        kind: "Attachment", sharedAt: 1, artifactID: "1"),
            Deliverable(id: "2", sessionKey: "agent:main:x", messageID: "m", title: "b", target: "https://e.com/b.pdf",
                        kind: "Document", sharedAt: 1),
        ]
        store.installDeliverablesForTesting(items)
        XCTAssertEqual(store.resultArtifactCounts(for: "x"), ResultArtifactCounts(total: 1, unreviewed: 1))
        XCTAssertNil(store.resultArtifactCounts(for: "agent:main:other"))
        store.markDeliverableReviewed(items[0].reviewID)
        XCTAssertEqual(store.resultArtifactCounts(for: "agent:main:x"), ResultArtifactCounts(total: 1, unreviewed: 0))
        let more = (2..<6).map {
            Deliverable(id: "b\($0)", sessionKey: "agent:main:y", messageID: "m", title: "b", target: "artifact:b\($0)",
                        kind: "Attachment", sharedAt: 1, artifactID: "b\($0)")
        }
        store.installDeliverablesForTesting(items + more)
        store.markDeliverablesReviewed(Array(more.prefix(2)).map(\.reviewID))
        XCTAssertEqual(store.resultArtifactCounts(for: "agent:main:y"), ResultArtifactCounts(total: 4, unreviewed: 2),
                       "Batch marking marks exactly the given items")
        XCTAssertFalse(store.isGatewayConnected)
        XCTAssertNil(store.chatWorkState(for: "agent:main:x"), "Reviewed artifacts and unconnected idle chat: no state")
    }
}
