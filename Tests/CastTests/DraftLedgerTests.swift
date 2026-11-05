import Foundation
import XCTest
@testable import Cast

final class DraftLedgerTests: XCTestCase {
    func testRoundTripThroughAtomicStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastDraftLedger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AtomicJSONLedgerStore<DraftLedger>(
            fileURL: root.appendingPathComponent("drafts.json"))

        var ledger = DraftLedger()
        XCTAssertTrue(ledger.setDraft("half-written reply", forSession: "agent:main:main"))
        try store.save(ledger)

        let restored = try store.load(defaultValue: DraftLedger())
        XCTAssertEqual(restored.draft(forSession: "agent:main:main"), "half-written reply")
        XCTAssertEqual(restored, ledger)
    }

    func testDraftsAreIsolatedPerSession() {
        var ledger = DraftLedger()
        ledger.setDraft("for session A", forSession: "agent:main:a")
        ledger.setDraft("for session B", forSession: "agent:main:b")

        XCTAssertEqual(ledger.draft(forSession: "agent:main:a"), "for session A")
        XCTAssertEqual(ledger.draft(forSession: "agent:main:b"), "for session B")

        XCTAssertTrue(ledger.clearDraft(forSession: "agent:main:a"))
        XCTAssertNil(ledger.draft(forSession: "agent:main:a"))
        XCTAssertEqual(ledger.draft(forSession: "agent:main:b"), "for session B")
    }

    func testWhitespaceOnlyTextIsNotContent() {
        var ledger = DraftLedger()
        XCTAssertFalse(ledger.setDraft("   \n\t ", forSession: "agent:main:main"))
        XCTAssertNil(ledger.draft(forSession: "agent:main:main"))

        ledger.setDraft("real draft", forSession: "agent:main:main")
        // Whitespace replacing real content clears the stored draft rather than saving noise.
        XCTAssertTrue(ledger.setDraft("  \n", forSession: "agent:main:main"))
        XCTAssertNil(ledger.draft(forSession: "agent:main:main"))
    }

    func testUnchangedTextAndRedundantClearReportNoChange() {
        var ledger = DraftLedger()
        XCTAssertTrue(ledger.setDraft("same", forSession: "agent:main:main"))
        XCTAssertFalse(ledger.setDraft("same", forSession: "agent:main:main"))
        XCTAssertTrue(ledger.clearDraft(forSession: "agent:main:main"))
        XCTAssertFalse(ledger.clearDraft(forSession: "agent:main:main"))
    }

    /// End-to-end relaunch shape: a draft written through one ChatStore is visible to a second
    /// ChatStore pointed at the same operations root, and clearing propagates the same way.
    @MainActor
    func testChatStoreDraftSurvivesRelaunchAndClears() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastDraftIntegration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = WorkspaceProfile(
            id: "home",
            name: "Home",
            gatewayURL: try XCTUnwrap(URL(string: "wss://gateway.example.com")),
            accent: "blue")
        let operationsRoot = root.appendingPathComponent("operations")
        let store = ChatStore(
            profile: profile,
            transcriptCacheRoot: root.appendingPathComponent("transcripts"),
            operationsLedgerRoot: operationsRoot)

        store.setDraft("typed on device one", forSession: "agent:main:main")
        store.setDraft("other chat", forSession: "agent:main:other")
        XCTAssertEqual(store.draft(forSession: "agent:main:main"), "typed on device one")

        let draftsFile = operationsRoot.appendingPathComponent("drafts.json")
        try await self.waitForLedgerFile(at: draftsFile) { ledger in
            ledger.draft(forSession: "agent:main:main") == "typed on device one"
                && ledger.draft(forSession: "agent:main:other") == "other chat"
        }

        let relaunched = ChatStore(
            profile: profile,
            transcriptCacheRoot: root.appendingPathComponent("transcripts"),
            operationsLedgerRoot: operationsRoot)
        XCTAssertEqual(relaunched.draft(forSession: "agent:main:main"), "typed on device one")
        XCTAssertEqual(relaunched.draft(forSession: "agent:main:other"), "other chat")

        relaunched.clearDraft(forSession: "agent:main:main")
        XCTAssertEqual(relaunched.draft(forSession: "agent:main:main"), "")
        try await self.waitForLedgerFile(at: draftsFile) { ledger in
            ledger.draft(forSession: "agent:main:main") == nil
                && ledger.draft(forSession: "agent:main:other") == "other chat"
        }
    }

    /// Draft persistence is a fire-and-forget hop through the operations persistence actor,
    /// so the durable file is awaited with a bounded poll rather than assumed synchronous.
    private func waitForLedgerFile(
        at url: URL,
        condition: @escaping (DraftLedger) -> Bool) async throws
    {
        for _ in 0..<200 {
            if let data = try? Data(contentsOf: url),
               let ledger = try? JSONDecoder().decode(DraftLedger.self, from: data),
               condition(ledger)
            {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for persisted draft ledger at \(url.path)")
    }
}
