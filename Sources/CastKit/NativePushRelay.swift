import CryptoKit
import Foundation
#if os(iOS)
import DeviceCheck
#endif

public enum NativePushRelayError: Error, LocalizedError {
    case unavailable, invalidIdentity, invalidResponse, rejected(Int)
    public var errorDescription: String? {
        switch self {
        case .unavailable: "This device cannot verify Cast for remote notifications."
        case .invalidIdentity: "This workspace did not provide a valid push identity."
        case .invalidResponse: "The Cast notification service returned an invalid response."
        case .rejected: "The Cast notification service could not register this device. Reconnect to try again."
        }
    }
}

public enum NativePushRelayConfiguration {
    public static let origin = "https://jeffs-mac-studio-3.tail5db72b.ts.net:10000"
    public static let bundleID = "com.besttechie.cast"

    public static func validates(deviceID: String, publicKey: String, origin: String?) -> Bool {
        guard origin == self.origin else { return false }
        var base64 = publicKey.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let bytes = Data(base64Encoded: base64), bytes.count == 32 else { return false }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == deviceID
    }
}

@MainActor
protocol NativeRelayProofProvider {
    func generateKey() async throws -> String
    func attest(key: String, challenge: String) async throws -> Data
    func assert(key: String, payload: Data) async throws -> Data
}

@MainActor
private struct AppleNativeRelayProof: NativeRelayProofProvider {
    func generateKey() async throws -> String {
        #if os(iOS)
        guard DCAppAttestService.shared.isSupported else { throw NativePushRelayError.unavailable }
        return try await DCAppAttestService.shared.generateKey()
        #else
        throw NativePushRelayError.unavailable
        #endif
    }
    func attest(key: String, challenge: String) async throws -> Data {
        #if os(iOS)
        return try await DCAppAttestService.shared.attestKey(key, clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8))))
        #else
        throw NativePushRelayError.unavailable
        #endif
    }
    func assert(key: String, payload: Data) async throws -> Data {
        #if os(iOS)
        return try await DCAppAttestService.shared.generateAssertion(key, clientDataHash: Data(SHA256.hash(data: payload)))
        #else
        throw NativePushRelayError.unavailable
        #endif
    }
}

struct NativeRelayGrant: Codable, Sendable {
    let relayHandle: String
    let sendGrant: String
    let expiresAtMs: Double
}

/// One serialized owner for App Attest counters and device-only Keychain registrations.
/// Requests never follow redirects, send Apple tokens to a gateway, or accept a gateway-supplied URL.
@MainActor
final class NativePushRelay {
    static let shared = NativePushRelay()
    private struct Challenge: Decodable { let challengeId: String; let challenge: String; let expiresAtMs: Double }
    private struct Cached: Codable {
        let gatewayID: String
        let tokenHash: String
        let grant: NativeRelayGrant
    }
    private struct State: Codable {
        var keyID: String
        var installationID: String
        var registrations: [String: Cached] = [:]
        var pendingRevocations: Set<String> = []
    }
    private let proof: any NativeRelayProofProvider
    private let request: (URLRequest) async throws -> (Data, Int)
    private let load: () throws -> Data?
    private let save: (Data) throws -> Void
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        proof: (any NativeRelayProofProvider)? = nil,
        request: ((URLRequest) async throws -> (Data, Int))? = nil,
        load: @escaping () throws -> Data? = { try SecureStore.data(for: "cast.push.relay.v1") },
        save: @escaping (Data) throws -> Void = { try SecureStore.set($0, for: "cast.push.relay.v1") })
    {
        self.proof = proof ?? AppleNativeRelayProof()
        self.request = request ?? { request in
            let (bytes, response) = try await NativeRelayHTTP.session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw NativePushRelayError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 32768 else { throw NativePushRelayError.invalidResponse }
                data.append(byte)
            }
            return (data, http.statusCode)
        }
        self.load = load
        self.save = save
    }

    private func acquire() async {
        if !self.busy { self.busy = true; return }
        await withCheckedContinuation { self.waiters.append($0) }
    }
    private func release() {
        if self.waiters.isEmpty { self.busy = false } else { self.waiters.removeFirst().resume() }
    }
    private func readState() throws -> State? {
        try self.load().map { try JSONDecoder().decode(State.self, from: $0) }
    }
    private func persist(_ state: State, resolving workspaceID: String? = nil) throws {
        var merged = state
        // Workspace edits can mark a revocation during an awaited enrollment.
        // Never overwrite that newer durable intent with this operation's snapshot.
        if let current = try self.readState() { merged.pendingRevocations.formUnion(current.pendingRevocations) }
        if let workspaceID { merged.pendingRevocations.remove(workspaceID) }
        try self.save(JSONEncoder().encode(merged))
    }

    func registration(workspaceID: String, token: String, gatewayID: String, publicKey: String,
                      origin: String?, force: Bool) async throws -> (grant: NativeRelayGrant, installationID: String) {
        guard NativePushRelayConfiguration.validates(deviceID: gatewayID, publicKey: publicKey, origin: origin) else {
            throw NativePushRelayError.invalidIdentity
        }
        await self.acquire()
        defer { self.release() }
        try Task.checkCancellation()
        var state = try self.readState()
        if var previous = state, let cached = previous.registrations[workspaceID],
           cached.gatewayID != gatewayID || previous.pendingRevocations.contains(workspaceID) {
            previous.pendingRevocations.insert(workspaceID)
            try self.persist(previous)
            try await self.revokeCached(workspaceID: workspaceID, state: &previous)
            state = previous
        }
        let tokenHash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        if !force, let state, let cached = state.registrations[workspaceID], cached.gatewayID == gatewayID,
           cached.tokenHash == tokenHash, cached.grant.expiresAtMs > Date().timeIntervalSince1970 * 1000 + 7 * 86400_000 {
            return (cached.grant, state.installationID)
        }
        let challenge: Challenge = try await self.post("challenge", body: [:])
        guard challenge.expiresAtMs > Date().timeIntervalSince1970 * 1000,
              challenge.challenge.utf8.count <= 512, !challenge.challenge.isEmpty else { throw NativePushRelayError.invalidResponse }
        let newIdentity = state == nil
        if state == nil { state = try await State(keyID: self.proof.generateKey(), installationID: UUID().uuidString) }
        guard var state else { throw NativePushRelayError.invalidResponse }
        let payload: [String: Any] = [
            "challengeId": challenge.challengeId, "installationId": state.installationID,
            "bundleId": NativePushRelayConfiguration.bundleID, "environment": "production",
            "apnsToken": token, "gateway": ["deviceId": gatewayID, "publicKey": publicKey],
        ]
        let envelope = try await self.envelope(payload, state: state, challenge: challenge.challenge, attest: newIdentity)
        let grant: NativeRelayGrant = try await self.post("register", body: envelope)
        guard !grant.relayHandle.isEmpty, grant.relayHandle.utf8.count <= 512,
              !grant.sendGrant.isEmpty, grant.sendGrant.utf8.count <= 1024,
              grant.expiresAtMs.isFinite, grant.expiresAtMs > Date().timeIntervalSince1970 * 1000 else {
            throw NativePushRelayError.invalidResponse
        }
        state.registrations[workspaceID] = Cached(gatewayID: gatewayID, tokenHash: tokenHash, grant: grant)
        // Persist only after server confirmation. A failed first enrollment never leaves
        // a key marked attested when the server might not have received its proof.
        try self.persist(state)
        return (grant, state.installationID)
    }

    /// Save a tombstone before disconnecting/replacing a workspace; retry on foreground.
    func markRevocationPending(workspaceID: String) throws {
        guard var state = try self.readState(), state.registrations[workspaceID] != nil else { return }
        state.pendingRevocations.insert(workspaceID)
        try self.persist(state)
    }

    func retryPendingRevocations() async {
        guard let state = try? self.readState() else { return }
        for workspaceID in state.pendingRevocations { try? await self.revoke(workspaceID: workspaceID) }
    }

    func revoke(workspaceID: String) async throws {
        await self.acquire()
        defer { self.release() }
        guard var state = try self.readState(), state.registrations[workspaceID] != nil else { return }
        state.pendingRevocations.insert(workspaceID)
        try self.persist(state)
        try await self.revokeCached(workspaceID: workspaceID, state: &state)
    }

    private func revokeCached(workspaceID: String, state: inout State) async throws {
        guard let cached = state.registrations[workspaceID] else { return }
        let challenge: Challenge = try await self.post("challenge", body: [:])
        let payload: [String: Any] = ["challengeId": challenge.challengeId, "relayHandle": cached.grant.relayHandle, "action": "revoke"]
        let envelope = try await self.envelope(payload, state: state, challenge: challenge.challenge, attest: false)
        struct Result: Decodable { let revoked: Bool }
        let result: Result = try await self.post("revoke", body: envelope)
        guard result.revoked else { throw NativePushRelayError.invalidResponse }
        state.registrations.removeValue(forKey: workspaceID)
        state.pendingRevocations.remove(workspaceID)
        try self.persist(state, resolving: workspaceID)
    }

    private func envelope(_ payload: [String: Any], state: State, challenge: String, attest: Bool) async throws -> [String: Any] {
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var result: [String: Any] = ["keyId": state.keyID, "signedPayloadBase64": bytes.base64EncodedString()]
        if attest { result["attestationObject"] = try await self.proof.attest(key: state.keyID, challenge: challenge).base64EncodedString() }
        result["assertion"] = try await self.proof.assert(key: state.keyID, payload: bytes).base64EncodedString()
        return result
    }

    private func post<T: Decodable>(_ endpoint: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: NativePushRelayConfiguration.origin + "/v1/push/" + endpoint) else { throw NativePushRelayError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, status) = try await self.request(request)
        guard data.count <= 32768 else { throw NativePushRelayError.invalidResponse }
        guard (200..<300).contains(status) else { throw NativePushRelayError.rejected(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private final class NativeRelayHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let delegate = NativeRelayHTTP()
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
