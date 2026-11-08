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
        XCTAssertEqual(store.notificationRecords.count, 1)
        XCTAssertEqual(store.notificationRecords.first?.linkage.sourceEventID, "completion:run-1")
        XCTAssertEqual(store.notificationRecords.first?.transitions.last?.detail, "test-host")
    }

    @MainActor
    func testCurrentConversationOnlySuppressesWhileActuallyVisible() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "agent:main:task"
        store.selectedSessionKey = key
        store.handleEvent(try taskCompletionEvent(sessionKey: key, runID: "visible"))
        XCTAssertEqual(store.notificationRecords.first?.transitions.last?.detail, "visible-session")
        store.isNotificationContextVisible = false
        store.handleEvent(try taskCompletionEvent(sessionKey: key, runID: "away"))
        XCTAssertEqual(store.notificationRecords.first(where: { $0.linkage.sourceEventID == "completion:away" })?.transitions.last?.detail, "test-host")
        store.handleEvent(try taskCompletionEvent(sessionKey: key, runID: "visible"))
        XCTAssertEqual(store.notificationRecords.count, 2)
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

    func testPushEnvironmentMustMatchExplicitSignedBuildSetting() {
        XCTAssertEqual(NativePushEnvironment.resolve("development"), "sandbox")
        XCTAssertEqual(NativePushEnvironment.resolve("production"), "production")
        XCTAssertNil(NativePushEnvironment.resolve("Release"))
        XCTAssertNil(NativePushEnvironment.resolve(nil))
    }
}
