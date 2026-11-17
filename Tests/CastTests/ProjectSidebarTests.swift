import Foundation
import XCTest
@testable import Cast

final class ProjectSidebarTests: XCTestCase {
    @MainActor private func store() -> ChatStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(profile: .init(id: "project-test", name: "Projects", gatewayURL: URL(string: "wss://example.invalid")!, accent: "blue"), transcriptCacheRoot: root, operationsLedgerRoot: root)
        store.isNotificationContextVisible = false
        return store
    }

    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func row(_ key: String, category: String? = nil, extra: [String: Any] = [:]) throws -> SessionRow {
        var value: [String: Any] = ["key": key, "sessionId": "incarnation-1", "displayName": key]
        if let category { value["category"] = category }
        value.merge(extra) { _, new in new }
        return try JSONDecoder().decode(SessionRow.self, from: json(value))
    }

    func testUnreadMutationAndCodableRoundTripPreserveProjectIdentity() throws {
        let value = try row("agent:main:chat", category: "Cast", extra: ["archived": true, "isBackground": false, "lastInteractionAt": 45])
        let changed = try JSONDecoder().decode(SessionRow.self, from: JSONEncoder().encode(value.settingUnread(true)))
        XCTAssertEqual(changed.category, "Cast")
        XCTAssertEqual(changed.sessionId, "incarnation-1")
        XCTAssertEqual(changed.archived, true)
        XCTAssertEqual(changed.lastInteractionAt, 45)
        XCTAssertEqual(changed.isUnread, true)
    }

    @MainActor func testProjectSelectionRetainsConversationAndDraft() throws {
        let store = store()
        store.installSessionSnapshotForTesting([try row("agent:main:chat", category: "Cast")])
        store.selectFromSidebar("agent:main:chat")
        store.setDraft("Keep these words", forSession: "agent:main:chat")
        store.selectProject("Cackles")
        XCTAssertEqual(store.selectedSessionKey, "agent:main:chat")
        XCTAssertEqual(store.draft(forSession: "agent:main:chat"), "Keep these words")
        XCTAssertTrue(store.projectOverviewPresented)
        store.selectFromSidebar("agent:main:chat")
        XCTAssertEqual(store.selectedProjectName, "Cast")
        XCTAssertFalse(store.projectOverviewPresented)
    }

    @MainActor func testProjectInventoryIncludesRowsBeyondLatestPageAndCatalogEmptyProjects() async throws {
        let store = store()
        store.installSessionSnapshotForTesting([try row("agent:main:recent")])
        await store.refreshUnreadInventory { offset in
            try self.json(offset == 0
                ? ["sessions": [["key": "agent:main:recent"]], "hasMore": true, "nextOffset": 200]
                : ["sessions": [["key": "agent:main:old", "category": "Long project"]], "hasMore": false])
        }
        await store.refreshProjects { try self.json(["groups": [["name": "Empty project", "position": 0]]]) }
        XCTAssertEqual(store.projectSessions(for: "Long project").map(\.key), ["agent:main:old"])
        XCTAssertTrue(store.sidebarProjects.contains { $0.name == "Empty project" })
        XCTAssertTrue(store.sidebarProjects.contains { $0.name == "Cackles" })
        XCTAssertTrue(store.projectSessions(for: "Cackles").isEmpty)
    }

    @MainActor func testNeedsYouDoesNotTreatUnreadAsHumanActionAndWorkingIsSeparate() throws {
        let store = store()
        store.installSessionSnapshotForTesting([
            try row("agent:main:unread", extra: ["unread": true]),
            try row("agent:main:working", extra: ["hasActiveRun": true]),
            try row("agent:main:failure", extra: ["status": "failed"]),
        ])
        store.sidebarFilter = .needsYou
        XCTAssertEqual(store.sidebarFilteredSessions.map(\.key), ["agent:main:failure"])
        store.sidebarFilter = .working
        XCTAssertEqual(store.sidebarFilteredSessions.map(\.key), ["agent:main:working"])
    }

    @MainActor func testBackgroundAndArchivedRowsDoNotLeakIntoProjectConversations() throws {
        let store = store()
        store.installSessionSnapshotForTesting([
            try row("agent:main:visible", category: "Cast"),
            try row("agent:main:archived", category: "Cast", extra: ["archived": true]),
            try row("agent:main:cron:child", category: "Cast"),
            try row("agent:main:subagent:child", category: "Cast"),
        ])
        XCTAssertEqual(store.projectSessions(for: "Cast").map(\.key), ["agent:main:visible"])
    }

    @MainActor func testMoveUsesExactIncarnationAndNeverExecutionOrReadFields() async throws {
        let store = store()
        store.installSessionSnapshotForTesting([try row("agent:main:chat", category: "Cast", extra: ["unread": true])])
        store.setDraft("Preserve", forSession: "agent:main:chat")
        try await store.moveSessionToProject(key: "agent:main:chat", project: "Cackles") { method, params in
            XCTAssertEqual(method, "sessions.patch")
            XCTAssertEqual(Set(params.keys), ["key", "expectedSessionId", "category"])
            XCTAssertEqual(params["expectedSessionId"] as? String, "incarnation-1")
            XCTAssertEqual(store.projectName(for: "agent:main:chat"), "Cast", "No optimistic move before acknowledgment")
            return try self.json(["ok": true])
        }
        XCTAssertEqual(store.projectName(for: "agent:main:chat"), "Cackles")
        XCTAssertEqual(store.projectSessions(for: "Cackles").first?.isUnread, true)
        XCTAssertEqual(store.draft(forSession: "agent:main:chat"), "Preserve")
        try await store.moveSessionToProject(key: "agent:main:chat", project: nil) { _, params in
            XCTAssertTrue(params["category"] is NSNull)
            return try self.json(["ok": true])
        }
        XCTAssertNil(store.projectName(for: "agent:main:chat"))
    }

    @MainActor func testFailedMoveDoesNotPublishNewProject() async throws {
        let store = store()
        store.installSessionSnapshotForTesting([try row("agent:main:chat", category: "Cast")])
        do {
            try await store.moveSessionToProject(key: "agent:main:chat", project: "Failed destination") { _, _ in
                throw URLError(.timedOut)
            }
            XCTFail("Expected failure")
        } catch {}
        XCTAssertEqual(store.projectName(for: "agent:main:chat"), "Cast")
        XCTAssertFalse(store.sidebarProjects.contains { $0.name == "Failed destination" })
        XCTAssertFalse(store.projectMutationInFlight)
    }

    @MainActor func testLateMoveAfterConnectionChangeDoesNotApplyLocally() async throws {
        let store = store()
        store.installSessionSnapshotForTesting([try row("agent:main:chat", category: "Cast")])
        do {
            try await store.moveSessionToProject(key: "agent:main:chat", project: "Cackles") { _, _ in
                store.suspendForBackground()
                return try self.json(["ok": true])
            }
            XCTFail("Expected obsolete response rejection")
        } catch {}
        XCTAssertEqual(store.projectName(for: "agent:main:chat"), "Cast")
    }

    @MainActor func testMoveCannotOverwriteNewSessionIncarnation() async throws {
        let store = store()
        store.installSessionSnapshotForTesting([try row("agent:main:chat", category: "Cast")])
        do {
            try await store.moveSessionToProject(key: "agent:main:chat", project: "Cackles") { _, _ in
                store.installSessionSnapshotForTesting([try self.row("agent:main:chat", category: "RunPR", extra: ["sessionId": "replacement"])])
                return try self.json(["ok": true])
            }
            XCTFail("Expected incarnation guard")
        } catch {}
        XCTAssertEqual(store.projectName(for: "agent:main:chat"), "RunPR")
    }

    @MainActor func testUncertainCreateRetryUsesSameKeyAndOnlyConfirmedChatAppears() async throws {
        let store = store()
        var attemptedKey: String?
        do {
            try await store.createProjectChat(in: "Cast") { method, params in
                XCTAssertEqual(method, "sessions.create")
                attemptedKey = params["key"] as? String
                XCTAssertEqual(params["idempotencyKey"] as? String, attemptedKey)
                XCTAssertEqual(params["category"] as? String, "Cast")
                for forbidden in ["projectId", "cwd", "worktree", "message", "task", "parentSessionKey", "displayName", "label"] { XCTAssertNil(params[forbidden]) }
                throw URLError(.timedOut)
            }
            XCTFail("Expected uncertainty")
        } catch {}
        XCTAssertTrue(store.projectSessions(for: "Cast").isEmpty)
        let key = try await store.createProjectChat(in: "Cast") { _, params in
            XCTAssertEqual(params["key"] as? String, attemptedKey)
            return try self.json(["ok": true, "key": attemptedKey!, "sessionId": "created-id"])
        }
        XCTAssertEqual(key, attemptedKey)
        XCTAssertEqual(store.projectSessions(for: "Cast").map(\.key), [key])
        XCTAssertEqual(store.projectSessions(for: "Cast").first?.sessionId, "created-id")
        XCTAssertEqual(store.selectedSessionKey, key)
    }

    @MainActor func testLateCreateAndCatalogResponsesDoNotChangeNewConnection() async throws {
        let store = store()
        do {
            try await store.createProjectChat(in: "Cast") { _, params in
                store.suspendForBackground()
                return try self.json(["ok": true, "key": params["key"]!, "sessionId": "created-id"])
            }
            XCTFail("Expected obsolete response rejection")
        } catch {}
        XCTAssertTrue(store.projectSessions(for: "Cast").isEmpty)
        let catalogStore = self.store()
        await catalogStore.refreshProjects {
            catalogStore.suspendForBackground()
            return try self.json(["groups": [["name": "Obsolete", "position": 0]]])
        }
        XCTAssertFalse(catalogStore.sidebarProjects.contains { $0.name == "Obsolete" })
    }

    func testStableOrderDoesNotFollowStreamingActivity() throws {
        let a = try row("agent:main:a", extra: ["updatedAt": 900])
        let b = try row("agent:main:b", extra: ["updatedAt": 100])
        XCTAssertEqual(ProjectSidebar.stableOrder([b, a]).map(\.key), [a.key, b.key])
        let newerB = try row("agent:main:b", extra: ["updatedAt": 999999])
        XCTAssertEqual(ProjectSidebar.stableOrder([newerB, a]).map(\.key), [a.key, b.key])
    }
    @MainActor func testEarlierFirstPageCannotUndoAcknowledgedMove() async throws {
        let store = store()
        store.installSessionSnapshotForTesting([try row("agent:main:chat", category: "Cast")])
        await store.refreshSessions {
            try await store.moveSessionToProject(key: "agent:main:chat", project: "Cackles") { _, _ in
                try self.json(["ok": true])
            }
            return try self.json(["sessions": [["key": "agent:main:chat", "sessionId": "incarnation-1", "category": "Cast"]]])
        }
        XCTAssertEqual(store.projectName(for: "agent:main:chat"), "Cackles")
        XCTAssertEqual(store.sessions.first?.category, "Cackles")
    }

    @MainActor func testOverviewDoesNotReadHiddenTranscriptAndReopenAcknowledgesIt() throws {
        let store = store()
        store.isNotificationContextVisible = true
        store.installSessionSnapshotForTesting([try row("agent:main:chat", category: "Cast")])
        store.selectFromSidebar("agent:main:chat")
        store.selectProject("Cackles")
        let event = try JSONDecoder().decode(EventFrame.self, from: json([
            "event": "session.message", "payload": ["sessionKey": "agent:main:chat", "message": [
                "id": "new-reply", "role": "assistant", "timestamp": 1000,
                "content": [["type": "text", "text": "New reply while overview is visible"]],
            ]],
        ]))
        store.handleEvent(event)
        XCTAssertEqual(store.unreadCount(for: "agent:main:chat"), 1)
        store.installSessionSnapshotForTesting([try row("agent:main:chat", category: "Cast", extra: ["unread": true, "updatedAt": 1000])])
        XCTAssertEqual(store.unreadCount(for: "agent:main:chat"), 1)
        store.selectFromSidebar("agent:main:chat")
        XCTAssertEqual(store.unreadCount(for: "agent:main:chat"), 0)
    }

    @MainActor func testChildrenRemainAccessibleOnlyUnderTheirParent() throws {
        let store = store()
        store.installSessionSnapshotForTesting([
            try row("agent:main:chat", category: "Cast"),
            try row("agent:main:subagent:child", category: "Cast", extra: ["spawnedBy": "agent:main:chat"]),
        ])
        XCTAssertEqual(store.projectSessions(for: "Cast").map(\.key), ["agent:main:chat"])
        XCTAssertEqual(store.projectChildSessions(of: "agent:main:chat").map(\.key), ["agent:main:subagent:child"])
    }

    func testUntitledProjectChatHasFriendlyFallbackWithoutPersistedExplicitTitle() throws {
        let key = "agent:main:cast-chat-" + UUID().uuidString.lowercased()
        let empty = try JSONDecoder().decode(SessionRow.self, from: json(["key": key]))
        XCTAssertEqual(empty.title, "New conversation")
        let named = try JSONDecoder().decode(SessionRow.self, from: json(["key": key, "derivedTitle": "Audio recovery"]))
        XCTAssertEqual(named.title, "Audio recovery")
    }

    @MainActor func testAccountSwitchRejectsOldCreateResponseAndClearsOldProjectInventory() async throws {
        let store = store()
        store.installSessionSnapshotForTesting([try row("agent:main:old-account", category: "Private old project")])
        do {
            try await store.createProjectChat(in: "Cast") { _, params in
                // A fresh random workspace has no stored credential; update itself must invalidate the request.
                store.update(profile: .init(id: "another-" + UUID().uuidString, name: "Another", gatewayURL: URL(string: "wss://another.invalid")!, accent: "blue"))
                return try self.json(["ok": true, "key": params["key"]!, "sessionId": "old-account-created"])
            }
            XCTFail("Expected old account response rejection")
        } catch {}
        XCTAssertTrue(store.projectSessions(for: "Private old project").isEmpty)
        XCTAssertTrue(store.projectSessions(for: "Cast").isEmpty)
        XCTAssertNil(store.selectedProjectName)
        XCTAssertFalse(store.projectMutationInFlight)
    }

    @MainActor func testRepeatedSameConversationSelectionAlwaysRequestsDetailNavigation() throws {
        let store = store()
        store.installSessionSnapshotForTesting([try row("agent:main:chat", category: "Cast")])
        store.selectFromSidebar("agent:main:chat")
        store.setDraft("Do not reset", forSession: "agent:main:chat")
        let firstRequest = store.detailNavigationRequest
        store.selectFromSidebar("agent:main:chat")
        XCTAssertGreaterThan(store.detailNavigationRequest, firstRequest)
        XCTAssertEqual(store.selectedSessionKey, "agent:main:chat")
        XCTAssertEqual(store.draft(forSession: "agent:main:chat"), "Do not reset")
    }

    @MainActor func testRepeatedSameProjectSelectionAlwaysRequestsDetailNavigation() {
        let store = store()
        store.selectProject("Cast")
        let firstRequest = store.detailNavigationRequest
        store.selectProject("Cast")
        XCTAssertGreaterThan(store.detailNavigationRequest, firstRequest)
        XCTAssertTrue(store.projectOverviewPresented)
        XCTAssertEqual(store.selectedProjectName, "Cast")
    }

    @MainActor func testAttentionPredicateMatchesFilterAndDoesNotPromoteUnread() throws {
        let store = store()
        store.installSessionSnapshotForTesting([
            try row("agent:main:unread", extra: ["unread": true]),
            try row("agent:main:failed", extra: ["status": "failed"]),
        ])
        XCTAssertFalse(store.needsProjectAttention(sessionKey: "agent:main:unread"))
        XCTAssertTrue(store.needsProjectAttention(sessionKey: "agent:main:failed"))
        store.sidebarFilter = .needsYou
        XCTAssertTrue(store.sidebarFilteredSessions.allSatisfy { store.needsProjectAttention(sessionKey: $0.key) })
    }

    @MainActor func testNilCompactBackDoesNotRequestDetailOrDropOverviewConversation() throws {
        let store = store()
        store.installSessionSnapshotForTesting([try row("agent:main:chat", category: "Cast")])
        store.selectFromSidebar("agent:main:chat")
        store.selectProject("Cackles")
        let request = store.detailNavigationRequest
        store.selectFromSidebar(nil)
        XCTAssertEqual(store.detailNavigationRequest, request)
        XCTAssertEqual(store.selectedSessionKey, "agent:main:chat")
        XCTAssertTrue(store.projectOverviewPresented)
        XCTAssertEqual(store.selectedProjectName, "Cackles")
        store.projectOverviewPresented = false
        store.selectedSessionKey = nil
        XCTAssertEqual(store.detailNavigationRequest, request)
    }

    @MainActor func testSideChatActionDoesNotDismissOrRetargetMainOverview() throws {
        let store = store()
        let sideKey = "agent:main:cast-side-" + UUID().uuidString.lowercased()
        store.installSessionSnapshotForTesting([try row("agent:main:chat", category: "Cast"), try row(sideKey, category: "RunPR")])
        store.selectFromSidebar("agent:main:chat")
        store.selectProject("Cackles")
        let navigation = store.detailNavigationRequest
        store.selectFromSidebar(sideKey)
        XCTAssertTrue(store.projectOverviewPresented)
        XCTAssertEqual(store.selectedProjectName, "Cackles")
        XCTAssertEqual(store.selectedSessionKey, "agent:main:chat")
        XCTAssertEqual(store.detailNavigationRequest, navigation)
    }

    @MainActor func testDirectSameKeyDeepLinkAcknowledgesTranscriptHiddenByOverview() throws {
        let store = store()
        store.isNotificationContextVisible = true
        store.installSessionSnapshotForTesting([try row("agent:main:chat", category: "Cast")])
        store.selectedSessionKey = "agent:main:chat"
        store.selectProject("Cast")
        store.installSessionSnapshotForTesting([try row("agent:main:chat", category: "Cast", extra: ["unread": true, "updatedAt": 1000])])
        XCTAssertEqual(store.unreadCount(for: "agent:main:chat"), 1)
        let navigation = store.detailNavigationRequest
        store.selectedSessionKey = "agent:main:chat"
        XCTAssertFalse(store.projectOverviewPresented)
        XCTAssertEqual(store.unreadCount(for: "agent:main:chat"), 0)
        XCTAssertGreaterThan(store.detailNavigationRequest, navigation)
    }

    @MainActor func testCreateUpsertsRacedRichRowWithoutDuplicatingIdentityOrClearingActivity() async throws {
        let store = store()
        let key = try await store.createProjectChat(in: "Cast") { _, params in
            let key = try XCTUnwrap(params["key"] as? String)
            store.installSessionSnapshotForTesting([try self.row(key, category: "Cast", extra: [
                "sessionId": "created", "displayName": "Already named", "lastMessagePreview": "A useful answer",
                "hasActiveRun": true, "status": "running", "unread": true,
            ])])
            return try self.json(["ok": true, "key": key, "sessionId": "created"])
        }
        XCTAssertEqual(store.sessions.filter { $0.key == key }.count, 1)
        let created = try XCTUnwrap(store.projectSessions(for: "Cast").first { $0.key == key })
        XCTAssertEqual(created.title, "Already named")
        XCTAssertEqual(created.lastMessagePreview, "A useful answer")
        XCTAssertEqual(created.hasActiveRun, true)
        XCTAssertEqual(created.status, "running")
        XCTAssertTrue(created.isUnread)
    }

    @MainActor func testNewChatDoesNotReuseUncertainKeyThatWasLaterObservedAndUsed() async throws {
        let store = store()
        var uncertainKey = ""
        do {
            try await store.createProjectChat(in: "Cast") { _, params in
                uncertainKey = try XCTUnwrap(params["key"] as? String)
                throw URLError(.timedOut)
            }
        } catch {}
        store.installSessionSnapshotForTesting([try row(uncertainKey, category: "Cast", extra: ["displayName": "Used chat", "hasActiveRun": true])])
        let freshKey = try await store.createProjectChat(in: "Cast") { _, params in
            let fresh = try XCTUnwrap(params["key"] as? String)
            XCTAssertNotEqual(fresh, uncertainKey)
            return try self.json(["ok": true, "key": fresh, "sessionId": "fresh-incarnation"])
        }
        XCTAssertNotEqual(freshKey, uncertainKey)
        XCTAssertEqual(store.projectSessions(for: "Cast").first { $0.key == uncertainKey }?.title, "Used chat")
        XCTAssertEqual(store.projectSessions(for: "Cast").first { $0.key == uncertainKey }?.hasActiveRun, true)
        XCTAssertEqual(store.projectSessions(for: "Cast").count, 2)
    }

    @MainActor func testMovePreservesIndependentFirstPagePresentationAndNewInventoryState() async throws {
        let store = store()
        let rich = try row("agent:main:chat", category: "Cast", extra: ["displayName": NSNull(), "derivedTitle": "Audio recovery", "lastMessagePreview": "Detailed answer"])
        store.installSessionSnapshotForTesting([rich])
        try await store.moveSessionToProject(key: rich.key, project: "Cackles") { _, _ in
            await store.refreshUnreadInventory { _ in
                try self.json(["sessions": [["key": rich.key, "sessionId": "incarnation-1", "category": "Cast", "unread": true, "hasActiveRun": true, "status": "running"]], "hasMore": false])
            }
            return try self.json(["ok": true])
        }
        XCTAssertEqual(store.sessions.first?.derivedTitle, "Audio recovery")
        XCTAssertEqual(store.sessions.first?.lastMessagePreview, "Detailed answer")
        XCTAssertEqual(store.sessions.first?.category, "Cackles")
        let inventory = try XCTUnwrap(store.projectSessions(for: "Cackles").first)
        XCTAssertTrue(inventory.isUnread)
        XCTAssertEqual(inventory.hasActiveRun, true)
        XCTAssertEqual(inventory.title, "Audio recovery")
    }

    @MainActor func testTitlelessInventoryKeepsKnownGeneratedTitleButNotAcrossIncarnations() async throws {
        let store = store()
        store.installSessionSnapshotForTesting([try row("agent:main:chat", category: "Cast", extra: ["displayName": NSNull(), "derivedTitle": "Useful generated title", "lastMessagePreview": "Preview"] )])
        await store.refreshUnreadInventory { _ in
            try self.json(["sessions": [["key": "agent:main:chat", "sessionId": "incarnation-1", "category": "Cast"]], "hasMore": false])
        }
        XCTAssertEqual(store.projectSessions(for: "Cast").first?.title, "Useful generated title")
        await store.refreshUnreadInventory { _ in
            try self.json(["sessions": [["key": "agent:main:chat", "sessionId": "replacement", "category": "Cast"]], "hasMore": false])
        }
        XCTAssertEqual(store.projectSessions(for: "Cast").first?.title, "agent:main:chat")
    }

    @MainActor func testCategoryOnlyChangeMovesKnownIncarnationWithoutLosingReadOrTitle() throws {
        let store = store()
        store.installSessionSnapshotForTesting([try row("agent:main:chat", category: "Cast", extra: ["unread": true, "displayName": "Keep name"] )])
        func event(category: Any, incarnation: String) throws -> EventFrame {
            try JSONDecoder().decode(EventFrame.self, from: json(["event": "sessions.changed", "payload": ["sessionKey": "agent:main:chat", "session": ["key": "agent:main:chat", "sessionId": incarnation, "category": category]]]))
        }
        store.handleEvent(try event(category: "Cackles", incarnation: "incarnation-1"))
        XCTAssertEqual(store.projectName(for: "agent:main:chat"), "Cackles")
        XCTAssertEqual(store.projectSessions(for: "Cackles").first?.title, "Keep name")
        XCTAssertEqual(store.projectSessions(for: "Cackles").first?.isUnread, true)
        store.handleEvent(try event(category: "RunPR", incarnation: "obsolete"))
        XCTAssertEqual(store.projectName(for: "agent:main:chat"), "Cackles")
        store.handleEvent(try event(category: NSNull(), incarnation: "incarnation-1"))
        XCTAssertNil(store.projectName(for: "agent:main:chat"))
    }

    func testRecentSortsByInteractionDescendingNotAlphabeticalOrStreamingUpdate() throws {
        let now = Date()
        let ms = now.timeIntervalSince1970 * 1000
        let alphabeticalFirst = try row("agent:main:a", extra: ["lastInteractionAt": ms - 2000, "updatedAt": ms])
        let interactedRecently = try row("agent:main:z", extra: ["lastInteractionAt": ms - 1000, "updatedAt": ms - 1000])
        XCTAssertEqual(ProjectSidebar.filtered([alphabeticalFirst, interactedRecently], by: .recent, attentionKeys: [], now: now).map(\.key), [interactedRecently.key, alphabeticalFirst.key])
    }

    @MainActor func testMissingProjectCatalogShowsCompatibilityNotice() async {
        let store = store()
        await store.refreshProjects()
        XCTAssertNotNil(store.projectSyncNotice)
        XCTAssertTrue(store.sidebarProjects.contains { $0.name == "Cast" })
    }

    @MainActor func testArchivedFailureDoesNotAppearInAttentionKeys() throws {
        let store = store()
        store.installSessionSnapshotForTesting([try row("agent:main:archived", category: "Cast", extra: ["archived": true, "status": "failed"] )])
        XCTAssertFalse(store.projectAttentionKeys.contains("agent:main:archived"))
    }

    @MainActor func testCreatedConversationAdoptsGeneratedTitleAndRetainsItAcrossMetadataInventory() async throws {
        let store = store()
        let key = try await store.createProjectChat(in: "Cast") { _, params in
            try self.json(["ok": true, "key": params["key"] as! String, "sessionId": "created-title"])
        }
        XCTAssertEqual(store.projectSessions(for: "Cast").first?.title, "New conversation")
        XCTAssertNil(store.projectSessions(for: "Cast").first?.displayName)
        XCTAssertEqual(SidebarGrouper.displayTitle(for: try XCTUnwrap(store.projectSessions(for: "Cast").first)), "New conversation")
        let event = try JSONDecoder().decode(EventFrame.self, from: json(["event": "sessions.changed", "payload": ["sessionKey": key, "session": ["key": key, "sessionId": "created-title", "category": "Cast", "unread": false, "derivedTitle": "Audio recovery"]]]))
        store.handleEvent(event)
        XCTAssertEqual(store.projectSessions(for: "Cast").first?.title, "Audio recovery")
        await store.refreshUnreadInventory { _ in
            try self.json(["sessions": [["key": key, "sessionId": "created-title", "category": "Cast"]], "hasMore": false])
        }
        XCTAssertEqual(store.projectSessions(for: "Cast").first?.title, "Audio recovery")
    }

}
