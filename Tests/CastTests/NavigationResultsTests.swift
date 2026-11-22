import Foundation
import XCTest
@testable import Cast

final class NavigationResultsTests: XCTestCase {
    private func row(_ key: String, _ extra: [String: Any] = [:]) throws -> SessionRow {
        var data: [String: Any] = ["key": key, "sessionId": "id-" + key, "displayName": key]
        data.merge(extra) { _, new in new }
        return try JSONDecoder().decode(SessionRow.self, from: JSONSerialization.data(withJSONObject: data))
    }

    private func item(_ id: String, kind: String, target: String, title: String = "result",
                      session: String = "agent:main:a", sharedAt: Double? = 1, artifactID: String? = nil,
                      mime: String? = nil, size: Int? = nil) -> Deliverable {
        Deliverable(id: id, sessionKey: session, messageID: "m-" + id, title: title, target: target, kind: kind,
                    sharedAt: sharedAt, artifactID: artifactID, sizeBytes: size, mimeType: mime)
    }

    private func attention(_ id: String, _ kind: AttentionItem.Kind) -> AttentionItem {
        AttentionItem(id: id, kind: kind, sessionKey: "agent:main:a", title: id, detail: "", referenceID: nil)
    }

    // MARK: Tab counts

    func testNeedsYouBadgeExcludesReviewItemsAndDuplicates() {
        let items = [attention("q", .question), attention("a", .approval), attention("r", .review),
                     attention("f", .failure), attention("q", .question)]
        XCTAssertEqual(CastNavigationCounts.needsYou(items), 3, "Reviews belong to Results; duplicate ids count once")
        XCTAssertEqual(CastNavigationCounts.needsYou([]), 0)
    }

    func testResultsBadgeCountsOnlyUnreviewedGatewayArtifacts() {
        let ledger = [
            item("f1", kind: "Attachment", target: "artifact:f1", session: "agent:main:a", artifactID: "f1"),
            item("f2", kind: "Attachment", target: "artifact:f2", session: "agent:main:b", artifactID: "f2"),
            item("f3", kind: "Attachment", target: "artifact:f3", session: "agent:main:b", artifactID: "f3"),
            item("l1", kind: "Pull request", target: "https://github.com/o/r/pull/7"),
        ]
        let reviewed: Set<String> = [ledger[2].reviewID]
        let counts = ResultArtifactCounts.index(ledger: ledger, reviewed: reviewed)
        XCTAssertEqual(CastNavigationCounts.results(counts), 2, "Plain links never inflate the badge; reviewed files drop out")
    }

    // MARK: Pinned switcher

    func testPinnedSwitcherKeepsGivenPinnedOrderAndMarksSelection() throws {
        let rows = try ["agent:main:c", "agent:main:a", "agent:main:b", "agent:main:x"].map { try row($0) }
        let pinned: Set<String> = ["agent:main:c", "agent:main:a", "agent:main:b"]
        let entries = PinnedSwitcher.entries(
            chats: rows,
            isPinned: { pinned.contains($0) },
            title: { $0.key.uppercased() },
            selectedKey: "agent:main:a",
            unread: { $0.key == "agent:main:b" },
            states: [SessionKeyMatcher.canonical("agent:main:c"): .working])
        XCTAssertEqual(entries.map(\.key), ["agent:main:c", "agent:main:a", "agent:main:b"],
                       "The switcher must never re-sort pinned chats by activity")
        XCTAssertEqual(entries.filter(\.isSelected).map(\.key), ["agent:main:a"])
        XCTAssertEqual(entries.filter(\.unread).map(\.key), ["agent:main:b"])
        XCTAssertEqual(entries.first?.state, .working)
        XCTAssertNil(entries.last?.state, "No signal yields no state, never a guess")
    }

    func testPinnedSwitcherDeduplicatesCanonicalKeys() throws {
        let rows = try [row("agent:main:a"), row("agent:main:a")]
        let entries = PinnedSwitcher.entries(chats: rows, isPinned: { _ in true }, title: { $0.key },
                                             selectedKey: nil, unread: { _ in false }, states: [:])
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].isSelected)
    }

    @MainActor func testStorePersonalChatsFeedSwitcherInUserPinnedRank() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ChatStore(profile: .init(id: "nav-tests", name: "Test", gatewayURL: URL(string: "wss://example.invalid")!, accent: "blue"),
                              transcriptCacheRoot: root, operationsLedgerRoot: root)
        store.isNotificationContextVisible = false
        let a = "agent:main:cast-chat-11111111-1111-4111-8111-111111111111"
        let b = "agent:main:cast-chat-22222222-2222-4222-8222-222222222222"
        let c = "agent:main:cast-chat-33333333-3333-4333-8333-333333333333"
        store.installSessionSnapshotForTesting([try row(a), try row(b), try row(c)])
        for key in [a, b, c] { store.keepPersonalChat(key) }
        store.updatePersonalChat(a) { $0.pinned = true; $0.rank = 0 }
        store.updatePersonalChat(b) { $0.pinned = true; $0.rank = 1 }
        store.movePinnedChat(b, by: -1)
        store.setDraft("half-written", forSession: a)
        let entries = PinnedSwitcher.entries(
            chats: store.personalChats, isPinned: { store.isSessionPinned($0) }, title: { store.chatTitle($0) },
            selectedKey: store.selectedSessionKey, unread: { _ in false }, states: [:])
        XCTAssertEqual(entries.map(\.key), [b, a], "Pinned rank from the store drives the switcher")
        XCTAssertFalse(entries.contains { $0.key == c }, "Unpinned chats stay out of the quick switcher")
        store.selectFromSidebar(b)
        XCTAssertEqual(store.draft(forSession: a), "half-written", "Switching chats keeps the other chat's draft")
    }

    // MARK: Results classification

    func testResultKindClassification() {
        XCTAssertEqual(ResultKind.of(item("1", kind: "Pull request", target: "https://github.com/o/r/pull/12")), .pullRequest)
        XCTAssertEqual(ResultKind.of(item("2", kind: "Image", target: "/tmp/shot.png")), .image)
        XCTAssertEqual(ResultKind.of(item("3", kind: "Attachment", target: "artifact:3", title: "screen.PNG", artifactID: "3")), .image)
        XCTAssertEqual(ResultKind.of(item("4", kind: "Attachment", target: "artifact:4", title: "notes", artifactID: "4", mime: "image/jpeg")), .image)
        XCTAssertEqual(ResultKind.of(item("5", kind: "Attachment", target: "artifact:5", title: "build.patch", artifactID: "5")), .file)
        XCTAssertEqual(ResultKind.of(item("6", kind: "Document", target: "https://example.com/report.pdf")), .file)
        XCTAssertEqual(ResultKind.of(item("7", kind: "Release", target: "https://github.com/o/r/releases/tag/v1")), .link)
        XCTAssertEqual(ResultKind.of(item("8", kind: "Package", target: "/tmp/app.zip")), .file)
    }

    func testPullRequestReferenceParsing() {
        XCTAssertEqual(PullRequestReference.parse("https://github.com/openclaw/cast/pull/42")?.display, "openclaw/cast #42")
        XCTAssertEqual(PullRequestReference.parse("https://www.github.com/o/r/pull/9/files")?.number, 9)
        XCTAssertNil(PullRequestReference.parse("https://gitlab.com/o/r/pull/9"))
        XCTAssertNil(PullRequestReference.parse("https://github.com/o/r/issues/9"))
        XCTAssertNil(PullRequestReference.parse("https://github.com/o/r/pull/zero"))
    }

    func testSubtitlesAreTruthful() {
        XCTAssertEqual(ResultsLibrary.subtitle(for: item("1", kind: "Pull request", target: "https://github.com/o/r/pull/3")), "o/r #3")
        XCTAssertEqual(ResultsLibrary.subtitle(for: item("2", kind: "Release", target: "https://example.com/releases/1")), "example.com")
        let sized = ResultsLibrary.subtitle(for: item("3", kind: "Attachment", target: "artifact:3", title: "a.md", artifactID: "3", size: 2048))
        XCTAssertTrue(sized.hasPrefix("MD · "), sized)
        XCTAssertEqual(ResultsLibrary.subtitle(for: item("4", kind: "Attachment", target: "artifact:4", title: "a.md", artifactID: "4")), "MD",
                       "No size is shown when the gateway did not report one")
    }

    func testLibraryItemsFilterSearchSortAndDeduplicate() {
        let ledger = [
            item("old", kind: "Image", target: "/a.png", title: "older shot", sharedAt: 10),
            item("new", kind: "Image", target: "/b.png", title: "newer shot", sharedAt: 20),
            item("pr", kind: "Pull request", target: "https://github.com/o/r/pull/1", title: "Fix nav", sharedAt: 15),
            item("new", kind: "Image", target: "/b.png", title: "newer shot", sharedAt: 20),
        ]
        XCTAssertEqual(ResultsLibrary.items(ledger, kind: nil, query: "").map(\.id), ["new", "pr", "old"])
        XCTAssertEqual(ResultsLibrary.items(ledger, kind: .image, query: "").map(\.id), ["new", "old"])
        XCTAssertEqual(ResultsLibrary.items(ledger, kind: nil, query: "fix").map(\.id), ["pr"])
        XCTAssertEqual(ResultsLibrary.counts(ledger), [.image: 2, .pullRequest: 1])
    }

    // MARK: Results states

    func testPhaseNeverHidesCachedItemsAndReportsHonestStates() {
        // Cached items always show, even offline or after a failed refresh.
        XCTAssertEqual(ResultsLibrary.phase(itemCount: 3, syncing: false, hasSynced: true, syncError: "boom", supportsArtifacts: true, connected: false), .content)
        XCTAssertEqual(ResultsLibrary.phase(itemCount: 0, syncing: true, hasSynced: false, syncError: nil, supportsArtifacts: true, connected: true), .loading)
        XCTAssertEqual(ResultsLibrary.phase(itemCount: 0, syncing: false, hasSynced: true, syncError: nil, supportsArtifacts: true, connected: false), .empty(.offline))
        XCTAssertEqual(ResultsLibrary.phase(itemCount: 0, syncing: false, hasSynced: true, syncError: "Some failed", supportsArtifacts: true, connected: true), .failed("Some failed"))
        XCTAssertEqual(ResultsLibrary.phase(itemCount: 0, syncing: false, hasSynced: true, syncError: nil, supportsArtifacts: false, connected: true), .empty(.unsupported))
        XCTAssertEqual(ResultsLibrary.phase(itemCount: 0, syncing: false, hasSynced: true, syncError: nil, supportsArtifacts: true, connected: true), .empty(.none))
        XCTAssertEqual(ResultsLibrary.phase(itemCount: 0, syncing: false, hasSynced: false, syncError: nil, supportsArtifacts: true, connected: true), .loading,
                       "Before the first refresh finishes, say nothing rather than claim emptiness")
    }

    func testSyncOutcomeMessages() {
        XCTAssertNil(DeliverableSync.Outcome.refreshed.message)
        XCTAssertNotNil(DeliverableSync.Outcome.unsupported.message)
        XCTAssertNotNil(DeliverableSync.Outcome.partialFailure.message)
    }

    func testTabsHaveLabelsAndSymbols() {
        XCTAssertEqual(CastTab.allCases.map(\.title), ["Chats", "Needs You", "Results"])
        XCTAssertTrue(CastTab.allCases.allSatisfy { !$0.systemImage.isEmpty })
    }
}
