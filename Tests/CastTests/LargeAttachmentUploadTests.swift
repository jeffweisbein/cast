import CryptoKit
import Foundation
import XCTest
@testable import Cast

final class LargeAttachmentUploadTests: XCTestCase {
    func testNativeWireTranscriptForReceiverReplay() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cast-native-upload-replay", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let movie = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/video-upload.mp4")
        var original = try Data(contentsOf: movie); original.append(Data(count: 27_000_000 - original.count))
        let source = dir.appendingPathComponent("synthetic.mp4"); try original.write(to: source)
        let attachment = try await AttachmentProcessor.prepareForSending(url: source)
        defer { attachment.removeOwnedFile(); try? FileManager.default.removeItem(at: source) }
        let batch = UUID().uuidString, fixture = UploadFixture(), trace = WireTrace(url: dir.appendingPathComponent("native-rpc.jsonl"))
        let refs = try await LargeAttachmentUpload.upload(sessionKey: "agent:main:upload-rpc", sessionID: "upload-incarnation", batchID: batch, attachments: [attachment], request: { method, params in
            try await trace.record(method: method, params: params)
            return try await fixture.request(method, params)
        }, progress: { _ in })
        try await trace.record(method: "chat.send", params: ["sessionKey":"agent:main:upload-rpc", "sessionId":"upload-incarnation", "idempotencyKey":batch, "message":"Synthetic receiver verification", "deliver":false, "attachments":refs])
        let manifest = ["sha256": attachment.sha256!, "sizeBytes": String(attachment.byteCount), "batchId":batch, "fileId":attachment.id.uuidString]
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("expected.json"), options: .atomic)
        print("NATIVE_UPLOAD_TRANSCRIPT=\(dir.path)")
    }

    func testLegacyOutboxDecodeAndSmallFileInlineFallback() async throws {
        let old = "{\"text\":\"hello\",\"attachments\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"type\":\"file\",\"mimeType\":\"text/plain\",\"fileName\":\"old.txt\",\"data\":\"aGk=\"}],\"deliver\":false}"
        let context = try JSONDecoder().decode(PendingSendContext.self, from: Data(old.utf8))
        XCTAssertNil(context.sessionID)
        XCTAssertEqual(context.attachments[0].data, Data("hi".utf8))
        let files = try AttachmentFiles.diskBacked([PreparedAttachment(type: "file", mimeType: "video/mp4", fileName: "clip.mp4", data: Data(repeating: 7, count: 2_000_000))])
        defer { files.forEach { $0.removeOwnedFile() } }
        XCTAssertFalse(try AttachmentProcessor.requiresUpload(message: "", attachments: files))
        XCTAssertEqual(Data(base64Encoded: try files[0].rpcValue["content"] as! String)?.count, 2_000_000)
        files[0].removeOwnedFile()
        XCTAssertThrowsError(try files[0].rpcValue)
    }

    func testLargeBatchOutboxDoesNotEmbedBase64Sources() async throws {
        let files = try AttachmentFiles.diskBacked((0..<20).map { PreparedAttachment(type: "file", mimeType: "application/octet-stream", fileName: "part\($0).bin", data: Data(count: 2_000_000)) })
        defer { files.forEach { $0.removeOwnedFile() } }
        XCTAssertTrue(try AttachmentProcessor.requiresUpload(message: "", attachments: files))
        let context = PendingSendContext(text: "original batch", attachments: files, deliver: false, sessionID: "incarnation")
        XCTAssertLessThan(try JSONEncoder().encode(context).count, 20_000)
        XCTAssertEqual(files.map(\.byteCount).reduce(0,+), 40_000_000)
    }

    func testDiskBudgetAndOrphanCleanupProtectOutstandingOutbox() throws {
        let root = AttachmentFiles.root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let orphan = root.appendingPathComponent(UUID().uuidString)
        let retained = root.appendingPathComponent(UUID().uuidString)
        let quota = root.appendingPathComponent(UUID().uuidString)
        let outbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            for file in [orphan, retained, quota, outbox, source, retained.appendingPathExtension("lease")] { try? FileManager.default.removeItem(at: file) }
        }
        try Data("unreferenced".utf8).write(to: orphan)
        try Data("pending retry".utf8).write(to: retained)
        try Data("outbox".utf8).write(to: outbox)
        try JSONSerialization.data(withJSONObject: ["outboxPath": outbox.path]).write(to: retained.appendingPathExtension("lease"))
        for file in [orphan, retained] { try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-172800)], ofItemAtPath:file.path) }
        try Data("new".utf8).write(to: source)
        let copy = try AttachmentFiles.copy(url: source, name: "new.bin", mimeType: "application/octet-stream")
        defer { copy.removeOwnedFile() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        // Sparse logical size replays admission without consuming 4 GB of physical disk.
        FileManager.default.createFile(atPath: quota.path, contents: Data())
        let handle = try FileHandle(forWritingTo: quota); try handle.truncate(atOffset: UInt64(AttachmentFiles.maxStoredBytes)); try handle.close()
        XCTAssertThrowsError(try AttachmentFiles.copy(url: source, name: "over-budget.bin", mimeType: "application/octet-stream"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testStaleWorkspaceImportIsDeletedAndCannotAttachElsewhere() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(transcriptCacheRoot: root, operationsLedgerRoot: root)
        store.selectedSessionKey = "original"
        let file = try AttachmentFiles.diskBacked([PreparedAttachment(type: "file", mimeType: "video/mp4", fileName: "clip.mp4", data: Data(count: 100))])[0]
        defer { file.removeOwnedFile() }
        let target = ChatStore.AttachmentDraftTarget(workspaceID: "other-workspace", gatewayURL: store.attachmentDraftTarget.gatewayURL, sessionKey: "original")
        store.finishAttachmentPreparation(.success(file), target: target)
        XCTAssertTrue(store.pendingAttachments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(file.fileURL).path))
    }

    func testPersistedUnresolvedSendCanBindIncarnationOnlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = SendOutbox(root: root)
        let context = PendingSendContext(text: "original", attachments: [], deliver: true)
        let send = StoredSend(sessionKey: "destination", idempotencyKey: "same-key", context: context, createdAt: Date())
        try await outbox.save(send)
        let bound = try await outbox.bindSessionID("first", key: "same-key", sessionKey: "destination")
        XCTAssertEqual(bound.context.sessionID, "first")
        XCTAssertEqual(bound.context.text, context.text)
        XCTAssertEqual(bound.createdAt, send.createdAt)
        _ = try await outbox.bindSessionID("first", key: "same-key", sessionKey: "destination")
        do { _ = try await outbox.bindSessionID("replaced", key: "same-key", sessionKey: "destination"); XCTFail("retargeted upload") } catch { }
        do { _ = try await outbox.bindSessionID("first", key: "same-key", sessionKey: "another"); XCTFail("retargeted destination") } catch { }
    }

    func testExactCountFileAndBatchBoundaries() throws {
        XCTAssertNoThrow(try AttachmentLimits.validate(sizes: Array(repeating: 100_000_000, count: 20)))
        XCTAssertNoThrow(try AttachmentLimits.validate(sizes: [500_000_000]))
        XCTAssertThrowsError(try AttachmentLimits.validate(sizes: Array(repeating: 1, count: 21)))
        XCTAssertThrowsError(try AttachmentLimits.validate(sizes: [500_000_001]))
        XCTAssertThrowsError(try AttachmentLimits.validate(sizes: [500_000_000,500_000_000,500_000_000,500_000_000,1]))
    }

    func testTwentyFileBatchLargerThanFrameUsesBoundedChunksAndOnlyReferences() async throws {
        let files = (0..<20).map { PreparedAttachment(type: "file", mimeType: "video/mp4", fileName: "clip\($0).mp4", data: Data(repeating: UInt8($0), count: 1_048_577)) }
        XCTAssertGreaterThan(try AttachmentProcessor.frameByteCount(message: "", attachments: files), AttachmentProcessor.maxFrameBytes)
        XCTAssertTrue(try AttachmentProcessor.requiresUpload(message: "", attachments: files))
        XCTAssertNoThrow(try AttachmentProcessor.validateFrame(message: "", attachments: files))
        let server = UploadFixture()
        let refs = try await LargeAttachmentUpload.upload(sessionKey: "agent:main:test", sessionID: "incarnation", batchID: UUID().uuidString, attachments: files, request: { try await server.request($0, $1) }, progress: { _ in })
        XCTAssertEqual(refs.count, 20)
        XCTAssertTrue(refs.allSatisfy { $0["upload"] != nil && $0["content"] == nil })
        let values = await server.stats()
        XCTAssertEqual(values.bytes, files.reduce(0) { $0 + $1.byteCount })
        XCTAssertEqual(values.largestChunk, 1_048_576)
        XCTAssertEqual(values.verifiedFiles, 20)
        XCTAssertTrue(values.bindingPreserved)
    }

    func testRetryResumesVerifiedOffsetRatherThanResendingPrefix() async throws {
        let attachment = PreparedAttachment(type: "file", mimeType: "application/octet-stream", fileName: "large.bin", data: Data(repeating: 12, count: 3_000_000))
        let server = UploadFixture(failOnce: true), batch = UUID().uuidString
        do {
            _ = try await LargeAttachmentUpload.upload(sessionKey: "key", sessionID: "original", batchID: batch, attachments: [attachment], request: { try await server.request($0, $1) }, progress: { _ in })
            XCTFail("expected interrupted upload")
        } catch { }
        _ = try await LargeAttachmentUpload.upload(sessionKey: "key", sessionID: "original", batchID: batch, attachments: [attachment], request: { try await server.request($0, $1) }, progress: { _ in })
        let stats = await server.stats()
        XCTAssertEqual(stats.bytes, attachment.byteCount)
        XCTAssertEqual(stats.verifiedFiles, 1)
    }

    func testCancellationCancelsOnlyBoundOriginAndDoesNotReturnSendReferences() async throws {
        let attachment = PreparedAttachment(type: "file", mimeType: "video/mp4", fileName: "clip.mp4", data: Data(count: 2_000_000))
        let server = UploadFixture(cancelAfterChunk: true)
        let task = Task {
            try await LargeAttachmentUpload.upload(sessionKey: "original-key", sessionID: "original-id", batchID: UUID().uuidString, attachments: [attachment], request: { try await server.request($0, $1) }, progress: { _ in })
        }
        do { _ = try await task.value; XCTFail("cancelled upload returned references") }
        catch is CancellationError { }
        let cancelled = await server.cancelled
        XCTAssertTrue(cancelled)
    }

    func testFileBackedOutboxIsSmallRetainsRetryBytesAndDeletesAfterAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("large.bin")
        try Data(count: 17_000_000).write(to: source)
        let attachment = try AttachmentProcessor.prepare(url: source)
        defer { attachment.removeOwnedFile() }
        let context = PendingSendContext(text: "original", attachments: [attachment], deliver: false, sessionID: "first-incarnation")
        let encoded = try JSONEncoder().encode(context)
        XCTAssertLessThan(encoded.count, 2000)
        let restored = try JSONDecoder().decode(PendingSendContext.self, from: encoded)
        XCTAssertEqual(restored, context)
        let outbox = SendOutbox(root: directory.appendingPathComponent("outbox")), key = UUID().uuidString
        try await outbox.save(StoredSend(sessionKey: "original-session", idempotencyKey: key, context: context, createdAt: Date()))
        let loaded = try await outbox.load(key, sessionKey: "original-session")
        XCTAssertEqual(loaded.context, context)
        do { _ = try await outbox.load(key, sessionKey: "another-session"); XCTFail("cross-session retry accepted") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(attachment.fileURL).path))
        await outbox.acknowledge([key], sessionKey: "original-session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(attachment.fileURL).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}

private actor UploadFixture {
    struct Entry { let hash: String; let size: Int; var data = Data() }
    var entries: [String: Entry] = [:]
    var binding: [String: String] = [:]
    var largest = 0, received = 0
    var failOnce: Bool, cancelAfterChunk: Bool
    var cancelled = false
    init(failOnce: Bool = false, cancelAfterChunk: Bool = false) { self.failOnce = failOnce; self.cancelAfterChunk = cancelAfterChunk }
    func request(_ method: String, _ params: [String: Any?]) throws -> Data {
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        if method == "chat.upload.policy" {
            return try json(["version":1,"enabled":true,"maxFiles":20,"maxFileBytes":500_000_000,"maxBatchBytes":2_000_000_000,"chunkBytes":1_048_576])
        }
        let newBinding = ["sessionKey", "sessionId", "batchId"].reduce(into: [String: String]()) { $0[$1] = params[$1] as? String }
        if binding.isEmpty { binding = newBinding }
        guard binding == newBinding else { throw AttachmentError.invalidUpload }
        if method == "chat.upload.begin" {
            for file in params["files"] as! [[String: Any?]] {
                let id = file["id"] as! String
                if entries[id] == nil { entries[id] = Entry(hash: file["sha256"] as! String, size: file["sizeBytes"] as! Int) }
            }
            return try json(["batchId": binding["batchId"]!, "chunkBytes":1_048_576,"files":entries.map { ["id":$0.key,"offset":$0.value.data.count,"complete":$0.value.data.count == $0.value.size] }])
        }
        if method == "chat.upload.cancel" { cancelled = true; return try json(["cancelled":true]) }
        let id = params["fileId"] as! String, offset = params["offset"] as! Int
        if failOnce, received > 0 { failOnce = false; throw AttachmentError.invalidUpload }
        var entry = entries[id]!
        guard offset == entry.data.count, let chunk = Data(base64Encoded: params["content"] as! String) else { throw AttachmentError.invalidUpload }
        largest = max(largest, chunk.count); received += chunk.count; entry.data.append(chunk); entries[id] = entry
        if cancelAfterChunk { throw CancellationError() }
        if entry.data.count == entry.size {
            guard SHA256.hash(data: entry.data).map({ String(format:"%02x",$0) }).joined() == entry.hash else { throw AttachmentError.invalidUpload }
        }
        return try json(["fileId":id,"offset":entry.data.count,"complete":entry.data.count == entry.size])
    }
    func stats() -> (bytes: Int, largestChunk: Int, verifiedFiles: Int, bindingPreserved: Bool) {
        (received, largest, entries.values.filter { $0.data.count == $0.size }.count, binding.count == 3)
    }
}

private actor WireTrace {
    let url: URL
    init(url: URL) { self.url = url; try? Data().write(to: url) }
    func record(method: String, params: [String: Any?]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        var encoded = try encoder.encode(AnyCodable(["method":method,"params":params] as [String: Any?]))
        encoded.append(10)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: encoded)
    }
}
