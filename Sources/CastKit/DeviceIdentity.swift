// Cast — mirrored from OpenClawKit DeviceIdentity.swift (MIT, © 2025 Peter Steinberger). See ATTRIBUTION.md.
import CryptoKit
import Foundation
import Security

public struct DeviceIdentity: Codable, Sendable {
    public var deviceId: String
    public var publicKey: String
    public var privateKey: String
    public var createdAtMs: Int
}

public enum DeviceIdentityStore {
    private static let keychainAccount = "device.identity.ed25519"

    public static func loadOrCreate() throws -> DeviceIdentity {
        if let data = try SecureStore.data(for: self.keychainAccount),
           let identity = try? JSONDecoder().decode(DeviceIdentity.self, from: data),
           self.isValid(identity) {
            return identity
        }

        // One-time M1 migration: commit the exact identity to Keychain, verify the
        // round-trip, then remove the plaintext private-key file.
        let url = self.fileURL()
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(DeviceIdentity.self, from: data),
           self.isValid(decoded) {
            try self.saveToKeychain(decoded)
            try? FileManager.default.removeItem(at: url)
            return decoded
        }
        let identity = self.generate()
        try self.saveToKeychain(identity)
        return identity
    }

    public static func signPayload(_ payload: String, identity: DeviceIdentity) -> String? {
        guard let privateKeyData = Data(base64Encoded: identity.privateKey) else { return nil }
        do {
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
            let signature = try privateKey.signature(for: Data(payload.utf8))
            return self.base64UrlEncode(signature)
        } catch {
            return nil
        }
    }

    public static func publicKeyBase64Url(_ identity: DeviceIdentity) -> String? {
        guard let data = Data(base64Encoded: identity.publicKey) else { return nil }
        return self.base64UrlEncode(data)
    }

    private static func generate() -> DeviceIdentity {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let deviceId = SHA256.hash(data: publicKeyData).compactMap { String(format: "%02x", $0) }.joined()
        return DeviceIdentity(
            deviceId: deviceId,
            publicKey: publicKeyData.base64EncodedString(),
            privateKey: privateKey.rawRepresentation.base64EncodedString(),
            createdAtMs: Int(Date().timeIntervalSince1970 * 1000))
    }

    private static func base64UrlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func saveToKeychain(_ identity: DeviceIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        try SecureStore.set(data, for: self.keychainAccount)
        guard let verified = try SecureStore.data(for: self.keychainAccount), verified == data else {
            throw SecureStoreError.keychain(errSecDecode)
        }
    }

    private static func isValid(_ identity: DeviceIdentity) -> Bool {
        guard !identity.deviceId.isEmpty,
              let publicData = Data(base64Encoded: identity.publicKey),
              let privateData = Data(base64Encoded: identity.privateKey),
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
        else { return false }
        return privateKey.publicKey.rawRepresentation == publicData
    }

    private static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Cast", isDirectory: true)
            .appendingPathComponent("identity", isDirectory: true)
            .appendingPathComponent("device.json", isDirectory: false)
    }
}

public enum GatewayDeviceAuthPayload {
    /// v3 signature payload — exact pipe-joined format the gateway verifies.
    public static func buildV3(
        deviceId: String,
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        signedAtMs: Int,
        token: String?,
        nonce: String,
        platform: String?,
        deviceFamily: String?) -> String
    {
        [
            "v3",
            deviceId,
            clientId,
            clientMode,
            role,
            scopes.joined(separator: ","),
            String(signedAtMs),
            token ?? "",
            nonce,
            normalizeMetadataField(platform),
            normalizeMetadataField(deviceFamily),
        ].joined(separator: "|")
    }

    /// Cross-runtime deterministic normalization: trim, then lowercase ASCII A-Z only.
    static func normalizeMetadataField(_ value: String?) -> String {
        guard let value else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        var output = String()
        output.reserveCapacity(trimmed.count)
        for scalar in trimmed.unicodeScalars {
            let codePoint = scalar.value
            if codePoint >= 65, codePoint <= 90, let lowered = UnicodeScalar(codePoint + 32) {
                output.unicodeScalars.append(lowered)
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}
