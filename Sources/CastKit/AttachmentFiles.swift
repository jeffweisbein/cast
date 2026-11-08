import CryptoKit
import Foundation

/// Durable, app-private sources survive restart and uncertain sends without encoding whole
/// videos into the outbox JSON. The original security-scoped URL is never retained or deleted.
enum AttachmentFiles {
    private static let storageLock = NSLock()
    static let maxStoredBytes: Int64 = 4_000_000_000
    private static var activeDrafts: Set<URL> = []
    private static var reservations: [URL: Int64] = [:]
    private struct Lease: Codable { let outboxPath: String? }
    private static func leaseURL(_ url: URL) -> URL { url.appendingPathExtension("lease") }
    static func remove(_ url: URL) {
        storageLock.lock(); defer { storageLock.unlock() }
        activeDrafts.remove(url)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: leaseURL(url))
    }
    /// Pin before atomically writing the outbox. A crash between these steps leaves an
    /// unreferenced draft, not a referenced file mistaken for an orphan.
    static func pin(_ attachments: [PreparedAttachment], outbox: URL) throws {
        storageLock.lock(); defer { storageLock.unlock() }
        for url in attachments.compactMap(\.fileURL) {
            guard url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
                  FileManager.default.fileExists(atPath: url.path) else { throw AttachmentError.unreadable }
            try JSONEncoder().encode(Lease(outboxPath: outbox.path)).write(to: leaseURL(url), options: .atomic)
        }
    }
    /// Reap only old, unreferenced copies. Active drafts and any extant outbox stay protected.
    private static func pruneOrphans(now: Date = Date()) throws {
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) where url.pathExtension != "lease" {
            guard !activeDrafts.contains(url),
                  let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(date) > 86400 else { continue }
            let lease = (try? Data(contentsOf: leaseURL(url))).flatMap { try? JSONDecoder().decode(Lease.self, from: $0) }
            if let path = lease?.outboxPath, FileManager.default.fileExists(atPath: path) { continue }
            try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: leaseURL(url))
        }
    }
    static func diskBacked(_ attachments: [PreparedAttachment]) throws -> [PreparedAttachment] {
        var results: [PreparedAttachment] = [], created: [PreparedAttachment] = []
        do {
            for item in attachments {
                try Task.checkCancellation()
                if item.fileURL != nil { results.append(item); continue }
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temp) }
                try item.data.write(to: temp, options: .atomic)
                let file = try copy(url: temp, name: item.fileName, mimeType: item.mimeType, id: item.id, type: item.type)
                created.append(file); results.append(file)
            }
            return results
        } catch { created.forEach { $0.removeOwnedFile() }; throw error }
    }
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cast/AttachmentSources", isDirectory: true)
    }
    static func copy(url: URL, name: String, mimeType: String, id: UUID = UUID(), type: String = "file") throws -> PreparedAttachment {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else { throw AttachmentError.unreadable }
        try AttachmentLimits.validate(sizes: [size])
        try Task.checkCancellation()
        let destination = root.appendingPathComponent(UUID().uuidString)
        try reserve(size: size, destination: destination)
        defer { storageLock.lock(); reservations[destination] = nil; storageLock.unlock() }
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let result = try digest(url: destination)
            guard result.size == size else { throw AttachmentError.unreadable }
            try Task.checkCancellation()
            try JSONEncoder().encode(Lease(outboxPath: nil)).write(to: leaseURL(destination), options: .atomic)
            storageLock.lock(); activeDrafts.insert(destination); storageLock.unlock()
            return PreparedAttachment(id: id, type: type, mimeType: mimeType, fileName: name, fileURL: destination, size: size, sha256: result.hash)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    private static func reserve(size: Int, destination: URL) throws {
        // Admission is serialized, but potentially large copy/hash IO never holds this lock.
        storageLock.lock(); defer { storageLock.unlock() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try pruneOrphans()
        let existing = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        let used = existing.filter { reservations[$0] == nil }.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard used + reservations.values.reduce(0,+) + Int64(size) <= maxStoredBytes else {
            throw NSError(domain: "CastAttachments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pending original attachments use the 4 GB local storage budget. Send or remove pending files before importing more."])
        }
        let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let available, available < Int64(size) + reservations.values.reduce(0,+) + 256_000_000 {
            throw NSError(domain: "CastAttachments", code: 2, userInfo: [NSLocalizedDescriptionKey: "There isn’t enough free storage to safely keep this original for upload and retry."])
        }
        var excluded = root; var backup = URLResourceValues(); backup.isExcludedFromBackup = true
        try? excluded.setResourceValues(backup)
        reservations[destination] = Int64(size)
    }
    static func digest(url: URL) throws -> (hash: String, size: Int) {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(), size = 0
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation(); size += bytes.count; hash.update(data: bytes)
            guard size <= AttachmentLimits.maxFileBytes else { throw AttachmentLimits.LimitError.file }
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}
