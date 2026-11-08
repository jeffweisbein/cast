import Foundation
import XCTest
@testable import Cast

final class OperationsLedgerTests: XCTestCase {
    func testAggregateUnreadActionUsesSidebarOrderWithinAWorkspace() {
        let earlier = self.session("agent:main:earlier")
        let later = self.session("agent:main:later")
        let sections = [
            SidebarSection(category: .main, title: "Chats", sessions: [earlier]),
            SidebarSection(category: .task, title: "Tasks", sessions: [later]),
        ]

        XCTAssertEqual(
            UnreadNavigation.firstSessionKey(
                in: sections,
                unreadCount: { [later.key: 3, earlier.key: 1][$0, default: 0] }),
            earlier.key)
    }

    func testAggregateUnreadActionPrefersCurrentWorkspaceThenProfileOrder() {
        let unreadByWorkspace = ["personal": "agent:main:personal", "work": "agent:main:work"]

        XCTAssertEqual(
            UnreadNavigation.nextDestination(
                selectedWorkspaceID: "work",
                workspaceIDs: ["personal", "work"],
                firstUnreadSessionKey: { unreadByWorkspace[$0] }),
            UnreadDestination(workspaceID: "work", sessionKey: "agent:main:work"))
        XCTAssertEqual(
            UnreadNavigation.nextDestination(
                selectedWorkspaceID: "empty",
                workspaceIDs: ["empty", "personal", "work"],
                firstUnreadSessionKey: { unreadByWorkspace[$0] }),
            UnreadDestination(workspaceID: "personal", sessionKey: "agent:main:personal"))
        XCTAssertNil(UnreadNavigation.nextDestination(
            selectedWorkspaceID: "empty",
            workspaceIDs: ["empty"],
            firstUnreadSessionKey: { _ in nil }))
    }

    @MainActor
    func testChatStorePersistsNumericUnreadAndClearsOnActualOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastOperationsIntegration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = WorkspaceProfile(
            id: "home",
            name: "Home",
            gatewayURL: try XCTUnwrap(URL(string: "wss://gateway.example.com")),
            accent: "blue")
        let store = ChatStore(
            profile: profile,
            transcriptCacheRoot: root.appendingPathComponent("transcripts"),
            operationsLedgerRoot: root.appendingPathComponent("operations"))
        let event = try JSONDecoder().decode(EventFrame.self, from: Data(#"""
        {
          "event":"session.message",
          "seq":42,
          "payload":{
            "sessionKey":"agent:main:other",
            "message":{
              "id":"message-42",
              "role":"assistant",
              "content":[{"type":"text","text":"done"}],
              "timestamp":42000
            }
          }
        }
        """#.utf8))

        store.handleEvent(event)
        store.handleEvent(event)
        let completion = try taskCompletionEvent(sessionKey: "agent:main:other")
        store.handleEvent(completion)
        store.handleEvent(completion)

        XCTAssertEqual(store.numericUnreadCount, 1)
        XCTAssertEqual(store.unreadCount(for: "agent:main:other"), 1)
        XCTAssertEqual(store.notificationRecords.count, 1)
        XCTAssertEqual(store.notificationRecords.first?.state, .suppressed)

        store.selectedSessionKey = "agent:main:other"

        XCTAssertEqual(store.numericUnreadCount, 0)
        XCTAssertEqual(store.unreadCount(for: "agent:main:other"), 0)
        XCTAssertEqual(store.notificationRecords.first?.state, .read)
    }

    private func session(
        _ key: String,
        displayName: String? = nil,
        lastMessagePreview: String? = nil,
        updatedAt: Double? = nil,
        unread: Bool? = true) -> SessionRow
    {
        SessionRow(
            key: key,
            kind: "direct",
            displayName: displayName,
            derivedTitle: nil,
            lastMessagePreview: lastMessagePreview,
            channel: nil,
            updatedAt: updatedAt,
            unread: unread,
            pinned: nil,
            hasActiveRun: nil,
            model: nil)
    }

    private func replyEvent(sessionKey: String, id: String) throws -> EventFrame {
        try JSONDecoder().decode(EventFrame.self, from: JSONSerialization.data(withJSONObject: [
            "event": "session.message",
            "seq": 7,
            "payload": [
                "sessionKey": sessionKey,
                "message": [
                    "id": id,
                    "role": "assistant",
                    "content": [["type": "text", "text": "fixture reply"]],
                    "timestamp": 42_000,
                ],
            ],
        ]))
    }

    @MainActor
    private func makeChatStore(id: String = "home") throws -> ChatStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastOperationsIntegration-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let profile = WorkspaceProfile(
            id: id,
            name: id,
            gatewayURL: try XCTUnwrap(URL(string: "wss://gateway.example.com")),
            accent: "blue")
        return ChatStore(
            profile: profile,
            transcriptCacheRoot: root.appendingPathComponent("transcripts"),
            operationsLedgerRoot: root.appendingPathComponent("operations"))
    }

    /// Mirrors what `refreshSessions` does after a `sessions.list` response: publish the rows,
    /// then reconcile unread state against them.
    @MainActor
    private func applySnapshot(_ sessions: [SessionRow], to store: ChatStore) {
        store.installSessionSnapshotForTesting(sessions)
    }

    @MainActor
    func testSnapshotReconciliationDoesNotAccumulateAcrossRepeatedPolls() throws {
        let store = try self.makeChatStore()
        let sessionKey = "agent:main:other"

        self.applySnapshot([self.session(sessionKey, updatedAt: 100)], to: store)
        XCTAssertEqual(store.unreadCount(for: sessionKey), 1)

        // A live run keeps advancing `updatedAt` on every `sessions.list` poll even though the
        // reader still hasn't seen anything new. Each poll used to be miscounted as a fresh
        // unread event, so the badge grew without bound for as long as the run stayed active.
        for tick in stride(from: 101.0, through: 200.0, by: 1.0) {
            self.applySnapshot([self.session(sessionKey, updatedAt: tick, unread: true)], to: store)
        }

        XCTAssertEqual(store.unreadCount(for: sessionKey), 1)
        XCTAssertEqual(store.numericUnreadCount, 1)
    }

    @MainActor
    func testMarkAllReadZerosEveryUnreadSessionLocally() throws {
        let store = try self.makeChatStore()
        self.applySnapshot([
            self.session("agent:main:one", updatedAt: 10),
            self.session("agent:main:two", updatedAt: 20),
            self.session("agent:main:three", updatedAt: 30, unread: false),
        ], to: store)
        XCTAssertEqual(store.numericUnreadCount, 2)

        store.markAllRead()

        XCTAssertEqual(store.numericUnreadCount, 0)
        XCTAssertEqual(store.unreadCount(for: "agent:main:one"), 0)
        XCTAssertEqual(store.unreadCount(for: "agent:main:two"), 0)
        XCTAssertTrue(store.unreadSummaries.isEmpty)
    }

    @MainActor
    func testMarkAllReadAlsoClearsUnreadSessionsMissingFromTheCurrentListPage() throws {
        let store = try self.makeChatStore()
        store.handleEvent(try self.replyEvent(
            sessionKey: "agent:main:aged-out",
            id: "message-aged-out"))
        XCTAssertEqual(store.numericUnreadCount, 1)
        XCTAssertEqual(store.unreadSummaries.map(\.sessionKey), ["agent:main:aged-out"])

        store.markAllRead()

        XCTAssertEqual(store.numericUnreadCount, 0)
        XCTAssertTrue(store.unreadSummaries.isEmpty)
    }

    @MainActor
    func testUnreadSummariesReflectPerChatBreakdownMostRecentFirst() throws {
        let store = try self.makeChatStore()
        self.applySnapshot([
            self.session(
                "agent:main:old",
                displayName: "Old Chat",
                lastMessagePreview: "an earlier reply",
                updatedAt: 10),
            self.session(
                "agent:main:new",
                displayName: "New Chat",
                lastMessagePreview: "a later reply",
                updatedAt: 20),
        ], to: store)

        let summaries = store.unreadSummaries
        XCTAssertEqual(summaries.map(\.sessionKey), ["agent:main:new", "agent:main:old"])
        XCTAssertEqual(summaries.map(\.unreadCount), [1, 1])
        XCTAssertEqual(summaries.first?.title, "New Chat")
        XCTAssertEqual(summaries.first?.preview, "a later reply")
    }

    @MainActor
    func testWorkspaceManagerUnreadInboxAggregatesAcrossWorkspacesAndMarkAllReadClearsAll() throws {
        let suiteName = "CastTests.unread-inbox.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = [
            WorkspaceProfile(id: "one", name: "One", gatewayURL: URL(string: "wss://one.example.test")!, accent: "purple"),
            WorkspaceProfile(id: "two", name: "Two", gatewayURL: URL(string: "wss://two.example.test")!, accent: "orange"),
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: "cast.workspaceProfiles.v2")
        let manager = WorkspaceManager(
            defaults: defaults,
            credentialProvider: { _ in nil },
            includeDevelopmentWorkspaces: false,
            legacyLocalCredentialAvailable: false)

        self.applySnapshot(
            [self.session("agent:main:a", displayName: "Chat A", updatedAt: 5)],
            to: manager.store(for: "one"))
        self.applySnapshot(
            [self.session("agent:main:b", displayName: "Chat B", updatedAt: 15)],
            to: manager.store(for: "two"))

        let inbox = manager.unreadInbox
        XCTAssertEqual(inbox.map(\.workspaceID), ["two", "one"])
        XCTAssertEqual(inbox.map(\.summary.sessionKey), ["agent:main:b", "agent:main:a"])

        manager.selectedWorkspaceID = "one"
        manager.openUnreadInboxItem(try XCTUnwrap(inbox.first { $0.workspaceID == "two" }))
        XCTAssertEqual(manager.selectedWorkspaceID, "two")
        XCTAssertEqual(manager.store(for: "two").selectedSessionKey, "agent:main:b")

        manager.markAllRead()
        XCTAssertTrue(manager.unreadInbox.isEmpty)
        XCTAssertEqual(manager.store(for: "one").numericUnreadCount, 0)
        XCTAssertEqual(manager.store(for: "two").numericUnreadCount, 0)
    }

    func testOperationWatermarkRejectsNonFiniteAndOutOfRangeValues() {
        XCTAssertEqual(ChatStore.operationWatermark(42_000.9), 42_000)
        XCTAssertNil(ChatStore.operationWatermark(.infinity))
        XCTAssertNil(ChatStore.operationWatermark(.nan))
        XCTAssertNil(ChatStore.operationWatermark(Double.greatestFiniteMagnitude))
    }

    func testUnreadObservationDedupeAndWatermarkAreDurable() throws {
        var ledger = UnreadLedger(dedupeCapacity: 3)

        XCTAssertEqual(
            ledger.observeUnread(
                workspaceID: "home",
                sessionKey: "agent:main:one",
                eventID: "event-10",
                watermark: 10),
            .incremented)
        XCTAssertEqual(
            ledger.observeUnread(
                workspaceID: "home",
                sessionKey: "agent:main:one",
                eventID: "event-10",
                watermark: 10),
            .duplicate)
        XCTAssertEqual(
            ledger.observeUnread(
                workspaceID: "home",
                sessionKey: "agent:main:one",
                eventID: "late-event",
                watermark: 9),
            .stale)

        let restored = try JSONDecoder().decode(
            UnreadLedger.self,
            from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored, ledger)
        XCTAssertEqual(restored.unreadCount, 1)
        XCTAssertEqual(
            restored.state(workspaceID: "home", sessionKey: "agent:main:one")?.accuracy,
            .lowerBound)
    }

    func testAuthoritativeBooleanDoesNotInventAnExactCount() {
        var ledger = UnreadLedger()

        XCTAssertEqual(
            ledger.reconcileAuthoritativeUnread(
                workspaceID: "home",
                sessionKey: "agent:main:one",
                isUnread: true,
                watermark: 20),
            .changed)
        var state = ledger.state(workspaceID: "home", sessionKey: "agent:main:one")
        XCTAssertEqual(state?.count, 1)
        XCTAssertEqual(state?.accuracy, .lowerBound)

        XCTAssertEqual(
            ledger.reconcileAuthoritativeUnread(
                workspaceID: "home",
                sessionKey: "agent:main:one",
                isUnread: true,
                watermark: 21),
            .changed)
        state = ledger.state(workspaceID: "home", sessionKey: "agent:main:one")
        XCTAssertEqual(state?.count, 1)
        XCTAssertEqual(state?.accuracy, .lowerBound)

        XCTAssertEqual(
            ledger.reconcileAuthoritativeUnread(
                workspaceID: "home",
                sessionKey: "agent:main:one",
                isUnread: false,
                watermark: 22),
            .changed)
        state = ledger.state(workspaceID: "home", sessionKey: "agent:main:one")
        XCTAssertEqual(state?.count, 0)
        XCTAssertEqual(state?.accuracy, .exact)

        XCTAssertEqual(
            ledger.observeUnread(
                workspaceID: "home",
                sessionKey: "agent:main:one",
                eventID: "event-23",
                watermark: 23),
            .incremented)
        state = ledger.state(workspaceID: "home", sessionKey: "agent:main:one")
        XCTAssertEqual(state?.count, 1)
        XCTAssertEqual(state?.accuracy, .exact)
    }

    func testClearOnOpenRejectsDelayedEventsAtOrBeforeCursor() {
        var ledger = UnreadLedger()
        _ = ledger.observeUnread(
            workspaceID: "home",
            sessionKey: "agent:main:one",
            eventID: "event-30",
            watermark: 30)

        XCTAssertTrue(ledger.clearOnOpen(
            workspaceID: "home",
            sessionKey: "agent:main:one",
            throughWatermark: 30))
        XCTAssertEqual(
            ledger.observeUnread(
                workspaceID: "home",
                sessionKey: "agent:main:one",
                eventID: "delayed-29",
                watermark: 29),
            .stale)
        XCTAssertEqual(
            ledger.observeUnread(
                workspaceID: "home",
                sessionKey: "agent:main:one",
                eventID: "event-31",
                watermark: 31),
            .incremented)
        XCTAssertEqual(ledger.unreadCount(workspaceID: "home"), 1)
    }

    func testUnreadTotalsRemainSeparatedByWorkspaceAndSession() {
        var ledger = UnreadLedger()
        _ = ledger.observeUnread(
            workspaceID: "home", sessionKey: "one", eventID: "h1", watermark: 1)
        _ = ledger.observeUnread(
            workspaceID: "home", sessionKey: "two", eventID: "h2", watermark: 2)
        _ = ledger.observeUnread(
            workspaceID: "work", sessionKey: "one", eventID: "w1", watermark: 1)

        XCTAssertEqual(ledger.unreadCount(workspaceID: "home"), 2)
        XCTAssertEqual(ledger.unreadCount(workspaceID: "work"), 1)
        XCTAssertEqual(ledger.unreadCount, 3)
    }

    func testNotificationLedgerCapturesDecisionDeliveryAndReadParity() {
        let observedAt = Date(timeIntervalSince1970: 100)
        let eligibleAt = Date(timeIntervalSince1970: 101)
        let deliveredAt = Date(timeIntervalSince1970: 102)
        let readAt = Date(timeIntervalSince1970: 103)
        let linkage = NotificationLinkage(
            workspaceID: "home",
            sessionKey: "agent:main:one",
            sourceEventID: "event-1",
            messageID: "message-1",
            runID: "run-1")
        var ledger = NotificationDeliveryLedger()

        XCTAssertEqual(
            ledger.observe(dedupeID: "home:event-1", linkage: linkage, at: observedAt),
            .inserted)
        XCTAssertEqual(
            ledger.observe(dedupeID: "home:event-1", linkage: linkage, at: observedAt),
            .duplicate)
        XCTAssertEqual(
            ledger.markEligible(
                dedupeID: "home:event-1",
                at: eligibleAt,
                detail: "background-session"),
            .transitioned)
        XCTAssertEqual(
            ledger.markDelivered(
                dedupeID: "home:event-1",
                at: deliveredAt,
                detail: "local-notification"),
            .transitioned)
        XCTAssertEqual(
            ledger.markRead(dedupeID: "home:event-1", at: readAt),
            .transitioned)

        let record = ledger.record(dedupeID: "home:event-1")
        XCTAssertEqual(record?.linkage, linkage)
        XCTAssertEqual(record?.state, .read)
        XCTAssertEqual(record?.observedAt, observedAt)
        XCTAssertEqual(record?.eligibleAt, eligibleAt)
        XCTAssertEqual(record?.deliveredAt, deliveredAt)
        XCTAssertEqual(record?.readAt, readAt)
        XCTAssertNil(record?.suppressedAt)
        XCTAssertNil(record?.failedAt)
    }

    func testNotificationLedgerRejectsImpossibleAndDuplicateTransitions() {
        var ledger = NotificationDeliveryLedger()
        _ = ledger.observe(
            dedupeID: "notification-1",
            linkage: NotificationLinkage(workspaceID: "home", sessionKey: "one"),
            at: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(
            ledger.markDelivered(
                dedupeID: "notification-1",
                at: Date(timeIntervalSince1970: 2)),
            .invalidTransition)
        XCTAssertEqual(
            ledger.markSuppressed(
                dedupeID: "notification-1",
                at: Date(timeIntervalSince1970: 3),
                reason: "foreground-selected-session"),
            .transitioned)
        XCTAssertEqual(
            ledger.markSuppressed(
                dedupeID: "notification-1",
                at: Date(timeIntervalSince1970: 4),
                reason: "foreground-selected-session"),
            .unchanged)
        XCTAssertEqual(
            ledger.markDelivered(
                dedupeID: "notification-1",
                at: Date(timeIntervalSince1970: 5)),
            .invalidTransition)
        XCTAssertEqual(
            ledger.markRead(
                dedupeID: "missing",
                at: Date(timeIntervalSince1970: 6)),
            .missing)
    }

    func testNotificationLedgerPrunesOldTerminalRecordsButKeepsOpenDecisions() {
        var ledger = NotificationDeliveryLedger()
        let linkage = NotificationLinkage(workspaceID: "home", sessionKey: "one")
        let ancient = Date(timeIntervalSince1970: 1)

        _ = ledger.observe(dedupeID: "old-delivered", linkage: linkage, at: ancient)
        _ = ledger.markEligible(dedupeID: "old-delivered", at: ancient)
        _ = ledger.markDelivered(dedupeID: "old-delivered", at: ancient)
        _ = ledger.observe(dedupeID: "old-failed", linkage: linkage, at: ancient)
        _ = ledger.markEligible(dedupeID: "old-failed", at: ancient)
        _ = ledger.markFailed(dedupeID: "old-failed", at: ancient, errorCode: "authorization-denied")
        // An unresolved decision is exactly what the parity audit exists to surface;
        // age alone must not erase it.
        _ = ledger.observe(dedupeID: "old-unresolved", linkage: linkage, at: ancient)
        _ = ledger.markEligible(dedupeID: "old-unresolved", at: ancient)
        // A record whose last transition is recent stays, however old its observation.
        _ = ledger.observe(dedupeID: "recently-read", linkage: linkage, at: ancient)
        _ = ledger.markRead(dedupeID: "recently-read", at: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(ledger.pruneTerminalRecords(before: Date(timeIntervalSince1970: 500)), 2)
        XCTAssertNil(ledger.record(dedupeID: "old-delivered"))
        XCTAssertNil(ledger.record(dedupeID: "old-failed"))
        XCTAssertNotNil(ledger.record(dedupeID: "old-unresolved"))
        XCTAssertNotNil(ledger.record(dedupeID: "recently-read"))
    }

    func testOperationsPersistenceSkipsRewritingUnchangedLedgers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastLedgerSkipTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = OperationsLedgerPersistence(root: directory)
        var unread = UnreadLedger()
        _ = unread.observeUnread(workspaceID: "home", sessionKey: "one", eventID: "e1", watermark: 1)
        let notifications = NotificationDeliveryLedger()
        let acknowledgements = AcknowledgementLedger()

        await persistence.save(
            unread: unread, notifications: notifications, acknowledgements: acknowledgements)
        let unreadURL = directory.appendingPathComponent("unread.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadURL.path))

        // The watchdog resubmits an identical snapshot every 20 seconds; deleting the
        // files first proves an unchanged snapshot performs no write at all.
        try FileManager.default.removeItem(at: unreadURL)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("notifications.json"))
        await persistence.save(
            unread: unread, notifications: notifications, acknowledgements: acknowledgements)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unreadURL.path))

        // A genuinely changed ledger writes again.
        _ = unread.observeUnread(workspaceID: "home", sessionKey: "two", eventID: "e2", watermark: 2)
        await persistence.save(
            unread: unread, notifications: notifications, acknowledgements: acknowledgements)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("notifications.json").path))
    }

    func testAtomicJSONLedgerStoreRoundTripsAndReplacesPreviousSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastLedgerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("unread.json")
        let store = AtomicJSONLedgerStore<UnreadLedger>(fileURL: url)

        XCTAssertEqual(try store.load(defaultValue: UnreadLedger()).unreadCount, 0)

        var first = UnreadLedger()
        _ = first.observeUnread(
            workspaceID: "home", sessionKey: "one", eventID: "one", watermark: 1)
        try store.save(first)
        XCTAssertEqual(try store.load(defaultValue: UnreadLedger()), first)

        var second = first
        _ = second.observeUnread(
            workspaceID: "home", sessionKey: "two", eventID: "two", watermark: 2)
        try store.save(second)
        XCTAssertEqual(try store.load(defaultValue: UnreadLedger()), second)
    }

    func testNotificationLedgerPersistencePreservesAppendOnlyHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastNotificationLedgerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AtomicJSONLedgerStore<NotificationDeliveryLedger>(
            fileURL: directory.appendingPathComponent("notifications.json"))
        var ledger = NotificationDeliveryLedger()
        _ = ledger.observe(
            dedupeID: "n1",
            linkage: NotificationLinkage(
                workspaceID: "home",
                sessionKey: "one",
                messageID: "m1"),
            at: Date(timeIntervalSince1970: 1))
        _ = ledger.markEligible(dedupeID: "n1", at: Date(timeIntervalSince1970: 2))
        _ = ledger.markFailed(
            dedupeID: "n1",
            at: Date(timeIntervalSince1970: 3),
            errorCode: "authorization-denied")
        _ = ledger.markEligible(
            dedupeID: "n1",
            at: Date(timeIntervalSince1970: 4),
            detail: "retry")
        _ = ledger.markDelivered(dedupeID: "n1", at: Date(timeIntervalSince1970: 5))

        try store.save(ledger)
        let restored = try store.load(defaultValue: NotificationDeliveryLedger())
        XCTAssertEqual(restored, ledger)
        XCTAssertEqual(
            restored.record(dedupeID: "n1")?.transitions.map(\.state),
            [.observed, .eligible, .failed, .eligible, .delivered])
    }
}

/// Per-session mute: suppresses the notification, never the unread truth, and survives
/// relaunch through the same operations root as the other ledgers.
final class MuteLedgerTests: XCTestCase {
    private func replyEvent(sessionKey: String, id: String) throws -> EventFrame {
        try JSONDecoder().decode(EventFrame.self, from: JSONSerialization.data(withJSONObject: [
            "event": "session.message",
            "seq": 7,
            "payload": [
                "sessionKey": sessionKey,
                "message": [
                    "id": id,
                    "role": "assistant",
                    "content": [["type": "text", "text": "cron output"]],
                    "timestamp": 42_000,
                ],
            ],
        ]))
    }

    @MainActor
    func testMutedSessionStillCountsUnreadButSuppressesTheNotification() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastMuteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = WorkspaceProfile(
            id: "home",
            name: "Home",
            gatewayURL: try XCTUnwrap(URL(string: "wss://gateway.example.com")),
            accent: "blue")
        let store = ChatStore(
            profile: profile,
            transcriptCacheRoot: root.appendingPathComponent("transcripts"),
            operationsLedgerRoot: root.appendingPathComponent("operations"))

        store.toggleSessionMuted("agent:main:noisy")
        XCTAssertTrue(store.isSessionMuted("agent:main:noisy"))

        store.handleEvent(try self.replyEvent(sessionKey: "agent:main:noisy", id: "m-1"))
        store.handleEvent(try taskCompletionEvent(sessionKey: "agent:main:noisy", runID: "muted"))

        // Unread accounting is untouched: mute is not "mark as read".
        XCTAssertEqual(store.unreadCount(for: "agent:main:noisy"), 1)
        // The interruption is what got suppressed, and the ledger records why.
        let record = try XCTUnwrap(store.notificationRecords.first)
        XCTAssertEqual(record.state, .suppressed)
        XCTAssertEqual(record.transitions.last?.detail, "muted")

        // An unmuted session in the same store keeps the normal path (test-host
        // suppression, not "muted").
        store.handleEvent(try self.replyEvent(sessionKey: "agent:main:other", id: "m-2"))
        store.handleEvent(try taskCompletionEvent(sessionKey: "agent:main:other", runID: "unmuted"))
        let other = try XCTUnwrap(store.notificationRecords.first(where: {
            $0.linkage.sessionKey == "agent:main:other"
        }))
        XCTAssertEqual(other.transitions.last?.detail, "test-host")
    }

    @MainActor
    func testMuteSurvivesRelaunchAndUnmutesAcrossAliases() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastMutePersistTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = WorkspaceProfile(
            id: "home",
            name: "Home",
            gatewayURL: try XCTUnwrap(URL(string: "wss://gateway.example.com")),
            accent: "blue")
        let operationsRoot = root.appendingPathComponent("operations")

        let store = ChatStore(
            profile: profile,
            transcriptCacheRoot: root.appendingPathComponent("transcripts"),
            operationsLedgerRoot: operationsRoot)
        store.setSessionMuted(true, sessionKey: "main")
        // Persistence is a detached task; give it a beat before "relaunching".
        try await Task.sleep(nanoseconds: 300_000_000)

        let relaunched = ChatStore(
            profile: profile,
            transcriptCacheRoot: root.appendingPathComponent("transcripts"),
            operationsLedgerRoot: operationsRoot)
        XCTAssertTrue(relaunched.isSessionMuted("main"))
        // Alias-aware in both directions: the canonical spelling reads as muted, and
        // unmuting through it clears the alias entry too.
        XCTAssertTrue(relaunched.isSessionMuted("agent:main:main"))
        relaunched.setSessionMuted(false, sessionKey: "agent:main:main")
        XCTAssertFalse(relaunched.isSessionMuted("main"))
        XCTAssertTrue(relaunched.mutedSessionKeys.isEmpty)
    }

    func testMuteLedgerSetAndClearReportChanges() {
        var ledger = MuteLedger()
        XCTAssertTrue(ledger.setMuted(true, sessionKey: "agent:main:a"))
        XCTAssertFalse(ledger.setMuted(true, sessionKey: "agent:main:a"))
        XCTAssertTrue(ledger.setMuted(false, sessionKey: "agent:main:a"))
        XCTAssertFalse(ledger.setMuted(false, sessionKey: "agent:main:a"))
    }
}

final class SidebarVisibilityTests: XCTestCase {
    private func row(_ key: String, unread: Bool = false, updatedAt: Double = 1) throws -> SessionRow {
        try JSONDecoder().decode(SessionRow.self, from: JSONSerialization.data(withJSONObject: [
            "key": key, "unread": unread, "updatedAt": updatedAt,
        ]))
    }

    @MainActor
    func testHiddenRepliesStayHiddenAndUnreadReturnsOnRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(transcriptCacheRoot: root, operationsLedgerRoot: root)
        let key = "agent:main:hidden-chat"
        store.installSessionSnapshotForTesting([try self.row(key, unread: true)])
        XCTAssertEqual(store.numericUnreadCount, 1)
        store.setSessionHidden(true, sessionKey: key)
        XCTAssertEqual(store.numericUnreadCount, 0)
        XCTAssertTrue(store.unreadSummaries.isEmpty)
        XCTAssertTrue(store.visibleSessions.isEmpty)
        XCTAssertTrue(store.sidebarSections.flatMap(\.sessions).isEmpty)

        let event = try JSONDecoder().decode(EventFrame.self, from: JSONSerialization.data(withJSONObject: [
            "event": "session.message", "seq": 1,
            "payload": ["sessionKey": key, "message": [
                "id": "new-hidden-reply", "role": "assistant", "timestamp": 42_000,
                "content": [["type": "text", "text": "A new reply"]],
            ]],
        ]))
        store.handleEvent(event)
        store.handleEvent(try taskCompletionEvent(sessionKey: key))
        XCTAssertTrue(store.isSessionHidden(key))
        XCTAssertEqual(store.numericUnreadCount, 0)
        XCTAssertEqual(store.unreadCount(for: key), 0)
        XCTAssertEqual(store.notificationRecords.last?.transitions.last?.detail, "hidden")
        XCTAssertGreaterThan(store.unreadCountsBySession[key] ?? 0, 0)

        // A gateway refresh must not resurrect the row, even with fresh activity.
        store.installSessionSnapshotForTesting([try self.row(key, unread: true, updatedAt: 42_000)])
        XCTAssertTrue(store.sidebarSections.flatMap(\.sessions).isEmpty)
        store.showHiddenSessions = true
        XCTAssertEqual(store.hiddenSessions.map(\.key), [key])
        XCTAssertEqual(store.visibleSessions.map(\.key), [key])
        XCTAssertEqual(store.numericUnreadCount, 0)
        store.undoHideSession()
        XCTAssertFalse(store.isSessionHidden(key))
        XCTAssertGreaterThan(store.numericUnreadCount, 0)
        XCTAssertFalse(store.unreadSummaries.isEmpty)
        XCTAssertNil(store.lastHiddenSessionKey)
    }

    @MainActor
    func testPreferencesPersistAndRemainWorkspaceLocal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func store(_ workspace: String) -> ChatStore {
            ChatStore(profile: WorkspaceProfile(id: workspace, name: workspace,
                gatewayURL: URL(string: "wss://gateway.example.com")!, accent: "blue"),
                transcriptCacheRoot: root, operationsLedgerRoot: root)
        }
        let first = store("one")
        first.setSessionHidden(true, sessionKey: "main")
        first.toggleSessionPinned("main")
        let reopened = store("one")
        XCTAssertTrue(reopened.isSessionHidden("agent:main:main"))
        XCTAssertTrue(reopened.isSessionPinned("agent:main:main"))
        XCTAssertFalse(store("two").isSessionHidden("main"))
        XCTAssertFalse(store("two").isSessionPinned("main"))
        reopened.setSessionHidden(false, sessionKey: "agent:main:main")
        reopened.toggleSessionPinned("agent:main:main")
        XCTAssertFalse(store("one").isSessionHidden("main"))
        XCTAssertFalse(store("one").isSessionPinned("main"))
    }

    @MainActor
    func testPinWinsOverInboxAndHidingSelectedChatSelectsVisibleFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(transcriptCacheRoot: root, operationsLedgerRoot: root)
        let favorite = "agent:main:imessage:direct:favorite"
        let inbox = "agent:main:main"
        store.installSessionSnapshotForTesting([try self.row(inbox), try self.row(favorite)])
        store.toggleSessionPinned(favorite)
        XCTAssertEqual(store.sidebarSections.first?.sessions.map(\.key), [favorite, inbox])
        store.selectedSessionKey = favorite
        store.setDraft("Keep this draft", forSession: favorite)
        store.setSessionHidden(true, sessionKey: favorite)
        XCTAssertEqual(store.selectedSessionKey, inbox)
        XCTAssertEqual(store.draft(forSession: favorite), "Keep this draft")
        XCTAssertTrue(store.isSessionPinned(favorite))
        store.undoHideSession()
        XCTAssertEqual(store.sidebarSections.first?.sessions.first?.key, favorite)
        store.setSessionHidden(true, sessionKey: favorite)
        store.setSessionHidden(true, sessionKey: inbox)
        XCTAssertNil(store.selectedSessionKey)
        XCTAssertTrue(store.sidebarSections.flatMap(\.sessions).isEmpty)
    }
}
