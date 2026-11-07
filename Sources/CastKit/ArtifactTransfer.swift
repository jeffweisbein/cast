import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Gateway-issued artifact identities, never arbitrary filesystem download requests.
public struct GatewayArtifact: Codable, Sendable, Identifiable {
    public struct Download: Codable, Sendable { public let mode: String }
    public let id: String
    public let title: String
    public let type: String
    public let sessionKey: String?
    public let mimeType: String?
    public let sizeBytes: Int?
    public let messageSeq: Int?
    public let download: Download
}

public enum ArtifactTransferError: Error, LocalizedError {
    case invalid, tooLarge, unavailable, changed, connectionChanged
    public var errorDescription: String? {
        switch self {
        case .invalid: return "The gateway returned an invalid download. No file was saved."
        case .tooLarge: return "This file exceeds Cast’s 64 MB download limit."
        case .unavailable: return "The file is unavailable or its link expired. Retry to request a fresh link."
        case .changed: return "The downloaded size does not match the artifact. Retry to fetch it again."
        case .connectionChanged: return "The connection changed during this download. Retry on the current connection."
        }
    }
}

public enum ArtifactTransferPolicy {
    public static let maximumBytes = 64 * 1024 * 1024
    public static func safeFilename(_ title: String) -> String {
        let name = (title.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            .components(separatedBy: .controlCharacters).joined()
        guard !name.isEmpty, name != ".", name != ".." else { return "download" }
        // Bound bytes, not Swift characters; leave room for an inferred extension.
        let ext = (name as NSString).pathExtension
        let suffix = !ext.isEmpty && ext.utf8.count <= 32 ? "." + ext : ""
        let stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
        var result = ""
        for character in stem {
            guard result.utf8.count + String(character).utf8.count <= 200 - suffix.utf8.count else { break }
            result.append(character)
        }
        return (result.isEmpty ? "download" : result) + suffix
    }
    public static func url(_ raw: String, gateway: URL) throws -> URL {
        var base = URLComponents(url: gateway, resolvingAgainstBaseURL: false)!
        base.scheme = gateway.scheme == "wss" ? "https" : "http"
        base.path = "/"; base.query = nil; base.fragment = nil
        let absoluteScheme = URLComponents(string: raw)?.scheme?.lowercased()
        guard raw.hasPrefix("/api/") || ["https", "http"].contains(absoluteScheme ?? "") else { throw ArtifactTransferError.invalid }
        guard !raw.hasPrefix("//"), let url = URL(string: raw, relativeTo: base.url)?.absoluteURL,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && base.scheme == "http" && url.host == base.host && url.port == base.port)
        else { throw ArtifactTransferError.invalid }
        if raw.hasPrefix("/") && !raw.hasPrefix("/api/") { throw ArtifactTransferError.invalid }
        return url
    }
    public static func bytes(_ response: AnyCodable, expectedSize: Int?) throws -> Data {
        guard response["encoding"]?.stringValue == "base64", let encoded = response["data"]?.stringValue,
              encoded.utf8.count <= ((maximumBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: encoded) else { throw ArtifactTransferError.invalid }
        try self.validateSize(data.count, expected: expectedSize)
        return data
    }
    public static func downloadSize(_ response: AnyCodable, listedSize: Int?) throws -> Int? {
        let current = response["artifact"]?["sizeBytes"]?.intValue
        for size in [current, listedSize].compactMap({ $0 }) {
            guard size >= 0 else { throw ArtifactTransferError.invalid }
            guard size <= maximumBytes else { throw ArtifactTransferError.tooLarge }
        }
        if let current, let listedSize, current != listedSize { throw ArtifactTransferError.changed }
        return current ?? listedSize
    }
    public static func fileBytes(_ response: AnyCodable) throws -> Data {
        guard let file = response["file"], file["missing"]?.boolValue != true,
              file["truncated"]?.boolValue != true, response["truncated"]?.boolValue != true,
              file["previewKind"]?.stringValue != "unsupported",
              let content = file["content"]?.stringValue else { throw ArtifactTransferError.unavailable }
        let encoding = file["contentEncoding"]?.stringValue ?? "utf8"
        // Bound before allocating the decoded copy, then validate actual byte count.
        guard content.utf8.count <= ((maximumBytes + 2) / 3) * 4 else { throw ArtifactTransferError.tooLarge }
        guard let bytes = encoding == "base64" ? Data(base64Encoded: content) : (encoding == "utf8" ? Data(content.utf8) : nil)
        else { throw ArtifactTransferError.invalid }
        try validateSize(bytes.count, expected: file["size"]?.intValue)
        return bytes
    }
    public static func validateSize(_ count: Int, expected: Int?) throws {
        guard count >= 0, expected == nil || expected! >= 0 else { throw ArtifactTransferError.invalid }
        guard count <= maximumBytes else { throw ArtifactTransferError.tooLarge }
        if let expected, count != expected { throw ArtifactTransferError.changed }
    }
}

/// Signed URLs carry their own authorization. Never attach the gateway token, cookies,
/// or follow redirects to a second host. Links are not persisted or included in errors.
private final class ArtifactRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum ArtifactDownloader {
    public static func download(url: URL, expectedSize: Int?, configuration: URLSessionConfiguration = .ephemeral,
                                progress: @escaping @Sendable (Int, Int?) async -> Void) async throws -> Data {
        try Task.checkCancellation()
        if let expectedSize, expectedSize > ArtifactTransferPolicy.maximumBytes { throw ArtifactTransferError.tooLarge }
        let config = configuration
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config, delegate: ArtifactRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (stream, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ArtifactTransferError.unavailable }
            let length = response.expectedContentLength >= 0 ? Int(response.expectedContentLength) : nil
            if let length, length > ArtifactTransferPolicy.maximumBytes { throw ArtifactTransferError.tooLarge }
            var data = Data()
            for try await byte in stream {
                data.append(byte)
                guard data.count <= ArtifactTransferPolicy.maximumBytes else { throw ArtifactTransferError.tooLarge }
                if data.count % 65536 == 0 {
                    try Task.checkCancellation()
                    await progress(data.count, expectedSize ?? length)
                }
            }
            try Task.checkCancellation()
            try ArtifactTransferPolicy.validateSize(data.count, expected: expectedSize)
            // URLSession delivers decoded bytes. A compressed Content-Length describes
            // the wire body, not these bytes, and must not be compared with them.
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
            if encoding == nil || encoding == "identity" {
                try ArtifactTransferPolicy.validateSize(data.count, expected: length)
            }
            await progress(data.count, data.count)
            try Task.checkCancellation()
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as ArtifactTransferError { throw error }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ArtifactTransferError.unavailable
        }
    }
}

public struct DeliverableFileCache: Sendable {
    public let root: URL
    public func scoped(to gateway: URL) -> Self {
        Self(root: root.appendingPathComponent(digest(Data(gateway.absoluteString.utf8))))
    }
    private struct Receipt: Codable { let count: Int; let sha256: String }
    private func receiptURL(for url: URL) -> URL {
        root.appendingPathComponent(url.deletingLastPathComponent().lastPathComponent + ".json")
    }
    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    public func url(for item: Deliverable) -> URL {
        let key = SHA256.hash(data: Data(item.reviewID.utf8)).map { String(format: "%02x", $0) }.joined()
        var name = item.artifactID == nil ? (item.target as NSString).lastPathComponent : item.title
        name = ArtifactTransferPolicy.safeFilename(name)
        if (name as NSString).pathExtension.isEmpty,
           let mime = item.mimeType, let ext = UTType(mimeType: mime)?.preferredFilenameExtension { name += "." + ext }
        return root.appendingPathComponent(key).appendingPathComponent(name)
    }
    public func existing(_ item: Deliverable) -> URL? {
        let url = self.url(for: item)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize,
              (try? ArtifactTransferPolicy.validateSize(size, expected: item.sizeBytes)) != nil,
              let receiptData = try? Data(contentsOf: receiptURL(for: url)),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: receiptData), receipt.count == size,
              let bytes = try? Data(contentsOf: url, options: .mappedIfSafe),
              bytes.count == size, digest(bytes) == receipt.sha256 else { return nil }
        return url
    }
    public func save(_ bytes: Data, for item: Deliverable) throws -> URL {
        try ArtifactTransferPolicy.validateSize(bytes.count, expected: item.sizeBytes)
        let url = self.url(for: item)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let receipt = try JSONEncoder().encode(Receipt(count: bytes.count, sha256: digest(bytes)))
        try receipt.write(to: receiptURL(for: url), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL(for: url).path)
        var excluded = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return url
    }
}
