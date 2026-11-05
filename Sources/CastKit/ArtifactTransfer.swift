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
    case invalid, tooLarge, unavailable, changed
    public var errorDescription: String? {
        switch self {
        case .invalid: return "The gateway returned an invalid download. No file was saved."
        case .tooLarge: return "This file exceeds Cast’s 64 MB download limit."
        case .unavailable: return "The file is unavailable or its link expired. Retry to request a fresh link."
        case .changed: return "The downloaded size does not match the artifact. Retry to fetch it again."
        }
    }
}

public enum ArtifactTransferPolicy {
    public static let maximumBytes = 64 * 1024 * 1024
    public static func safeFilename(_ title: String) -> String {
        let name = (title.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            .components(separatedBy: .controlCharacters).joined()
        return name.isEmpty || name == "." || name == ".." ? "download" : String(name.prefix(180))
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
    public static func validateSize(_ count: Int, expected: Int?) throws {
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
            await progress(data.count, data.count)
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as ArtifactTransferError { throw error }
        catch { throw ArtifactTransferError.unavailable }
    }
}

public struct DeliverableFileCache: Sendable {
    public let root: URL
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
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }
    public func save(_ bytes: Data, for item: Deliverable) throws -> URL {
        let url = self.url(for: item)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var excluded = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return url
    }
}
