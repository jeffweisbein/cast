import Foundation
import XCTest
@testable import Cast

final class TranscriptCacheWriteTests: XCTestCase {
    private let sessionKey = "agent:main:cache-write-regression"
    private let sentinel = Date(timeIntervalSince1970: 1_000_000)

    private func message(_ index: Int, bytes: Data = Data([1, 2, 3])) -> ChatMessage {
        ChatMessage(id: "image-\(index)", role: "user", blocks: [
            ChatContentBlock(type: "text", text: "Synthetic image \(index)",
                thinking: nil, name: nil, mimeType: nil, fileName: nil)
        ], timestamp: Double(index), localImageData: [bytes])
    }

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CastCacheWrites-\(UUID())")
    }

    private func files(_ root: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private func markUnchanged(_ files: [URL]) throws {
        for file in files {
            try FileManager.default.setAttributes([.modificationDate: self.sentinel], ofItemAtPath: file.path)
        }
    }

    private func assertUnchanged(_ files: [URL], file: StaticString = #filePath, line: UInt = #line) throws {
        for url in files {
            let date = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            XCTAssertEqual(date, self.sentinel, url.lastPathComponent, file: file, line: line)
        }
    }

    func testRepeatedSnapshotsDoNotRewriteJSONMetadataOrMediaAcrossCacheRestart() async throws {
        let root = self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(workspaceID: "test", root: root)
        let messages = [self.message(1), self.message(2)]
        await cache.save(messages, sessionKey: self.sessionKey)
        let files = self.files(root)
        XCTAssertEqual(files.count, 4)
        try self.markUnchanged(files)
        for _ in 0 ..< 3 { await cache.save(messages, sessionKey: self.sessionKey) }
        let restarted = TranscriptCache(workspaceID: "test", root: root)
        await restarted.save(messages, sessionKey: self.sessionKey)
        try self.assertUnchanged(files)
        let loaded = await restarted.load(sessionKey: self.sessionKey)
        XCTAssertEqual(loaded, messages)
    }

    func testImageChangeRewritesOnlyChangedImageEvenWhenJSONIsUnchanged() async throws {
        let root = self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(workspaceID: "test", root: root)
        var messages = [self.message(1), self.message(2)]
        await cache.save(messages, sessionKey: self.sessionKey)
        let files = self.files(root)
        try self.markUnchanged(files)
        messages[0].localImageData = [Data([3, 2, 1])]
        await cache.save(messages, sessionKey: self.sessionKey)
        let loaded = await cache.load(sessionKey: self.sessionKey)
        XCTAssertEqual(loaded, messages)
        let changed = try files.filter {
            (try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) != self.sentinel
        }
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?.pathExtension, "bin")
    }

    func testDeliveryAndCompletenessChangesRemainDurableWithoutRewritingImages() async throws {
        let root = self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(workspaceID: "test", root: root)
        var messages = [self.message(1)]
        await cache.save(messages, sessionKey: self.sessionKey, historyIsComplete: false)
        let media = self.files(root).filter { $0.pathExtension == "bin" }
        try self.markUnchanged(media)
        messages[0].localDeliveryState = .failed
        await cache.save(messages, sessionKey: self.sessionKey, historyIsComplete: true)
        let snapshot = await cache.loadSnapshot(sessionKey: self.sessionKey)
        XCTAssertEqual(snapshot.messages, messages)
        XCTAssertTrue(snapshot.isComplete)
        try self.assertUnchanged(media)
        messages.append(self.message(2))
        await cache.save(messages, sessionKey: self.sessionKey)
        let appended = await cache.load(sessionKey: self.sessionKey)
        XCTAssertEqual(appended, messages)
    }

    func testMissingFilesAreRepairedAndOnlyCompleteSnapshotsPruneMedia() async throws {
        let root = self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(workspaceID: "test", root: root)
        let messages = [self.message(1), self.message(2)]
        await cache.save(messages, sessionKey: self.sessionKey)
        for file in self.files(root) where file.pathExtension != "meta" {
            try FileManager.default.removeItem(at: file)
        }
        await cache.save(messages, sessionKey: self.sessionKey)
        let repaired = await cache.load(sessionKey: self.sessionKey)
        XCTAssertEqual(repaired, messages)
        await cache.save([messages[1]], sessionKey: self.sessionKey, historyIsComplete: false)
        XCTAssertEqual(self.files(root).filter { $0.pathExtension == "bin" }.count, 2)
        await cache.save([messages[1]], sessionKey: self.sessionKey, historyIsComplete: true)
        XCTAssertEqual(self.files(root).filter { $0.pathExtension == "bin" }.count, 1)
    }

    func testSyntheticRepeatedMediaHistorySaveWritesNoUnchangedFiles() async throws {
        let root = self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(workspaceID: "test", root: root)
        let image = Data(repeating: 0x5A, count: 256 * 1_024)
        let messages = (0 ..< 8).map { self.message($0, bytes: image) }
        await cache.save(messages, sessionKey: self.sessionKey)
        let files = self.files(root)
        try self.markUnchanged(files)
        let start = Date()
        for _ in 0 ..< 100 { await cache.save(messages, sessionKey: self.sessionKey) }
        try self.assertUnchanged(files)
        let snapshot = await cache.loadSnapshot(sessionKey: self.sessionKey)
        XCTAssertEqual(snapshot.messages, messages)
        let replacements = try files.filter {
            (try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) != self.sentinel
        }.count
        print("CACHE_WRITE_STRESS repeats=100 media_bytes_per_snapshot=2097152 replaced_file_count=\(replacements) elapsed_seconds=\(Date().timeIntervalSince(start))")
    }
}
