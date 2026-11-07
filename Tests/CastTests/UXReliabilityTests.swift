import Foundation
import XCTest
@testable import Cast

final class UXReliabilityTests: XCTestCase {
    private func item(_ id: String = "one") -> Deliverable {
        Deliverable(id: id, sessionKey: "a", messageID: "m", title: "Report.txt", target: "/report.txt", kind: "Document", sharedAt: nil)
    }
    @MainActor func testDownloadCancellationDoesNotLetOldAttemptReplaceRetry() async {
        let center = DownloadCenter(), file = item()
        var first: CheckedContinuation<URL, Never>?
        var second: CheckedContinuation<URL, Never>?
        center.start(file) { progress in
            await progress(10, 20)
            return await withCheckedContinuation { first = $0 }
        }
        while first == nil { await Task.yield() }
        XCTAssertEqual(center.entry(for: file)?.received, 10)
        center.start(file) { _ in XCTFail("Duplicate transfer started"); return URL(fileURLWithPath: "/bad") }
        XCTAssertEqual(center.activeCount, 1)
        center.cancel(file)
        XCTAssertEqual(center.entry(for: file)?.phase, .cancelled)
        center.start(file) { _ in await withCheckedContinuation { second = $0 } }
        while second == nil { await Task.yield() }
        first?.resume(returning: URL(fileURLWithPath: "/old"))
        await Task.yield()
        XCTAssertEqual(center.entry(for: file)?.phase, .downloading)
        second?.resume(returning: URL(fileURLWithPath: "/new"))
        while center.activeCount > 0 { await Task.yield() }
        XCTAssertEqual(center.entry(for: file)?.phase, .saved(URL(fileURLWithPath: "/new")))
    }
    @MainActor func testDownloadScopeResetRejectsLateCacheLookupAndTransfer() async {
        let center = DownloadCenter(), file = item()
        await center.inspect(file) {
            center.reset()
            return URL(fileURLWithPath: "/old-workspace")
        }
        XCTAssertTrue(center.entries.isEmpty)
        var finish: CheckedContinuation<URL, Never>?
        center.start(file) { _ in await withCheckedContinuation { finish = $0 } }
        while finish == nil { await Task.yield() }
        center.reset()
        finish?.resume(returning: URL(fileURLWithPath: "/old-transfer"))
        await Task.yield()
        XCTAssertTrue(center.entries.isEmpty)
    }
    @MainActor func testDownloadCacheChecksMissingFileAndPreservesNewAttempt() async {
        let center = DownloadCenter(), file = item()
        await center.inspect(file) { URL(fileURLWithPath: "/cached") }
        XCTAssertNotNil(center.entry(for: file))
        await center.inspect(file) { nil }
        XCTAssertNil(center.entry(for: file))
        await center.inspect(file) {
            center.start(file) { _ in throw URLError(.notConnectedToInternet) }
            return URL(fileURLWithPath: "/stale-cache")
        }
        while center.activeCount > 0 { await Task.yield() }
        if case .failed = center.entry(for: file)?.phase {} else { XCTFail("Stale cache replaced attempt") }
    }
    @MainActor func testApprovalDoesNotSubmitTwiceAndLostAckIsNotSuccess() async throws {
        let store = ChatStore(transcriptCacheRoot: temp(), operationsLedgerRoot: temp())
        store.handleEvent(try JSONDecoder().decode(EventFrame.self, from: Data(#"{"type":"event","event":"exec.approval.requested","payload":{"id":"A","request":{"command":"A"}}}"#.utf8)))
        var calls = 0
        await store.resolveApproval(id: "A", decision: "allow-once") { _, _ in
            calls += 1
            XCTAssertEqual(store.approvalActivity["A"]?.state, .submitting)
            await store.resolveApproval(id: "A", decision: "allow-once") { _, _ in calls += 1 }
            throw URLError(.timedOut)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.approvalActivity["A"]?.state, .uncertain)
        await store.resolveApproval(id: "A", decision: "deny") { _, _ in calls += 1 }
        XCTAssertEqual(calls, 1)
        await store.refreshApprovals { method in
            Data((method == "exec.approval.list" ? #"[{"id":"A","request":{"command":"A"}}]"# : "[]").utf8)
        }
        await store.resolveApproval(id: "A", decision: "deny") { _, _ in calls += 1 }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.approvalActivity["A"]?.state, .confirmed)
        XCTAssertTrue(store.approvals.isEmpty)
    }
    @MainActor func testGatewayChangeClearsOldApprovalsAndDownloads() async throws {
        let store = ChatStore(transcriptCacheRoot: temp(), operationsLedgerRoot: temp())
        store.handleEvent(try JSONDecoder().decode(EventFrame.self, from: Data(#"{"type":"event","event":"exec.approval.requested","payload":{"id":"A","request":{"command":"A"}}}"#.utf8)))
        await store.downloads.inspect(item()) { URL(fileURLWithPath: "/cache") }
        var profile = store.profile
        profile.gatewayURL = URL(string: "wss://different.invalid")!
        store.update(profile: profile)
        XCTAssertTrue(store.approvals.isEmpty)
        XCTAssertTrue(store.approvalActivity.isEmpty)
        XCTAssertTrue(store.downloads.entries.isEmpty)
    }
    func testNavigationBookmarksAndSearchStayBounded() {
        var navigation = TranscriptNavigation()
        navigation.remember(.item("original")); navigation.remember(.item("search"))
        XCTAssertEqual(navigation.takeReturn(), .item("original"))
        XCTAssertNil(navigation.takeReturn())
        navigation.remember(.latest); navigation.reset(); XCTAssertNil(navigation.returnPlace)
        let items: [TranscriptItem] = (0..<500).map { index in
            let message = ChatMessage(id: "\(index)", role: index % 2 == 0 ? "assistant" : "user", blocks: [ChatContentBlock(type: "text", text: "Find this", thinking: nil, name: nil, mimeType: nil, fileName: nil)], timestamp: nil)
            return .group(TranscriptGroup(id: "g\(index)", role: message.role, messages: [message], date: nil))
        }
        XCTAssertEqual(TranscriptNavigation.matches(items, query: "find").count, 200)
        XCTAssertTrue(TranscriptNavigation.matches(items, query: " ").isEmpty)
        XCTAssertEqual(TranscriptNavigation.latestReply(items), "g498")
        XCTAssertLessThanOrEqual(TranscriptWindow.searchRange(index: 250, total: 500).count, 200)
    }
    func testConnectedCopyDoesNotClaimMessageConfirmation() {
        XCTAssertTrue(ConnectionPresentation.detail(.connected(mainSessionKey: nil), unconfirmed: 1).contains("still need gateway confirmation"))
        XCTAssertTrue(ConnectionPresentation.detail(.disconnected(nil), unconfirmed: 0).contains("Nothing is resent automatically"))
    }
    private func temp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
}
