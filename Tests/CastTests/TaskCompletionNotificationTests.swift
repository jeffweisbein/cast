import XCTest
@testable import Cast

func taskCompletionEvent(sessionKey: String, runID: String = "run-1", state: String = "final", yielded: Bool = false, transcriptOnly: Bool = false) throws -> EventFrame {
    try JSONDecoder().decode(EventFrame.self, from: JSONSerialization.data(withJSONObject: [
        "event": "chat", "seq": 3,
        "payload": ["sessionKey": sessionKey, "runId": runID, "state": state,
                    "yielded": yielded, "transcriptOnly": transcriptOnly],
    ]))
}

final class TaskCompletionNotificationTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (ChatStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = WorkspaceProfile(id: UUID().uuidString, name: "Test", gatewayURL: URL(string: "wss://example.invalid")!, accent: "blue")
        return (ChatStore(profile: profile, transcriptCacheRoot: root, operationsLedgerRoot: root), root)
    }

    @MainActor
    func testOnlyTerminalCompletionsNotifyAndDuplicateRunsStaySilent() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "agent:main:task"
        for state in ["delta", "error", "aborted"] {
            store.handleEvent(try taskCompletionEvent(sessionKey: key, state: state))
        }
        store.handleEvent(try taskCompletionEvent(sessionKey: key, yielded: true))
        store.handleEvent(try taskCompletionEvent(sessionKey: key, transcriptOnly: true))
        store.handleEvent(try taskCompletionEvent(sessionKey: key, runID: ""))
        XCTAssertTrue(store.notificationRecords.isEmpty)
        let event = try taskCompletionEvent(sessionKey: key)
        store.handleEvent(event)
        store.handleEvent(event)
        #if os(iOS)
        XCTAssertTrue(store.notificationRecords.isEmpty, "APNs owns iOS completion delivery")
        #else
        XCTAssertEqual(store.notificationRecords.count, 1)
        XCTAssertEqual(store.notificationRecords.first?.linkage.sourceEventID, "completion:run-1")
        XCTAssertEqual(store.notificationRecords.first?.transitions.last?.detail, "test-host")
        #endif
    }

    @MainActor
    func testCurrentConversationOnlySuppressesWhileActuallyVisible() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "agent:main:task"
        store.selectedSessionKey = key
        store.handleEvent(try taskCompletionEvent(sessionKey: key, runID: "visible"))
        #if os(iOS)
        XCTAssertTrue(store.notificationRecords.isEmpty, "APNs owns iOS completion delivery")
        #else
        XCTAssertEqual(store.notificationRecords.first?.transitions.last?.detail, "visible-session")
        #endif
        store.isNotificationContextVisible = false
        store.handleEvent(try taskCompletionEvent(sessionKey: key, runID: "away"))
        #if os(iOS)
        XCTAssertTrue(store.notificationRecords.isEmpty, "APNs owns iOS completion delivery")
        #else
        XCTAssertEqual(store.notificationRecords.first(where: { $0.linkage.sourceEventID == "completion:away" })?.transitions.last?.detail, "test-host")
        #endif
        store.handleEvent(try taskCompletionEvent(sessionKey: key, runID: "visible"))
        #if os(iOS)
        XCTAssertTrue(store.notificationRecords.isEmpty, "APNs owns iOS completion delivery")
        #else
        XCTAssertEqual(store.notificationRecords.count, 2)
        #endif
    }

    @MainActor
    func testProgressMessagesNeverMakeCompletionAlerts() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let event = try JSONDecoder().decode(EventFrame.self, from: JSONSerialization.data(withJSONObject: [
            "event": "session.message", "payload": ["sessionKey": "agent:main:task", "message": [
                "id": "progress-1", "role": "assistant", "content": [["type": "text", "text": "Still working"]], "timestamp": 42000,
            ]],
        ]))
        store.handleEvent(event)
        XCTAssertEqual(store.numericUnreadCount, 1)
        XCTAssertTrue(store.notificationRecords.isEmpty)
    }

    @MainActor
    func testReplayMirrorsAndAutomationsDoNotNotify() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for key in ["agent:main:cron:daily", "agent:main:dreaming-nightly", "agent:main:subagent:incognito-abc"] {
            store.handleEvent(try taskCompletionEvent(sessionKey: key))
        }
        let ignored: [[String: Any]] = [
            ["replay": true], ["replayed": true],
            ["message": ["role": "assistant", "provider": "openclaw", "model": "delivery-mirror"]],
            ["message": ["role": "assistant", "provider": "openclaw", "model": "gateway-injected"]],
            ["message": ["role": "assistant", "openclawDeliveryMirror": ["kind": "channel-final"]]],
        ]
        for extra in ignored {
            let payload: [String: Any] = ["sessionKey": "agent:main:task", "runId": UUID().uuidString, "state": "final"]
                .merging(extra) { _, next in next }
            store.handleEvent(try JSONDecoder().decode(EventFrame.self,
                from: JSONSerialization.data(withJSONObject: ["event": "chat", "payload": payload])))
        }
        XCTAssertTrue(store.notificationRecords.isEmpty)
    }

    func testDestinationRejectsMalformedAndUnrelatedRemotePayloads() {
        XCTAssertNil(NativeNotificationDestination(userInfo: ["workspaceID": "w"]))
        XCTAssertNil(NativeNotificationDestination(userInfo: ["workspaceID": "w", "sessionKey": "x\n"]))
        XCTAssertNil(NativeNotificationDestination(userInfo: ["openclaw": ["kind": "approval", "workspaceId": "w", "sessionKey": "s"]]))
        let destination = NativeNotificationDestination(userInfo: ["openclaw": ["kind": "task.completed", "workspaceId": "w", "sessionKey": "s", "runId": "r", "gatewayDeviceId": "g"]])
        XCTAssertEqual(destination?.workspaceID, "w")
        XCTAssertEqual(destination?.gatewayDeviceID, "g")
        XCTAssertEqual(destination?.runID, "r")
    }

    @MainActor
    func testUnknownWorkspaceCannotCreateWorkspaceOrNavigate() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let manager = WorkspaceManager(defaults: defaults, credentialProvider: { _ in nil }, includeDevelopmentWorkspaces: false, legacyLocalCredentialAvailable: false)
        let before = manager.profiles
        let selected = manager.selectedWorkspaceID
        let destination = try XCTUnwrap(NativeNotificationDestination(userInfo: ["workspaceID": "unknown", "sessionKey": "agent:main:private"]))
        XCTAssertFalse(manager.openNotification(destination))
        XCTAssertEqual(manager.profiles.map(\.id), before.map(\.id))
        XCTAssertEqual(manager.selectedWorkspaceID, selected)
    }

    @MainActor
    func testRemoteBindingAndDeliveryDeduplicateSocketEcho() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bindingKey = "cast.push.binding.\(store.profile.id)"
        defer { UserDefaults.standard.removeObject(forKey: bindingKey) }
        let destination = try XCTUnwrap(NativeNotificationDestination(userInfo: ["openclaw": ["kind": "task.completed", "workspaceId": store.profile.id, "sessionKey": "agent:main:task", "runId": "r", "gatewayDeviceId": "g"]]))
        XCTAssertFalse(store.acceptsRemoteNotification(destination))
        UserDefaults.standard.set(["url": "wss://wrong.invalid", "gatewayDeviceID": "g"], forKey: bindingKey)
        XCTAssertFalse(store.acceptsRemoteNotification(destination))
        UserDefaults.standard.set(["url": store.profile.gatewayURL.absoluteString, "gatewayDeviceID": "g"], forKey: bindingKey)
        XCTAssertTrue(store.observeRemoteCompletion(destination, presenting: false))
        XCTAssertFalse(store.observeRemoteCompletion(destination, presenting: false))
        store.handleEvent(try taskCompletionEvent(sessionKey: "agent:main:task", runID: "r"))
        XCTAssertEqual(store.notificationRecords.count, 1)
        XCTAssertEqual(store.notificationRecords.first?.transitions.last?.detail, "remote-notification")
    }

    @MainActor
    func testRemoteDeliveryDoesNotFallBackLocallyDuringSyncOrBackgroundTransition() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.usesRemoteCompletionDelivery = true
        XCTAssertFalse(store.remotePushReady)
        store.isNotificationContextVisible = false
        store.handleEvent(try taskCompletionEvent(sessionKey: "agent:main:task", runID: "pending-sync"))
        XCTAssertTrue(store.notificationRecords.isEmpty)
        let bindingKey = "cast.push.binding.\(store.profile.id)"
        defer { UserDefaults.standard.removeObject(forKey: bindingKey) }
        UserDefaults.standard.set(["url": store.profile.gatewayURL.absoluteString, "gatewayDeviceID": "g"], forKey: bindingKey)
        let destination = try XCTUnwrap(NativeNotificationDestination(userInfo: ["openclaw": ["kind": "task.completed", "workspaceId": store.profile.id, "sessionKey": "agent:main:task", "runId": "pending-sync", "gatewayDeviceId": "g"]]))
        XCTAssertTrue(store.observeRemoteCompletion(destination, presenting: false))
        store.handleEvent(try taskCompletionEvent(sessionKey: "agent:main:task", runID: "pending-sync"))
        XCTAssertEqual(store.notificationRecords.count, 1)
    }

    func testAliasStatusNamesTheActualOwnerInsteadOfClaimingReady() throws {
        let data = Data(#"{"registered":true,"enabled":true,"configured":true,"gatewayDeviceId":"g","workspaceId":"owner"}"#.utf8)
        let status = try JSONDecoder().decode(NativePushStatus.self, from: data)
        XCTAssertFalse(status.isManagedElsewhere(workspaceID: "owner"))
        XCTAssertTrue(status.isManagedElsewhere(workspaceID: "alias"))
    }

    func testPushEnvironmentMustMatchExplicitSignedBuildSetting() {
        XCTAssertEqual(NativePushEnvironment.resolve("development"), "sandbox")
        XCTAssertEqual(NativePushEnvironment.resolve("production"), "production")
        XCTAssertNil(NativePushEnvironment.resolve("Release"))
        XCTAssertNil(NativePushEnvironment.resolve(nil))
    }

    @MainActor
    func testReminderRoutesToBoundWorkspaceAndDoesNotCollideWithTaskCompletion() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bindingKey = "cast.push.binding.\(store.profile.id)"
        defer { UserDefaults.standard.removeObject(forKey: bindingKey) }
        let payload: [String: Any] = ["kind": "task.completed", "notificationKind": "reminder.due", "workspaceId": store.profile.id,
            "sessionKey": "agent:main:task", "runId": "reminder:r", "gatewayDeviceId": "g"]
        let reminder = try XCTUnwrap(NativeNotificationDestination(userInfo: ["openclaw": payload]))
        XCTAssertFalse(store.acceptsRemoteNotification(reminder))
        UserDefaults.standard.set(["url": store.profile.gatewayURL.absoluteString, "gatewayDeviceID": "g"], forKey: bindingKey)
        XCTAssertEqual(reminder.kind, .reminderDue)
        XCTAssertEqual(reminder.eventID, "completion:reminder:r")
        var legacyPayload = payload
        legacyPayload.removeValue(forKey: "notificationKind")
        let legacy = try XCTUnwrap(NativeNotificationDestination(userInfo: ["openclaw": legacyPayload]))
        XCTAssertEqual(legacy.kind, .taskCompleted)
        XCTAssertTrue(store.observeRemoteCompletion(legacy, presenting: false))
        XCTAssertFalse(store.observeRemoteCompletion(reminder, presenting: false), "An upgrade must not duplicate retained notifications")
        let completion = try XCTUnwrap(NativeNotificationDestination(userInfo: ["openclaw":
            legacyPayload.merging(["runId": "r"]) { _, new in new }]))
        XCTAssertTrue(store.observeRemoteCompletion(completion, presenting: false))
        XCTAssertEqual(Set(store.notificationRecords.map(\.linkage.sourceEventID)), ["completion:reminder:r", "completion:r"])
    }

    func testReminderMarkerMustMatchCompatibleEnvelopeAndNamespacedRun() {
        let base: [String: Any] = ["kind": "task.completed", "notificationKind": "reminder.due",
            "workspaceId": "w", "sessionKey": "s", "runId": "reminder:r", "gatewayDeviceId": "g"]
        for overrides: [String: Any] in [["notificationKind": "unknown"], ["notificationKind": 1],
            ["runId": "r"], ["runId": "reminder:"], ["kind": "reminder.due"]] {
            XCTAssertNil(NativeNotificationDestination(userInfo: ["openclaw":
                base.merging(overrides) { _, new in new }]))
        }
    }

    func testMalformedReminderCannotFallBackToLocalRouting() {
        let base: [String: Any] = ["kind": "reminder.due", "workspaceId": "w",
            "sessionKey": "agent:main:task", "runId": "r", "gatewayDeviceId": "g"]
        for field in ["runId", "gatewayDeviceId", "workspaceId", "sessionKey"] {
            var payload = base
            payload[field] = ""
            XCTAssertNil(NativeNotificationDestination(userInfo: ["openclaw": payload,
                "workspaceID": "local", "sessionKey": "local-session"]), field)
            payload.removeValue(forKey: field)
            XCTAssertNil(NativeNotificationDestination(userInfo: ["openclaw": payload,
                "workspaceID": "local", "sessionKey": "local-session"]), "missing \(field)")
        }
    }

    func testReminderReadinessRequiresExplicitGatewaySupportAndConfiguredDelivery() throws {
        let base: [String: Any] = ["registered": true, "enabled": true, "configured": true,
            "gatewayDeviceId": "g", "workspaceId": "w"]
        func status(_ overrides: [String: Any] = [:]) throws -> NativePushStatus {
            try JSONDecoder().decode(NativePushStatus.self, from: JSONSerialization.data(
                withJSONObject: base.merging(overrides) { _, new in new }))
        }
        let legacy = try status()
        XCTAssertFalse(legacy.supportsReminders)
        XCTAssertEqual(legacy.readinessMessage(workspaceID: "w"),
            "Task alerts are ready. Update this workspace to enable reminder alerts.")
        let capable = try status(["supportedKinds": ["task.completed", "reminder.due"]])
        XCTAssertTrue(capable.supportsReminders)
        XCTAssertEqual(capable.readinessMessage(workspaceID: "w"),
            "Reminders and task alerts are ready, even when Cast is closed.")
        XCTAssertEqual(capable.readinessMessage(workspaceID: "alias"),
            "Notifications are managed by another workspace on this device.")
        for field in ["registered", "enabled", "configured"] {
            XCTAssertEqual(try status([field: false, "supportedKinds": ["reminder.due"]])
                .readinessMessage(workspaceID: "w"),
                "This workspace still needs notification delivery configured.")
        }
    }

    @MainActor
    func testOnlyCommittedReminderEventsNotifyLocallyAndDoNotDuplicate() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.isNotificationContextVisible = false
        func event(_ overrides: [String: Any] = [:], name: String = "notification.reminder") throws -> EventFrame {
            try JSONDecoder().decode(EventFrame.self, from: JSONSerialization.data(withJSONObject: [
                "event": name, "payload": ["sessionKey": "agent:main:task", "runId": "scheduled-1"]
                    .merging(overrides) { _, new in new },
            ]))
        }
        store.handleEvent(try event(["action": "finished", "status": "ok"], name: "cron"))
        for malformed: [String: Any] in [["runId": ""], ["sessionKey": ""], ["replay": true],
            ["sessionKey": "agent:main:cron:daily"], ["sessionKey": "agent:main:incognito-private"],
            ["runId": "bad\n"], ["sessionKey": "bad\n"]] {
            store.handleEvent(try event(malformed))
        }
        XCTAssertTrue(store.notificationRecords.isEmpty)
        store.handleEvent(try event())
        store.handleEvent(try event())
        #if os(iOS)
        XCTAssertTrue(store.notificationRecords.isEmpty, "APNs owns iOS reminder delivery")
        #else
        XCTAssertEqual(store.notificationRecords.count, 1)
        XCTAssertEqual(store.notificationRecords.first?.linkage.sourceEventID, "reminder:scheduled-1")
        XCTAssertEqual(store.notificationRecords.first?.transitions.last?.detail, "test-host")
        #endif
    }

    @MainActor
    func testReminderSocketDoesNotRaceAPNsDuringRegistration() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.usesRemoteCompletionDelivery = true
        store.isNotificationContextVisible = false
        let event = try JSONDecoder().decode(EventFrame.self, from: JSONSerialization.data(withJSONObject: [
            "event": "notification.reminder", "payload": ["sessionKey": "agent:main:task", "runId": "r"],
        ]))
        store.handleEvent(event)
        XCTAssertTrue(store.notificationRecords.isEmpty)
    }
}
