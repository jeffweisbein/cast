import XCTest
@testable import Cast

@MainActor final class SideChatRecoveryTests: XCTestCase {
    let key = "agent:main:cast-side-11111111-1111-4111-8111-111111111111"
    func profile(_ id: String = "a", _ url: String = "ws://127.0.0.1:9") -> WorkspaceProfile {
        WorkspaceProfile(id: id, name: "Fixture", gatewayURL: URL(string: url)!, accent: "orange")
    }
    func rows() throws -> [SessionRow] {
        try JSONDecoder().decode([SessionRow].self, from: Data("[{\"key\":\"\(key)\",\"derivedTitle\":\"Saved captions question\",\"updatedAt\":1}]".utf8))
    }
    func testLegacyDiscoverySurvivesFreshStoreAndClosePreservesLocator() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        let data = try JSONSerialization.data(withJSONObject: ["sessions": [["key": key, "derivedTitle": "Saved captions question", "updatedAt": 1]]])
        await store.refreshSessions { data }
        XCTAssertEqual(store.savedSideChats.map(\.sessionKey), [key])
        store.resumeSideChat(key)
        XCTAssertEqual(store.sideChat?.sessionKey, key)
        XCTAssertTrue(store.isSideChatPresented)
        XCTAssertNil(store.selectedSessionKey, "Side chat must not become the main transcript")
        let relaunched = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        XCTAssertEqual(relaunched.sideChat?.sessionKey, key)
        XCTAssertTrue(relaunched.isSideChatPresented)
        relaunched.closeSideChat()
        let closedRelaunch = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        XCTAssertFalse(closedRelaunch.isSideChatPresented)
        XCTAssertEqual(closedRelaunch.savedSideChats.count, 1)
        closedRelaunch.resumeSideChat(key)
        XCTAssertTrue(closedRelaunch.isSideChatPresented)
    }
    func testProfileAndGatewayIdentityDoNotLeakLocators() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        a.discoverSideChats(try rows()); a.resumeSideChat(key)
        for other in [profile("b"), profile("a", "ws://127.0.0.1:10")] {
            let b = ChatStore(profile: other, transcriptCacheRoot: root, operationsLedgerRoot: root)
            XCTAssertTrue(b.savedSideChats.isEmpty); XCTAssertNil(b.sideChat)
        }
        var renamed = profile(); renamed.name = "Renamed"
        XCTAssertEqual(ChatStore(profile: renamed, transcriptCacheRoot: root, operationsLedgerRoot: root).savedSideChats.count, 1)
    }
    func testResumeLoadsQuoteAndNeverCreatesOrMutatesMainSession() async throws {
        let quote = "Keep this original passage"
        let initial = SideChat.initialMessage(context: quote, question: "Explain captions")
        var calls: [(String, [String: Any?])] = []
        let saved = SavedSideChat(sessionKey: key, sourceSessionKey: "agent:main:main", context: "", title: "Saved", created: true, hasSent: true)
        let chat = SideChat(saved: saved, persist: { _ in }) { method, params in
            calls.append((method, params))
            if method == "sessions.list" { return try JSONSerialization.data(withJSONObject: ["sessions": [["key": self.key]]]) }
            if method == "chat.history" {
                return try JSONSerialization.data(withJSONObject: ["sessionKey": self.key, "messages": [["role":"user", "content": initial]], "sessionInfo": ["hasActiveRun": false]])
            }
            return Data("{}".utf8)
        }
        chat.draft = "Next question"
        await chat.send()
        XCTAssertTrue(calls.isEmpty, "Unknown saved history must block send")
        await chat.reconnect()
        XCTAssertEqual(chat.context, quote)
        XCTAssertEqual(chat.messages.count, 1)
        await chat.send()
        XCTAssertFalse(calls.contains { $0.0 == "sessions.create" })
        XCTAssertFalse(calls.contains { $0.0 == "sessions.patch" })
        let send = try XCTUnwrap(calls.first { $0.0 == "chat.send" })
        XCTAssertEqual(send.1["sessionKey"] as? String, key)
        XCTAssertEqual(send.1["message"] as? String, "Next question")
        XCTAssertEqual(send.1["deliver"] as? Bool, false)
    }
    func testUnconfirmedDeliverySurvivesProcessStateAndUsesSameID() async throws {
        var persisted: SavedSideChat?
        var ids: [String] = []
        let request: (String, [String: Any?]) async throws -> Data = { method, params in
            if method == "sessions.create" { return try JSONSerialization.data(withJSONObject: ["key": params["key"]!!]) }
            if method == "sessions.list" { return try JSONSerialization.data(withJSONObject: ["sessions": [["key": params["search"]!!]]]) }
            if method == "chat.send" { ids.append(params["idempotencyKey"] as! String); throw URLError(.timedOut) }
            if method == "chat.history" { return Data(#"{"messages":[],"sessionInfo":{"hasActiveRun":false}}"#.utf8) }
            return Data("{}".utf8)
        }
        let chat = SideChat(sourceSessionKey: "agent:main:main", context: "original", request: request)
        chat.enablePersistence { persisted = $0 }
        chat.draft = "Question"; await chat.send()
        let saved = try XCTUnwrap(persisted)
        let reopened = SideChat(saved: saved, persist: { persisted = $0 }, request: request)
        await reopened.reconnect(); await reopened.send()
        XCTAssertEqual(ids.count, 2); XCTAssertEqual(ids.first, ids.last)
        XCTAssertEqual(reopened.sessionKey, chat.sessionKey)
        XCTAssertEqual(reopened.context, "original")
    }
    func testUnavailableSavedConversationDoesNotCreateReplacement() async {
        var methods: [String] = []
        let saved = SavedSideChat(sessionKey: key, sourceSessionKey: "agent:main:main", context: "", title: "Saved", created: true)
        let chat = SideChat(saved: saved, persist: { _ in }) { method, _ in methods.append(method); throw URLError(.resourceUnavailable) }
        await chat.reconnect(); chat.draft = "Try again"; await chat.send()
        XCTAssertNotNil(chat.error); XCTAssertFalse(chat.historyLoaded)
        XCTAssertFalse(methods.contains("sessions.create")); XCTAssertFalse(methods.contains("chat.send"))
        XCTAssertEqual(chat.sessionKey, key)
    }
    func testMissingSessionRowBlocksHistoryAndSendWithoutReplacement() async {
        var methods: [String] = []
        let saved = SavedSideChat(sessionKey: key, sourceSessionKey: "agent:main:main", context: "", title: "Saved", created: true)
        let chat = SideChat(saved: saved, persist: { _ in }) { method, _ in
            methods.append(method)
            return Data(#"{"sessions":[]}"#.utf8)
        }
        await chat.reconnect(); chat.draft = "Question"; await chat.send()
        XCTAssertEqual(methods, ["sessions.list"])
        XCTAssertFalse(chat.historyLoaded); XCTAssertNotNil(chat.error)
    }
    func testLegacyQuoteCanBeRecoveredBeyondLatestHistoryWindow() async throws {
        var offsets: [Int] = []
        let saved = SavedSideChat(sessionKey: key, sourceSessionKey: "agent:main:main", context: "", title: "Saved", created: true, hasSent: true)
        let chat = SideChat(saved: saved, persist: { _ in }) { method, params in
            if method == "sessions.list" { return try JSONSerialization.data(withJSONObject: ["sessions": [["key": self.key]]]) }
            if method == "chat.history" {
                if let offset = params["offset"] as? Int {
                    offsets.append(offset)
                    return try JSONSerialization.data(withJSONObject: ["messages": [["role": "user", "content": SideChat.initialMessage(context: "Original distant quote", question: "Initial question")]]])
                }
                return Data(#"{"messages":[{"role":"user","content":"Recent follow-up"}],"totalMessages":200,"sessionInfo":{"hasActiveRun":false}}"#.utf8)
            }
            return Data("{}".utf8)
        }
        await chat.reconnect()
        XCTAssertEqual(offsets, [120]); XCTAssertEqual(chat.context, "Original distant quote")
        XCTAssertEqual(chat.snapshot.title, "Initial question")
        XCTAssertEqual(chat.messages.first?.text, "Recent follow-up")
    }
    func testCorruptLocalIndexIsPreservedNotReplacedWithEmptyState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = SideChatArchive.store(root: root, profile: profile())
        try FileManager.default.createDirectory(at: disk.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("damaged but retained".utf8)
        try bytes.write(to: disk.fileURL)
        let store = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        store.discoverSideChats(try rows())
        XCTAssertNotNil(store.sideChatDiscoveryError)
        XCTAssertEqual(try Data(contentsOf: disk.fileURL), bytes)
    }
    func testStoreRoutesSideEventsWithoutChangingMainConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        store.selectedSessionKey = "agent:main:main"
        store.discoverSideChats(try rows()); store.resumeSideChat(key)
        store.handleEvent(EventFrame(event: "chat", payload: AnyCodable(["sessionKey": key, "state": "delta", "deltaText": "Side answer"].mapValues { AnyCodable($0) }), seq: nil))
        XCTAssertEqual(store.sideChat?.streamingText, "Side answer")
        XCTAssertEqual(store.streamingText, ""); XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.selectedSessionKey, "agent:main:main")
    }
    func testExactSessionBeyondFirstSearchPageCanReopen() async throws {
        var offsets: [Int] = []
        let saved = SavedSideChat(sessionKey: key, sourceSessionKey: "agent:main:main", context: "Quote", title: "Saved", created: true)
        let chat = SideChat(saved: saved, persist: { _ in }) { method, params in
            if method == "sessions.list" {
                let offset = params["offset"] as? Int ?? 0
                offsets.append(offset)
                let matches = offset == 0 ? (0..<10).map { ["key": "agent:main:other-\($0)", "displayName": self.key] } : [["key": self.key]]
                return try JSONSerialization.data(withJSONObject: ["sessions": matches])
            }
            if method == "chat.history" { return Data(#"{"messages":[{"role":"assistant","content":"Saved answer"}]}"#.utf8) }
            return Data("{}".utf8)
        }
        await chat.reconnect()
        XCTAssertEqual(offsets, [0, 10])
        XCTAssertTrue(chat.historyLoaded)
        XCTAssertEqual(chat.messages.first?.text, "Saved answer")
        XCTAssertNil(chat.error)
    }

    func testOlderIdenticalQuestionCannotConfirmNewUncertainSendAfterRelaunch() async throws {
        var saved = SavedSideChat(sessionKey: key, sourceSessionKey: "agent:main:main", context: "Quote", title: "Saved", created: true, hasSent: true)
        var sends = 0
        var deliveredID: String? = "older-delivery:user"
        let request: (String, [String: Any?]) async throws -> Data = { method, _ in
            if method == "sessions.list" { return try JSONSerialization.data(withJSONObject: ["sessions": [["key": self.key]]]) }
            if method == "chat.send" { sends += 1; throw URLError(.notConnectedToInternet) }
            if method == "chat.history" {
                var message = ["role": "user", "content": "Repeat question"]
                message["idempotencyKey"] = deliveredID
                return try JSONSerialization.data(withJSONObject: ["sessionKey": self.key, "messages": [message], "sessionInfo": ["hasActiveRun": false]])
            }
            return Data("{}".utf8)
        }
        let chat = SideChat(saved: saved, persist: { saved = $0 }, request: request)
        await chat.reconnect()
        chat.draft = "Repeat question"
        await chat.send()
        let pendingID = try XCTUnwrap(saved.sendID)
        // Encode/decode the actual archive value, not a new manually assembled pending send.
        let diskState = try JSONDecoder().decode(SavedSideChat.self, from: JSONEncoder().encode(saved))
        let relaunched = SideChat(saved: diskState, persist: { saved = $0 }, request: request)
        await relaunched.reconnect()
        XCTAssertEqual(relaunched.draft, "Repeat question")
        XCTAssertEqual(saved.sendID, pendingID)
        XCTAssertEqual(saved.pendingQuestion, "Repeat question")
        XCTAssertNotNil(relaunched.error, "Unresolved delivery remains visible after reconnect")
        XCTAssertEqual(sends, 1, "Reopening never resends")
        // Legacy history without delivery identity is also insufficient.
        deliveredID = nil
        await relaunched.refresh()
        XCTAssertEqual(saved.sendID, pendingID)
        XCTAssertEqual(relaunched.draft, "Repeat question")
        // An exact wire delivery identity may confirm the pending send.
        deliveredID = pendingID + ":user"
        await relaunched.refresh()
        XCTAssertNil(saved.sendID)
        XCTAssertNil(saved.pendingQuestion)
        XCTAssertEqual(relaunched.draft, "")
        XCTAssertEqual(sends, 1)
    }

    func testSuccessfulDiscoveryDoesNotClearCorruptArchiveWarning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = SideChatArchive.store(root: root, profile: profile())
        try FileManager.default.createDirectory(at: disk.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("retained corrupt archive".utf8)
        try original.write(to: disk.fileURL)
        let store = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        await store.refreshSideChats { _, _ in
            try JSONSerialization.data(withJSONObject: ["sessions": [["key": self.key]]])
        }
        XCTAssertEqual(store.savedSideChats.count, 1)
        XCTAssertNotNil(store.sideChatDiscoveryError)
        XCTAssertEqual(try Data(contentsOf: disk.fileURL), original)
    }

    func testSuccessfulDiscoveryDoesNotClearSaveFailureAndLaterSaveRecovers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        let disk = SideChatArchive.store(root: root, profile: profile())
        try FileManager.default.removeItem(at: disk.fileURL)
        try FileManager.default.createDirectory(at: disk.fileURL, withIntermediateDirectories: false)
        await store.refreshSideChats { _, _ in
            try JSONSerialization.data(withJSONObject: ["sessions": [["key": self.key]]])
        }
        XCTAssertNotNil(store.sideChatDiscoveryError)
        try FileManager.default.removeItem(at: disk.fileURL)
        await store.refreshSideChats { _, _ in Data(#"{"sessions":[]}"#.utf8) }
        XCTAssertNil(store.sideChatDiscoveryError)
        XCTAssertEqual(try disk.load(defaultValue: SideChatArchive()).chats.count, 1)
    }

    func testSensitiveArchiveUsesOwnerOnlyPermissionsAcrossAtomicReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = SideChatArchive.store(root: root, profile: profile())
        for title in ["First", "Replacement"] {
            let saved = SavedSideChat(sessionKey: key, sourceSessionKey: "agent:main:main", context: "Private quote", title: title, created: true, draft: "Private draft")
            try disk.save(SideChatArchive(chats: [key: saved]))
            let file = try FileManager.default.attributesOfItem(atPath: disk.fileURL.path)
            let directory = try FileManager.default.attributesOfItem(atPath: disk.fileURL.deletingLastPathComponent().path)
            XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual(try disk.load(defaultValue: SideChatArchive()).chats[key]?.title, title)
        }
    }

    func testSideChatKeyRecognitionIsExact() {
        XCTAssertTrue(SavedSideChat.isSideChatKey(key))
        XCTAssertFalse(SavedSideChat.isSideChatKey("agent:main:main"))
        XCTAssertFalse(SavedSideChat.isSideChatKey(key + ":subagent:child"))
        XCTAssertFalse(SavedSideChat.isSideChatKey("agent:main:cast-side-invalid"))
    }

    private let now: Double = 2_000_000_000_000
    private var old: Double { now - 90 * 86_400_000 }
    private func row(_ updates: [String: Any] = [:]) throws -> SessionRow {
        var fields: [String: Any] = ["key": key, "updatedAt": old, "hasActiveRun": false, "unread": false]
        fields.merge(updates) { _, new in new }
        return try JSONDecoder().decode(SessionRow.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    private func archive() -> SideChatArchive {
        let saved = SavedSideChat(sessionKey: key, sourceSessionKey: "agent:main:main", context: "Original", title: "Saved", created: true)
        return SideChatArchive(chats: [key: saved], presentation: [key: SideChatPresentation(lastUsedAt: old, gatewayUpdatedAt: old)], autoArchiveDays: 30)
    }

    func testArchiveSchemaReadsLegacyRecoveryWithoutLosingPendingDelivery() throws {
        let original = SavedSideChat(sessionKey: key, sourceSessionKey: "agent:main:main", context: "Quote", title: "Saved", created: true, draft: "Uncertain question", sendID: "send-1", pendingQuestion: "Uncertain question", pendingMessage: "Wire message")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SideChatArchive(chats: [key: original]))) as! [String: Any]
        object.removeValue(forKey: "presentation"); object.removeValue(forKey: "autoArchiveDays")
        var decoded = try JSONDecoder().decode(SideChatArchive.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.autoArchiveDays); XCTAssertNil(decoded.presentation)
        decoded.setArchived(.manual, key: key, now: now)
        let roundtrip = try JSONDecoder().decode(SideChatArchive.self, from: JSONEncoder().encode(decoded))
        XCTAssertTrue(roundtrip.isArchived(key))
        XCTAssertEqual(roundtrip.chats[key]?.sendID, "send-1")
        XCTAssertEqual(roundtrip.chats[key]?.pendingMessage, "Wire message")
        XCTAssertEqual(roundtrip.chats[key]?.draft, "Uncertain question")
    }

    func testInactiveArchiveIsOffByDefaultAndHonorsThirtySixtyNinetyDayBoundaries() throws {
        let row = try row()
        var value = archive()
        for days in [30, 60, 90] {
            value.autoArchiveDays = days
            value.presentation?[key]?.lastUsedAt = now - Double(days) * 86_400_000 + 1
            XCTAssertTrue(value.inactiveKeys(rows: [row], now: now, protectedKeys: []).isEmpty)
            value.presentation?[key]?.lastUsedAt = now - Double(days) * 86_400_000
            XCTAssertEqual(value.inactiveKeys(rows: [row], now: now, protectedKeys: []), [key])
        }
        for setting in [nil, 0, 29, -1] as [Int?] {
            value.autoArchiveDays = setting
            XCTAssertTrue(value.inactiveKeys(rows: [row], now: now, protectedKeys: []).isEmpty)
        }
    }

    func testInactiveArchiveRejectsUnknownFutureRecentActivityAndActiveUnreadPinnedRows() throws {
        let value = archive()
        let variants: [[String: Any]] = [
            ["updatedAt": NSNull()], ["updatedAt": 0], ["updatedAt": -1], ["updatedAt": now + 1],
            ["updatedAt": now - 1], ["hasActiveRun": true], ["hasActiveRun": NSNull()],
            ["unread": true], ["pinned": true], ["status": "running"], ["status": "queued"], ["status": "unknown"]
        ]
        for fields in variants {
            XCTAssertTrue(value.inactiveKeys(rows: [try row(fields)], now: now, protectedKeys: []).isEmpty, "Unsafe row: \(fields)")
        }
        XCTAssertTrue(value.inactiveKeys(rows: [try row()], now: now, protectedKeys: [key]).isEmpty)
        XCTAssertFalse(SideChatArchive.trustedTime(.infinity, now: now))
        XCTAssertFalse(SideChatArchive.trustedTime(.nan, now: now))
        XCTAssertTrue(value.inactiveKeys(rows: [], now: now, protectedKeys: []).isEmpty)
    }

    func testInactiveArchiveProtectsDraftPendingDeliveryAndUnknownLocalClock() throws {
        for field in ["draft", "sendID", "pendingQuestion", "pendingMessage", "clock", "futureClock"] {
            var value = archive()
            switch field {
            case "draft": value.chats[key]?.draft = "Unsaved thought"
            case "sendID": value.chats[key]?.sendID = "uncertain"
            case "pendingQuestion": value.chats[key]?.pendingQuestion = "Question"
            case "pendingMessage": value.chats[key]?.pendingMessage = "Message"
            case "clock": value.presentation?[key]?.lastUsedAt = nil
            default: value.presentation?[key]?.lastUsedAt = now + 1
            }
            XCTAssertTrue(value.inactiveKeys(rows: [try row()], now: now, protectedKeys: []).isEmpty, field)
        }
    }

    func testRefreshDoesNotCountAsUseAndLegacyChatsReceiveGracePeriod() throws {
        let row = try row()
        var value = archive()
        value.observe(row, now: now)
        XCTAssertEqual(value.presentation?[key]?.lastUsedAt, old)
        XCTAssertEqual(value.inactiveKeys(rows: [row], now: now, protectedKeys: []), [key])
        value.presentation = nil
        value.observe(row, now: now)
        XCTAssertEqual(value.presentation?[key]?.lastUsedAt, now)
        XCTAssertTrue(value.inactiveKeys(rows: [row], now: now, protectedKeys: []).isEmpty)
    }

    func testNewGatewayActivityRestoresOnlyAutomaticallyArchivedChats() throws {
        for reason in [SideChatArchiveReason.manual, .inactive] {
            var value = archive()
            value.setArchived(reason, key: key, now: now)
            value.observe(try row(), now: now)
            XCTAssertTrue(value.isArchived(key), "Unchanged refresh is not new activity")
            value.observe(try row(["updatedAt": now]), now: now)
            XCTAssertEqual(value.isArchived(key), reason == .manual)
            value.setArchived(nil, key: key, now: now)
            XCTAssertTrue(value.inactiveKeys(rows: [try row()], now: now, protectedKeys: []).isEmpty, "Restore starts a new grace period")
        }
    }

    func testArchiveRestoreSurvivesRelaunchRediscoveryAndKeepsMainDraftAndLocator() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = SideChatArchive.store(root: root, profile: profile())
        var value = archive(); value.chats[key]?.draft = "Keep draft"; value.chats[key]?.sendID = "pending"
        value.chats[key]?.pendingMessage = "Keep wire message"
        try disk.save(value)
        let store = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        store.selectedSessionKey = "agent:main:main"
        store.archiveSideChat(key)
        XCTAssertTrue(store.savedSideChats.isEmpty); XCTAssertEqual(store.archivedSideChats.count, 1)
        XCTAssertEqual(store.selectedSessionKey, "agent:main:main")
        store.discoverSideChats(try rows())
        XCTAssertTrue(store.savedSideChats.isEmpty, "Rediscovery must not undo explicit Archive")
        let relaunched = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        XCTAssertTrue(relaunched.savedSideChats.isEmpty); XCTAssertEqual(relaunched.archivedSideChats.count, 1)
        relaunched.restoreArchivedSideChat(key)
        XCTAssertEqual(relaunched.savedSideChats.first?.sessionKey, key)
        XCTAssertEqual(relaunched.savedSideChats.first?.draft, "Keep draft")
        XCTAssertEqual(relaunched.savedSideChats.first?.sendID, "pending")
        XCTAssertEqual(relaunched.savedSideChats.first?.context, "Original")
        XCTAssertTrue(relaunched.archivedSideChats.isEmpty)
        XCTAssertNil(relaunched.sideChat, "Restore must not create/send/open a conversation")
    }

    func testArchiveCurrentChatClosesPaneWithoutChangingMainAndUndoRestores() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        store.discoverSideChats(try rows()); store.resumeSideChat(key)
        store.selectedSessionKey = "agent:main:main"
        store.archiveSideChat(key)
        XCTAssertFalse(store.isSideChatPresented)
        XCTAssertEqual(store.sideChat?.sessionKey, key)
        XCTAssertEqual(store.selectedSessionKey, "agent:main:main")
        store.undoArchiveSideChat()
        XCTAssertEqual(store.savedSideChats.count, 1)
        XCTAssertNil(store.lastArchivedSideChatKey)
    }

    func testRunningSideChatCannotBeManuallyArchived() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        store.discoverSideChats([try row(["hasActiveRun": true])])
        XCTAssertFalse(store.canArchiveSideChat(key))
        store.archiveSideChat(key)
        XCTAssertEqual(store.savedSideChats.count, 1); XCTAssertTrue(store.archivedSideChats.isEmpty)
    }

    func testArchiveSaveFailureKeepsVisibleStateAndCorruptIndexBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        store.discoverSideChats(try rows())
        let disk = SideChatArchive.store(root: root, profile: profile())
        try FileManager.default.removeItem(at: disk.fileURL)
        try FileManager.default.createDirectory(at: disk.fileURL, withIntermediateDirectories: false)
        store.archiveSideChat(key)
        XCTAssertEqual(store.savedSideChats.count, 1); XCTAssertTrue(store.archivedSideChats.isEmpty)
        XCTAssertNil(store.lastArchivedSideChatKey); XCTAssertNotNil(store.sideChatDiscoveryError)
        try FileManager.default.removeItem(at: disk.fileURL)
        let corrupt = Data("preserve this corrupt index".utf8); try corrupt.write(to: disk.fileURL)
        let broken = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        broken.discoverSideChats(try rows()); broken.archiveSideChat(key)
        XCTAssertEqual(broken.savedSideChats.count, 1)
        XCTAssertEqual(try Data(contentsOf: disk.fileURL), corrupt)
    }

    func testAutoArchiveRequiresCompleteRefreshAndNeverMakesMutationRPC() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let realNow = Date().timeIntervalSince1970 * 1000
        var value = archive()
        value.presentation?[key]?.lastUsedAt = realNow - 91 * 86_400_000
        value.presentation?[key]?.gatewayUpdatedAt = realNow - 91 * 86_400_000
        let disk = SideChatArchive.store(root: root, profile: profile()); try disk.save(value)
        let store = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        let fields: [String: Any] = ["key": key, "updatedAt": realNow - 91 * 86_400_000, "hasActiveRun": false]
        var calls = 0
        await store.refreshSideChats { method, _ in
            XCTAssertEqual(method, "sessions.list"); calls += 1
            if calls > 1 { throw URLError(.timedOut) }
            return try JSONSerialization.data(withJSONObject: ["sessions": Array(repeating: fields, count: 100)])
        }
        XCTAssertEqual(store.savedSideChats.count, 1, "A partial refresh cannot archive")
        await store.refreshSideChats { method, _ in
            XCTAssertEqual(method, "sessions.list")
            return try JSONSerialization.data(withJSONObject: ["sessions": [fields], "hasMore": false, "totalCount": 1])
        }
        XCTAssertTrue(store.savedSideChats.isEmpty); XCTAssertEqual(store.archivedSideChats.count, 1)
        XCTAssertEqual(try disk.load(defaultValue: SideChatArchive()).chats.count, 1, "History locator is retained")
    }

    func testArchivePreferencesAndStateDoNotCrossProfileOrGateway() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        store.discoverSideChats(try rows()); store.archiveSideChat(key); store.setSideChatAutoArchiveDays(60)
        for other in [profile("b"), profile("a", "ws://127.0.0.1:10")] {
            let fresh = ChatStore(profile: other, transcriptCacheRoot: root, operationsLedgerRoot: root)
            XCTAssertEqual(fresh.sideChatAutoArchiveDays, 0); XCTAssertTrue(fresh.archivedSideChats.isEmpty)
            fresh.discoverSideChats(try rows()); XCTAssertEqual(fresh.savedSideChats.count, 1)
        }
        let reopened = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        XCTAssertEqual(reopened.sideChatAutoArchiveDays, 60); XCTAssertEqual(reopened.archivedSideChats.count, 1)
    }


    func testShortOrUnconfirmedGatewayPagesCannotAutoArchive() async throws {
        let realNow = Date().timeIntervalSince1970 * 1000
        let metadata: [[String: Any]] = [
            [:], ["hasMore": true, "nextOffset": 1], ["hasMore": false, "truncated": true],
            ["hasMore": true, "nextOffset": 0], ["hasMore": false, "nextOffset": 1],
            ["hasMore": false, "totalCount": 2]
        ]
        for flags in metadata {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var value = archive()
            value.presentation?[key]?.lastUsedAt = realNow - 91 * 86_400_000
            value.presentation?[key]?.gatewayUpdatedAt = realNow - 91 * 86_400_000
            try SideChatArchive.store(root: root, profile: profile()).save(value)
            let store = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
            var calls = 0
            await store.refreshSideChats { method, _ in
                XCTAssertEqual(method, "sessions.list"); calls += 1
                if calls > 1 { throw URLError(.timedOut) }
                var payload = flags
                payload["sessions"] = [["key": self.key, "updatedAt": realNow - 91 * 86_400_000, "hasActiveRun": false]]
                return try JSONSerialization.data(withJSONObject: payload)
            }
            XCTAssertEqual(store.savedSideChats.count, 1, "Incomplete/unconfirmed page must not archive: \(flags)")
            XCTAssertTrue(store.archivedSideChats.isEmpty)
        }
    }


    func testShortPagesFollowGatewayCursorAndOnlyArchiveAfterConfirmedEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let realNow = Date().timeIntervalSince1970 * 1000
        var value = archive()
        value.presentation?[key]?.lastUsedAt = realNow - 91 * 86_400_000
        value.presentation?[key]?.gatewayUpdatedAt = realNow - 91 * 86_400_000
        try SideChatArchive.store(root: root, profile: profile()).save(value)
        let store = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        var offsets: [Int] = []
        await store.refreshSideChats { method, params in
            XCTAssertEqual(method, "sessions.list")
            let offset = params["offset"] as? Int ?? 0; offsets.append(offset)
            if offset == 0 {
                XCTAssertEqual(store.savedSideChats.count, 1)
                return try JSONSerialization.data(withJSONObject: ["sessions": [["key": self.key, "updatedAt": realNow - 91 * 86_400_000, "hasActiveRun": false]], "hasMore": true, "nextOffset": 7])
            }
            XCTAssertEqual(store.savedSideChats.count, 1, "Do not archive before the terminal page")
            return Data(#"{"sessions":[],"hasMore":false,"nextOffset":null,"totalCount":1}"#.utf8)
        }
        XCTAssertEqual(offsets, [0, 7]); XCTAssertEqual(store.archivedSideChats.count, 1)
    }


    func testAnyProtectedDuplicateObservationVetoesOlderEligiblePage() throws {
        let value = archive(), eligible = try row()
        for newer in [["hasActiveRun": true], ["unread": true], ["pinned": true], ["updatedAt": now], ["updatedAt": NSNull()]] as [[String: Any]] {
            let protected = try row(newer)
            XCTAssertTrue(value.inactiveKeys(rows: [eligible, protected], now: now, protectedKeys: []).isEmpty)
            XCTAssertTrue(value.inactiveKeys(rows: [protected, eligible], now: now, protectedKeys: []).isEmpty)
        }
        XCTAssertEqual(value.inactiveKeys(rows: [eligible, eligible], now: now, protectedKeys: []), [key])
    }

    func testIncomingActivityRestoresAutoArchiveButPreservesExplicitArchiveAndMainSelection() throws {
        for reason in [SideChatArchiveReason.manual, .inactive] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var value = archive()
            value.presentation?[key]?.lastUsedAt = 1
            value.setArchived(reason, key: key, now: now)
            try SideChatArchive.store(root: root, profile: profile()).save(value)
            let store = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
            store.selectedSessionKey = "agent:main:main"
            store.handleEvent(EventFrame(event: "chat", payload: AnyCodable(["sessionKey": key, "state": "delta", "deltaText": "New answer"].mapValues { AnyCodable($0) }), seq: nil))
            XCTAssertEqual(store.archivedSideChats.count, reason == .manual ? 1 : 0)
            XCTAssertEqual(store.selectedSessionKey, "agent:main:main")
            XCTAssertFalse(store.isSideChatPresented)
            XCTAssertTrue(store.messages.isEmpty)
        }
    }

    func testSuspendingDuringDiscoveryPreventsStaleAutoArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let realNow = Date().timeIntervalSince1970 * 1000
        var value = archive()
        value.presentation?[key]?.lastUsedAt = realNow - 91 * 86_400_000
        value.presentation?[key]?.gatewayUpdatedAt = realNow - 91 * 86_400_000
        try SideChatArchive.store(root: root, profile: profile()).save(value)
        let store = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        await store.refreshSideChats { _, _ in
            store.suspendForBackground()
            return try JSONSerialization.data(withJSONObject: ["sessions": [["key": self.key, "updatedAt": realNow - 91 * 86_400_000, "hasActiveRun": false]], "hasMore": false])
        }
        XCTAssertEqual(store.savedSideChats.count, 1); XCTAssertTrue(store.archivedSideChats.isEmpty)
    }

    func testDraftSnapshotCannotUndoArchiveAndOpenChatCannotAutoArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(profile: profile(), transcriptCacheRoot: root, operationsLedgerRoot: root)
        store.discoverSideChats(try rows()); store.resumeSideChat(key)
        let chat = try XCTUnwrap(store.sideChat)
        store.archiveSideChat(key)
        chat.draft = "A later draft snapshot"
        XCTAssertEqual(store.archivedSideChats.count, 1)
        XCTAssertEqual(store.archivedSideChats.first?.draft, "A later draft snapshot")
        store.resumeSideChat(key); chat.draft = ""
        store.setSideChatAutoArchiveDays(30)
        store.archiveInactiveSideChats(rows: [try row()], now: now)
        XCTAssertTrue(store.archivedSideChats.isEmpty, "Presented chat is protected even after long clock advance")
    }

}

@MainActor final class SideChatArchiveSyncTests: XCTestCase {
    let key = "agent:main:cast-side-11111111-1111-4111-8111-111111111111"
    func testManualArchiveAndRestoreReachSecondDeviceAndRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = WorkspaceProfile(id: "sync", name: "Fixture", gatewayURL: URL(string: "ws://127.0.0.1:9")!, accent: "orange")
        var entries: [String: Any] = [:]
        var methods: [String] = []
        let request: (String, [String: Any?]) async throws -> Data = { method, params in
            methods.append(method)
            if method == "users.self" { return Data(#"{"profile":{"id":"person-a"}}"#.utf8) }
            if method == "users.prefs.get" { return try JSONSerialization.data(withJSONObject: ["status": "ok", "entries": entries]) }
            XCTAssertEqual(method, "users.prefs.set")
            // Exercise the actual gateway wire encoder, not just the injected closure.
            let frame = RequestFrame(id: "sync-wire", method: method, params: GatewayClient.jsonValue(params))
            let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as! [String: Any]
            let encoded = wire["params"] as! [String: Any]
            let expected = encoded["expectedEntries"] as! [String: Any]
            if entries.isEmpty { XCTAssertTrue(expected[SideChatArchive.preferenceKey] is NSNull) }
            else { XCTAssertNotNil(expected[SideChatArchive.preferenceKey] as? [String: Any]) }
            entries = encoded["entries"] as! [String: Any]
            return Data(#"{"status":"ok"}"#.utf8)
        }
        let rows = try JSONDecoder().decode([SessionRow].self, from: Data("[{\"key\":\"\(key)\",\"hasActiveRun\":false}]".utf8))
        func device(_ name: String) -> ChatStore {
            ChatStore(profile: profile, transcriptCacheRoot: root.appendingPathComponent(name), operationsLedgerRoot: root.appendingPathComponent(name))
        }
        let mac = device("mac"), phone = device("phone")
        mac.discoverSideChats(rows); phone.discoverSideChats(rows)
        mac.archiveSideChat(key)
        await mac.syncSideChatArchives(request: request)
        await phone.syncSideChatArchives(request: request)
        XCTAssertEqual(phone.archivedSideChats.map(\.sessionKey), [key])
        phone.restoreArchivedSideChat(key)
        await phone.syncSideChatArchives(request: request)
        await mac.syncSideChatArchives(request: request)
        XCTAssertEqual(mac.savedSideChats.map(\.sessionKey), [key])
        let relaunched = device("mac")
        await relaunched.syncSideChatArchives(request: request)
        XCTAssertTrue(relaunched.archivedSideChats.isEmpty)
        XCTAssertFalse(methods.contains("sessions.patch"))
    }

    func testLegacyMigrationHonorsRemoteRestoreTombstoneAndPendingRestore() {
        var archive = SideChatArchive()
        archive.setArchived(.manual, key: key, now: 1)
        XCTAssertEqual(archive.mergedArchivePreferences([:])[key], true)
        XCTAssertEqual(archive.mergedArchivePreferences([key: false])[key], false)
        archive.queueArchiveSync(false, key: key)
        XCTAssertEqual(archive.mergedArchivePreferences([key: true])[key], false)
        archive.applyArchivePreferences([key: false], sent: [key: false], now: 2)
        XCTAssertFalse(archive.isArchived(key))
        XCTAssertTrue(archive.archiveSyncPending!.isEmpty)
        XCTAssertEqual(archive.archiveSyncMigrated, true)
    }

    func testAccountChangesNeverWritePreferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = WorkspaceProfile(id: "sync", name: "Fixture", gatewayURL: URL(string: "ws://127.0.0.1:9")!, accent: "orange")
        let disk = SideChatArchive.store(root: root, profile: profile)
        var archive = SideChatArchive(); archive.archiveSyncProfileID = "person-a"
        try disk.save(archive)
        let store = ChatStore(profile: profile, transcriptCacheRoot: root, operationsLedgerRoot: root)
        for account in ["person-b"] {
            var methods: [String] = []
            await store.syncSideChatArchives { method, _ in
                methods.append(method)
                return try JSONSerialization.data(withJSONObject: ["profile": ["id": account]])
            }
            XCTAssertEqual(methods, ["users.self"])
            XCTAssertNotNil(store.sideChatDiscoveryError)
        }
    }

    func testFailedPreferenceWriteKeepsPendingAcrossRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = WorkspaceProfile(id: "sync", name: "Fixture", gatewayURL: URL(string: "ws://127.0.0.1:9")!, accent: "orange")
        var archive = SideChatArchive(); archive.queueArchiveSync(true, key: key)
        let disk = SideChatArchive.store(root: root, profile: profile); try disk.save(archive)
        let store = ChatStore(profile: profile, transcriptCacheRoot: root, operationsLedgerRoot: root)
        await store.syncSideChatArchives { method, _ in
            if method == "users.self" { return Data(#"{"profile":{"id":"person-a"}}"#.utf8) }
            if method == "users.prefs.get" { return Data(#"{"status":"ok","entries":{}}"#.utf8) }
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(try disk.load(defaultValue: SideChatArchive()).archiveSyncPending?[key], true)
        XCTAssertNotNil(store.sideChatDiscoveryError)
    }
    func testCASConflictRereadsAndPreservesOtherDevicesEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = WorkspaceProfile(id: "sync", name: "Fixture", gatewayURL: URL(string: "ws://127.0.0.1:9")!, accent: "orange")
        var archive = SideChatArchive(); archive.queueArchiveSync(true, key: key)
        let disk = SideChatArchive.store(root: root, profile: profile); try disk.save(archive)
        let store = ChatStore(profile: profile, transcriptCacheRoot: root, operationsLedgerRoot: root)
        let other = "agent:main:cast-side-22222222-2222-4222-8222-222222222222"
        var remote: [String: Bool] = [:], writes = 0
        await store.syncSideChatArchives { method, params in
            if method == "users.self" { return Data(#"{"profile":{"id":"gateway-owner"}}"#.utf8) }
            if method == "users.prefs.get" {
                return try JSONSerialization.data(withJSONObject: ["status": "ok", "entries": [SideChatArchive.preferenceKey: remote]])
            }
            writes += 1
            if writes == 1 {
                remote[other] = true
                return Data(#"{"status":"conflict"}"#.utf8)
            }
            let expected = (params["expectedEntries"] as! [String: Any])[SideChatArchive.preferenceKey] as! [String: Bool]
            XCTAssertEqual(expected, [other: true])
            remote = (params["entries"] as! [String: Any])[SideChatArchive.preferenceKey] as! [String: Bool]
            return Data(#"{"status":"ok"}"#.utf8)
        }
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(remote, [key: true, other: true])
        XCTAssertEqual(try disk.load(defaultValue: SideChatArchive()).archiveSyncProfileID, "gateway-owner")
    }

    func testLateArchiveAcknowledgementDoesNotEraseNewLocalRestore() {
        var archive = SideChatArchive()
        archive.queueArchiveSync(false, key: key)
        archive.applyArchivePreferences([key: true], sent: [key: true], now: 1)
        XCTAssertEqual(archive.archiveSyncPending?[key], false)
        XCTAssertFalse(archive.isArchived(key))
    }

    func testMigratedIdleDeviceNeverReuploadsStaleArchiveAfterRemoteRestore() {
        var archive = SideChatArchive()
        archive.setArchived(.manual, key: key, now: 1)
        archive.archiveSyncMigrated = true
        XCTAssertEqual(archive.mergedArchivePreferences([key: false]), [key: false])
        archive.applyArchivePreferences([key: false], sent: [:], now: 2)
        XCTAssertFalse(archive.isArchived(key))
    }

    func testMalformedArchivePreferenceFailsVisiblyWithoutWriteOrPendingLoss() async throws {
        for malformed: Any in [NSNull(), "x", 1, true, [], [key: 1]] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let profile = WorkspaceProfile(id: "malformed", name: "Fixture", gatewayURL: URL(string: "ws://127.0.0.1:9")!, accent: "orange")
            var archive = SideChatArchive(); archive.queueArchiveSync(true, key: key)
            let disk = SideChatArchive.store(root: root, profile: profile); try disk.save(archive)
            let store = ChatStore(profile: profile, transcriptCacheRoot: root, operationsLedgerRoot: root)
            var writes = 0
            await store.syncSideChatArchives { method, _ in
                if method == "users.self" { return Data(#"{"profile":{"id":"person-a"}}"#.utf8) }
                if method == "users.prefs.get" {
                    return try JSONSerialization.data(withJSONObject: ["status": "ok", "entries": [SideChatArchive.preferenceKey: malformed]])
                }
                writes += 1; return Data(#"{"status":"ok"}"#.utf8)
            }
            XCTAssertEqual(writes, 0)
            XCTAssertNotNil(store.sideChatDiscoveryError)
            XCTAssertEqual(try disk.load(defaultValue: SideChatArchive()).archiveSyncPending?[key], true)
        }
    }

    func testFullArchiveStoreStillReceivesRemoteChangesAndKeepsMigrationPending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = WorkspaceProfile(id: "full", name: "Fixture", gatewayURL: URL(string: "ws://127.0.0.1:9")!, accent: "orange")
        var archive = SideChatArchive()
        for i in 0..<80 {
            let legacyKey = String(format: "agent:main:cast-side-%08d-1111-4111-8111-111111111111", i)
            archive.setArchived(.manual, key: legacyKey, now: 1)
        }
        archive.queueArchiveSync(false, key: key)
        let other = "agent:main:cast-side-22222222-2222-4222-8222-222222222222"
        let disk = SideChatArchive.store(root: root, profile: profile); try disk.save(archive)
        let store = ChatStore(profile: profile, transcriptCacheRoot: root, operationsLedgerRoot: root)
        var writes = 0
        await store.syncSideChatArchives { method, _ in
            if method == "users.self" { return Data(#"{"profile":{"id":"person-a"}}"#.utf8) }
            if method == "users.prefs.get" {
                return try JSONSerialization.data(withJSONObject: ["status": "ok", "entries": [SideChatArchive.preferenceKey: [other: true, self.key: true]]])
            }
            writes += 1; return Data(#"{"status":"ok"}"#.utf8)
        }
        let saved = try disk.load(defaultValue: SideChatArchive())
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(saved.isArchived(other))
        XCTAssertFalse(saved.isArchived(key))
        XCTAssertEqual(saved.archiveSyncPending?[key], false)
        XCTAssertNotEqual(saved.archiveSyncMigrated, true)
        XCTAssertTrue(store.sideChatArchiveSyncNotice.contains("storage is full"))
    }

}
