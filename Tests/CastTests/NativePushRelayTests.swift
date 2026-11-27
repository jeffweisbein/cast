import CryptoKit
import XCTest
@testable import Cast

@MainActor
private final class FakeRelayProof: NativeRelayProofProvider {
    var generated = 0
    var attested = 0
    var payloads: [Data] = []
    func generateKey() async throws -> String { self.generated += 1; return "key-\(self.generated)" }
    func attest(key: String, challenge: String) async throws -> Data { self.attested += 1; return Data("attestation".utf8) }
    func assert(key: String, payload: Data) async throws -> Data { self.payloads.append(payload); return Data("assertion".utf8) }
}

@MainActor
final class NativePushRelayTests: XCTestCase {
    private func identity(_ seed: UInt8 = 1) -> (String, String) {
        let key = Data(repeating: seed, count: 32)
        return (SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined(),
                key.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))
    }

    func testRejectsUnboundOrForeignOriginBeforeNetworkAndKeychain() async throws {
        let (id, key) = self.identity()
        XCTAssertTrue(NativePushRelayConfiguration.validates(deviceID: id, publicKey: key, origin: NativePushRelayConfiguration.origin))
        XCTAssertFalse(NativePushRelayConfiguration.validates(deviceID: "other", publicKey: key, origin: NativePushRelayConfiguration.origin))
        XCTAssertFalse(NativePushRelayConfiguration.validates(deviceID: id, publicKey: key, origin: "https://attacker.invalid"))
        let relay = NativePushRelay(proof: FakeRelayProof(), request: { _ in XCTFail("no network"); throw NativePushRelayError.invalidResponse },
                                   load: { XCTFail("no keychain"); return nil }, save: { _ in XCTFail("no write") })
        do {
            _ = try await relay.registration(workspaceID: "w", token: "token", gatewayID: id, publicKey: key, origin: "https://attacker.invalid", force: false)
            XCTFail("must reject")
        } catch { XCTAssertTrue(error is NativePushRelayError) }
    }

    func testEnrollmentCacheAndRevocationUseSignedBindingAndKeepTokenOffGatewayGrant() async throws {
        let (id, key) = self.identity()
        let proof = FakeRelayProof()
        var stored: Data?
        var endpoints: [String] = []
        let relay = NativePushRelay(proof: proof, request: { request in
            XCTAssertEqual(request.url?.host, "jeffs-mac-studio-3.tail5db72b.ts.net")
            let endpoint = request.url!.lastPathComponent
            endpoints.append(endpoint)
            let response: [String: Any]
            switch endpoint {
            case "challenge": response = ["challengeId": "challenge-1", "challenge": "random", "expiresAtMs": Date().timeIntervalSince1970 * 1000 + 60000]
            case "register":
                let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                XCTAssertNil(envelope["apnsToken"])
                let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["signedPayloadBase64"] as? String)))
                XCTAssertEqual(bytes, proof.payloads.last)
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                XCTAssertEqual(payload["apnsToken"] as? String, "private-token")
                XCTAssertEqual((payload["gateway"] as? [String: String])?["deviceId"], id)
                response = ["relayHandle": "handle", "sendGrant": "grant", "expiresAtMs": Date().timeIntervalSince1970 * 1000 + 90 * 86400_000]
            default: response = ["revoked": true]
            }
            return (try JSONSerialization.data(withJSONObject: response), 200)
        }, load: { stored }, save: { stored = $0 })
        let result = try await relay.registration(workspaceID: "w", token: "private-token", gatewayID: id, publicKey: key, origin: NativePushRelayConfiguration.origin, force: false)
        XCTAssertEqual(result.grant.sendGrant, "grant")
        _ = try await relay.registration(workspaceID: "w", token: "private-token", gatewayID: id, publicKey: key, origin: NativePushRelayConfiguration.origin, force: false)
        XCTAssertEqual(endpoints, ["challenge", "register"])
        XCTAssertEqual(proof.generated, 1)
        XCTAssertEqual(proof.attested, 1)
        XCTAssertFalse(String(data: try XCTUnwrap(stored), encoding: .utf8)!.contains("private-token"))
        try await relay.revoke(workspaceID: "w")
        XCTAssertEqual(endpoints, ["challenge", "register", "challenge", "revoke"])
        try await relay.revoke(workspaceID: "w")
        XCTAssertEqual(endpoints.count, 4)
    }

    func testFailedRevokePersistsAndRetriesBeforeDifferentGatewayReplacement() async throws {
        let (id, key) = self.identity()
        let (otherID, otherKey) = self.identity(2)
        var stored: Data?
        var failRevoke = true
        var endpoints: [String] = []
        let relay = NativePushRelay(proof: FakeRelayProof(), request: { request in
            let endpoint = request.url!.lastPathComponent
            endpoints.append(endpoint)
            if endpoint == "revoke", failRevoke { return (Data("{}".utf8), 503) }
            let body: [String: Any] = endpoint == "challenge"
                ? ["challengeId": "c", "challenge": "random", "expiresAtMs": Date().timeIntervalSince1970 * 1000 + 60000]
                : endpoint == "register"
                    ? ["relayHandle": "h", "sendGrant": "g", "expiresAtMs": Date().timeIntervalSince1970 * 1000 + 90 * 86400_000]
                    : ["revoked": true]
            return (try JSONSerialization.data(withJSONObject: body), 200)
        }, load: { stored }, save: { stored = $0 })
        _ = try await relay.registration(workspaceID: "w", token: "token", gatewayID: id, publicKey: key, origin: NativePushRelayConfiguration.origin, force: false)
        do {
            _ = try await relay.registration(workspaceID: "w", token: "token", gatewayID: otherID, publicKey: otherKey, origin: NativePushRelayConfiguration.origin, force: false)
            XCTFail("must not replace an unrevoked binding")
        } catch {}
        XCTAssertEqual(endpoints.filter { $0 == "register" }.count, 1)
        XCTAssertTrue(String(data: try XCTUnwrap(stored), encoding: .utf8)!.contains("pendingRevocations"))
        failRevoke = false
        await relay.retryPendingRevocations()
        _ = try await relay.registration(workspaceID: "w", token: "token", gatewayID: otherID, publicKey: otherKey, origin: NativePushRelayConfiguration.origin, force: false)
        XCTAssertEqual(endpoints.filter { $0 == "register" }.count, 2)
        XCTAssertEqual(endpoints.filter { $0 == "revoke" }.count, 2)
    }

    func testFailedInitialEnrollmentDoesNotPersistAttestedIdentity() async throws {
        let (id, key) = self.identity()
        var saves = 0
        let relay = NativePushRelay(proof: FakeRelayProof(), request: { request in
            if request.url!.lastPathComponent == "challenge" {
                return (try JSONSerialization.data(withJSONObject: ["challengeId": "c", "challenge": "random", "expiresAtMs": Date().timeIntervalSince1970 * 1000 + 60000]), 200)
            }
            return (Data("{}".utf8), 503)
        }, load: { nil }, save: { _ in saves += 1 })
        do {
            _ = try await relay.registration(workspaceID: "w", token: "token", gatewayID: id, publicKey: key, origin: NativePushRelayConfiguration.origin, force: false)
            XCTFail("must fail")
        } catch {}
        XCTAssertEqual(saves, 0)
    }
}
