import Foundation
import XCTest
@testable import Cast

private final class ArtifactTestProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static func reset() { lock.lock(); requests = []; lock.unlock() }
    static func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let path = request.url!.path
        let status = path == "/expired" ? 401 : path == "/redirect" ? 302 : 200
        let body = path == "/large" ? Data(repeating: 65, count: 131072) : Data([0x50,0x4b,0x03,0x04,0,255,1,2])
        let length = path == "/oversized" ? ArtifactTransferPolicy.maximumBytes + 1 : path == "/short-body" ? body.count + 4 : path == "/compressed" ? 4 : body.count
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(length)", "Content-Encoding": path == "/compressed" ? "gzip" : "identity", "Content-Type": "application/zip", "Location": "https://elsewhere.test/file"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ArtifactNetworkTests: XCTestCase {
    private func config() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtifactTestProtocol.self]
        return config
    }
    func testBinaryTransferIsExactAndDoesNotSendGatewayCredentials() async throws {
        ArtifactTestProtocol.reset()
        let data = try await ArtifactDownloader.download(url: URL(string: "https://fixture.test/file")!,
            expectedSize: 8, configuration: config(), progress: { _, _ in })
        XCTAssertEqual(data, Data([0x50,0x4b,0x03,0x04,0,255,1,2]))
        let request = try XCTUnwrap(ArtifactTestProtocol.snapshot().first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }
    func testExpiredRedirectOversizedAndTruncatedDownloadsAreRefused() async {
        for path in ["expired", "redirect", "oversized", "mismatch", "short-body"] {
            do {
                _ = try await ArtifactDownloader.download(url: URL(string: "https://fixture.test/\(path)")!,
                    expectedSize: path == "mismatch" ? 10 : nil, configuration: config(), progress: { _, _ in })
                XCTFail("Accepted \(path)")
            } catch let error as ArtifactTransferError {
                XCTAssertEqual(error, path == "oversized" ? .tooLarge : ["mismatch", "short-body"].contains(path) ? .changed : .unavailable)
            } catch { XCTFail("Unexpected error for \(path): \(error)") }
        }
    }
    func testCancelledTransferCannotReturnAFile() async {
        let config = config()
        let task = Task {
            return try await ArtifactDownloader.download(url: URL(string: "https://fixture.test/large")!,
                expectedSize: 131072, configuration: config, progress: { _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        do { _ = try await task.value; XCTFail("Cancelled transfer succeeded") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation, got \(error)") }
    }

    func testUnicodeDownloadNameFitsFilesystemAndPreservesExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var item = Deliverable(id: "unicode", sessionKey: "a", messageID: "m", title: String(repeating: "🦊", count: 100) + ".pdf", target: "artifact:a", kind: "Attachment", sharedAt: nil)
        item.artifactID = "a"
        let cache = DeliverableFileCache(root: root)
        let url = try cache.save(Data([1, 2, 3]), for: item)
        XCTAssertLessThanOrEqual(url.lastPathComponent.utf8.count, 240)
        XCTAssertEqual(url.pathExtension, "pdf")
        XCTAssertNotNil(cache.existing(item))
    }

    func testCacheRejectsTruncatedAndSameSizeCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var item = Deliverable(id: "a", sessionKey: "a", messageID: "m", title: "file.bin", target: "artifact:a", kind: "Attachment", sharedAt: nil)
        item.artifactID = "a"; item.sizeBytes = 4
        let cache = DeliverableFileCache(root: root)
        let url = try cache.save(Data([1, 2, 3, 4]), for: item)
        XCTAssertNotNil(cache.existing(item))
        try Data([1]).write(to: url)
        XCTAssertNil(cache.existing(item))
        try Data([4, 3, 2, 1]).write(to: url)
        XCTAssertNil(cache.existing(item))
        XCTAssertThrowsError(try cache.save(Data([1]), for: item))
    }

    func testOutgoingFrameIncludesJSONEscaping() {
        // The raw string fits; its serialized wire representation does not.
        let message = String(repeating: "\"", count: AttachmentProcessor.maxFrameBytes / 2 + 1)
        XCTAssertThrowsError(try AttachmentProcessor.validateFrame(message: message, attachments: []))
    }

    func testArtifactResponseSizeAndLegacyCompleteness() throws {
        func json(_ raw: String) throws -> AnyCodable { try JSONDecoder().decode(AnyCodable.self, from: Data(raw.utf8)) }
        let response = try json(#"{"artifact":{"sizeBytes":4}}"#)
        XCTAssertEqual(try ArtifactTransferPolicy.downloadSize(response, listedSize: nil), 4)
        XCTAssertThrowsError(try ArtifactTransferPolicy.downloadSize(response, listedSize: 3))
        XCTAssertThrowsError(try ArtifactTransferPolicy.downloadSize(json(#"{"artifact":{"sizeBytes":-1}}"#), listedSize: nil))
        XCTAssertEqual(try ArtifactTransferPolicy.fileBytes(json(#"{"file":{"content":"AAH/","contentEncoding":"base64","size":3}}"#)), Data([0, 1, 255]))
        XCTAssertEqual(try ArtifactTransferPolicy.fileBytes(json(#"{"file":{"content":"🦊","contentEncoding":"utf8","size":4}}"#)), Data("🦊".utf8))
        for raw in [#"{"file":{"content":"abc","truncated":true}}"#, #"{"file":{"content":"abc","size":4}}"#,
                    #"{"file":{"content":"abc","missing":true}}"#, #"{"file":{"content":"!","contentEncoding":"base64"}}"#] {
            XCTAssertThrowsError(try ArtifactTransferPolicy.fileBytes(json(raw)))
        }
    }

    func testCacheIsScopedToGatewayAndRejectsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = Deliverable(id: "same", sessionKey: "same", messageID: "same", title: "file", target: "artifact:same", kind: "Attachment", sharedAt: nil)
        let a = DeliverableFileCache(root: root).scoped(to: URL(string: "wss://a.test")!)
        let b = DeliverableFileCache(root: root).scoped(to: URL(string: "wss://b.test")!)
        let url = try a.save(Data([1]), for: item)
        XCTAssertNotNil(a.existing(item)); XCTAssertNil(b.existing(item))
        let target = root.appendingPathComponent("target")
        try Data([1]).write(to: target)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertNil(a.existing(item))
    }

    func testOutgoingFrameAccountsForBase64SlashesAndStillAcceptsNormalFile() throws {
        let small = PreparedAttachment(type: "file", mimeType: "application/octet-stream", fileName: "file.bin", data: Data([0, 255]))
        XCTAssertNoThrow(try AttachmentProcessor.validateFrame(message: "A file", attachments: [small]))
        let large = PreparedAttachment(type: "file", mimeType: "application/octet-stream", fileName: "file.bin", data: Data(repeating: 255, count: 10 * 1024 * 1024))
        // Base64 slash escaping is deliberately disabled on the actual wire encoder.
        XCTAssertNoThrow(try AttachmentProcessor.validateFrame(message: "", attachments: [large]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let message = "quote\" slash/ backslash\\ control\u{0001}\n🦊\u{2028}"
        let payload = AnyCodable(["message": message, "attachments": [try small.rpcValue]] as [String: Any?])
        XCTAssertEqual(try AttachmentProcessor.frameByteCount(message: message, attachments: [small]), try encoder.encode(payload).count)
    }

    func testDecodedCompressedBodyDoesNotUseWireLength() async throws {
        let bytes = try await ArtifactDownloader.download(url: URL(string: "https://fixture.test/compressed")!, expectedSize: 8, configuration: config(), progress: { _, _ in })
        XCTAssertEqual(bytes.count, 8)
    }

    func testLoadedAttachmentStateSurvivesReappearanceButNotRevision() {
        let attachment = ManagedChatAttachment(artifactId: "a", label: "file", mimeType: nil, sizeBytes: 8)
        let id = ManagedAttachmentLoadState.ID(attachment: attachment, attempt: 0)
        var state = ManagedAttachmentLoadState()
        state.begin(id)
        let url = URL(fileURLWithPath: "/tmp/file")
        state.localURL = url
        state.begin(id) // A lazy row reappearing with the same task identity.
        XCTAssertEqual(state.localURL, url)
        state.begin(.init(attachment: attachment, attempt: 1))
        XCTAssertNil(state.localURL)
    }

    @MainActor
    func testLocalhostFileOverTransferLimitStillOpensWithoutDownloading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.zip")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ArtifactTransferPolicy.maximumBytes + 1))
        try handle.close()
        let profile = WorkspaceProfile(id: "local", name: "Local", gatewayURL: URL(string: "ws://localhost:18789")!, accent: "blue")
        let store = ChatStore(profile: profile, transcriptCacheRoot: root.appendingPathComponent("transcripts"), operationsLedgerRoot: root.appendingPathComponent("operations"))
        let item = Deliverable(id: "large", sessionKey: "a", messageID: "m", title: "large.zip", target: file.path, kind: "Package", sharedAt: nil)
        let actual = await store.localDeliverableURL(item)
        XCTAssertEqual(actual, file)
    }
}
