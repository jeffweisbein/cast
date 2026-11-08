import Foundation
#if os(iOS)
import UIKit
#endif

/// Shared by the signed entitlement and Info.plist; never infer environment from Debug/Release.
public enum NativePushEnvironment {
    public static func resolve(_ value: String?) -> String? {
        switch value {
        case "development": return "sandbox"
        case "production": return "production"
        default: return nil
        }
    }
}

@MainActor
public final class NativePushRegistration {
    public static let shared = NativePushRegistration()
    public static let changed = Notification.Name("CastNativePushRegistrationChanged")
    public private(set) var token: String?
    public private(set) var failureMessage: String?
    public var environment: String? {
        NativePushEnvironment.resolve(Bundle.main.object(forInfoDictionaryKey: "CastAPNSEnvironment") as? String)
    }

    public func registerIfAuthorized() async {
        #if os(iOS)
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard self.environment != nil else {
            self.failureMessage = "This build does not support remote notifications."
            return
        }
        guard await NativeNotificationDelivery.shared.isAuthorized() else { return }
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    public func received(token: Data) {
        self.token = token.map { String(format: "%02x", $0) }.joined()
        self.failureMessage = nil
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    public func failed() {
        self.token = nil
        self.failureMessage = "Apple notification registration failed. Check this build’s notification support and try again."
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

#if os(iOS)
@MainActor
final class CastNotificationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NativePushRegistration.shared.received(token: deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Do not log tokens or provider errors containing identity details.
        NativePushRegistration.shared.failed()
    }
}
#endif

public struct NativePushStatus: Decodable, Sendable {
    public let registered: Bool
    public let enabled: Bool
    public let configured: Bool
    public let gatewayDeviceId: String
}
