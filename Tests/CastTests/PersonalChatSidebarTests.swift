import Foundation
import XCTest
@testable import Cast

final class PersonalChatSidebarTests: XCTestCase {
    let chatKey = "agent:main:cast-chat-11111111-1111-4111-8111-111111111111"
    func row(_ key: String, _ extra: [String: Any] = [:]) throws -> SessionRow {
        var data: [String: Any] = ["key": key, "sessionId": "same-identity", "displayName": key]
        data.merge(extra) { _, new in new }
        return try JSONDecoder().decode(SessionRow.self, from: JSONSerialization.data(withJSONObject: data))
    }
    @MainActor func store(root: URL? = nil) -> ChatStore {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ChatStore(profile: .init(id: "personal-tests", name: "Test", gatewayURL: URL(string: "wss://example.invalid")!, accent: "blue"), transcriptCacheRoot: root, operationsLedgerRoot: root)
        store.isNotificationContextVisible = false
        return store
    }
    func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    func testLegacyPinsAndHidesDecodeWithoutLoss() throws {
        let prefs = try JSONDecoder().decode(SidebarPreferences.self, from: Data("{\"hiddenKeys\":[\"agent:main:hidden\"],\"pinnedKeys\":[\"agent:main:kept\"]}".utf8))
        XCTAssertTrue(prefs.chat("agent:main:hidden").hidden)
        XCTAssertTrue(prefs.chat("agent:main:kept").kept)
        XCTAssertTrue(prefs.mergedChats([:])["agent:main:kept"]!.pinned)
    }
    @MainActor func testOnlyExplicitChatsAppearEvenWithUnmarkedProbesAndCategoryMetadata() throws {
        let store = store()
        var rows = try (0..<100).map { try row("agent:main:probe-\($0)", ["category": "Cast"]) }
        rows += [try row(chatKey), try row("agent:main:main"), try row("agent:main:cron:123"), try row("agent:main:worker", ["spawnedBy": chatKey])]
        store.installSessionSnapshotForTesting(rows)
        XCTAssertTrue(store.personalChats.isEmpty, "Even old empty Cast chats must require an explicit keep")
        store.keepPersonalChat(chatKey)
        store.keepPersonalChat("agent:main:main")
        store.keepPersonalChat("agent:main:probe-4")
        XCTAssertEqual(store.personalChats.count, 3)
        XCTAssertFalse(store.manageableChats.contains { $0.key == "agent:main:worker" })
        store.installSessionSnapshotForTesting(rows + [try row("agent:main:new-probe")])
        XCTAssertEqual(store.personalChats.count, 3, "Refresh must not opt in newly discovered sessions")
    }
    @MainActor func testArchiveHideAndUndoPreserveIdentityDraftAndDoNotBounceOnUpdates() throws {
        let store = store()
        store.installSessionSnapshotForTesting([try row(chatKey)])
        store.setDraft("Keep this draft", forSession: chatKey)
        store.cleanupPersonalChat(chatKey, archive: true)
        store.installSessionSnapshotForTesting([try row(chatKey, ["unread": true, "hasActiveRun": true])])
        XCTAssertTrue(store.personalChats.isEmpty)
        XCTAssertEqual(store.manageableChats.first?.sessionId, "same-identity")
        store.undoChatCleanup()
        XCTAssertEqual(store.personalChats.map(\.key), [chatKey])
        XCTAssertEqual(store.draft(forSession: chatKey), "Keep this draft")
        store.cleanupPersonalChat(chatKey, archive: false)
        XCTAssertTrue(store.personalChats.isEmpty)
        store.undoChatCleanup()
        XCTAssertEqual(store.personalChats.count, 1)
    }
    @MainActor func testPinsReorderAndRestoreAcrossColdStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = chatKey, b = "agent:main:cast-chat-22222222-2222-4222-8222-222222222222"
        let rows = [try row(a), try row(b)]
        let first = store(root: root); first.installSessionSnapshotForTesting(rows)
        first.updatePersonalChat(a) { $0.title = "Cast"; $0.pinned = true; $0.rank = 0 }
        first.updatePersonalChat(b) { $0.title = "Cackles"; $0.pinned = true; $0.rank = 1 }
        first.movePinnedChat(b, by: -1)
        let cold = store(root: root); cold.installSessionSnapshotForTesting(rows)
        XCTAssertEqual(cold.personalChats.map(\.key), [b, a])
        XCTAssertEqual(cold.chatTitle(rows[0]), "Cast")
        cold.cleanupPersonalChat(a, archive: true)
        let next = store(root: root); next.installSessionSnapshotForTesting(rows)
        XCTAssertEqual(next.personalChats.map(\.key), [b])
        next.keepPersonalChat(a)
        XCTAssertEqual(next.personalChats.count, 2)
    }
    func testPendingChangesSurviveOlderSyncAcknowledgment() {
        var prefs = SidebarPreferences()
        prefs.updateChat(chatKey) { $0.hidden = true }
        let sent = prefs.pendingChats!
        prefs.updateChat(chatKey) { $0.hidden = false; $0.pinned = true }
        prefs.receiveChats(sent, sent: sent)
        XCTAssertFalse(prefs.chat(chatKey).hidden)
        XCTAssertTrue(prefs.chat(chatKey).pinned)
        XCTAssertNotNil(prefs.pendingChats?[chatKey])
    }
    @MainActor func testCASConflictMergesOtherDeviceChangesAndReceivesArchive() async throws {
        let store = store(); store.installSessionSnapshotForTesting([try row(chatKey)])
        store.keepPersonalChat(chatKey)
        var writes = 0; var reads = 0
        let remoteKey = "agent:main:other"
        var remote = [String: ChatSidebarPreference]()
        await store.syncChatSidebar { method, params in
            if method == "users.self" { return try self.data(["profile": ["id": "owner"]]) }
            if method == "users.prefs.get" {
                reads += 1
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(remote))
                return try self.data(["status": "ok", "entries": [SidebarPreferences.chatPreferenceKey: object]])
            }
            writes += 1
            if writes == 1 { remote[remoteKey] = ChatSidebarPreference(kept: true, pinned: true); return try self.data(["status": "conflict"]) }
            let entries = params["entries"] as! [String: Any]
            let object = entries[SidebarPreferences.chatPreferenceKey] as! [String: Any]
            XCTAssertNotNil(object[remoteKey])
            return try self.data(["status": "ok"])
        }
        XCTAssertEqual(writes, 2); XCTAssertEqual(reads, 2)
        XCTAssertTrue(store.sidebarPreferences.chat(remoteKey).pinned)
        XCTAssertTrue((store.sidebarPreferences.pendingChats ?? [:]).isEmpty)
        remote[chatKey] = ChatSidebarPreference(kept: true, archived: true)
        await store.syncChatSidebar { method, _ in
            if method == "users.self" { return try self.data(["profile": ["id": "owner"]]) }
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(remote))
            return try self.data(["status": "ok", "entries": [SidebarPreferences.chatPreferenceKey: object]])
        }
        XCTAssertTrue(store.isChatArchived(chatKey)); XCTAssertFalse(store.personalChats.contains { $0.key == chatKey })
    }
    @MainActor func testAccountSwitchCannotUploadPreviousPreferences() async throws {
        let store = store(); store.keepPersonalChat(chatKey)
        await store.syncChatSidebar { method, _ in
            if method == "users.self" { return try self.data(["profile": ["id": "first"]]) }
            if method == "users.prefs.get" { return try self.data(["status": "ok", "entries": [:]]) }
            return try self.data(["status": "ok"])
        }
        var methods = [String]()
        await store.syncChatSidebar { method, _ in methods.append(method); return try self.data(["profile": ["id": "other"]]) }
        XCTAssertEqual(methods, ["users.self"])
        XCTAssertNotNil(store.chatSidebarSyncNotice)
    }
    @MainActor func testMalformedRemoteLeavesLocalAndPendingChoicesIntact() async throws {
        let store = store(); store.keepPersonalChat(chatKey)
        await store.syncChatSidebar { method, _ in
            if method == "users.self" { return try self.data(["profile": ["id": "owner"]]) }
            XCTAssertEqual(method, "users.prefs.get")
            return try self.data(["status": "ok", "entries": [SidebarPreferences.chatPreferenceKey: "invalid"]])
        }
        XCTAssertTrue(store.sidebarPreferences.chat(chatKey).kept)
        XCTAssertNotNil(store.sidebarPreferences.pendingChats?[chatKey])
        XCTAssertNotNil(store.chatSidebarSyncNotice)
    }
    @MainActor func testOpeningAndCancellingComposerDoesNotCreateChat() throws {
        let store = store(); store.installSessionSnapshotForTesting([try row(chatKey)])
        store.keepPersonalChat(chatKey)
        store.newPersonalChatPresented = true
        store.newPersonalChatPresented = false
        XCTAssertEqual(store.personalChats.map(\.key), [chatKey])
        XCTAssertFalse(store.projectMutationInFlight)
    }
    @MainActor func testKeptChatsSurviveMissingInventoryAndOfflineColdStart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = store(root: root)
        first.installSessionSnapshotForTesting([try row(chatKey, ["displayName": "Cast"])] )
        first.keepPersonalChat(chatKey)
        let cold = store(root: root)
        XCTAssertEqual(cold.personalChats.map(\.key), [chatKey])
        XCTAssertEqual(cold.chatTitle(cold.personalChats[0]), "Cast")
        cold.installSessionSnapshotForTesting(try (0..<100).map { try row("agent:main:recent-\($0)") })
        XCTAssertEqual(cold.personalChats.map(\.key), [chatKey])
    }
    func testCompactFormatAndLegacyHiddenOnlyEntriesDoNotExhaustSync() throws {
        var prefs = SidebarPreferences()
        for index in 0..<100 { prefs.setHidden(true, key: "agent:main:old-probe-\(index)") }
        prefs.setPinned(true, key: chatKey)
        XCTAssertEqual(prefs.mergedChats([:]).count, 1)
        let data = try JSONEncoder().encode(ChatSidebarPreference())
        XCTAssertEqual(String(data: data, encoding: .utf8), "{}")
        XCTAssertEqual(try JSONDecoder().decode(ChatSidebarPreference.self, from: Data("{}".utf8)), ChatSidebarPreference())
        XCTAssertTrue(prefs.isHidden("agent:main:old-probe-1"))
    }
    @MainActor func testArchiveSelectionClearsWithoutOpeningAnotherUnreadChat() throws {
        let store = store(); let second = "agent:main:second"
        store.installSessionSnapshotForTesting([try row(chatKey), try row(second, ["unread": true])])
        store.keepPersonalChat(chatKey); store.keepPersonalChat(second)
        store.selectFromSidebar(chatKey)
        let navigation = store.detailNavigationRequest
        store.cleanupPersonalChat(chatKey, archive: true)
        XCTAssertNil(store.selectedSessionKey)
        XCTAssertEqual(store.detailNavigationRequest, navigation)
        XCTAssertTrue(store.manageableChats.first { $0.key == second }!.isUnread)
    }
    @MainActor func testSyncDoesNotEvictDeliberatelyOpenedHiddenChat() async throws {
        let store = store(); store.installSessionSnapshotForTesting([try row(chatKey)])
        store.keepPersonalChat(chatKey); store.cleanupPersonalChat(chatKey, archive: false)
        store.selectFromSidebar(chatKey)
        let value = store.sidebarPreferences.chat(chatKey)
        await store.syncChatSidebar { method, _ in
            if method == "users.self" { return try self.data(["profile": ["id": "owner"]]) }
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode([self.chatKey: value]))
            return try self.data(["status": "ok", "entries": [SidebarPreferences.chatPreferenceKey: object]])
        }
        XCTAssertEqual(store.selectedSessionKey, chatKey)
    }
    @MainActor func testOverflowStillDownloadsRemoteChangesAndRetainsLocalPending() async throws {
        let store = store()
        for i in 0..<200 { store.keepPersonalChat("agent:main:kept-\(i)") }
        let other = "agent:main:another-device"
        await store.syncChatSidebar { method, _ in
            if method == "users.self" { return try self.data(["profile": ["id": "owner"]]) }
            XCTAssertEqual(method, "users.prefs.get", "Oversize upload must not be attempted")
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode([other: ChatSidebarPreference(kept: true, pinned: true)]))
            return try self.data(["status": "ok", "entries": [SidebarPreferences.chatPreferenceKey: object]])
        }
        XCTAssertTrue(store.sidebarPreferences.chat(other).pinned)
        XCTAssertEqual(store.sidebarPreferences.pendingChats?.count, 200)
        XCTAssertTrue(store.chatSidebarSyncNotice?.contains("storage is full") == true)
    }

    @MainActor func testChangingConversationClosesUnrelatedSidePaneButPreservesIt() throws {
        let store = store()
        let sideKey = "agent:main:cast-side-dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        store.discoverSideChats([try row(sideKey, ["derivedTitle": "Saved side conversation"])])
        store.resumeSideChat(sideKey)
        XCTAssertTrue(store.isSideChatPresented)
        store.selectedSessionKey = chatKey
        XCTAssertFalse(store.isSideChatPresented)
        XCTAssertEqual(store.savedSideChats.map(\.sessionKey), [sideKey])
        store.resumeSideChat(sideKey)
        XCTAssertTrue(store.isSideChatPresented)
    }

    @MainActor func testLongDiscoveredTitleIsBoundedBeforeSync() async throws {
        let store = store()
        store.installSessionSnapshotForTesting([try row(chatKey, ["displayName": String(repeating: "é", count: 200)])])
        store.keepPersonalChat(chatKey)
        XCTAssertEqual(store.sidebarPreferences.chat(chatKey).title?.count, 100)
        var wrote = false
        await store.syncChatSidebar { method, _ in
            if method == "users.self" { return try self.data(["profile": ["id": "owner"]]) }
            if method == "users.prefs.get" { return try self.data(["status": "ok", "entries": [:]]) }
            wrote = true
            return try self.data(["status": "ok"])
        }
        XCTAssertTrue(wrote)
        XCTAssertNil(store.sidebarPreferences.pendingChats?[chatKey])
    }
    @MainActor func testBackendRestoreUsesIdentityAndPreservesConcurrentRowUpdate() async throws {
        let store = store(), archived = try row(chatKey, ["archived": true])
        store.installSessionSnapshotForTesting([archived])
        try await store.restorePersonalChat(archived) { method, params in
            XCTAssertEqual(method, "sessions.patch")
            XCTAssertEqual(params["expectedSessionId"] as? String, "same-identity")
            XCTAssertEqual(params["archived"] as? Bool, false)
            store.installSessionSnapshotForTesting([try self.row(self.chatKey, ["archived": true, "displayName": "Updated while restoring", "unread": true])])
            return try self.data(["ok": true])
        }
        XCTAssertEqual(store.personalChats.count, 1)
        XCTAssertEqual(store.chatTitle(store.personalChats[0]), "Updated while restoring")
        XCTAssertTrue(store.personalChats[0].isUnread)
        XCTAssertNotEqual(store.personalChats[0].archived, true)
    }
    @MainActor func testBackendRestoreRejectsFalseAckReplacementAndDisconnect() async throws {
        for failure in ["false-ack", "replacement", "disconnect"] {
            let store = store(), archived = try row(chatKey, ["archived": true])
            store.installSessionSnapshotForTesting([archived])
            do {
                try await store.restorePersonalChat(archived) { _, _ in
                    if failure == "replacement" { store.installSessionSnapshotForTesting([try self.row(self.chatKey, ["archived": true, "sessionId": "new-incarnation"])]) }
                    if failure == "disconnect" { store.suspendForBackground() }
                    return try self.data(["ok": failure != "false-ack"])
                }
                XCTFail("Restore must fail: " + failure)
            } catch {}
            XCTAssertTrue(store.personalChats.isEmpty)
            XCTAssertFalse(store.sidebarPreferences.chat(chatKey).kept)
        }
    }

}
