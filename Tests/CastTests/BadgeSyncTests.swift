import Foundation
import XCTest
@testable import Cast

final class BadgeSyncTests: XCTestCase {
    @MainActor private func store() -> ChatStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(profile: .init(id: "badge-test", name: "Badge test", gatewayURL: URL(string: "wss://example.invalid")!, accent: "blue"), transcriptCacheRoot: root, operationsLedgerRoot: root)
        store.isNotificationContextVisible = false
        return store
    }
    private func event(role: String = "assistant", id: String = "one", timestamp: Int = 1000) throws -> EventFrame {
        try JSONDecoder().decode(EventFrame.self, from: JSONSerialization.data(withJSONObject: ["event":"session.message","payload":["sessionKey":"agent:main:test","message":["id":id,"role":role,"timestamp":timestamp,"content":[["type":"text","text":"fixture"]]]]]))
    }
    private func row(unread: Bool?, lastReadAt: Int? = nil) throws -> SessionRow {
        var value: [String:Any] = ["key":"agent:main:test","updatedAt":100]
        if let unread { value["unread"] = unread }
        if let lastReadAt { value["lastReadAt"] = lastReadAt }
        return try JSONDecoder().decode(SessionRow.self, from: JSONSerialization.data(withJSONObject: value))
    }
    @MainActor func testToolsAndSystemEventsDoNotInflateUnread() throws {
        let store = store()
        for role in ["toolResult", "system", "user"] { store.handleEvent(try event(role: role, id: role)) }
        XCTAssertEqual(store.numericUnreadCount, 0)
    }
    @MainActor func testBadgeCountsConversationsNotDeviceSpecificEventTotals() throws {
        let store = store()
        store.handleEvent(try event())
        store.handleEvent(try event(id: "two", timestamp: 2000))
        XCTAssertEqual(store.numericUnreadCount, 1)
        XCTAssertEqual(store.unreadCount(for: "agent:main:test"), 1)
    }
    @MainActor func testReadOnAnotherDeviceClearsNewerLocalEventUsingReadWatermark() throws {
        let store = store()
        store.handleEvent(try event())
        store.installSessionSnapshotForTesting([try row(unread: false, lastReadAt: 2000)])
        XCTAssertEqual(store.numericUnreadCount, 0)
        store.handleEvent(try event(id: "delayed", timestamp: 1500))
        XCTAssertEqual(store.numericUnreadCount, 0)
        store.handleEvent(try event(id: "new", timestamp: 3000))
        XCTAssertEqual(store.numericUnreadCount, 1)
    }
    @MainActor func testMissingUnreadFieldIsNotAReadAcknowledgment() throws {
        let store = store()
        store.handleEvent(try event(timestamp: 50))
        store.installSessionSnapshotForTesting([try row(unread: nil)])
        XCTAssertEqual(store.numericUnreadCount, 1)
    }
    @MainActor func testFullInventoryReconcilesBeyondSidebarAndRetiresMissingRows() async throws {
        let store = store()
        store.handleEvent(try event())
        var offsets: [Int] = []
        await store.refreshUnreadInventory { offset in
            offsets.append(offset)
            let value: [String:Any] = offset == 0
                ? ["sessions":[["key":"agent:main:other","unread":true,"updatedAt":100]],"hasMore":true,"nextOffset":200]
                : ["sessions":[["key":"agent:main:test","unread":false,"updatedAt":100,"lastReadAt":2000]],"hasMore":false]
            return try JSONSerialization.data(withJSONObject:value)
        }
        XCTAssertEqual(offsets,[0,200])
        XCTAssertEqual(store.unreadCount(for:"agent:main:test"),0)
        XCTAssertEqual(store.numericUnreadCount,1)
        await store.refreshUnreadInventory { _ in
            try JSONSerialization.data(withJSONObject:["sessions":[],"hasMore":false])
        }
        XCTAssertEqual(store.numericUnreadCount,0)
    }
    @MainActor func testFailedOrChangingInventoryNeverPrunesRetainedUnread() async throws {
        let store = store()
        store.handleEvent(try event())
        await store.refreshUnreadInventory { offset in
            if offset > 0 { throw NSError(domain:"fixture",code:1) }
            return try JSONSerialization.data(withJSONObject:["sessions":[],"hasMore":true,"nextOffset":200])
        }
        XCTAssertEqual(store.numericUnreadCount,1)
        await store.refreshUnreadInventory { _ in
            store.handleEvent(try self.event(id:"during",timestamp:2000))
            return try JSONSerialization.data(withJSONObject:["sessions":[],"hasMore":false])
        }
        XCTAssertEqual(store.numericUnreadCount,1)
    }
    @MainActor func testChangeEventClearsSessionOutsideCurrentSidebarPage() throws {
        let store = store()
        store.handleEvent(try event())
        let change = try JSONDecoder().decode(EventFrame.self,from:JSONSerialization.data(withJSONObject:["event":"sessions.changed","payload":["sessionKey":"agent:main:test","session":["key":"agent:main:test","unread":false,"updatedAt":100,"lastReadAt":2000]]]))
        store.handleEvent(change)
        XCTAssertEqual(store.numericUnreadCount,0)
    }
    @MainActor func testTranscriptRefreshReturnsWhileInventoryIsBlocked() async throws {
        let store = store()
        let gate = BadgeWriteProbe()
        let returned = expectation(description: "sidebar refresh returns before inventory")
        Task { @MainActor in
            await store.refreshSessions(request: {
                try JSONSerialization.data(withJSONObject:["sessions":[],"hasMore":false])
            }, unreadRequest: { _ in
                await gate.write(1)
                return try JSONSerialization.data(withJSONObject:["sessions":[],"hasMore":false])
            })
            returned.fulfill()
        }
        await fulfillment(of:[returned],timeout:2)
        await gate.waitUntilStarted()
        await gate.release()
    }
    @MainActor func testIncompleteTotalAndLocalReadCannotBeOverwrittenByInventory() async throws {
        let store = store()
        store.handleEvent(try event())
        await store.refreshUnreadInventory { _ in
            try JSONSerialization.data(withJSONObject:["sessions":[],"hasMore":false,"totalCount":1])
        }
        XCTAssertEqual(store.numericUnreadCount,1)
        await store.refreshUnreadInventory { _ in
            store.markAllRead()
            return try JSONSerialization.data(withJSONObject:["sessions":[["key":"agent:main:test","unread":true,"updatedAt":2000]],"hasMore":false])
        }
        XCTAssertEqual(store.numericUnreadCount,0)
    }
    @MainActor func testImageOnlyReplyCountsAsUnread() throws {
        let store = store()
        let event = try JSONDecoder().decode(EventFrame.self,from:JSONSerialization.data(withJSONObject:["event":"session.message","payload":["sessionKey":"agent:main:image","message":["id":"image-only","role":"assistant","timestamp":1000,"content":[["type":"image","mimeType":"image/png"]]]]]))
        store.handleEvent(event)
        XCTAssertEqual(store.numericUnreadCount,1)
    }
    @MainActor func testOlderUnreadConversationHasTitleAndCanBeOpenedAndCleared() async throws {
        let store = store()
        await store.refreshUnreadInventory { _ in
            try JSONSerialization.data(withJSONObject:["sessions":[["key":"agent:main:older","displayName":"Older conversation","unread":true,"updatedAt":1000]],"hasMore":false])
        }
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.firstUnreadSessionKey,"agent:main:older")
        XCTAssertEqual(store.unreadSummaries.first?.title,"Older conversation")
        store.selectFromSidebar("agent:main:older")
        XCTAssertEqual(store.selectedSessionKey,"agent:main:older")
        XCTAssertEqual(store.numericUnreadCount,0)
    }

    func testNativeBadgeWritesFinishInLatestValueOrder() async {
        let probe = BadgeWriteProbe()
        let writer = BadgeCountDelivery { value in await probe.write(value) }
        let first = Task { await writer.set(9) }
        await probe.waitUntilStarted()
        await writer.set(5)
        await writer.set(0)
        await probe.release()
        await first.value
        let values = await probe.values
        XCTAssertEqual(values,[9,0])
    }

}

private actor BadgeWriteProbe {
    var values: [Int] = []
    var blocked: CheckedContinuation<Void,Never>?
    var started: CheckedContinuation<Void,Never>?
    func write(_ value:Int) async {
        if values.isEmpty {
            await withCheckedContinuation { continuation in
                blocked=continuation
                started?.resume();started=nil
            }
        }
        values.append(value)
    }
    func waitUntilStarted() async {
        if blocked != nil { return }
        await withCheckedContinuation { started=$0 }
    }
    func release() { blocked?.resume();blocked=nil }
}
