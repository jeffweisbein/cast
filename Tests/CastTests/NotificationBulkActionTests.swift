import Foundation
import XCTest
@testable import Cast

final class NotificationBulkActionTests: XCTestCase {
    func testBulkReadPreservesOtherWorkspacesAndDedupeAfterReload() throws {
        var ledger = NotificationDeliveryLedger()
        let now = Date()
        for (id, workspace, key) in [("one", "home", "main"), ("two", "home", "agent:main:other"), ("three", "work", "main")] {
            ledger.observe(dedupeID: id, linkage: .init(workspaceID: workspace, sessionKey: key), at: now)
            ledger.markEligible(dedupeID: id, at: now)
        }
        XCTAssertEqual(ledger.markRead(workspaceID: "home", sessionKey: "agent:main:main", at: now), ["one"])
        XCTAssertEqual(ledger.record(dedupeID: "two")?.state, .eligible)
        XCTAssertEqual(ledger.markRead(workspaceID: "home", at: now), ["two"])
        XCTAssertEqual(ledger.record(dedupeID: "three")?.state, .eligible)
        XCTAssertTrue(ledger.markRead(workspaceID: "home", at: now).isEmpty)
        var restored = try JSONDecoder().decode(NotificationDeliveryLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.observe(dedupeID: "one", linkage: .init(workspaceID: "home", sessionKey: "main"), at: now), .duplicate)
        XCTAssertEqual(restored.markDelivered(dedupeID: "one", at: now), .invalidTransition)
        XCTAssertEqual(restored.record(dedupeID: "one")?.state, .read)
    }

    func testBulkUnreadClearPreservesWatermarksAliasesAndNewReplies() throws {
        var ledger = UnreadLedger(workspaces: [
            "home": .init(sessions: [
                "main": .init(count: 2, highestObservedWatermark: 10, recentEventIDs: ["old"]),
                "paged-out": .init(count: 1, highestObservedWatermark: 30),
            ]),
            "work": .init(sessions: ["main": .init(count: 4)]),
        ])
        ledger.clearAll(workspaceID: "home", sessionWatermarks: ["agent:main:main": 20])
        XCTAssertEqual(ledger.unreadCount(workspaceID: "home"), 0)
        XCTAssertEqual(ledger.unreadCount(workspaceID: "work"), 4)
        XCTAssertEqual(ledger.state(workspaceID: "home", sessionKey: "main")?.clearedThroughWatermark, 20)
        XCTAssertEqual(ledger.state(workspaceID: "home", sessionKey: "paged-out")?.clearedThroughWatermark, 30)
        ledger = try JSONDecoder().decode(UnreadLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(ledger.observeUnread(workspaceID: "home", sessionKey: "main", eventID: "old", watermark: 10), .duplicate)
        XCTAssertEqual(ledger.observeUnread(workspaceID: "home", sessionKey: "main", eventID: "late", watermark: 20), .stale)
        XCTAssertEqual(ledger.observeUnread(workspaceID: "home", sessionKey: "main", eventID: "new", watermark: 21), .incremented)
    }

    @MainActor
    func testReadReceiptQueueSerializesAndCoalescesWithoutBlockingCaller() async {
        let queue = ReadReceiptQueue()
        let started = expectation(description: "First receipt started")
        let finished = expectation(description: "Latest queued receipts finish")
        finished.expectedFulfillmentCount = 2
        var release: CheckedContinuation<Void, Never>?
        var active = 0
        var peak = 0
        var calls: [String] = []
        queue.enqueue(key: "first") {
            active += 1
            peak = max(peak, active)
            calls.append("first")
            await withCheckedContinuation { continuation in
                release = continuation
                started.fulfill()
            }
            active -= 1
        }
        XCTAssertTrue(calls.isEmpty, "Enqueue must never wait for the gateway")
        await fulfillment(of: [started], timeout: 2)
        queue.enqueue(key: "second") { XCTFail("Superseded queued receipt ran") }
        queue.enqueue(key: "second") {
            active += 1
            peak = max(peak, active)
            await Task.yield()
            calls.append("second")
            active -= 1
            finished.fulfill()
        }
        queue.enqueue(key: "third") {
            active += 1
            peak = max(peak, active)
            await Task.yield()
            calls.append("third")
            active -= 1
            finished.fulfill()
        }
        XCTAssertEqual(calls, ["first"])
        release?.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(Set(calls), ["first", "second", "third"])
    }

    @MainActor
    func testPendingReadDoesNotResurrectOnPollOrClearNewerReply() async throws {
        let (store, row) = try self.makeReadReceiptStore()
        store.markAllRead()
        let started = expectation(description: "Receipt waiting")
        let returned = expectation(description: "Receipt returned")
        var release: CheckedContinuation<Void, Never>?
        store.enqueueReadReceipt(row) {
            await withCheckedContinuation { continuation in
                release = continuation
                started.fulfill()
            }
            returned.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        store.installSessionSnapshotForTesting([row])
        XCTAssertEqual(store.numericUnreadCount, 0, "Unchanged poll must not undo a queued read")
        let newer = self.row(updatedAt: 200)
        store.installSessionSnapshotForTesting([newer])
        XCTAssertEqual(store.numericUnreadCount, 1)
        release?.resume()
        await fulfillment(of: [returned], timeout: 2)
        await Task.yield()
        XCTAssertEqual(store.numericUnreadCount, 1)
        XCTAssertEqual(store.sessions.first?.isUnread, true)
    }

    @MainActor
    func testFailedReceiptReleasesPollSuppression() async throws {
        let (store, row) = try self.makeReadReceiptStore()
        store.markAllRead()
        let failed = expectation(description: "Request fails")
        store.enqueueReadReceipt(row) {
            failed.fulfill()
            throw NSError(domain: "fixture", code: 1)
        }
        await fulfillment(of: [failed], timeout: 2)
        await Task.yield()
        store.installSessionSnapshotForTesting([row])
        XCTAssertEqual(store.numericUnreadCount, 1, "Failed server read must remain retryable")
    }

    @MainActor
    func testQueuedReceiptSkipsNewerSnapshotBeforeSending() async throws {
        let (store, row) = try self.makeReadReceiptStore()
        store.markAllRead()
        store.enqueueReadReceipt(row) { XCTFail("Stale queued read should not be sent") }
        let drainRow = self.row(key: "agent:main:drain")
        store.installSessionSnapshotForTesting([self.row(updatedAt: 200), drainRow])
        // A distinct chat drains behind the stale receipt without replacing it in the queue.
        let drained = expectation(description: "Queue drained")
        store.markAllRead()
        store.enqueueReadReceipt(drainRow) { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }

    @MainActor
    func testSuccessfulReceiptClearsGatewayFlag() async throws {
        let (store, row) = try self.makeReadReceiptStore()
        store.markAllRead()
        let done = expectation(description: "Receipt succeeded")
        store.enqueueReadReceipt(row) { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        await Task.yield()
        XCTAssertEqual(store.sessions.first?.isUnread, false)
        XCTAssertEqual(store.numericUnreadCount, 0)
    }

    @MainActor
    func testOldConnectionReceiptCannotChangeReplacementSnapshot() async throws {
        let (store, row) = try self.makeReadReceiptStore()
        store.markAllRead()
        let started = expectation(description: "Old connection request started")
        let returned = expectation(description: "Old connection request returned")
        var release: CheckedContinuation<Void, Never>?
        store.enqueueReadReceipt(row) {
            await withCheckedContinuation { continuation in
                release = continuation
                started.fulfill()
            }
            returned.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        store.suspendForBackground()
        store.installSessionSnapshotForTesting([row])
        release?.resume()
        await fulfillment(of: [returned], timeout: 2)
        await Task.yield()
        XCTAssertEqual(store.sessions.first?.isUnread, true)
        XCTAssertEqual(store.numericUnreadCount, 1)
    }

    private func row(updatedAt: Double = 100, key: String = "agent:main:test") -> SessionRow {
        SessionRow(key: key, kind: "direct", displayName: nil, derivedTitle: nil,
                   lastMessagePreview: nil, channel: nil, updatedAt: updatedAt, unread: true,
                   pinned: nil, hasActiveRun: nil, model: nil)
    }

    @MainActor
    private func makeReadReceiptStore() throws -> (ChatStore, SessionRow) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(profile: .init(id: "home", name: "Home", gatewayURL: URL(string: "wss://example.invalid")!, accent: "blue"),
                              transcriptCacheRoot: root.appendingPathComponent("transcripts"), operationsLedgerRoot: root)
        let row = self.row()
        store.installSessionSnapshotForTesting([row])
        return (store, row)
    }

    @MainActor
    func testLargeBacklogClearsPromptlyAndRetainsNotificationHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let sessions = Dictionary(uniqueKeysWithValues: (0..<2_000).map {
            ("agent:main:chat-\($0)", SessionUnreadState(count: 5, highestObservedWatermark: 10))
        })
        let records = Dictionary(uniqueKeysWithValues: (0..<10_000).map { index in
            let id = "notification-\(index)"
            return (id, NotificationDeliveryRecord(dedupeID: id,
                linkage: .init(workspaceID: "home", sessionKey: "agent:main:chat-\(index % 2_000)"),
                transitions: [.init(state: .observed, timestamp: now), .init(state: .eligible, timestamp: now)]))
        })
        try AtomicJSONLedgerStore<UnreadLedger>(fileURL: root.appendingPathComponent("unread.json"))
            .save(.init(workspaces: ["home": .init(sessions: sessions)]))
        try AtomicJSONLedgerStore<NotificationDeliveryLedger>(fileURL: root.appendingPathComponent("notifications.json"))
            .save(.init(recordsByDedupeID: records))
        let store = ChatStore(profile: .init(id: "home", name: "Home", gatewayURL: URL(string: "wss://example.invalid")!, accent: "blue"),
                              transcriptCacheRoot: root.appendingPathComponent("transcripts"), operationsLedgerRoot: root)
        XCTAssertEqual(store.numericUnreadCount, 10_000)
        let start = ContinuousClock.now
        store.markAllRead()
        let elapsed = start.duration(to: .now)
        print("BULK_CLEAR_BENCHMARK 2000 chats / 10000 notifications: \(elapsed)")
        XCTAssertLessThan(elapsed, .seconds(2), "Bulk clearing must not regress to a per-chat full-history sort")
        XCTAssertEqual(store.numericUnreadCount, 0)
        XCTAssertEqual(store.notificationRecords.count, 10_000)
        XCTAssertTrue(store.notificationRecords.allSatisfy { $0.state == .read })
        store.markAllRead()
        XCTAssertTrue(store.notificationRecords.allSatisfy { $0.transitions.count == 3 })
    }
}
