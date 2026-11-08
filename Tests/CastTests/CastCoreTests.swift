import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Cast

/// `withObservationTracking`'s `onChange` is `@Sendable`, so the flag it sets has to be a
/// reference. Everything here runs on the main actor; the box exists for the type checker.
private final class ObservationFlag: @unchecked Sendable {
    private(set) var changed = false
    func mark() { self.changed = true }
}

final class LongHistoryPerformanceTests: XCTestCase {
    private static func message(_ index: Int) -> ChatMessage {
        // 1,999 role groups plus TranscriptBuilder's one day separator yields the same
        // 2,000-item retained render window used by the production transcript.
        let roleGroup = index < 10 ? 0 : 1 + ((index - 10) / 5)
        return ChatMessage(
            id: "message-\(index)",
            role: roleGroup.isMultiple(of: 2) ? "user" : "assistant",
            blocks: [ChatContentBlock(
                type: "text",
                text: "Synthetic transcript row \(index) with enough content to exercise reconciliation.",
                thinking: nil,
                name: nil,
                mimeType: nil,
                fileName: nil)],
            timestamp: Double(index))
    }

    func testBackfillAccumulatorCrossesKnownTailAndRestoresChronologicalOrder() {
        let messages = (0 ..< 1_000).map(Self.message)
        var accumulator = HistoryBackfillAccumulator(current: Array(messages.suffix(400)))

        // A bounded cache already knows the newest pages. They must not stop the walk: the
        // first unseen page is older than the retained tail.
        XCTAssertEqual(accumulator.ingest(Array(messages[800 ..< 1_000])), 0)
        XCTAssertEqual(accumulator.ingest(Array(messages[600 ..< 800])), 0)
        XCTAssertEqual(accumulator.ingest(Array(messages[400 ..< 600])), 200)
        XCTAssertEqual(accumulator.ingest(Array(messages[200 ..< 400])), 200)
        XCTAssertEqual(accumulator.ingest(Array(messages[0 ..< 200])), 200)
        XCTAssertEqual(
            accumulator.olderMessagesInChronologicalOrder.map(\.id),
            messages.prefix(600).map(\.id))
    }

    func testIndexedReconcileMatchesPhaseTwoSemantics() {
        let original = ChatMessage(
            id: "same-id",
            role: "assistant",
            blocks: [ChatContentBlock(
                type: "text", text: "old text", thinking: nil, name: nil,
                mimeType: nil, fileName: nil)],
            timestamp: 10)
        let legacyID = ChatMessage(
            id: "legacy-uuid",
            role: "assistant",
            blocks: [ChatContentBlock(
                type: "text", text: "legacy content", thinking: nil, name: nil,
                mimeType: nil, fileName: nil)],
            timestamp: 20)
        let updated = ChatMessage(
            id: "same-id",
            role: "assistant",
            blocks: [ChatContentBlock(
                type: "text", text: "new text", thinking: nil, name: nil,
                mimeType: nil, fileName: nil)],
            timestamp: 10)
        let oldContentAgain = ChatMessage(
            id: "new-row",
            role: "assistant",
            blocks: original.blocks,
            timestamp: 10)
        let contentAddressedLegacy = legacyID.withID("gateway-derived-id")
        var phaseTwoPending: [PendingEcho] = []
        var indexedPending: [PendingEcho] = []

        let phaseTwo = Self.legacyReconciledHistory(
            [updated, oldContentAgain, contentAddressedLegacy],
            current: [original, legacyID],
            pendingEchoes: &phaseTwoPending,
            position: .latest)
        let indexed = ChatStore.reconciledHistory(
            [updated, oldContentAgain, contentAddressedLegacy],
            current: [original, legacyID],
            pendingEchoes: &indexedPending,
            position: .latest)

        XCTAssertEqual(indexed.map(\.id), phaseTwo.map(\.id))
        XCTAssertEqual(indexed.map(\.text), phaseTwo.map(\.text))
        XCTAssertEqual(indexed.map(\.timestamp), phaseTwo.map(\.timestamp))
    }

    func testTranscriptCachePersistsOnlyTwoThousandNewestMessages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastBoundedCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(workspaceID: "test", root: root)
        let messages = (0 ..< 2_050).map(Self.message)

        await cache.save(messages, sessionKey: "agent:main:long", historyIsComplete: true)
        let snapshot = await cache.loadSnapshot(sessionKey: "agent:main:long")

        XCTAssertEqual(snapshot.messages.count, TranscriptCache.maximumPersistedMessages)
        XCTAssertEqual(snapshot.messages.first?.id, "message-50")
        XCTAssertEqual(snapshot.messages.last?.id, "message-2049")
        XCTAssertEqual(snapshot.totalMessageCount, 2_050)
        XCTAssertFalse(snapshot.isComplete)
    }

    func testBoundedCacheRetainsOlderLocalMediaForOnlineBackfill() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastBoundedMedia-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(workspaceID: "test", root: root)
        var messages = (0 ..< 2_001).map(Self.message)
        let media = Data([0xCA, 0x57])
        messages[0].localImageData = [media]

        await cache.save(messages, sessionKey: "agent:main:media", historyIsComplete: true)
        // A later first-page save knows nothing about the old row but must not garbage-
        // collect its deterministic media side file while history is still partial.
        await cache.save(
            Array(messages.suffix(200)),
            sessionKey: "agent:main:media",
            historyIsComplete: false)
        let rehydrated = await cache.rehydrateLocalMedia(
            in: [Self.message(0)],
            sessionKey: "agent:main:media")

        XCTAssertEqual(rehydrated.first?.localImageData, [media])
    }

    func testSmallCompleteTranscriptCacheRetainsCompletenessMetadata() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastCompleteCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(workspaceID: "test", root: root)
        let messages = (0 ..< 20).map(Self.message)

        await cache.save(messages, sessionKey: "agent:main:small", historyIsComplete: true)
        let snapshot = await cache.loadSnapshot(sessionKey: "agent:main:small")

        XCTAssertEqual(snapshot.messages.map(\.id), messages.map(\.id))
        XCTAssertEqual(snapshot.totalMessageCount, messages.count)
        XCTAssertTrue(snapshot.isComplete)
    }

    func testLegacyCacheWithoutCompletenessMetadataBackfillsConservatively() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastLegacyMetadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(workspaceID: "test", root: root)
        await cache.save([Self.message(1)], sessionKey: "agent:main:legacy-metadata")

        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil)
        let json = try XCTUnwrap(files.first(where: { $0.pathExtension == "json" }))
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        payload["isComplete"] = nil
        payload["totalMessageCount"] = nil
        try JSONSerialization.data(withJSONObject: payload).write(to: json, options: .atomic)
        for metadata in files where metadata.pathExtension == "meta" {
            try FileManager.default.removeItem(at: metadata)
        }

        let snapshot = await cache.loadSnapshot(sessionKey: "agent:main:legacy-metadata")
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertFalse(snapshot.isComplete)
    }

    func testOversizedLegacyCacheIsSkippedWithoutDecoding() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastLegacyCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(workspaceID: "test", root: root)
        await cache.save([Self.message(1)], sessionKey: "agent:main:legacy")

        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil)
        let json = try XCTUnwrap(files.first(where: { $0.pathExtension == "json" }))
        for metadata in files where metadata.pathExtension == "meta" {
            try FileManager.default.removeItem(at: metadata)
        }
        let handle = try FileHandle(forWritingTo: json)
        try handle.truncate(atOffset: UInt64(TranscriptCache.maximumLegacyOpenBytes + 1))
        try handle.close()

        let snapshot = await cache.loadSnapshot(sessionKey: "agent:main:legacy")
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.skippedOversizedLegacyFile)
        XCTAssertFalse(snapshot.isComplete)
    }

    /// Reproduces Phase 2's zero-latency cold-open CPU path: 50 newest-to-oldest pages,
    /// 200 rows each, with the old implementation reconciling and rescanning after every
    /// page. The Phase 3 open ends after page one; its utility backfill is timed separately.
    func testSyntheticTenThousandMessageColdOpenBenchmark() {
        let messages = (0 ..< 10_000).map(Self.message)
        let pages = stride(from: messages.count, to: 0, by: -200).map { end in
            Array(messages[max(0, end - 200) ..< end])
        }

        let beforeStart = DispatchTime.now().uptimeNanoseconds
        var legacyTranscript: [ChatMessage] = []
        var legacyPending: [PendingEcho] = []
        for (index, page) in pages.enumerated() {
            let knownIDs = Set(legacyTranscript.map(\.id))
            legacyTranscript = Self.legacyReconciledHistory(
                page,
                current: legacyTranscript,
                pendingEchoes: &legacyPending,
                position: index == 0 ? .latest : .older)
            _ = legacyTranscript.contains { !knownIDs.contains($0.id) }
        }
        let beforeMilliseconds = Self.elapsedMilliseconds(since: beforeStart)

        let tailStart = DispatchTime.now().uptimeNanoseconds
        var afterPending: [PendingEcho] = []
        let interactiveTail = ChatStore.reconciledHistory(
            pages[0],
            current: [],
            pendingEchoes: &afterPending,
            position: .latest)
        let tailMilliseconds = Self.elapsedMilliseconds(since: tailStart)

        let backfillStart = DispatchTime.now().uptimeNanoseconds
        var accumulator = HistoryBackfillAccumulator(current: interactiveTail)
        for page in pages.dropFirst() { accumulator.ingest(page) }
        let completed = ChatStore.reconciledHistory(
            accumulator.olderMessagesInChronologicalOrder,
            current: interactiveTail,
            pendingEchoes: &afterPending,
            position: .older)
        let backfillMilliseconds = Self.elapsedMilliseconds(since: backfillStart)

        let transcriptBuilderStart = DispatchTime.now().uptimeNanoseconds
        let transcriptItems = TranscriptBuilder.items(from: completed)
        let transcriptBuilderMilliseconds = Self.elapsedMilliseconds(since: transcriptBuilderStart)

        XCTAssertEqual(legacyTranscript.map(\.id), messages.map(\.id))
        XCTAssertEqual(completed.map(\.id), messages.map(\.id))
        XCTAssertEqual(transcriptItems.count, 2_000)
        XCTAssertLessThan(tailMilliseconds, beforeMilliseconds)
        print(String(format:
            "CAST_HISTORY_BENCHMARK messages=10000 pages=50 before_blocking_ms=%.3f after_tail_ms=%.3f after_backfill_cpu_ms=%.3f transcript_builder_ms=%.3f output_items=%d",
            beforeMilliseconds,
            tailMilliseconds,
            backfillMilliseconds,
            transcriptBuilderMilliseconds,
            transcriptItems.count))
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// Frozen copy of Phase 2's page reconcile for an honest same-process before number.
    private static func legacyReconciledHistory(
        _ history: [ChatMessage],
        current: [ChatMessage],
        pendingEchoes: inout [PendingEcho],
        position: ChatStore.HistoryPagePosition) -> [ChatMessage]
    {
        var reconciled = ChatStore.dedupedByID(current)
        var indexByID = Dictionary(
            uniqueKeysWithValues: reconciled.enumerated().map { ($1.id, $0) })
        var additions: [ChatMessage] = []
        for var message in history {
            let existingIndex = indexByID[message.id] ?? reconciled.firstIndex(where: {
                ChatStore.isSameTranscriptEntry($0, message)
            })
            if let existingIndex {
                let existing = reconciled[existingIndex]
                if !existing.localImageData.isEmpty { message.localImageData = existing.localImageData }
                reconciled[existingIndex] = message.withID(existing.id)
                continue
            }
            if message.isUser,
               let pendingIndex = pendingEchoes.firstIndex(where: { $0.sentText == message.text })
            {
                let pending = pendingEchoes.remove(at: pendingIndex)
                if let localIndex = reconciled.firstIndex(where: { $0.id == pending.id }) {
                    message.localImageData = reconciled[localIndex].localImageData
                    reconciled.remove(at: localIndex)
                    indexByID = Dictionary(
                        uniqueKeysWithValues: reconciled.enumerated().map { ($1.id, $0) })
                }
            }
            additions.append(message)
        }
        reconciled = position == .older ? additions + reconciled : reconciled + additions
        return ChatStore.chronologicallySorted(ChatStore.dedupedByID(reconciled))
    }
}

final class CastCoreTests: XCTestCase {
    /// Everything `Composer.body` reads through `ComposerModel`, tracked as one scope — the
    /// same set SwiftUI would register while evaluating that body.
    @MainActor
    private func composerIsInvalidated(
        _ model: ComposerModel,
        by mutate: () -> Void) -> Bool
    {
        let box = ObservationFlag()
        withObservationTracking {
            _ = model.pendingAttachments
            _ = model.selectedSessionKey
            _ = model.deliverExternally
            _ = model.lastError
            _ = model.contextCompactionOfferKey
        } onChange: {
            box.mark()
        }
        mutate()
        return box.changed
    }

    @MainActor
    func testComposerObservationIgnoresUnrelatedStoreChurn() {
        let store = ChatStore(profile: .unconfigured)
        let model = ComposerModel(store: store)

        // Sidebar search is one of ChatStore's many observable values. It must not reach
        // the field editor's observation boundary.
        XCTAssertFalse(self.composerIsInvalidated(model) { store.searchQuery = "sidebar churn" })

        // Neither may the transcript, which is the loudest of them: a streamed reply writes
        // `messages` (and `transcriptRevision`) for every row that lands.
        XCTAssertFalse(self.composerIsInvalidated(model) {
            store.installOfflineDiagnosticTranscript([
                Self.textMessage(id: "m-1", role: "assistant", text: "streamed", timestamp: 1),
            ])
        })

        // Attachments are rendered by Composer and therefore must still invalidate it.
        let attachment = PreparedAttachment(
            type: "file",
            mimeType: "text/plain",
            fileName: "note.txt",
            data: Data("hello".utf8))
        XCTAssertTrue(self.composerIsInvalidated(model) { store.addAttachments([attachment]) })
        XCTAssertEqual(model.pendingAttachments, [attachment])

        // The projection reads through to the store rather than mirroring it, so it can
        // never render a value the store has already moved past.
        store.deliverExternally = true
        XCTAssertTrue(model.deliverExternally)
        XCTAssertTrue(self.composerIsInvalidated(model) { store.showError("nope") })
        XCTAssertEqual(model.lastError, "nope")
    }

    /// The transcript cache used to be rebuilt from the whole history on every write, so a
    /// streamed reply cost O(messages) per row. An append now extends the retained builder;
    /// the recorded interval is the proof of which path ran and how much it walked.
    @MainActor
    func testAppendedMessageExtendsTheTranscriptCacheInsteadOfReprocessingHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(transcriptCacheRoot: root, operationsLedgerRoot: root)

        // Selecting first: opening a session resets the transcript, which would wipe the
        // history installed below. Everything up to the final `await` is synchronous, so no
        // background task can rewrite `messages` between the assertions.
        store.selectedSessionKey = "agent:main:cast-tests"
        func history(_ count: Int) -> [ChatMessage] {
            (0 ..< count).map { index in
                Self.textMessage(
                    id: "m-\(index)",
                    role: index.isMultiple(of: 2) ? "user" : "assistant",
                    text: "row \(index)",
                    timestamp: 1_784_600_000_000 + Double(index) * 1000)
            }
        }
        store.installOfflineDiagnosticTranscript(history(400))

        let rebuilt = store.transcriptItems(showAgentWork: true)
        var lastBuild = try XCTUnwrap(Self.transcriptCacheBuild(after: nil))
        XCTAssertEqual(lastBuild.mode, "rebuild")
        XCTAssertEqual(lastBuild.processedMessages, 400)
        XCTAssertEqual(store.transcriptBuilderConsumedMessageCount, 400)

        // A whole-transcript replacement — a history reconcile, a session switch — can move
        // rows the builder already folded into a group, so it must never be mistaken for an
        // append even though the count only grew.
        store.installOfflineDiagnosticTranscript(history(401))
        _ = store.transcriptItems(showAgentWork: true)
        lastBuild = try XCTUnwrap(Self.transcriptCacheBuild(after: lastBuild.operationID))
        XCTAssertEqual(lastBuild.mode, "rebuild")
        XCTAssertEqual(lastBuild.processedMessages, 401)

        // A send is the real append path: one optimistic row on the tail, nothing else moved.
        let config = GatewayClientConfig(
            url: try XCTUnwrap(URL(string: "ws://127.0.0.1:9")),
            workspaceID: "test",
            credential: GatewayCredential(kind: .deviceToken, token: "unused"),
            deviceCredentialProvider: { nil },
            onDeviceToken: { _ in },
            clientId: "cast-tests",
            platform: "macOS",
            deviceFamily: "Mac",
            displayName: "Cast Tests")
        store.installClientForTesting(GatewayClient(config: config, onEvent: { _ in }, onState: { _ in }))
        let sendSettled = expectation(description: "send settles against the dead port")
        XCTAssertTrue(store.send("one more", idempotencyKey: "idem-append") { _ in sendSettled.fulfill() })
        XCTAssertEqual(store.messages.count, 402)

        let extended = store.transcriptItems(showAgentWork: true)
        lastBuild = try XCTUnwrap(Self.transcriptCacheBuild(after: lastBuild.operationID))
        XCTAssertEqual(lastBuild.mode, "append")
        // The whole point: one message walked, not four hundred and two.
        XCTAssertEqual(lastBuild.processedMessages, 1)
        // The materialized array also changes only at its open tail; reducing one message
        // and then copying 402 rendered rows would still be O(total history).
        XCTAssertEqual(Self.transcriptCacheUpdatedItems(operationID: lastBuild.operationID), 4)
        XCTAssertEqual(store.transcriptBuilderConsumedMessageCount, 402)

        // Equivalence: the extended cache is exactly what a full rebuild would have produced,
        // down to which messages landed in which group.
        XCTAssertGreaterThan(extended.count, rebuilt.count)
        XCTAssertEqual(
            Self.fingerprint(extended),
            Self.fingerprint(TranscriptBuilder.items(from: store.messages, showAgentWork: true)))

        // Hiding agent work is a whole-history filter and always rebuilds, and flipping back
        // must not mistake the discarded builder for an extendable prefix.
        _ = store.transcriptItems(showAgentWork: false)
        XCTAssertNil(store.transcriptBuilderConsumedMessageCount)
        XCTAssertEqual(
            Self.fingerprint(store.transcriptItems(showAgentWork: true)),
            Self.fingerprint(TranscriptBuilder.items(from: store.messages, showAgentWork: true)))
        XCTAssertEqual(store.transcriptBuilderConsumedMessageCount, 402)

        await fulfillment(of: [sendSettled], timeout: 20)
    }

    /// Structural identity, not just item ids: a group that silently lost a message keeps
    /// the same id.
    private static func fingerprint(_ items: [TranscriptItem]) -> [String] {
        items.map { item in
            switch item {
            case let .daySeparator(id, _): return "day|\(id)"
            case let .toolRun(run): return "run|\(run.id)|" + run.steps.map(\.id).joined(separator: ",")
            case let .group(group):
                return "group|\(group.id)|\(group.role)|" + group.messages.map(\.id).joined(separator: ",")
            }
        }
    }

    private struct TranscriptCacheBuild {
        let operationID: UUID
        let mode: String
        let processedMessages: Int
    }

    /// Most recent `ChatStore.transcriptCache` begin record, optionally skipping everything
    /// up to and including a previously observed one.
    private static func transcriptCacheBuild(after operationID: UUID?) -> TranscriptCacheBuild? {
        var records = CastPerformanceDiagnostics.recentOperations()
            .filter { $0.operation == CastPerformanceOperation.transcriptCache.rawValue && $0.phase == "begin" }
        if let operationID, let index = records.firstIndex(where: { $0.operationID == operationID }) {
            records = Array(records[(index + 1)...])
        }
        guard let record = records.last, let metadata = record.metadata else { return nil }
        func field(_ key: String) -> String? {
            metadata.split(separator: " ")
                .first { $0.hasPrefix("\(key)=") }
                .map { String($0.dropFirst(key.count + 1)) }
        }
        guard let mode = field("mode"), let processed = field("processed_messages").flatMap(Int.init)
        else { return nil }
        return TranscriptCacheBuild(operationID: record.operationID, mode: mode, processedMessages: processed)
    }

    private static func transcriptCacheUpdatedItems(operationID: UUID) -> Int? {
        guard let metadata = CastPerformanceDiagnostics.recentOperations().last(where: {
            $0.operationID == operationID && $0.phase == "end"
        })?.metadata else { return nil }
        return metadata.split(separator: " ")
            .first { $0.hasPrefix("updated_items=") }
            .map { String($0.dropFirst("updated_items=".count)) }
            .flatMap(Int.init)
    }

    // MARK: - sessions.subscribe

    func testSessionsSubscribeLadderIsBoundedAndBacksOffLikeThePerSessionSubscribe() {
        XCTAssertEqual(GatewayFailurePolicy.maximumSessionsSubscribeAttempts, 3)
        XCTAssertNil(GatewayFailurePolicy.sessionsSubscribeRetryDelayNanoseconds(attempt: 0))
        XCTAssertEqual(GatewayFailurePolicy.sessionsSubscribeRetryDelayNanoseconds(attempt: 1), 500_000_000)
        XCTAssertEqual(GatewayFailurePolicy.sessionsSubscribeRetryDelayNanoseconds(attempt: 2), 1_000_000_000)
        // No delay after the final attempt: that is what ends the ladder rather than a
        // separate stop condition, so it must stay nil for every attempt at or past the cap.
        XCTAssertNil(GatewayFailurePolicy.sessionsSubscribeRetryDelayNanoseconds(attempt: 3))
        XCTAssertNil(GatewayFailurePolicy.sessionsSubscribeRetryDelayNanoseconds(attempt: 99))
        // Whole ladder bounded well inside a foreground: 1.5 s of waiting, worst case.
        let total = (1 ..< GatewayFailurePolicy.maximumSessionsSubscribeAttempts)
            .compactMap { GatewayFailurePolicy.sessionsSubscribeRetryDelayNanoseconds(attempt: $0) }
            .reduce(0, +)
        XCTAssertEqual(total, 1_500_000_000)
    }

    @MainActor
    func testBoundedSubscribeRetryStopsAtTheCapAndStopsEarlyWhenAbandoned() async {
        var attempts: [Int] = []
        var slept: [UInt64] = []
        let alwaysFails = await BoundedSubscribeRetry.sessions.run(
            sleep: { slept.append($0) },
            perform: { attempt in
                attempts.append(attempt)
                return false
            })
        XCTAssertFalse(alwaysFails)
        // Bounded, not a loop: exactly three tries, two waits, then it gives up.
        XCTAssertEqual(attempts, [1, 2, 3])
        XCTAssertEqual(slept, [500_000_000, 1_000_000_000])

        // Success short-circuits the rest of the ladder.
        attempts = []
        slept = []
        let succeeds = await BoundedSubscribeRetry.sessions.run(
            sleep: { slept.append($0) },
            perform: { attempt in
                attempts.append(attempt)
                return attempt == 2
            })
        XCTAssertTrue(succeeds)
        XCTAssertEqual(attempts, [1, 2])
        XCTAssertEqual(slept, [500_000_000])

        // A swapped client or a background suspend abandons the ladder rather than
        // finishing a schedule nobody is waiting on.
        attempts = []
        slept = []
        let abandoned = await BoundedSubscribeRetry.sessions.run(
            isCurrent: { false },
            sleep: { slept.append($0) },
            perform: { attempt in
                attempts.append(attempt)
                return false
            })
        XCTAssertFalse(abandoned)
        XCTAssertEqual(attempts, [1])
        XCTAssertTrue(slept.isEmpty)
    }

    func testMainThreadStallRingBufferIsBoundedAndSummarizesThePriorRun() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastStallRingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("stalls.json")
        let firstRunID = UUID()
        let buffer = MainThreadStallRingBuffer(fileURL: fileURL, capacity: 2)
        XCTAssertTrue(buffer.beginRun(firstRunID).isEmpty)

        for milliseconds in [600.0, 3_100.0, 3_400.0] {
            buffer.append(MainThreadStallRecord(
                id: UUID(),
                runID: firstRunID,
                stallID: UUID(),
                timestamp: Date(),
                phase: milliseconds < 3_000 ? .warning : .hang,
                observedDurationMilliseconds: milliseconds,
                mainThreadBacktrace: ["frame"],
                recentOperations: []))
        }
        XCTAssertEqual(
            buffer.snapshot().records.map(\.observedDurationMilliseconds),
            [3_100, 3_400])

        // Reload from disk to exercise the real encoding path used after force-quit.
        let nextLaunch = MainThreadStallRingBuffer(fileURL: fileURL, capacity: 2)
        let nextRunID = UUID()
        let previousRun = nextLaunch.beginRun(nextRunID)
        XCTAssertEqual(previousRun.map(\.observedDurationMilliseconds), [3_100, 3_400])
        XCTAssertEqual(nextLaunch.snapshot().activeRunID, nextRunID)
    }

    @MainActor
    func testWorkspaceManagerSuspendsEveryConfiguredStore() throws {
        let suiteName = "CastTests.multi-workspace-suspend.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = [
            WorkspaceProfile(id: "one", name: "One", gatewayURL: URL(string: "wss://one.example.test")!, accent: "purple"),
            WorkspaceProfile(id: "two", name: "Two", gatewayURL: URL(string: "wss://two.example.test")!, accent: "orange"),
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: "cast.workspaceProfiles.v2")
        let manager = WorkspaceManager(
            defaults: defaults,
            credentialProvider: { _ in nil },
            includeDevelopmentWorkspaces: false,
            legacyLocalCredentialAvailable: false)

        manager.suspendAllForBackground()

        XCTAssertTrue(manager.store(for: "one").isSuspendedForBackground)
        XCTAssertTrue(manager.store(for: "two").isSuspendedForBackground)
    }

    @MainActor
    func testStaleClientCallbacksAreRejectedAfterSuspension() {
        let store = ChatStore(profile: .unconfigured)
        let generation = store.clientGeneration
        store.suspendForBackground()

        store.receiveState(.connected(mainSessionKey: "stale"), generation: generation)

        XCTAssertEqual(store.connectionState, .disconnected(nil))
        XCTAssertTrue(store.isSuspendedForBackground)
        XCTAssertFalse(ChatStore.acceptsClientCallback(
            generation: generation,
            currentGeneration: store.clientGeneration,
            suspended: true))
    }

    @MainActor
    func testFreshInstallPresentsVersionedOnboardingWithoutInternalWorkspaces() throws {
        let suiteName = "CastTests.onboarding.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = WorkspaceManager(
            defaults: defaults,
            credentialProvider: { _ in nil },
            includeDevelopmentWorkspaces: false,
            legacyLocalCredentialAvailable: false)

        XCTAssertTrue(manager.profiles.isEmpty)
        XCTAssertTrue(manager.isOnboardingPresented)
        XCTAssertEqual(
            defaults.integer(forKey: CastOnboarding.seenKey),
            CastOnboarding.currentVersion)
        let relaunchedAfterIncompletePairing = WorkspaceManager(
            defaults: defaults,
            credentialProvider: { _ in GatewayCredential(kind: .bootstrapToken, token: "pending") },
            includeDevelopmentWorkspaces: false,
            legacyLocalCredentialAvailable: false)
        XCTAssertTrue(relaunchedAfterIncompletePairing.isOnboardingPresented)
        manager.dismissOnboarding()
        XCTAssertFalse(manager.isOnboardingPresented)
        manager.presentOnboarding()
        XCTAssertTrue(manager.isOnboardingPresented)
        manager.completeOnboarding()
        XCTAssertFalse(manager.isOnboardingPresented)
        XCTAssertEqual(
            defaults.integer(forKey: CastOnboarding.completionKey),
            CastOnboarding.currentVersion)
    }

    @MainActor
    func testExistingCredentialBearingInstallMigratesWithoutOnboardingTrap() throws {
        let suiteName = "CastTests.onboarding-migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = WorkspaceProfile(
            id: "home",
            name: "Home",
            gatewayURL: try XCTUnwrap(URL(string: "wss://gateway.example.com")),
            accent: "purple")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "cast.workspaceProfiles.v2")

        let manager = WorkspaceManager(
            defaults: defaults,
            credentialProvider: { id in
                id == "home" ? GatewayCredential(kind: .deviceToken, token: "stored") : nil
            },
            includeDevelopmentWorkspaces: false,
            legacyLocalCredentialAvailable: false)

        XCTAssertEqual(manager.profiles.map(\.id), ["home"])
        XCTAssertFalse(manager.isOnboardingPresented)
        XCTAssertEqual(
            defaults.integer(forKey: CastOnboarding.completionKey),
            CastOnboarding.currentVersion)
        XCTAssertEqual(
            CastOnboarding.launchDecision(
                completedVersion: CastOnboarding.currentVersion - 1,
                seenVersion: CastOnboarding.currentVersion - 1,
                hasConfiguredCredential: true),
            .present)
    }

    func testPublicWorkspaceBootstrapPreservesLegacyButDoesNotSeedPrivateDefaults() {
        XCTAssertTrue(WorkspaceBootstrapPolicy.profiles(
            saved: [],
            includeDevelopmentWorkspaces: false,
            hasCredential: { _ in false }).isEmpty)
        XCTAssertEqual(WorkspaceBootstrapPolicy.profiles(
            saved: [],
            includeDevelopmentWorkspaces: false,
            hasCredential: { $0 == WorkspaceProfile.developmentLocal.id }).map(\.id), ["local"])

        let saved = WorkspaceProfile(
            id: "team",
            name: "Team",
            gatewayURL: URL(string: "wss://team.example.com")!,
            accent: "purple")
        XCTAssertEqual(WorkspaceBootstrapPolicy.profiles(
            saved: [saved],
            includeDevelopmentWorkspaces: false,
            hasCredential: { _ in false }).map(\.id), ["team"])
    }

    func testPairingConnectionStatesUseActionablePublicPhases() {
        XCTAssertEqual(PairingConnectionPhase.phase(for: .disconnected(nil)), .connecting)
        XCTAssertEqual(PairingConnectionPhase.phase(for: .connecting), .connecting)
        XCTAssertEqual(PairingConnectionPhase.phase(for: .waitingForApproval), .approvalRequired)
        XCTAssertEqual(PairingConnectionPhase.phase(for: .connected(mainSessionKey: nil)), .connected)
        XCTAssertEqual(PairingConnectionPhase.phase(for: .needsCredentials("raw secret")), .authenticationFailed)
        XCTAssertEqual(PairingConnectionPhase.phase(for: .disconnected("AUTH_TOKEN_MISMATCH raw")), .authenticationFailed)
        XCTAssertEqual(PairingConnectionPhase.phase(for: .disconnected("network connection lost")), .unreachable)
    }

    func testPairingErrorsDoNotExposeUnexpectedStorageDetails() {
        XCTAssertEqual(
            PairingError.userFacingMessage(for: PairingError.expiredCode),
            "That setup code expired. Generate a fresh code and try again.")
        XCTAssertEqual(
            PairingError.userFacingMessage(for: NSError(
                domain: NSOSStatusErrorDomain,
                code: -25_300,
                userInfo: [NSLocalizedDescriptionKey: "raw keychain detail"])),
            "Cast couldn’t save this workspace securely. Make sure Keychain is available, then try again.")
    }

    func testCanceledGatewayPeriodicWaitTerminatesPromptly() async {
        let started = Date()
        let wait = Task {
            await GatewayClient.waitForPeriodicInterval(nanoseconds: 30_000_000_000)
        }

        wait.cancel()

        let shouldContinue = await wait.value
        XCTAssertFalse(shouldContinue)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testLongAssistantResponseCopyTextIsCompleteRenderedText() {
        let paragraphs = (0..<300).map { "Paragraph \($0) keeps its full contents." }
        let markdown = paragraphs.joined(separator: "\n\n")
            + "\n\nRead [the guide](https://example.com/guide).\n\n```swift\nlet complete = true\n```"

        let content = AssistantResponseContent(markdown: markdown)

        XCTAssertTrue(content.copyText.hasPrefix(paragraphs[0]))
        XCTAssertTrue(content.copyText.contains(paragraphs[150]))
        XCTAssertTrue(content.copyText.contains(paragraphs[299]))
        XCTAssertTrue(content.copyText.contains("Read the guide."))
        XCTAssertTrue(content.copyText.contains("let complete = true"))
        XCTAssertFalse(content.copyText.contains("https://example.com/guide"))
    }

    func testOperatorScopeSetStaysWithinBootstrapHandoffProfile() {
        // The gateway's setup-code bootstrap profile only allows
        // operator.approvals/read/talk.secrets/write; any extra scope makes
        // pairing fail closed as "bootstrap token invalid".
        let allowed: Set<String> = [
            "operator.approvals", "operator.read", "operator.talk.secrets", "operator.write",
        ]
        XCTAssertTrue(Set(GatewayClient.scopes).isSubset(of: allowed))
        XCTAssertFalse(GatewayClient.scopes.contains("operator.pairing"))
    }

    func testGatewayAdvertisesStructuredToolEvents() {
        XCTAssertEqual(GatewayClient.capabilities, ["tool-events"])
    }

    func testGatewayEchoReplacesOptimisticUserBubble() {
        // The gateway echoes every chat.send back as a session.message event;
        // it must replace the optimistic local bubble, not render a second one.
        let local = Self.textMessage(id: "local-1", role: "user", text: "hello?")
        var pending = [PendingEcho(id: "local-1", sentText: "hello?")]
        let echo = Self.textMessage(id: "server-1", role: "user", text: "hello?")
        let merged = ChatStore.mergedMessages([local], incoming: echo, pendingEchoes: &pending)
        XCTAssertEqual(merged.map(\.id), ["server-1"])
        XCTAssertTrue(pending.isEmpty)
    }

    func testRepeatedIdenticalSendsEachKeepOneBubble() {
        let locals = [
            Self.textMessage(id: "local-1", role: "user", text: "hello?"),
            Self.textMessage(id: "local-2", role: "user", text: "hello?"),
        ]
        var pending = [
            PendingEcho(id: "local-1", sentText: "hello?"),
            PendingEcho(id: "local-2", sentText: "hello?"),
        ]
        var merged = ChatStore.mergedMessages(locals, incoming: Self.textMessage(id: "server-1", role: "user", text: "hello?"), pendingEchoes: &pending)
        merged = ChatStore.mergedMessages(merged, incoming: Self.textMessage(id: "server-2", role: "user", text: "hello?"), pendingEchoes: &pending)
        XCTAssertEqual(merged.map(\.id), ["server-1", "server-2"])
        XCTAssertTrue(pending.isEmpty)
    }

    @MainActor
    func testFailedSendKeepsBubbleMarkedFailedAndRetryReusesIdempotencyKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(transcriptCacheRoot: root, operationsLedgerRoot: root)
        let config = GatewayClientConfig(
            url: try XCTUnwrap(URL(string: "ws://127.0.0.1:9")),
            workspaceID: "test",
            credential: GatewayCredential(kind: .deviceToken, token: "unused"),
            deviceCredentialProvider: { nil },
            onDeviceToken: { _ in },
            clientId: "cast-tests",
            platform: "macOS",
            deviceFamily: "Mac",
            displayName: "Cast Tests")
        // Port 9 (discard) is closed, so the real send path fails at the transport.
        store.installClientForTesting(GatewayClient(config: config, onEvent: { _ in }, onState: { _ in }))
        store.selectedSessionKey = "agent:main:cast-tests"

        let firstAttempt = expectation(description: "send fails")
        XCTAssertTrue(store.send("hello from the failing send", idempotencyKey: "idem-1") { ok in
            XCTAssertFalse(ok)
            firstAttempt.fulfill()
        })
        XCTAssertEqual(store.messages.last?.localDeliveryState, .pending)
        await fulfillment(of: [firstAttempt], timeout: 20)

        // The original bug: the bubble stayed indistinguishable from a delivered send and
        // was re-cached that way forever, while a retry appended a second copy beside it.
        XCTAssertEqual(store.messages.count, 1)
        let failed = try XCTUnwrap(store.messages.last)
        XCTAssertEqual(failed.localDeliveryState, .failed)
        XCTAssertEqual(failed.text, "hello from the failing send")
        XCTAssertEqual(failed.localIdempotencyKey, "idem-1")
        XCTAssertFalse(store.isAgentTurnActive)

        store.retrySend(messageID: failed.id)
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.last?.id, failed.id)
        XCTAssertEqual(store.messages.last?.localDeliveryState, .pending)
        // The retry keeps the original key, so a first attempt that actually reached the
        // gateway cannot double-post. It fails against the dead port and re-marks the row.
        XCTAssertEqual(store.messages.last?.localIdempotencyKey, "idem-1")
        for _ in 0..<200 where store.messages.last?.localDeliveryState != .failed {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.last?.localDeliveryState, .failed)
    }

    func testRetriedEchoMergesGatewayEchoIntoSameBubbleAndClearsFailure() {
        let failed = ChatMessage(
            id: "local-1",
            role: "user",
            blocks: [ChatContentBlock(type: "text", text: "hello?", thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: 1,
            localDeliveryState: .failed,
            localIdempotencyKey: "idem-1")
        // Retry re-arms the pending echo; the gateway echo must then replace the failed
        // bubble rather than render a second one beside it.
        var pending = [PendingEcho(id: "local-1", sentText: "hello?")]
        let echo = Self.textMessage(id: "server-1", role: "user", text: "hello?", timestamp: 2)
        let merged = ChatStore.mergedMessages([failed], incoming: echo, pendingEchoes: &pending)
        XCTAssertEqual(merged.map(\.id), ["server-1"])
        XCTAssertEqual(merged.first?.localDeliveryState, .delivered)
    }

    func testFailedBubblePersistsAcrossCacheAndHistoryReconcile() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(workspaceID: "test", root: root)
        let failed = ChatMessage(
            role: "user",
            blocks: [ChatContentBlock(type: "text", text: "went nowhere", thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: 5,
            localDeliveryState: .failed,
            localIdempotencyKey: "idem-9")
            .identifiedByContent()
        await cache.save([failed], sessionKey: "agent:main:test")
        let loaded = await cache.load(sessionKey: "agent:main:test")
        XCTAssertEqual(loaded.first?.localDeliveryState, .failed)
        XCTAssertEqual(loaded.first?.localIdempotencyKey, "idem-9")

        // A history refresh cannot launder the failure: the retained row stays failed.
        var pending: [PendingEcho] = []
        let history = [Self.textMessage(id: "server-1", role: "assistant", text: "earlier reply", timestamp: 1)]
        let reconciled = ChatStore.reconciledHistory(history, current: loaded, pendingEchoes: &pending)
        XCTAssertEqual(reconciled.last?.localDeliveryState, .failed)
        XCTAssertEqual(reconciled.last?.localIdempotencyKey, "idem-9")
    }

    func testDuplicateEventByIdIsDropped() {
        // History reload + a late echo can carry the same server message twice.
        let existing = Self.textMessage(id: "server-1", role: "user", text: "hello?")
        var pending: [PendingEcho] = []
        let merged = ChatStore.mergedMessages([existing], incoming: existing, pendingEchoes: &pending)
        XCTAssertEqual(merged.count, 1)
    }

    func testDedupedByIDKeepsFirstOccurrenceInOrder() {
        // A gateway list response carrying the same identifier twice must never
        // reach a selectable List — duplicate IDs abort in AppKit's diff.
        let messages = [
            Self.textMessage(id: "a", role: "user", text: "one"),
            Self.textMessage(id: "b", role: "assistant", text: "two"),
            Self.textMessage(id: "a", role: "user", text: "one again"),
        ]
        XCTAssertEqual(ChatStore.dedupedByID(messages).map(\.id), ["a", "b"])
        let sessions = try? JSONDecoder().decode(
            [SessionRow].self,
            from: Data(#"[{"key":"agent:main:main"},{"key":"agent:main:main"},{"key":"agent:main:other"}]"#.utf8))
        XCTAssertEqual(ChatStore.dedupedByID(sessions ?? []).map(\.key), ["agent:main:main", "agent:main:other"])
    }

    func testChronologicalSortHasStableTotalOrderWithMissingAndInvalidTimestamps() {
        let input = [
            Self.textMessage(id: "new", role: "assistant", text: "new", timestamp: 10),
            Self.textMessage(id: "missing-a", role: "assistant", text: "missing a", timestamp: nil),
            Self.textMessage(id: "old", role: "assistant", text: "old", timestamp: 5),
            Self.textMessage(id: "equal-a", role: "assistant", text: "equal a", timestamp: 7),
            Self.textMessage(id: "invalid", role: "assistant", text: "invalid", timestamp: .nan),
            Self.textMessage(id: "equal-b", role: "assistant", text: "equal b", timestamp: 7),
            Self.textMessage(id: "missing-b", role: "assistant", text: "missing b", timestamp: nil),
        ]

        for _ in 0..<100 {
            XCTAssertEqual(
                ChatStore.chronologicallySorted(input).map(\.id),
                ["old", "missing-a", "equal-a", "equal-b", "invalid", "new", "missing-b"])
        }
    }

    func testForeignUserMessageStillAppends() {
        // A user message sent from another paired device has no pending echo here.
        let mine = Self.textMessage(id: "server-1", role: "user", text: "hello?")
        var pending: [PendingEcho] = []
        let other = Self.textMessage(id: "server-2", role: "user", text: "from my phone")
        let merged = ChatStore.mergedMessages([mine], incoming: other, pendingEchoes: &pending)
        XCTAssertEqual(merged.map(\.id), ["server-1", "server-2"])
    }

    func testCrossDeviceHistoryMergeAddsRemoteMessagesWithoutReplacingLocalTranscript() {
        let desktopBacklog = [
            Self.textMessage(id: "old-user", role: "user", text: "desktop question", timestamp: 1),
            Self.textMessage(id: "old-answer", role: "assistant", text: "desktop answer", timestamp: 2),
        ]
        let phoneMessages = [
            Self.textMessage(id: "phone-user", role: "user", text: "sent from iPhone", timestamp: 3),
            Self.textMessage(id: "phone-answer", role: "assistant", text: "seen on iPhone", timestamp: 4),
        ]
        var pending: [PendingEcho] = []

        let merged = ChatStore.reconciledHistory(
            phoneMessages,
            current: desktopBacklog,
            pendingEchoes: &pending)

        XCTAssertEqual(merged.map(\.id), ["old-user", "old-answer", "phone-user", "phone-answer"])
        XCTAssertEqual(merged.map(\.text), ["desktop question", "desktop answer", "sent from iPhone", "seen on iPhone"])
    }

    func testCrossDeviceSessionChangeRefreshesOnlySelectedConversation() {
        XCTAssertTrue(ChatStore.sessionChangeAffectsSelectedHistory(
            changedSessionKey: "main",
            selectedSessionKey: "agent:main:main"))
        XCTAssertFalse(ChatStore.sessionChangeAffectsSelectedHistory(
            changedSessionKey: "agent:main:other",
            selectedSessionKey: "agent:main:main"))
        XCTAssertFalse(ChatStore.sessionChangeAffectsSelectedHistory(
            changedSessionKey: nil,
            selectedSessionKey: "agent:main:main"))
    }

    func testCrossDeviceRefreshDuringHistoryLoadQueuesFollowUp() {
        var coordinator = HistoryRefreshCoordinator()

        XCTAssertTrue(coordinator.begin(key: "agent:main:main"))
        XCTAssertFalse(coordinator.begin(key: "agent:main:main"))
        XCTAssertTrue(coordinator.finish(key: "agent:main:main"))

        XCTAssertTrue(coordinator.begin(key: "agent:main:main"))
        XCTAssertFalse(coordinator.finish(key: "agent:main:main"))
    }

    func testStaleSessionOpenTokenCannotApplyToNewSelection() {
        let stale = ChatStore.SessionOpenToken(generation: 4, key: "agent:main:old")
        XCTAssertTrue(ChatStore.shouldApplySessionOpen(stale, generation: 4, selectedKey: "agent:main:old"))
        XCTAssertFalse(ChatStore.shouldApplySessionOpen(stale, generation: 5, selectedKey: "agent:main:new"))
        XCTAssertFalse(ChatStore.shouldApplySessionOpen(stale, generation: 4, selectedKey: "agent:main:new"))
    }

    func testDesktopSidebarTransientNilCannotBlankSelectedTranscript() {
        XCTAssertFalse(ChatStore.shouldAcceptSidebarSelection(
            candidate: nil,
            current: "agent:main:main",
            allowsDeselection: false))
        XCTAssertTrue(ChatStore.shouldAcceptSidebarSelection(
            candidate: "agent:main:other",
            current: "agent:main:main",
            allowsDeselection: false))
        XCTAssertTrue(ChatStore.shouldAcceptSidebarSelection(
            candidate: nil,
            current: nil,
            allowsDeselection: false))
    }

    func testIOSBackCanClearSelectionSoSameChatCanReopen() {
        XCTAssertTrue(ChatStore.shouldAcceptSidebarSelection(
            candidate: nil,
            current: "agent:main:main",
            allowsDeselection: true))
        XCTAssertTrue(ChatStore.shouldAcceptSidebarSelection(
            candidate: "agent:main:main",
            current: nil,
            allowsDeselection: true))
    }

    func testStaleHistoryCannotCancelLocallyPendingTurn() {
        var activity = AgentTurnActivityState()
        activity.beginLocal(runId: "client-run", atMs: 1_000)

        activity.applyHistory(hasActiveRun: false, runIds: [])

        XCTAssertTrue(activity.isActive)
        XCTAssertTrue(activity.contains("client-run"))

        activity.acknowledge(localRunId: "client-run", gatewayRunId: "gateway-run")
        activity.observe(runId: "gateway-run")
        activity.finish(runId: "gateway-run")
        XCTAssertFalse(activity.isActive)
    }

    func testLostTerminalEventCannotWedgePendingTurnForever() {
        // Send, background the app, run completes while iOS has the socket suspended:
        // the terminal event is gone. The next `.latest` history page reports no active
        // run AND carries the reply — a message newer than the send — which must clear
        // the pending run instead of pulsing "Thinking…" forever.
        var activity = AgentTurnActivityState()
        activity.beginLocal(runId: "client-run", atMs: 1_000)

        // A page still stale relative to the send (its newest row predates it) retains
        // the pending run — the flicker case the retention exists for.
        activity.applyHistory(hasActiveRun: false, runIds: [], newestMessageTimestampMs: 900)
        XCTAssertTrue(activity.isActive)

        // The page that postdates the send with no active run drops it.
        activity.applyHistory(hasActiveRun: false, runIds: [], newestMessageTimestampMs: 5_000)
        XCTAssertFalse(activity.isActive)
        XCTAssertFalse(activity.contains("client-run"))
    }

    func testActiveRunReportedByHistoryRetainsPendingTurn() {
        // A run the gateway still reports as active is not a lost terminal, however new
        // the transcript tail is — streaming replies land while the run is live.
        var activity = AgentTurnActivityState()
        activity.beginLocal(runId: "client-run", atMs: 1_000)
        activity.applyHistory(hasActiveRun: true, runIds: [], newestMessageTimestampMs: 5_000)
        XCTAssertTrue(activity.isActive)
        XCTAssertTrue(activity.contains("client-run"))
    }

    func testPendingRunAgeOutBackstopUnblocksWatchdog() {
        var activity = AgentTurnActivityState()
        activity.beginLocal(runId: "client-run", atMs: 1_000)

        XCTAssertFalse(activity.expirePendingRuns(before: 1_000))
        XCTAssertTrue(activity.isActive)

        XCTAssertTrue(activity.expirePendingRuns(before: 1_001))
        XCTAssertFalse(activity.isActive)
        XCTAssertFalse(activity.contains("client-run"))
    }

    func testHistoryReconciliationPreservesOptimisticImageBytes() {
        let bytes = Data([7, 8, 9])
        let local = ChatMessage(
            id: "local-1",
            role: "user",
            blocks: [ChatContentBlock(type: "text", text: "photo", thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: 1,
            localImageData: [bytes])
        let server = ChatMessage(
            id: "server-1",
            role: "user",
            blocks: [ChatContentBlock(type: "text", text: "photo", thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: 2,
            mediaPaths: ["/gateway/photo.jpg"])
        var pending = [PendingEcho(id: "local-1", sentText: "photo")]
        let reconciled = ChatStore.reconciledHistory([server], current: [local], pendingEchoes: &pending)
        XCTAssertEqual(reconciled.first?.id, "server-1")
        XCTAssertEqual(reconciled.first?.localImageData, [bytes])
        XCTAssertTrue(pending.isEmpty)
    }

    func testImageAndCaptionBubbleSurvivesGatewayEchoAndRemainsRenderable() {
        let bytes = Data([1, 3, 3, 7])
        let local = ChatMessage(
            id: "local-image",
            role: "user",
            blocks: [ChatContentBlock(type: "text", text: "what is in this image?", thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: 1,
            localImageData: [bytes])
        var pending = [PendingEcho(id: local.id, sentText: local.text)]
        let echo = ChatMessage(
            id: "server-image",
            role: "user",
            blocks: [ChatContentBlock(type: "text", text: "what is in this image?", thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: 2,
            mediaPaths: ["/gateway/shared.jpg"],
            mediaTypes: ["image/jpeg"])

        let merged = ChatStore.mergedMessages([local], incoming: echo, pendingEchoes: &pending)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, "server-image")
        XCTAssertEqual(merged.first?.text, "what is in this image?")
        XCTAssertEqual(merged.first?.localImageData, [bytes])
        XCTAssertEqual(merged.first?.mediaPaths, ["/gateway/shared.jpg"])
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(TranscriptBuilder.items(from: merged).count, 2) // day separator + user group
    }

    func testPartialLatestHistoryRetainsOlderCachedAndNewerLiveMessages() {
        let cachedOld = Self.textMessage(id: "old", role: "user", text: "older", timestamp: 1)
        let staleShared = Self.textMessage(id: "shared", role: "assistant", text: "stale", timestamp: 2)
        let liveTail = Self.textMessage(id: "live", role: "assistant", text: "still streaming", timestamp: 4)
        let refreshedShared = Self.textMessage(id: "shared", role: "assistant", text: "updated", timestamp: 2)
        let refreshedRecent = Self.textMessage(id: "recent", role: "user", text: "recent", timestamp: 3)
        var pending: [PendingEcho] = []

        let reconciled = ChatStore.reconciledHistory(
            [refreshedShared, refreshedRecent],
            current: [cachedOld, staleShared, liveTail],
            pendingEchoes: &pending)

        XCTAssertEqual(reconciled.map(\.id), ["old", "shared", "recent", "live"])
        XCTAssertEqual(reconciled.first(where: { $0.id == "shared" })?.text, "updated")
    }

    func testOlderHistoryPagePrependsWithoutReplacingFullerTranscript() {
        let oldest = Self.textMessage(id: "oldest", role: "user", text: "first", timestamp: 1)
        let overlap = Self.textMessage(id: "overlap", role: "assistant", text: "second", timestamp: 2)
        let latest = Self.textMessage(id: "latest", role: "assistant", text: "third", timestamp: 3)
        var pending: [PendingEcho] = []

        let reconciled = ChatStore.reconciledHistory(
            [oldest, overlap],
            current: [overlap, latest],
            pendingEchoes: &pending,
            position: .older)

        XCTAssertEqual(reconciled.map(\.id), ["oldest", "overlap", "latest"])
    }

    func testTranscriptSnapshotStoreEvictsLeastRecentlyUsedAndStripsImageBytes() {
        var store = TranscriptSnapshotStore(capacity: 2)
        let image = ChatMessage(
            id: "img",
            role: "user",
            blocks: [ChatContentBlock(type: "text", text: "photo", thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: 1,
            localImageData: [Data([1, 2, 3])])
        store.store([image], for: "a")
        // Image bytes never enter the snapshot; the disk cache rehydrates them on open.
        XCTAssertEqual(store.snapshot(for: "a")?.first?.localImageData, [])

        store.store([Self.textMessage(id: "b1", role: "user", text: "b")], for: "b")
        // Reading "a" makes it most recent, so a third session evicts "b", not "a".
        _ = store.snapshot(for: "a")
        store.store([Self.textMessage(id: "c1", role: "user", text: "c")], for: "c")
        XCTAssertNil(store.snapshot(for: "b"))
        XCTAssertNotNil(store.snapshot(for: "a"))
        XCTAssertNotNil(store.snapshot(for: "c"))
    }

    func testHistoryPaginationStopSignalDetectsFullyKnownPages() {
        // reloadHistory used to walk every older page of a months-old session after each
        // reply. The stop signal is "this page contributed nothing new": reconciliation
        // keeps incumbent identifiers for rows it already renders, so a fully known page
        // yields no unseen ids even though every row was processed — while a page with a
        // single unseen row keeps pagination alive.
        let backlog = (0 ..< 5).map {
            Self.textMessage(id: "m\($0)", role: "assistant", text: "row \($0)", timestamp: Double($0))
        }
        var pending: [PendingEcho] = []
        let knownIDs = Set(backlog.map(\.id))

        let fullyKnownPage = Array(backlog.prefix(3))
        let afterKnown = ChatStore.reconciledHistory(
            fullyKnownPage, current: backlog, pendingEchoes: &pending, position: .older)
        XCTAssertFalse(ChatStore.transcriptGainedRows(knownIDs: knownIDs, in: afterKnown))
        XCTAssertEqual(afterKnown.map(\.id), backlog.map(\.id))

        let unseen = Self.textMessage(id: "older-1", role: "assistant", text: "unseen", timestamp: -1)
        let afterUnseen = ChatStore.reconciledHistory(
            [unseen] + fullyKnownPage, current: backlog, pendingEchoes: &pending, position: .older)
        XCTAssertTrue(ChatStore.transcriptGainedRows(knownIDs: knownIDs, in: afterUnseen))
    }

    func testSendReloadAndLateStreamEchoPreserveEntireBacklog() {
        let backlog = (0..<250).map {
            Self.textMessage(
                id: "old-\($0)",
                role: $0.isMultiple(of: 2) ? "user" : "assistant",
                text: "message \($0)",
                timestamp: Double($0))
        }
        let optimistic = Self.textMessage(id: "local", role: "user", text: "new", timestamp: 251)
        var pending = [PendingEcho(id: optimistic.id, sentText: optimistic.text)]

        // A stale bounded tail can arrive after the optimistic bubble was published.
        var transcript = ChatStore.reconciledHistory(
            Array(backlog.suffix(200)),
            current: backlog + [optimistic],
            pendingEchoes: &pending)
        XCTAssertEqual(transcript.count, 251)
        XCTAssertEqual(transcript.first?.id, "old-0")
        XCTAssertEqual(transcript.last?.id, "local")

        // The eventual server echo replaces only the optimistic row, never the backlog.
        transcript = ChatStore.mergedMessages(
            transcript,
            incoming: Self.textMessage(id: "server-new", role: "user", text: "new", timestamp: 252),
            pendingEchoes: &pending)
        XCTAssertEqual(transcript.count, 251)
        XCTAssertEqual(transcript.first?.id, "old-0")
        XCTAssertEqual(transcript.last?.id, "server-new")
        XCTAssertTrue(pending.isEmpty)
    }

    func testFinishedStreamStaysVisibleUntilHistoryContainsAnswer() {
        let old = Self.textMessage(id: "old", role: "assistant", text: "old answer")
        let final = Self.textMessage(id: "final", role: "assistant", text: "new answer")

        XCTAssertFalse(ChatStore.transcriptContains(streamingText: "new answer", in: [old]))
        XCTAssertTrue(ChatStore.transcriptContains(streamingText: "new answer", in: [old, final]))
    }

    /// Reported double-text: a turn that streams text, runs tools, then streams more text leaves
    /// one concatenated buffer ("…both.Two real…"), while history stores the blocks as separate
    /// assistant messages. That buffer must still count as delivered, or the finished stream
    /// renders again above the stored reply.
    func testMultiBlockTurnClearsStreamAgainstSplitHistory() {
        let question = Self.textMessage(id: "ask", role: "user", text: "how do we enable screenshots?")
        let opener = Self.textMessage(id: "a1", role: "assistant", text: "Let me dig into both.")
        let answer = Self.textMessage(
            id: "a2",
            role: "assistant",
            text: "Two real findings. First, screenshots — the skill's env-var override was masking a host.")
        let streamed = "Let me dig into both.Two real findings. First, screenshots — "
            + "the skill's env-var override was masking a host."

        XCTAssertTrue(ChatStore.transcriptContains(
            streamingText: streamed,
            in: [question, opener, answer]))
        // Blocks stored inside one message are joined with a blank line the stream never sent.
        XCTAssertTrue(ChatStore.transcriptContains(
            streamingText: "First block.Second block.",
            in: [Self.textMessage(id: "a3", role: "assistant", text: "First block.\n\nSecond block.")]))
        // An answer that never reached history still holds the stream on screen.
        XCTAssertFalse(ChatStore.transcriptContains(
            streamingText: streamed,
            in: [question, opener]))
    }

    func testHistoryPaginationAndActiveRunMetadataDecode() throws {
        let payload = try JSONDecoder().decode(ChatHistoryPayload.self, from: Data(#"""
        {
          "sessionKey":"agent:main:main",
          "messages":[],
          "offset":0,
          "nextOffset":200,
          "hasMore":true,
          "totalMessages":425,
          "sessionInfo":{"hasActiveRun":true,"activeRunIds":["run-1"]},
          "inFlightRun":{"runId":"run-1","text":"partial"}
        }
        """#.utf8))

        XCTAssertEqual(payload.nextOffset, 200)
        XCTAssertEqual(payload.totalMessages, 425)
        XCTAssertEqual(payload.sessionInfo?.activeRunIds, ["run-1"])
        XCTAssertEqual(payload.inFlightRun?.text, "partial")
    }

    func testIdlessHistoryRowsReceiveStableFallbackIdentifiers() throws {
        let data = Data(#"{"messages":[{"role":"assistant","content":[{"type":"text","text":"hello"}],"timestamp":42}]}"#.utf8)
        let first = try JSONDecoder().decode(ChatHistoryPayload.self, from: data).decodedMessages()
        let second = try JSONDecoder().decode(ChatHistoryPayload.self, from: data).decodedMessages()

        XCTAssertEqual(first.first?.id, second.first?.id)
        XCTAssertTrue(first.first?.id.hasPrefix("msg-") == true)
    }

    /// Two byte-identical rows in one page used to hash to a single identifier, and
    /// `dedupedByID` then silently dropped the second one.
    func testIdenticalIdlessHistoryRowsKeepDistinctIdentifiers() throws {
        let row = #"{"role":"assistant","content":[{"type":"text","text":"ok"}],"timestamp":42}"#
        let data = Data(#"{"messages":[\#(row),\#(row)]}"#.utf8)
        let decoded = try JSONDecoder().decode(ChatHistoryPayload.self, from: data).decodedMessages()

        XCTAssertEqual(decoded.count, 2)
        XCTAssertNotEqual(decoded[0].id, decoded[1].id)
        XCTAssertEqual(ChatStore.dedupedByID(decoded).count, 2)
    }

    /// The scroll-reset regression: every history reconcile handed the same logical row a
    /// new identifier, `TranscriptGroup.id`/`ToolRun.id` changed with it, and `ForEach` read
    /// the transcript as a mass delete plus insert — resetting the scroll offset to the top.
    func testTranscriptIdentitySurvivesRepeatedHistoryReconciles() throws {
        let page = Data(#"""
        {"messages":[
          {"role":"user","content":[{"type":"text","text":"hi"}],"timestamp":1},
          {"role":"assistant","content":[{"type":"text","text":"hello"}],"timestamp":2}
        ]}
        """#.utf8)
        var pending: [PendingEcho] = []

        // Live events arrive first and are content-addressed on the same terms.
        let live = try JSONDecoder().decode(ChatHistoryPayload.self, from: page)
            .decodedMessages()
            .map { $0.identifiedByContent() }
        var transcript = ChatStore.reconciledHistory(live, current: [], pendingEchoes: &pending)
        let originalIDs = transcript.map(\.id)
        let originalItemIDs = TranscriptBuilder.items(from: transcript).map(\.id)

        // Session open, then the 20s watchdog reload: an in-place replacement each time.
        for _ in 0..<3 {
            let refreshed = try JSONDecoder().decode(ChatHistoryPayload.self, from: page).decodedMessages()
            transcript = ChatStore.reconciledHistory(
                refreshed,
                current: transcript,
                pendingEchoes: &pending)
        }

        XCTAssertEqual(transcript.count, 2)
        XCTAssertEqual(transcript.map(\.id), originalIDs)
        XCTAssertEqual(TranscriptBuilder.items(from: transcript).map(\.id), originalItemIDs)
    }

    /// Legacy caches hold rows keyed by the old random `UUID`. Reconciling must adopt the
    /// incumbent identifier rather than the page's, or those rows churn once per refresh.
    func testHistoryReconcileKeepsIncumbentIdentifierForContentMatchedRows() {
        let cachedUUIDRow = Self.textMessage(
            id: UUID().uuidString,
            role: "assistant",
            text: "cached",
            timestamp: 7)
        let historyRow = Self.textMessage(
            id: "msg-deadbeef",
            role: "assistant",
            text: "cached",
            timestamp: 7)
        var pending: [PendingEcho] = []

        let reconciled = ChatStore.reconciledHistory(
            [historyRow],
            current: [cachedUUIDRow],
            pendingEchoes: &pending)

        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled.first?.id, cachedUUIDRow.id)
    }

    func testOptimisticSendIdentifierIsContentAddressedNotRandom() {
        let blocks = [ChatContentBlock(
            type: "text",
            text: "ship it",
            thinking: nil,
            name: nil,
            mimeType: nil,
            fileName: nil)]
        let echo = ChatMessage(role: "user", blocks: blocks, timestamp: 99).identifiedByContent()
        let sameRowDecodedAgain = ChatMessage(role: "user", blocks: blocks, timestamp: 99)
            .identifiedByContent()

        XCTAssertEqual(echo.id, sameRowDecodedAgain.id)
        XCTAssertTrue(echo.id.hasPrefix("msg-"))
        XCTAssertNil(UUID(uuidString: echo.id))
    }

    func testLargeHistoryPageDecodeAndReconciliationStayBounded() throws {
        let rowCount = 6_000
        let current = (0..<rowCount).map {
            Self.textMessage(
                id: "message-\($0)",
                role: $0.isMultiple(of: 2) ? "user" : "assistant",
                text: "cached \($0)",
                timestamp: Double($0))
        }
        let refreshed = (0..<rowCount).map {
            Self.textMessage(
                id: "message-\($0)",
                role: $0.isMultiple(of: 2) ? "user" : "assistant",
                text: "refreshed \($0)",
                timestamp: Double($0))
        }
        var pending: [PendingEcho] = []
        let started = Date()

        let reconciled = ChatStore.reconciledHistory(
            refreshed,
            current: current,
            pendingEchoes: &pending)

        XCTAssertEqual(reconciled.count, rowCount)
        XCTAssertEqual(reconciled.first?.text, "refreshed 0")
        XCTAssertEqual(reconciled.last?.text, "refreshed \(rowCount - 1)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)

        let encodedPage = try JSONSerialization.data(withJSONObject: [
            "messages": (0..<1_000).map { index in
                [
                    "id": "decoded-\(index)",
                    "role": "assistant",
                    "content": [["type": "text", "text": "row \(index)"]],
                    "timestamp": index,
                ] as [String: Any]
            },
        ])
        let page = try ChatStore.decodeHistoryPage(encodedPage)
        XCTAssertEqual(page.messages.count, 1_000)
        XCTAssertEqual(page.messages.last?.id, "decoded-999")
    }

    func testStructuredStreamTextUsesSnapshotsAndDeltas() {
        XCTAssertEqual(
            ChatStore.mergedStreamText(
                current: "one",
                data: AnyCodable(["delta": AnyCodable(" two")])),
            "one two")
        XCTAssertEqual(
            ChatStore.mergedStreamText(
                current: "stale",
                data: AnyCodable(["text": AnyCodable("current")])),
            "current")
    }

    private static func textMessage(
        id: String,
        role: String,
        text: String,
        timestamp: Double? = 0) -> ChatMessage
    {
        ChatMessage(
            id: id,
            role: role,
            blocks: [ChatContentBlock(type: "text", text: text, thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: timestamp)
    }

    private static func event(_ name: String, payload: [String: Any]) throws -> EventFrame {
        let data = try JSONSerialization.data(withJSONObject: [
            "event": name,
            "payload": payload,
        ])
        return try JSONDecoder().decode(EventFrame.self, from: data)
    }

    func testAnyCodableIntValueRejectsOutOfRangeDoubles() throws {
        // Gateway numbers land as Double when they don't fit Int; intValue must
        // return nil instead of trapping on the conversion.
        let decoder = JSONDecoder()
        let huge = try decoder.decode(AnyCodable.self, from: Data("1e300".utf8))
        XCTAssertNil(huge.intValue)
        XCTAssertNil(AnyCodable(-1e300).intValue)
        XCTAssertNil(AnyCodable(Double.nan).intValue)
        XCTAssertNil(AnyCodable(Double.infinity).intValue)
        XCTAssertEqual(AnyCodable(12.4).intValue, 12)
        XCTAssertEqual(AnyCodable(42).intValue, 42)
    }

    func testTickWatchdogStaysDisarmedUntilTheSocketProvesItCarriesTicks() {
        // A gateway that never emits ticks left the seeded lastTick to age past tolerance,
        // so a healthy connection was declared dead every ~60s and cycled through a
        // reconnect plus full history reload. Silence only counts once a tick has arrived.
        XCTAssertFalse(GatewayClient.tickWatchdogShouldReconnect(
            hasObservedTick: false, msSinceLastTick: 600_000, toleranceMs: 60_000))
        XCTAssertFalse(GatewayClient.tickWatchdogShouldReconnect(
            hasObservedTick: true, msSinceLastTick: 30_000, toleranceMs: 60_000))
        XCTAssertTrue(GatewayClient.tickWatchdogShouldReconnect(
            hasObservedTick: true, msSinceLastTick: 61_000, toleranceMs: 60_000))
    }

    func testGatewayMsClampBoundsAndRejectsNonFinite() {
        XCTAssertEqual(GatewayClient.clampedMs(1e300, min: 250, max: 60_000), 60_000)
        XCTAssertEqual(GatewayClient.clampedMs(-5000, min: 250, max: 60_000), 250)
        XCTAssertEqual(GatewayClient.clampedMs(1500, min: 250, max: 60_000), 1500)
        XCTAssertNil(GatewayClient.clampedMs(.nan, min: 250, max: 60_000))
        XCTAssertNil(GatewayClient.clampedMs(.infinity, min: 250, max: 60_000))
    }

    func testHistoryFailurePolicyClassifiesTimeoutsAndBoundsRetries() {
        XCTAssertTrue(GatewayFailurePolicy.isRecoverable(GatewayTimeoutError(context: "chat.history request")))
        XCTAssertTrue(GatewayFailurePolicy.isRecoverable(URLError(.networkConnectionLost)))
        XCTAssertTrue(GatewayFailurePolicy.isRecoverable(GatewayRequestError(
            method: "chat.history",
            code: "UNAVAILABLE",
            message: "busy")))
        XCTAssertFalse(GatewayFailurePolicy.isRecoverable(GatewayRequestError(
            method: "chat.history",
            code: "AUTH_SCOPE_MISMATCH",
            message: "forbidden")))
        XCTAssertEqual(GatewayFailurePolicy.historyRetryDelayNanoseconds(attempt: 1), 1_000_000_000)
        XCTAssertEqual(GatewayFailurePolicy.historyRetryDelayNanoseconds(attempt: 2), 3_000_000_000)
        XCTAssertEqual(GatewayFailurePolicy.historyRetryDelayNanoseconds(attempt: 3), 8_000_000_000)
        XCTAssertNil(GatewayFailurePolicy.historyRetryDelayNanoseconds(attempt: 0))
        XCTAssertNil(GatewayFailurePolicy.historyRetryDelayNanoseconds(attempt: 4))
    }

    func testChatFailurePolicySuppressesInternalAbortDiagnostics() {
        XCTAssertNil(GatewayFailurePolicy.agentRunAlertMessage(for: "final", runAlreadyAnswered: false))
        XCTAssertNil(GatewayFailurePolicy.agentRunAlertMessage(for: "aborted", runAlreadyAnswered: false))
        XCTAssertNil(GatewayFailurePolicy.agentRunAlertMessage(for: "delta", runAlreadyAnswered: false))
    }

    func testChatFailurePolicyRetainsFriendlyActionableFailures() {
        let alert = GatewayFailurePolicy.agentRunAlertMessage(for: "error", runAlreadyAnswered: false)

        XCTAssertEqual(alert, GatewayFailurePolicy.agentRunAlert)
        XCTAssertEqual(
            GatewayFailurePolicy.messageSendAlert,
            "Your message couldn’t be sent. Check the connection and try again.")
        XCTAssertFalse(alert?.contains("rg: command not found") == true)
    }

    /// The reported event order on the real store: a streamed result reaches a successful
    /// chat final and is visible, then stale lifecycle/aborted/error terminals arrive for
    /// that same run. None may put a blocking failure over the valid answer.
    @MainActor
    func testAnsweredTurnSuppressesLateTerminalFailureModal() throws {
        let store = ChatStore()
        let sessionKey = "agent:main:answered"
        store.selectedSessionKey = sessionKey

        store.handleEvent(try Self.event("chat", payload: [
            "runId": "run-1", "sessionKey": sessionKey,
            "state": "delta", "deltaText": "The completed answer.",
        ]))
        store.handleEvent(try Self.event("chat", payload: [
            "runId": "run-1", "sessionKey": sessionKey, "state": "final",
        ]))
        XCTAssertEqual(store.streamingText, "The completed answer.")
        XCTAssertTrue(AgentTurnPresentation(
            isActive: store.isAgentTurnActive,
            showDetails: false,
            assistantText: store.streamingText,
            reasoningText: "",
            toolName: nil).shouldRender)

        store.handleEvent(try Self.event("agent", payload: [
            "runId": "run-1", "sessionKey": sessionKey,
            "stream": "lifecycle", "data": ["phase": "error", "error": "late timeout"],
        ]))
        store.handleEvent(try Self.event("chat", payload: [
            "runId": "run-1", "sessionKey": sessionKey, "state": "aborted",
        ]))
        store.handleEvent(try Self.event("chat", payload: [
            "runId": "run-1", "sessionKey": sessionKey,
            "state": "error", "errorMessage": "late timeout",
        ]))

        XCTAssertNil(store.lastError)
    }

    /// A bare lifecycle end is not enough to hide a later error: without a successful chat
    /// final, the turn is still unanswered and must surface the safe terminal alert.
    @MainActor
    func testUnansweredTerminalFailureStillSurfaces() throws {
        let store = ChatStore()
        let sessionKey = "agent:main:failed"
        store.selectedSessionKey = sessionKey

        store.handleEvent(try Self.event("agent", payload: [
            "runId": "run-2", "sessionKey": sessionKey,
            "stream": "lifecycle", "data": ["phase": "start"],
        ]))
        store.handleEvent(try Self.event("agent", payload: [
            "runId": "run-2", "sessionKey": sessionKey,
            "stream": "lifecycle", "data": ["phase": "end"],
        ]))
        store.handleEvent(try Self.event("chat", payload: [
            "runId": "run-2", "sessionKey": sessionKey,
            "state": "error", "errorMessage": "provider failed",
        ]))

        XCTAssertEqual(store.lastError, GatewayFailurePolicy.agentRunAlert)
    }

    /// Cross-run isolation: one turn's answer must not silence a different turn's real
    /// failure in the same conversation.
    @MainActor
    func testCrossRunErrorDoesNotInheritAnotherTurnsAnswer() throws {
        let store = ChatStore()
        let sessionKey = "agent:main:cross-run"
        store.selectedSessionKey = sessionKey

        store.handleEvent(try Self.event("chat", payload: [
            "runId": "run-answered", "sessionKey": sessionKey,
            "state": "final",
        ]))
        store.handleEvent(try Self.event("chat", payload: [
            "runId": "run-failed", "sessionKey": sessionKey,
            "state": "delta", "deltaText": "",
        ]))
        store.handleEvent(try Self.event("chat", payload: [
            "runId": "run-failed", "sessionKey": sessionKey,
            "state": "error", "errorMessage": "provider failed",
        ]))

        XCTAssertEqual(store.lastError, GatewayFailurePolicy.agentRunAlert)
    }

    func testShareInboxAtomicallyPersistsTextAndFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = try ShareInbox(root: root)
        let id = UUID()
        let request = try inbox.enqueue(
            workspaceID: "build",
            sessionKey: "agent:main:cast-dev",
            message: "context",
            items: [
                SharedItemInput(kind: .url, text: "https://example.com"),
                SharedItemInput(
                    kind: .file,
                    data: Data("document".utf8),
                    fileName: "brief.txt",
                    typeIdentifier: UTType.plainText.identifier),
            ],
            id: id,
            createdAt: Date(timeIntervalSince1970: 42))
        XCTAssertEqual(request.id, id)
        XCTAssertEqual(inbox.pending(), [request])
        XCTAssertEqual(request.items.map(\.kind), [.url, .file])
        let fileItem = try XCTUnwrap(request.items.first(where: { $0.kind == .file }))
        let fileURL = try XCTUnwrap(inbox.fileURL(for: fileItem, requestID: request.id))
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("document".utf8))
        try inbox.remove(request)
        XCTAssertTrue(inbox.pending().isEmpty)
    }

    func testShareDestinationSnapshotContainsNoGatewaySecrets() throws {
        let suite = "cast-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShareDestinationStore(defaults: defaults)
        let snapshot = ShareDestinationSnapshot(
            workspaces: [ShareWorkspaceDestination(
                id: "build",
                name: "Build",
                sessions: [ShareSessionDestination(key: "agent:main:main", name: "Main")])],
            selectedWorkspaceID: "build")
        store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
        let raw = try XCTUnwrap(defaults.data(forKey: "cast.share.destinations.v1"))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("wss://"))
    }

    func testShareInboxCopiesStagedFilesAndPreservesRoutingMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        try Data("from staged file".utf8).write(to: source, options: .atomic)
        let inbox = try ShareInbox(root: root)
        let request = try inbox.enqueue(
            workspaceID: "home",
            sessionKey: "agent:main:main",
            message: "",
            items: [SharedItemInput(
                kind: .file,
                sourceFileURL: source,
                fileName: "Original Notes.txt",
                typeIdentifier: UTType.plainText.identifier)])

        XCTAssertEqual(request.workspaceID, "home")
        XCTAssertEqual(request.sessionKey, "agent:main:main")
        let item = try XCTUnwrap(request.items.first)
        XCTAssertEqual(item.fileName, "Original Notes.txt")
        XCTAssertEqual(item.typeIdentifier, UTType.plainText.identifier)
        let storedURL = try XCTUnwrap(inbox.fileURL(for: item, requestID: request.id))
        XCTAssertEqual(try Data(contentsOf: storedURL), Data("from staged file".utf8))
        let prepared = try AttachmentProcessor.prepare(
            url: storedURL,
            originalFileName: item.fileName,
            typeIdentifier: item.typeIdentifier)
        XCTAssertEqual(prepared.fileName, "Original Notes.txt")
        XCTAssertEqual(prepared.mimeType, "text/plain")
    }

    func testShareDestinationResolverPrefersRecentThenCurrentConversation() {
        let snapshot = ShareDestinationSnapshot(
            workspaces: [
                ShareWorkspaceDestination(
                    id: "home",
                    name: "home",
                    sessions: [
                        ShareSessionDestination(key: "agent:main:direct:+15551234567", name: "Contact"),
                        ShareSessionDestination(key: "agent:main:main", name: "Main Session"),
                    ],
                    preferredSessionKey: "agent:main:main"),
                ShareWorkspaceDestination(
                    id: "build",
                    name: "build",
                    sessions: [ShareSessionDestination(key: "agent:main:cast-dev", name: "Cast")]),
            ],
            selectedWorkspaceID: "home")
        let recent = ShareDestinationSelection(
            workspaceID: "build",
            sessionKey: "agent:main:cast-dev")
        XCTAssertEqual(ShareDestinationResolver.resolve(snapshot: snapshot, recent: recent), recent)

        let stale = ShareDestinationSelection(workspaceID: "home", sessionKey: "agent:main:removed")
        XCTAssertEqual(
            ShareDestinationResolver.resolve(snapshot: snapshot, recent: stale),
            ShareDestinationSelection(workspaceID: "home", sessionKey: "agent:main:main"))
    }

    func testShareDestinationStoreRemembersSelectionSeparatelyFromSnapshot() throws {
        let suite = "cast-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShareDestinationStore(defaults: defaults)
        let snapshot = ShareDestinationSnapshot(
            workspaces: [ShareWorkspaceDestination(
                id: "home",
                name: "home",
                sessions: [ShareSessionDestination(key: "agent:main:main", name: "Main Session")])],
            selectedWorkspaceID: "home")
        store.save(snapshot)
        let selection = ShareDestinationSelection(workspaceID: "home", sessionKey: "agent:main:main")
        store.remember(selection)

        XCTAssertEqual(store.load(), snapshot)
        XCTAssertEqual(store.loadRecentSelection(), selection)
    }

    func testLegacyShareDestinationSnapshotDecodesWithoutPreferredSession() throws {
        let legacy = #"{"workspaces":[{"id":"home","name":"home","sessions":[{"key":"agent:main:main","name":"Main Session"}]}],"selectedWorkspaceID":"home"}"#
        let snapshot = try JSONDecoder().decode(ShareDestinationSnapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(snapshot.workspaces.first?.id, "home")
        XCTAssertNil(snapshot.workspaces.first?.preferredSessionKey)
    }

    func testQueuedShareRoutingIsExactAndNeverFallsBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try ShareInbox(root: root).enqueue(
            workspaceID: "home",
            sessionKey: "agent:main:main",
            message: "hello",
            items: [])
        XCTAssertEqual(
            ShareDestinationResolver.exactRoute(for: request, availableWorkspaceIDs: ["home", "build"]),
            ShareDestinationSelection(workspaceID: "home", sessionKey: "agent:main:main"))
        XCTAssertNil(ShareDestinationResolver.exactRoute(for: request, availableWorkspaceIDs: ["build"]))
    }

    func testSessionAliasesNormalizeAndMatch() {
        XCTAssertEqual(SessionKeyMatcher.canonical("main"), "agent:main:main")
        XCTAssertEqual(SessionKeyMatcher.canonical("cast-dev"), "agent:main:cast-dev")
        XCTAssertTrue(SessionKeyMatcher.matches("main", "agent:main:main"))
        XCTAssertFalse(SessionKeyMatcher.matches("agent:main:main", "agent:other:main"))
        XCTAssertEqual(SessionKeyMatcher.agentID(from: "agent:build:work"), "build")
    }

    func testDeviceSignaturePayloadIsExact() {
        let payload = GatewayDeviceAuthPayload.buildV3(
            deviceId: "device",
            clientId: "openclaw-ios",
            clientMode: "ui",
            role: "operator",
            scopes: ["operator.read", "operator.write"],
            signedAtMs: 42,
            token: "secret",
            nonce: "nonce",
            platform: " iOS ",
            deviceFamily: "iPhone")
        XCTAssertEqual(payload, "v3|device|openclaw-ios|ui|operator|operator.read,operator.write|42|secret|nonce|ios|iphone")
    }

    func testSetupCodeSafetyAndDecode() throws {
        let json = #"{"url":"wss://gateway.example.com","bootstrapToken":"boot","expiresAtMs":4102444800000}"#
        let code = Data(json.utf8).base64EncodedString()
        let decoded = try GatewaySetupPayload.decode(setupCode: code)
        XCTAssertEqual(decoded.bootstrapToken, "boot")
        XCTAssertEqual(decoded.url.host, "gateway.example.com")
        XCTAssertTrue(GatewaySetupPayload.isSafeBootstrapURL(URL(string: "ws://127.0.0.1:18789")!))
        XCTAssertTrue(GatewaySetupPayload.isSafeBootstrapURL(URL(string: "ws://192.168.1.5:18789")!))
        XCTAssertFalse(GatewaySetupPayload.isSafeBootstrapURL(URL(string: "ws://100.64.0.1:18789")!))
        XCTAssertNoThrow(try GatewaySetupPayload.validateManualURL("wss://gateway.example.com"))
        XCTAssertNoThrow(try GatewaySetupPayload.validateManualURL("ws://192.168.1.5:18789"))
        XCTAssertThrowsError(try GatewaySetupPayload.validateManualURL("ws://gateway.example.com")) { error in
            guard case PairingError.insecureRemoteURL = error else {
                return XCTFail("Expected insecure remote URL, got \(error)")
            }
        }
    }

    func testExpiredSetupCodeFailsClosed() {
        let json = #"{"url":"wss://gateway.example.com","bootstrapToken":"boot","expiresAtMs":1}"#
        XCTAssertThrowsError(try GatewaySetupPayload.decode(setupCode: Data(json.utf8).base64EncodedString())) { error in
            guard case PairingError.expiredCode = error else {
                return XCTFail("Expected an expired-code error, got \(error)")
            }
        }
    }

    func testMalformedSetupCodeUsesFriendlyInvalidCodeError() {
        let malformedJSON = Data(#"{"url":42,"bootstrapToken":false}"#.utf8).base64EncodedString()
        XCTAssertThrowsError(try GatewaySetupPayload.decode(setupCode: malformedJSON)) { error in
            guard case PairingError.invalidCode = error else {
                return XCTFail("Expected an invalid-code error, got \(error)")
            }
        }
    }

    func testFrameBudgetAccountsForBase64Expansion() throws {
        let safe = PreparedAttachment(type: "file", mimeType: "application/octet-stream", fileName: "safe.bin", data: Data(count: 1024))
        XCTAssertNoThrow(try AttachmentProcessor.validateFrame(message: "hello", attachments: [safe]))
        let oversized = PreparedAttachment(type: "file", mimeType: "application/octet-stream", fileName: "large.bin", data: Data(count: 19 * 1024 * 1024))
        XCTAssertGreaterThan(try AttachmentProcessor.frameByteCount(message: "hello", attachments: [oversized]), AttachmentProcessor.maxFrameBytes)
        XCTAssertTrue(try AttachmentProcessor.requiresUpload(message: "hello", attachments: [oversized]))
        XCTAssertNoThrow(try AttachmentProcessor.validateFrame(message: "hello", attachments: [oversized]))
    }

    func testImageProcessorProducesBoundedJPEG() throws {
        let width = 1400, height = 1000
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.95, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let result = try AttachmentProcessor.compressImage(png as Data)
        XCTAssertLessThanOrEqual(result.count, AttachmentProcessor.inlineImageTargetBytes)
        XCTAssertNotNil(CGImageSourceCreateWithData(result as CFData, nil))
    }

    func testPreparedPastedImageIsBoundedJPEG() throws {
        let width = 900, height = 700
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let attachment = try AttachmentProcessor.prepareImage(data: png as Data, fileName: "Pasted Image")
        XCTAssertEqual(attachment.type, "image")
        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertEqual(attachment.fileName, "Pasted Image.jpg")
        XCTAssertLessThanOrEqual(attachment.byteCount, AttachmentProcessor.inlineImageTargetBytes)
    }

    func testTranscriptCacheRoundTripAndSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(workspaceID: "test", root: root)
        let message = ChatMessage(
            id: "message-1",
            role: "assistant",
            blocks: [ChatContentBlock(type: "text", text: "The unique lobster verdict is green.", thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: 123)
        await cache.save([message], sessionKey: "agent:main:test")
        let loaded = await cache.load(sessionKey: "agent:main:test")
        XCTAssertEqual(loaded.first?.text, message.text)
        let hits = await cache.search("lobster")
        XCTAssertEqual(hits.first?.sessionKey, "agent:main:test")
        XCTAssertTrue(hits.first?.snippet.contains("lobster") == true)
    }

    func testTranscriptCachePersistsSharedImageCaptionMediaAndLink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(workspaceID: "test", root: root)
        let bytes = Data([4, 2, 4, 2])
        let message = ChatMessage(
            id: "shared-image",
            role: "user",
            blocks: [ChatContentBlock(type: "text", text: "review this https://example.com/photo", thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: 123,
            localImageData: [bytes])

        await cache.save([message], sessionKey: "agent:main:test")
        let loaded = await cache.load(sessionKey: "agent:main:test")

        XCTAssertEqual(loaded.first?.text, message.text)
        XCTAssertEqual(loaded.first?.localImageData, [bytes])
        XCTAssertEqual(LibraryScanner.media(in: loaded).first?.localData, bytes)
        XCTAssertEqual(LibraryScanner.links(in: loaded).first?.url.absoluteString, "https://example.com/photo")
    }

    func testTranscriptSearchRanksGloballyBeforeApplyingLimit() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(workspaceID: "test", root: root)
        await cache.save(
            [Self.textMessage(id: "scattered", role: "assistant", text: "alpha appears here and much later comes beta")],
            sessionKey: "agent:main:newer")
        let exact = ChatMessage(
            id: "exact",
            role: "assistant",
            blocks: [ChatContentBlock(type: "text", text: "alpha beta", thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: 1)
        await cache.save([exact], sessionKey: "agent:main:exact")

        let hits = await cache.search("alpha beta", limit: 1)
        XCTAssertEqual(hits.map(\.sessionKey), ["agent:main:exact"])
    }

    func testTranscriptSearchMatchesTokensDiacriticsAndUnsavedCurrentSession() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = TranscriptCache(workspaceID: "test", root: root)
        let current = Self.textMessage(id: "current", role: "user", text: "Résumé planning notes")
        let hits = await cache.search(
            "resume notes",
            includingSessionKey: "agent:main:current",
            currentMessages: [current])
        XCTAssertEqual(hits.map(\.sessionKey), ["agent:main:current"])
        XCTAssertEqual(hits.first?.matchedText?.lowercased(), "résumé")
    }
}

/// Stage-2 gateway event coverage: approvals (both families), restart notices, update
/// notices, and error-kind decoding. Payloads mirror the installed gateway's emitters, and
/// each handler also gets a malformed/missing-field payload because a fleet client always
/// runs against gateway versions it was not built for.
final class GatewayEventHandlingTests: XCTestCase {
    private static func event(_ name: String, payload: [String: Any]) throws -> EventFrame {
        let data = try JSONSerialization.data(withJSONObject: [
            "event": name,
            "payload": payload,
        ])
        return try JSONDecoder().decode(EventFrame.self, from: data)
    }

    // MARK: - Plugin approvals

    /// Mirrors `buildRequestedApprovalEvent` + `PluginApprovalRequestParams` in the
    /// installed dist, including the nulls the gateway emits for unset turn-source fields.
    @MainActor
    func testPluginApprovalRequestedRendersThroughTheExecApprovalPath() throws {
        let store = ChatStore()
        let expires = Date().timeIntervalSince1970 * 1000 + 60_000
        store.handleEvent(try Self.event("plugin.approval.requested", payload: [
            "id": "plugin:0b8ee149-9e0f-4a5e-8f7a-2f4f2f6f2f6f",
            "request": [
                "pluginId": "voice-call",
                "title": "Place outbound call",
                "description": "Call +1 (555) 010-4477 and read the morning brief.",
                "severity": "warn",
                "toolName": "voice_call",
                "toolCallId": "toolu_014zsA",
                "allowedDecisions": ["allow-once", "deny"],
                "agentId": "main",
                "sessionKey": "agent:main:main",
                "turnSourceChannel": NSNull(),
                "turnSourceTo": NSNull(),
            ],
            "createdAtMs": Date().timeIntervalSince1970 * 1000,
            "expiresAtMs": expires,
        ]))

        let approval = try XCTUnwrap(store.approvals.first)
        XCTAssertEqual(approval.kind, .plugin)
        XCTAssertEqual(approval.commandText, "Place outbound call")
        XCTAssertEqual(approval.request.pluginId, "voice-call")
        XCTAssertTrue(approval.allows(decision: "allow-once"))
        XCTAssertTrue(approval.allows(decision: "deny"))
        XCTAssertFalse(approval.allows(decision: "allow-always"))

        store.handleEvent(try Self.event("plugin.approval.resolved", payload: [
            "id": "plugin:0b8ee149-9e0f-4a5e-8f7a-2f4f2f6f2f6f",
            "decision": "allow-once",
            "ts": Date().timeIntervalSince1970 * 1000,
        ]))
        XCTAssertTrue(store.approvals.isEmpty)
    }

    @MainActor
    func testPluginApprovalWithMissingAndUnexpectedFieldsDoesNotCrashOrLinger() throws {
        let store = ChatStore()
        // Bare-minimum request from a newer gateway: no allowedDecisions, unknown extras.
        store.handleEvent(try Self.event("plugin.approval.requested", payload: [
            "id": "plugin:min",
            "request": [
                "title": "Do a thing",
                "futureField": ["nested": true],
            ],
            "unexpectedTopLevel": 7,
        ]))
        let approval = try XCTUnwrap(store.approvals.first(where: { $0.id == "plugin:min" }))
        XCTAssertEqual(approval.kind, .plugin)
        // No allowedDecisions means all three decisions stay offered.
        XCTAssertTrue(approval.allows(decision: "allow-always"))

        // A payload with no id/request cannot become a card, and must not crash.
        store.handleEvent(try Self.event("plugin.approval.requested", payload: ["noise": true]))
        XCTAssertEqual(store.approvals.count, 1)

        // Expired prompts are dead on arrival.
        store.handleEvent(try Self.event("plugin.approval.requested", payload: [
            "id": "plugin:expired",
            "request": ["title": "Too late"],
            "expiresAtMs": Date().timeIntervalSince1970 * 1000 - 1_000,
        ]))
        XCTAssertFalse(store.approvals.contains(where: { $0.id == "plugin:expired" }))
    }

    @MainActor
    func testExecApprovalStillDecodesAndDefaultsToExecKind() throws {
        let store = ChatStore()
        store.handleEvent(try Self.event("exec.approval.requested", payload: [
            "id": "exec:1",
            "request": [
                "command": "rm -rf build",
                "cwd": "/Users/developer/projects/cast",
                "host": "forge",
            ],
        ]))
        let approval = try XCTUnwrap(store.approvals.first)
        XCTAssertEqual(approval.kind, .exec)
        XCTAssertEqual(approval.commandText, "rm -rf build")
        XCTAssertTrue(approval.allows(decision: "allow-always"))
    }

    // MARK: - Abort

    @MainActor
    func testAbortWithoutClientOrActiveTurnIsANoOp() throws {
        let store = ChatStore()
        store.selectedSessionKey = "agent:main:idle"
        // No client and no active turn: nothing to do, nothing to crash, no error raised.
        store.abortActiveRun()
        XCTAssertFalse(store.isAbortingRun)
        XCTAssertNil(store.lastError)
    }
    // MARK: - Shutdown and update notices

    func testAnnouncedRestartRewritesDisconnectsUntilTheDeadline() {
        let now: Double = 1_785_000_000_000
        XCTAssertEqual(
            ChatStore.presentedConnectionState(
                .disconnected("Socket is not connected"),
                restartDeadlineMs: now + 20_000,
                nowMs: now),
            .disconnected("gateway restarting…"))
        // Past the gateway's own estimate the claim expires and the truth returns.
        XCTAssertEqual(
            ChatStore.presentedConnectionState(
                .disconnected("Socket is not connected"),
                restartDeadlineMs: now - 1,
                nowMs: now),
            .disconnected("Socket is not connected"))
        // Only disconnects are rewritten; a live connection is never masked.
        XCTAssertEqual(
            ChatStore.presentedConnectionState(
                .connected(mainSessionKey: "agent:main:main"),
                restartDeadlineMs: now + 20_000,
                nowMs: now),
            .connected(mainSessionKey: "agent:main:main"))
        XCTAssertEqual(
            ChatStore.presentedConnectionState(
                .disconnected("offline"), restartDeadlineMs: nil, nowMs: now),
            .disconnected("offline"))
    }

    @MainActor
    func testShutdownEventPresentsRestartImmediately() throws {
        let store = ChatStore()
        store.handleEvent(try Self.event("shutdown", payload: [
            "reason": "config-reload",
            "restartExpectedMs": 8_000,
        ]))
        XCTAssertEqual(store.connectionState, .disconnected("gateway restarting…"))

        // Missing restartExpectedMs (older gateway) still announces the restart.
        let bare = ChatStore()
        bare.handleEvent(try Self.event("shutdown", payload: ["reason": "update"]))
        XCTAssertEqual(bare.connectionState, .disconnected("gateway restarting…"))
    }

    func testUpdateNoticeDecodesAvailabilityRetractionAndGarbage() throws {
        func payload(_ json: String) throws -> AnyCodable {
            try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
        }
        XCTAssertEqual(
            ChatStore.updateNoticeText(from: try payload(
                #"{"updateAvailable":{"currentVersion":"2026.7.1-2","latestVersion":"2026.8.1","channel":"stable"}}"#)),
            "Gateway update available: 2026.8.1")
        // Shape drift downgrades to the generic line instead of dropping the event.
        XCTAssertEqual(
            ChatStore.updateNoticeText(from: try payload(#"{"updateAvailable":{"note":"soon"}}"#)),
            "A gateway update is available.")
        // Null retracts the notice (check ran clean / update applied).
        XCTAssertNil(ChatStore.updateNoticeText(from: try payload(#"{"updateAvailable":null}"#)))
        XCTAssertNil(ChatStore.updateNoticeText(from: try payload(#"{"unrelated":true}"#)))
        XCTAssertNil(ChatStore.updateNoticeText(from: nil))
    }

    // MARK: - Error kinds

    func testErrorKindsProduceSpecificActionableMessages() {
        XCTAssertEqual(
            GatewayFailurePolicy.agentRunAlertMessage(
                for: "error", errorKind: "refusal", runAlreadyAnswered: false),
            "The model declined to complete this request. Rephrase it and try again.")
        XCTAssertEqual(
            GatewayFailurePolicy.agentRunAlertMessage(
                for: "error", errorKind: "timeout", runAlreadyAnswered: false),
            "The run timed out before it could finish. Check the conversation and completed actions before retrying.")
        XCTAssertEqual(
            GatewayFailurePolicy.agentRunAlertMessage(
                for: "error", errorKind: "rate_limit", runAlreadyAnswered: false),
            "The provider is rate limiting this workspace. Wait for the limit to reset, then review the conversation before retrying.")
        XCTAssertEqual(
            GatewayFailurePolicy.agentRunAlertMessage(
                for: "error", errorKind: "context_length", runAlreadyAnswered: false),
            GatewayFailurePolicy.contextLengthAlert)
        // Unknown and future kinds degrade to the generic alert; nothing is dropped.
        XCTAssertEqual(
            GatewayFailurePolicy.agentRunAlertMessage(
                for: "error", errorKind: "unknown", runAlreadyAnswered: false),
            GatewayFailurePolicy.agentRunAlert)
        XCTAssertEqual(
            GatewayFailurePolicy.agentRunAlertMessage(
                for: "error", errorKind: "some_future_kind", runAlreadyAnswered: false),
            GatewayFailurePolicy.agentRunAlert)
        // An answered run stays quiet regardless of kind, and non-error states never alert.
        XCTAssertNil(GatewayFailurePolicy.agentRunAlertMessage(
            for: "error", errorKind: "refusal", runAlreadyAnswered: true))
        XCTAssertNil(GatewayFailurePolicy.agentRunAlertMessage(
            for: "aborted", errorKind: "timeout", runAlreadyAnswered: false))
    }

    @MainActor
    func testContextLengthErrorOffersOneTapCompactionAndClearsWithTheAlert() throws {
        let store = ChatStore()
        store.handleEvent(try Self.event("cast.hello", payload: ["features": ["methods": ["sessions.compact"]]]))
        let sessionKey = "agent:main:overflow"
        store.selectedSessionKey = sessionKey

        store.handleEvent(try Self.event("chat", payload: [
            "runId": "run-ctx", "sessionKey": sessionKey, "seq": 4,
            "state": "error", "errorKind": "context_length",
            "errorMessage": "prompt exceeds context window", "stopReason": "error",
        ]))

        XCTAssertEqual(store.lastError, GatewayFailurePolicy.contextLengthAlert)
        XCTAssertEqual(store.contextCompactionOfferKey, sessionKey)

        store.clearError()
        XCTAssertNil(store.contextCompactionOfferKey)

        // A non-context error must not leave a stale compact offer behind.
        store.handleEvent(try Self.event("chat", payload: [
            "runId": "run-rate", "sessionKey": sessionKey,
            "state": "error", "errorKind": "rate_limit",
        ]))
        XCTAssertNil(store.contextCompactionOfferKey)
    }

    // MARK: - Session token counts

    func testSessionRowDecodesTokenCountsAndComputesContextFill() throws {
        let row = try JSONDecoder().decode(SessionRow.self, from: Data(#"""
        {
          "key": "agent:main:main",
          "updatedAt": 1785163097000,
          "inputTokens": 154000,
          "outputTokens": 6200,
          "totalTokens": 160200,
          "contextTokens": 200000,
          "totalTokensFresh": true
        }
        """#.utf8))
        XCTAssertEqual(row.totalTokens, 160_200)
        XCTAssertEqual(row.contextTokens, 200_000)
        XCTAssertEqual(try XCTUnwrap(row.contextFillFraction), 0.801, accuracy: 0.0001)

        // Fraction clamps: right before a compaction total can exceed the window.
        let over = try JSONDecoder().decode(SessionRow.self, from: Data(
            #"{"key":"k","totalTokens":230000,"contextTokens":200000}"#.utf8))
        XCTAssertEqual(over.contextFillFraction, 1)

        // Missing or malformed counts yield nil, never a trap or a bogus percentage.
        let missing = try JSONDecoder().decode(SessionRow.self, from: Data(#"{"key":"k"}"#.utf8))
        XCTAssertNil(missing.contextFillFraction)
        let malformed = try JSONDecoder().decode(SessionRow.self, from: Data(
            #"{"key":"k","totalTokens":"lots","contextTokens":0}"#.utf8))
        XCTAssertNil(malformed.contextFillFraction)
    }
}

final class ComposerModelStatusTests: XCTestCase {
    func testUsesExactSessionModelWithoutAssumingProviderOrReasoningEffort() {
        XCTAssertEqual(ComposerModelStatus(model: " openai/gpt-6-astra ", isConnected: true).label,
                       "Model: openai/gpt-6-astra")
        XCTAssertEqual(ComposerModelStatus(model: "claude-opus-5", isConnected: true).label,
                       "Model: claude-opus-5")
    }

    func testMissingModelNeverClaimsTheGatewayDefault() {
        for model in [nil, "", "  \n"] as [String?] {
            XCTAssertEqual(ComposerModelStatus(model: model, isConnected: true).label,
                           "Model: unavailable")
        }
    }

    func testDisconnectedModelIsExplicitlyStale() {
        let status = ComposerModelStatus(model: "gpt-6-astra", isConnected: false)
        XCTAssertEqual(status.label, "Model: gpt-6-astra · Offline")
        XCTAssertTrue(status.help.contains("Last reported"))
        XCTAssertEqual(ComposerModelStatus(model: nil, isConnected: false).label,
                       "Model: unavailable · Offline")
    }
}
