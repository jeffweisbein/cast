import Foundation
import Security

public enum SecureStoreError: Error, LocalizedError, Sendable {
    case keychain(OSStatus)
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        case .invalidUTF8:
            return "Stored secret is not valid UTF-8"
        }
    }
}

/// Small Keychain wrapper shared by iOS and macOS. Profiles remain non-secret;
/// only credentials and the Ed25519 identity enter this store.
public enum SecureStore {
    // v2 intentionally does not read credentials created by ad-hoc M2 builds.
    // Those items have unstable ACLs and can trigger repeated macOS password prompts.
    private static let service = "com.besttechie.cast.secure-store.v2"

    public static func data(for account: String) throws -> Data? {
        var query = self.baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecureStoreError.keychain(status) }
        return result as? Data
    }

    public static func set(_ data: Data, for account: String) throws {
        let query = self.baseQuery(account: account)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw SecureStoreError.keychain(updateStatus) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SecureStoreError.keychain(addStatus) }
    }

    public static func string(for account: String) throws -> String? {
        guard let data = try self.data(for: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { throw SecureStoreError.invalidUTF8 }
        return value
    }

    public static func set(_ value: String, for account: String) throws {
        try self.set(Data(value.utf8), for: account)
    }

    public static func delete(account: String) throws {
        let status = SecItemDelete(self.baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.keychain(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account,
        ]
    }
}

public enum GatewayCredentialKind: String, Codable, Sendable {
    case sharedToken
    case deviceToken
    case bootstrapToken
}

public struct GatewayCredential: Equatable, Sendable {
    public let kind: GatewayCredentialKind
    public let token: String

    public var authKey: String {
        self.kind == .bootstrapToken ? "bootstrapToken" : "token"
    }
}

public enum GatewayCredentialStore {
    public static func preferred(workspaceID: String) -> GatewayCredential? {
        if let shared = try? SecureStore.string(for: self.account(workspaceID, "shared")), !shared.isEmpty {
            return GatewayCredential(kind: .sharedToken, token: shared)
        }
        if let device = self.deviceToken(workspaceID: workspaceID) {
            return GatewayCredential(kind: .deviceToken, token: device)
        }
        if let bootstrap = try? SecureStore.string(for: self.account(workspaceID, "bootstrap")), !bootstrap.isEmpty {
            return GatewayCredential(kind: .bootstrapToken, token: bootstrap)
        }
        return nil
    }

    public static func deviceCredential(workspaceID: String) -> GatewayCredential? {
        self.deviceToken(workspaceID: workspaceID).map { GatewayCredential(kind: .deviceToken, token: $0) }
    }

    public static func setSharedToken(_ token: String, workspaceID: String) throws {
        try SecureStore.set(token, for: self.account(workspaceID, "shared"))
    }

    public static func setBootstrapToken(_ token: String, workspaceID: String) throws {
        try SecureStore.set(token, for: self.account(workspaceID, "bootstrap"))
    }

    /// An explicit setup-code pairing must supersede stale shared/device credentials. Otherwise
    /// `preferred` selects those first and a fresh recovery code is never attempted.
    public static func replaceWithBootstrapToken(_ token: String, workspaceID: String) throws {
        try self.setBootstrapToken(token, workspaceID: workspaceID)
        try SecureStore.delete(account: self.account(workspaceID, "shared"))
        try SecureStore.delete(account: self.account(workspaceID, "device.operator"))
    }

    public static func setDeviceToken(_ token: String, workspaceID: String) throws {
        try SecureStore.set(token, for: self.account(workspaceID, "device.operator"))
        try? SecureStore.delete(account: self.account(workspaceID, "bootstrap"))
    }

    public static func removeAll(workspaceID: String) {
        for suffix in ["shared", "bootstrap", "device.operator"] {
            try? SecureStore.delete(account: self.account(workspaceID, suffix))
        }
    }

    private static func deviceToken(workspaceID: String) -> String? {
        guard let token = try? SecureStore.string(for: self.account(workspaceID, "device.operator")), !token.isEmpty else { return nil }
        return token
    }

    private static func account(_ workspaceID: String, _ suffix: String) -> String {
        "workspace.\(workspaceID).\(suffix)"
    }
}
