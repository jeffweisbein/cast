import Foundation
import UserNotifications

public enum NativeNotificationOutcome: Sendable, Equatable {
    case delivered
    case suppressed(String)
    case failed(String)
}

/// The only native-notification boundary. Ledger tests never instantiate or call it.
///
/// Cast does not prompt opportunistically when an event arrives. Delivery is attempted only
/// after the user has authorized notifications; the in-app notification center owns the
/// explicit authorization action.
public actor NativeNotificationDelivery {
    public static let shared = NativeNotificationDelivery()

    private let center = UNUserNotificationCenter.current()

    public func isAuthorized() async -> Bool {
        let status = await self.center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    public func requestAuthorization() async -> Bool {
        (try? await self.center.requestAuthorization(options: [.alert, .badge, .sound])) == true
    }

    public func deliver(
        identifier: String,
        workspaceID: String,
        sessionKey: String,
        title: String,
        body: String
    ) async -> NativeNotificationOutcome {
        let settings = await self.center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            return .suppressed("authorization-not-requested")
        case .denied:
            return .suppressed("authorization-denied")
        @unknown default:
            return .suppressed("authorization-unknown")
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            "workspaceID": workspaceID,
            "sessionKey": sessionKey,
        ]
        do {
            try await self.center.add(UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil))
            return .delivered
        } catch {
            return .failed("native-delivery-failed")
        }
    }

    public func deliveredRemoteDestinations() async -> [NativeNotificationDestination] {
        await self.center.deliveredNotifications().compactMap {
            guard let destination = NativeNotificationDestination(userInfo: $0.request.content.userInfo),
                  destination.gatewayDeviceID != nil else { return nil }
            return destination
        }
    }

    public func remove(identifiers: [String]) async {
        // APNs assigns its own notification identifier. Match the exact per-run snapshot,
        // never remove every remote alert while a newer completion can be arriving.
        let matching = Set(identifiers)
        var deliveredIDs = identifiers
        for notification in await self.center.deliveredNotifications() {
            guard let destination = NativeNotificationDestination(userInfo: notification.request.content.userInfo),
                  let runID = destination.runID,
                  matching.contains("\(destination.workspaceID):completion:\(runID)") else { continue }
            deliveredIDs.append(notification.request.identifier)
        }
        self.center.removePendingNotificationRequests(withIdentifiers: identifiers)
        self.center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
    }

    public func setBadgeCount(_ count: Int) async {
        try? await self.center.setBadgeCount(max(0, count))
    }
}

/// Typed notification routing; payloads never supply a gateway address or credentials.
public struct NativeNotificationDestination: Equatable, Sendable {
    public let workspaceID: String
    public let sessionKey: String
    public let gatewayDeviceID: String?
    public let runID: String?

    public init?(userInfo: [AnyHashable: Any]) {
        let remote = userInfo["openclaw"] as? [String: Any]
        if userInfo["openclaw"] != nil && remote == nil { return nil }
        if let remote {
            guard remote["kind"] as? String == "task.completed",
                  let gateway = remote["gatewayDeviceId"] as? String, !gateway.isEmpty,
                  let run = remote["runId"] as? String, !run.isEmpty,
                  gateway.utf8.count <= 512, run.utf8.count <= 512 else { return nil }
        }
        guard let workspaceID = (remote?["workspaceId"] ?? userInfo["workspaceID"]) as? String,
              let sessionKey = (remote?["sessionKey"] ?? userInfo["sessionKey"]) as? String,
              !workspaceID.isEmpty, workspaceID.utf8.count <= 512,
              !sessionKey.isEmpty, sessionKey.utf8.count <= 2048,
              workspaceID.rangeOfCharacter(from: .controlCharacters) == nil,
              sessionKey.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        self.workspaceID = workspaceID
        self.sessionKey = sessionKey
        self.gatewayDeviceID = remote?["gatewayDeviceId"] as? String
        self.runID = remote?["runId"] as? String
    }
}

/// Install during app initialization so a cold-launch response is retained until the
/// workspace manager is ready. Never create a workspace from notification payload data.
@MainActor
public final class NativeNotificationResponseRouter: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NativeNotificationResponseRouter()
    public var openDestination: ((NativeNotificationDestination) -> Bool)?
    public var presentRemoteDestination: ((NativeNotificationDestination) -> Bool)?
    private var pendingDestination: NativeNotificationDestination?

    public func install() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    public func consumePendingDestination() {
        guard let destination = self.pendingDestination, let openDestination else { return }
        self.pendingDestination = nil
        _ = openDestination(destination)
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void)
    {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let destination = NativeNotificationDestination(userInfo: response.notification.request.content.userInfo)
        else { completionHandler(); return }
        Task { @MainActor in
            self.pendingDestination = destination
            self.consumePendingDestination()
            completionHandler()
        }
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
    {
        guard let destination = NativeNotificationDestination(userInfo: notification.request.content.userInfo) else {
            completionHandler([])
            return
        }
        guard destination.gatewayDeviceID != nil else {
            // ChatStore already applies local visibility and per-run deduplication.
            completionHandler([.banner, .sound])
            return
        }
        Task { @MainActor in
            let present = self.presentRemoteDestination?(destination) ?? false
            completionHandler(present ? [.banner, .sound] : [])
        }
    }
}
