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

/// Exercises real selection and cache hydration without a live gateway or user data.
@MainActor
final class ChatSwitchPerformanceTests: XCTestCase {
    private let a = "agent:main:switch-a"
    private let b = "agent:main:switch-b"

    private func fixture() async -> (ChatStore, TranscriptCache) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CastSwitch-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(workspaceID: "switch-tests", root: root)
        let rows = (0..<1_000).map { index in
            ChatMessage(id: "row-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                blocks: [ChatContentBlock(type: "text", text: "Synthetic transcript row \(index)",
                    thinking: nil, name: nil, mimeType: nil, fileName: nil)], timestamp: Double(index * 1_000))
        }
        await cache.save(rows, sessionKey: a)
        await cache.save(Array(rows.suffix(20)), sessionKey: b)
        let store = ChatStore(profile: .init(id: "switch-tests", name: "Test",
            gatewayURL: URL(string: "wss://example.invalid")!, accent: "blue"),
            transcriptCacheRoot: root, operationsLedgerRoot: root.appendingPathComponent("operations"))
        return (store, cache)
    }

    private func settle(_ store: ChatStore) async throws {
        for _ in 0..<500 {
            if store.historySyncState == .idle { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Offline session open did not settle")
    }

    func testWarmSwitchReusesPreparedRowsWithoutDiskRepublish() async throws {
        let (store, _) = await fixture()
        store.selectedSessionKey = a
        try await settle(store)
        let expected = store.transcriptItems(showAgentWork: true)
        XCTAssertEqual(store.messages.count, 1_000)
        store.selectedSessionKey = b
        try await settle(store)
        _ = store.transcriptItems(showAgentWork: true)
        let start = ContinuousClock.now
        store.selectedSessionKey = a
        let revision = store.transcriptRevision
        // The ready-to-render snapshot must survive selection, before any async work runs.
        XCTAssertEqual(store.transcriptBuilderConsumedMessageCount, 1_000)
        XCTAssertEqual(store.transcriptItems(showAgentWork: true), expected)
        try await settle(store)
        XCTAssertEqual(store.transcriptRevision, revision, "Warm text-only opens must not republish disk history")
        print("CHAT_SWITCH warm_1000_rows_elapsed=\(start.duration(to: .now)) extra_publications=\(store.transcriptRevision - revision)")
    }

    func testRapidSwitchNeverAppliesOtherChatsDiskHistory() async throws {
        let (store, _) = await fixture()
        store.selectedSessionKey = a
        store.selectedSessionKey = b
        store.selectedSessionKey = a
        try await settle(store)
        XCTAssertEqual(store.selectedSessionKey, a)
        XCTAssertEqual(store.messages.count, 1_000)
    }

    func testWarmImageTranscriptStillRehydratesLocalMedia() async throws {
        let (store, cache) = await fixture()
        let image = ChatMessage(id: "photo", role: "user", blocks: [], timestamp: 1,
            localImageData: [Data([1, 2, 3])])
        await cache.save([image], sessionKey: a)
        store.selectedSessionKey = a
        try await settle(store)
        XCTAssertEqual(store.messages.first?.localImageData, image.localImageData)
        _ = store.transcriptItems(showAgentWork: true)
        store.selectedSessionKey = b
        try await settle(store)
        store.selectedSessionKey = a
        XCTAssertEqual(store.messages.first?.localImageData, [])
        try await settle(store)
        XCTAssertEqual(store.messages.first?.localImageData, image.localImageData)
    }
    func testWarmSwitchRespectsDisplayModeAndInvalidatedRows() async throws {
        let (store, _) = await fixture()
        store.selectedSessionKey = a
        try await settle(store)
        let hidden = store.transcriptItems(showAgentWork: false)
        store.selectedSessionKey = b
        try await settle(store)
        store.selectedSessionKey = a
        XCTAssertEqual(store.transcriptItems(showAgentWork: false), hidden)
        XCTAssertNil(store.transcriptBuilderConsumedMessageCount)
        let expanded = store.transcriptItems(showAgentWork: true)
        XCTAssertFalse(expanded.isEmpty)
        XCTAssertEqual(store.transcriptBuilderConsumedMessageCount, 1_000)
        try await settle(store)
        var edited = store.messages
        edited[0] = ChatMessage(id: "edited", role: "user", blocks: [
            ChatContentBlock(type: "text", text: "Updated after preparing the display",
                thinking: nil, name: nil, mimeType: nil, fileName: nil)], timestamp: 0)
        store.installOfflineDiagnosticTranscript(edited)
        store.selectedSessionKey = b
        try await settle(store)
        store.selectedSessionKey = a
        XCTAssertNil(store.transcriptBuilderConsumedMessageCount, "Never reuse stale prepared rows")
        XCTAssertEqual(store.messages.first?.id, "edited")
        XCTAssertNotEqual(store.transcriptItems(showAgentWork: true), expanded)
        try await settle(store)
        XCTAssertEqual(store.messages.first?.id, "edited", "Disk must not overwrite newer memory")
    }

    func testSnapshotEvictionDropsRenderStateAndPreservesPendingMediaHydration() {
        var snapshots = TranscriptSnapshotStore(capacity: 2)
        let photo = ChatMessage(id: "photo", role: "user", blocks: [], timestamp: 1,
            localImageData: [Data([1, 2, 3])])
        let render = TranscriptRenderSnapshot(items: TranscriptBuilder.items(from: [photo], showAgentWork: true),
            showsAgentWork: true, builder: nil)
        snapshots.store([photo], for: a, render: render)
        XCTAssertNil(snapshots.renderSnapshot(for: a), "Do not retain image bytes via display groups")
        XCTAssertTrue(snapshots.needsMediaHydration(for: a))
        let stripped = snapshots.snapshot(for: a)!
        snapshots.store(stripped, for: a)
        XCTAssertTrue(snapshots.needsMediaHydration(for: a), "Rapid switches must not forget stripped images")
        snapshots.store([], for: b, render: .init(items: [], showsAgentWork: false, builder: nil))
        snapshots.store([], for: "third")
        XCTAssertNil(snapshots.snapshot(for: a))
        XCTAssertFalse(snapshots.needsMediaHydration(for: a))
        snapshots.store([], for: "fourth")
        XCTAssertNil(snapshots.renderSnapshot(for: b))
    }

}
