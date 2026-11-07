import Foundation
import XCTest
@testable import Cast

final class ContinuityTests: XCTestCase {
    @MainActor
    func testOldConnectionCannotReplaceSidebarAfterSuspension() async {
        let store = ChatStore(transcriptCacheRoot: root(), operationsLedgerRoot: root())
        await store.refreshSessions {
            store.suspendForBackground()
            return Data(#"{"sessions":[{"key":"old-gateway-session","label":"Stale"}]}"#.utf8)
        }
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.selectedSessionKey)
    }

    func testOutboxCannotOverwriteAnIdempotencyKeysOriginalPayload() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = SendOutbox(root: directory)
        let original = StoredSend(sessionKey: "a", idempotencyKey: "same", context: PendingSendContext(text: "original", attachments: [], deliver: false), createdAt: Date())
        try await outbox.save(original)
        try await outbox.save(original) // An identical retry is allowed.
        let changed = StoredSend(sessionKey: "b", idempotencyKey: "same", context: PendingSendContext(text: "changed", attachments: [], deliver: true), createdAt: Date())
        do { try await outbox.save(changed); XCTFail("Overwrote an existing send's identity") } catch {}
        let retained = try await outbox.load("same", sessionKey: "a")
        XCTAssertEqual(retained.context.text, "original")
        XCTAssertFalse(retained.context.deliver)
    }

    @MainActor
    func testComposerFilesStayWithTheirOriginalConversation() {
        let store = ChatStore(transcriptCacheRoot: root(), operationsLedgerRoot: root())
        store.selectedSessionKey = "a"
        let attachment = PreparedAttachment(type: "file", mimeType: "text/plain", fileName: "private.txt", data: Data("a".utf8))
        store.addAttachments([attachment])
        store.selectedSessionKey = "b"
        XCTAssertTrue(store.pendingAttachments.isEmpty)
        store.selectedSessionKey = "a"
        XCTAssertEqual(store.pendingAttachments, [attachment])
        let target = store.attachmentDraftTarget
        store.selectedSessionKey = "b"
        store.finishAttachmentPreparation(.success(attachment), target: target)
        XCTAssertTrue(store.pendingAttachments.isEmpty)
        store.selectedSessionKey = "a"
        XCTAssertEqual(store.pendingAttachments.count, 2)
    }

    @MainActor
    func testPartialApprovalRefreshKeepsFailedFamilyAndLiveEvents() async throws {
        let store = ChatStore(transcriptCacheRoot: root(), operationsLedgerRoot: root())
        func event(_ name: String, _ id: String) throws -> EventFrame {
            try JSONDecoder().decode(EventFrame.self, from: JSONSerialization.data(withJSONObject: ["type":"event", "event":name, "payload":["id":id,"request":["command":"echo test"]]]))
        }
        store.handleEvent(try event("plugin.approval.requested", "keep"))
        await store.refreshApprovals { method in
            if method == "plugin.approval.list" { throw URLError(.notConnectedToInternet) }
            return Data("[]".utf8)
        }
        XCTAssertEqual(store.approvals.map(\.id), ["keep"])
        await store.refreshApprovals { _ in
            store.handleEvent(try event("exec.approval.requested", "new"))
            return Data("[]".utf8)
        }
        XCTAssertTrue(store.approvals.contains { $0.id == "new" })
    }

    @MainActor
    func testApprovalRefreshRetriesWhenLiveEventRacesNonemptySnapshot() async throws {
        let store = ChatStore(transcriptCacheRoot: root(), operationsLedgerRoot: root())
        var calls = 0
        await store.refreshApprovals { method in
            if method == "plugin.approval.list" { return Data("[]".utf8) }
            calls += 1
            if calls == 1 {
                store.handleEvent(try JSONDecoder().decode(EventFrame.self, from: Data(#"{"type":"event","event":"exec.approval.requested","payload":{"id":"B","request":{"command":"B"}}}"#.utf8)))
                return Data(#"[{"id":"A","request":{"command":"A"}}]"#.utf8)
            }
            return Data(#"[{"id":"A","request":{"command":"A"}},{"id":"B","request":{"command":"B"}}]"#.utf8)
        }
        XCTAssertEqual(Set(store.approvals.map(\.id)), ["A", "B"])
        XCTAssertEqual(calls, 2)
    }

    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
    private func attachment() -> PreparedAttachment {
        PreparedAttachment(type: "file", mimeType: "application/pdf", fileName: "QA packet.pdf", data: Data([0, 255, 12, 0, 75]))
    }

    func testOutboxPreservesExactFileAndExternalDeliveryAcrossRestart() async throws {
        let directory = root()
        let context = PendingSendContext(text: "Please review", attachments: [attachment()], deliver: true)
        let saved = StoredSend(sessionKey: "agent:a:chat", idempotencyKey: "same-request", context: context, createdAt: Date())
        try await SendOutbox(root: directory).save(saved)
        let restored = try await SendOutbox(root: directory).load("same-request", sessionKey: "agent:a:chat")
        XCTAssertEqual(restored.context.text, context.text)
        XCTAssertEqual(restored.context.attachments, context.attachments)
        XCTAssertTrue(restored.context.deliver)
        XCTAssertEqual(restored.idempotencyKey, "same-request")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testOutboxRefusesOtherWorkspaceOrSessionAndRemovesAcknowledgedPayload() async throws {
        let directory = root(); let outbox = SendOutbox(root: directory)
        try await outbox.save(StoredSend(sessionKey: "a", idempotencyKey: "key", context: PendingSendContext(text: "x", attachments: [], deliver: false), createdAt: Date()))
        do { _ = try await outbox.load("key", sessionKey: "b"); XCTFail("cross-session replay") } catch {}
        do { _ = try await SendOutbox(root: root()).load("key", sessionKey: "a"); XCTFail("cross-workspace replay") } catch {}
        await outbox.remove("key")
        do { _ = try await outbox.load("key", sessionKey: "a"); XCTFail("acknowledged send still retained") } catch {}
    }

    func testOutboxDiskFailureDoesNotPretendToSave() async throws {
        let file = root(); try Data().write(to: file)
        do {
            try await SendOutbox(root: file).save(StoredSend(sessionKey: "a", idempotencyKey: "key", context: PendingSendContext(text: "x", attachments: [], deliver: false), createdAt: Date()))
            XCTFail("write must fail before any send")
        } catch {}
    }

    func testPendingCachedSendBecomesUnconfirmedAfterRestart() async throws {
        let cache = TranscriptCache(workspaceID: "restart", root: root())
        let message = ChatMessage(role: "user", blocks: [ChatContentBlock(type: "text", text: "request", thinking: nil, name: nil, mimeType: nil, fileName: nil)], timestamp: 1000, localDeliveryState: .pending, localIdempotencyKey: "unchanged")
        await cache.save([message], sessionKey: "a")
        let messages = await cache.load(sessionKey: "a")
        XCTAssertEqual(messages.first?.localDeliveryState, .uncertain)
        XCTAssertEqual(messages.first?.localIdempotencyKey, "unchanged")
    }

    func testAuthoritativeEchoResolvesUnconfirmedBubbleWithoutDuplicating() {
        let local = ChatMessage(id: "local", role: "user", blocks: [ChatContentBlock(type: "text", text: "hello", thinking: nil, name: nil, mimeType: nil, fileName: nil)], timestamp: 1000, localDeliveryState: .uncertain, localIdempotencyKey: "same")
        let incoming = ChatMessage(id: "gateway", role: "user", blocks: local.blocks, timestamp: 1000)
        var pending: [PendingEcho] = []
        let merged = ChatStore.reconciledHistory([incoming], current: [local], pendingEchoes: &pending)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.localDeliveryState, .delivered)
    }

    func testWireRequestIdentityReconcilesAfterRestartDespiteDifferentTimestamp() throws {
        let local = ChatMessage(id: "local", role: "user", blocks: [ChatContentBlock(type: "text", text: "hello", thinking: nil, name: nil, mimeType: nil, fileName: nil)], timestamp: 1000,
            localDeliveryState: .uncertain, localIdempotencyKey: "request-1")
        let wire = try decode(ChatMessage.self, #"{"id":"server","role":"user","content":"hello","timestamp":2345,"idempotencyKey":"request-1:user"}"#)
        XCTAssertEqual(wire.gatewayRequestID, "request-1")
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(wire)).gatewayRequestID, "request-1")
        var pending: [PendingEcho] = []
        let merged = ChatStore.reconciledHistory([wire], current: [local], pendingEchoes: &pending)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.localDeliveryState, .delivered)
        XCTAssertEqual(merged.first?.id, "local")
        let live = ChatStore.mergedMessages([local], incoming: wire, pendingEchoes: &pending)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.localDeliveryState, .delivered)
    }

    func testAcknowledgementCannotRetireAnotherSessionsSend() async throws {
        let outbox = SendOutbox(root: root())
        try await outbox.save(StoredSend(sessionKey: "a", idempotencyKey: "key", context: PendingSendContext(text: "x", attachments: [], deliver: false), createdAt: Date()))
        await outbox.acknowledge(["key"], sessionKey: "b")
        let stillPresent = try await outbox.load("key", sessionKey: "a")
        XCTAssertEqual(stillPresent.sessionKey, "a")
        await outbox.acknowledge(["key"], sessionKey: "a")
        do { _ = try await outbox.load("key", sessionKey: "a"); XCTFail("Confirmed payload still retained") } catch {}
    }

    func testArtifactDownloadUsesIdentityAndRejectsForeignSession() throws {
        let artifacts = try decode([GatewayArtifact].self, #"[{"id":"artifact_1","type":"file","title":"QA.zip","sessionKey":"a","sizeBytes":4,"download":{"mode":"url"}},{"id":"artifact_2","type":"file","title":"private.pdf","sessionKey":"b","download":{"mode":"bytes"}}]"#)
        var ledger = DeliverableLedger()
        ledger.ingest(artifacts: artifacts, sessionKey: "a")
        ledger.ingest(artifacts: artifacts, sessionKey: "a")
        XCTAssertEqual(ledger.items.count, 1)
        XCTAssertEqual(ledger.items.first?.artifactID, "artifact_1")
        XCTAssertEqual(ledger.items.first?.sizeBytes, 4)
        let roundTrip = try JSONDecoder().decode(DeliverableLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(roundTrip, ledger)
    }

    func testArtifactTransferRejectsCredentialsUntrustedSchemesAndDowngrades() throws {
        let gateway = URL(string: "wss://gateway.test:18789")!
        for raw in ["file:///etc/passwd", "https://u:p@host.test/file", "//other.test/file", "http://evil.test/file", "/etc/passwd", "javascript:alert(1)"] {
            XCTAssertThrowsError(try ArtifactTransferPolicy.url(raw, gateway: gateway), raw)
        }
        XCTAssertEqual(try ArtifactTransferPolicy.url("/api/attachments/file", gateway: gateway).absoluteString, "https://gateway.test:18789/api/attachments/file")
        XCTAssertEqual(try ArtifactTransferPolicy.url("https://files.test/report.zip", gateway: gateway).host, "files.test")
        XCTAssertThrowsError(try ArtifactTransferPolicy.url("http://gateway.test:18789/file", gateway: gateway))
    }

    func testArtifactBytesRejectInvalidBase64AndSizeMismatch() throws {
        let bytes = try decode(AnyCodable.self, #"{"encoding":"base64","data":"AAEC/w=="}"#)
        XCTAssertEqual(try ArtifactTransferPolicy.bytes(bytes, expectedSize: 4), Data([0,1,2,255]))
        XCTAssertThrowsError(try ArtifactTransferPolicy.bytes(bytes, expectedSize: 5))
        XCTAssertThrowsError(try ArtifactTransferPolicy.bytes(AnyCodable(["encoding": "base64", "data": "not base64"]), expectedSize: nil))
        XCTAssertThrowsError(try ArtifactTransferPolicy.validateSize(ArtifactTransferPolicy.maximumBytes + 1, expected: nil))
    }

    func testDownloadedFilePersistsWithCorrectNameAndRevisionIsolation() throws {
        let directory = root()
        var item = Deliverable(id: "a", sessionKey: "chat", messageID: "m1", title: "QA report", target: "artifact:a", kind: "Document", sharedAt: 1)
        item.artifactID = "a"; item.mimeType = "application/pdf"
        let bytes = Data([0,1,2,255])
        let url = try DeliverableFileCache(root: directory).save(bytes, for: item)
        XCTAssertEqual(url.lastPathComponent, "QA report.pdf")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNotNil(DeliverableFileCache(root: directory).existing(item))
        XCTAssertNil(DeliverableFileCache(root: root()).existing(item))
        let revised = Deliverable(id: "a", sessionKey: "chat", messageID: "m2", title: "QA report", target: "artifact:a", kind: "Document", sharedAt: 2)
        XCTAssertNil(DeliverableFileCache(root: directory).existing(revised))
        XCTAssertEqual(ArtifactTransferPolicy.safeFilename("../../secret.zip"), "secret.zip")
        XCTAssertEqual(ArtifactTransferPolicy.safeFilename(".."), "download")
    }

    func testSearchCombinesKindsDeduplicatesAndHonorsHiddenChats() {
        let items = [
            OperationsSearchResult(id: "a", kind: .conversation, title: "Family Central", detail: "QA", sessionKey: "a", messageID: nil, referenceID: nil, source: "Session list"),
            OperationsSearchResult(id: "b", kind: .deliverable, title: "Family Central QA.zip", detail: "Package", sessionKey: "b", messageID: nil, referenceID: "doc", source: "Deliverables"),
            OperationsSearchResult(id: "c", kind: .message, title: "Other conversation", detail: "Family Central review", sessionKey: "c", messageID: "message", referenceID: nil, source: "Gateway history")
        ]
        let all = OperationsSearch.ranked(items + items, query: "Family Central", hidden: ["b"], includeHidden: true)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(Set(all.map(\.kind)), [.conversation, .deliverable, .message])
        XCTAssertEqual(OperationsSearch.ranked(items, query: "Family Central", hidden: ["b"], includeHidden: false).count, 2)
        XCTAssertTrue(OperationsSearch.ranked(items, query: "unrelated", hidden: [], includeHidden: true).isEmpty)
    }

    func testDeepSearchKeepsEagerTranscriptBounded() {
        for index in [0, 100, 50000, 99999] {
            let range = TranscriptWindow.searchRange(index: index, total: 100000)
            XCTAssertTrue(range.contains(index))
            XCTAssertLessThanOrEqual(range.count, 200)
            XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
            XCTAssertLessThanOrEqual(range.upperBound, 100000)
        }
        XCTAssertTrue(TranscriptWindow.searchRange(index: 0, total: 0).isEmpty)
    }

    func testTaskActionsDependOnRealStateAndDeliveryFailure() throws {
        let active = try decode(GatewayTask.self, #"{"id":"a","status":"running","sessionKey":"parent","childSessionKey":"child","deliveryStatus":"pending"}"#)
        XCTAssertTrue(active.isActive); XCTAssertFalse(active.canRetryDelivery); XCTAssertEqual(active.conversationKey, "child")
        let failed = try decode(GatewayTask.self, #"{"id":"b","status":"failed","deliveryStatus":"delivered"}"#)
        XCTAssertFalse(failed.isActive); XCTAssertFalse(failed.canRetryDelivery)
        let delivery = try decode(GatewayTask.self, #"{"id":"c","status":"completed","deliveryStatus":"failed","result":"Done"}"#)
        XCTAssertTrue(delivery.canRetryDelivery); XCTAssertEqual(delivery.result, "Done")
        let unknown = try decode(GatewayTask.self, #"{"id":"d","status":"future-state"}"#)
        XCTAssertFalse(unknown.isActive); XCTAssertFalse(unknown.canRetryDelivery)
    }

    @MainActor
    func testUnsupportedGatewayControlsFailClosed() async throws {
        let store = ChatStore(profile: WorkspaceProfile(id: "test", name: "Test", gatewayURL: URL(string: "ws://127.0.0.1:1")!, accent: "blue"), operationsLedgerRoot: root())
        do { _ = try await store.taskDetail("a"); XCTFail("unsupported task request") } catch {}
        do { _ = try await store.remoteOperationsSearch("query"); XCTFail("unsupported search") } catch {}
        XCTAssertTrue(store.gatewayMethods.isEmpty)
    }
}
