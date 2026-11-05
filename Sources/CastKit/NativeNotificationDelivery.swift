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

    public func remove(identifiers: [String]) {
        // Target only the click's snapshot; a new reply arriving during clearing stays visible.
        self.center.removePendingNotificationRequests(withIdentifiers: identifiers)
        self.center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    public func setBadgeCount(_ count: Int) async {
        try? await self.center.setBadgeCount(max(0, count))
    }
}
