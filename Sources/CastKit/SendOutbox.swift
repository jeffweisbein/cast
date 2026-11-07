import CryptoKit
import Foundation

struct StoredSend: Codable, Sendable {
    let sessionKey: String
    let idempotencyKey: String
    let context: PendingSendContext
    let createdAt: Date
}

/// Exact original payloads, workspace-local and never replayed automatically.
actor SendOutbox {
    let root: URL
    init(root: URL) { self.root = root }
    private func url(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest + ".json")
    }
    func save(_ send: StoredSend) throws {
        if FileManager.default.fileExists(atPath: url(send.idempotencyKey).path) {
            let original = try load(send.idempotencyKey, sessionKey: send.sessionKey)
            guard original.context == send.context else { throw ArtifactTransferError.invalid }
            return // Exact retry: retain the original bytes and creation time.
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoded = try JSONEncoder().encode(send)
        let existing = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let otherBytes = existing.filter { $0 != url(send.idempotencyKey) }.reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard encoded.count + otherBytes <= 128 * 1024 * 1024 else {
            throw NSError(domain: "CastOutbox", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unconfirmed sends exceed the 128 MB local outbox limit."])
        }
        try encoded.write(to: url(send.idempotencyKey), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(send.idempotencyKey).path)
        var excluded = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
    }
    func load(_ key: String, sessionKey: String) throws -> StoredSend {
        let send = try JSONDecoder().decode(StoredSend.self, from: Data(contentsOf: url(key)))
        guard send.idempotencyKey == key, SessionKeyMatcher.matches(send.sessionKey, sessionKey) else { throw ArtifactTransferError.invalid }
        return send
    }
    func acknowledge(_ keys: Set<String>, sessionKey: String) {
        for key in keys {
            if (try? self.load(key, sessionKey: sessionKey)) != nil { self.remove(key) }
        }
    }
    func remove(_ key: String) { try? FileManager.default.removeItem(at: url(key)) }
}

enum SendAttemptError: Error { case notSubmitted, uncertain }
