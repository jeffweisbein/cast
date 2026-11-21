import Foundation
import XCTest
@testable import Cast

/// B5: a gateway artifact must keep one review identity whichever path last wrote the
/// ledger (transcript scan vs `artifacts.list`), or local review marks silently return.
final class ArtifactReviewIdentityTests: XCTestCase {
    private let key = "agent:main:review-identity"

    private func message(id: String, artifactId: String, at timestamp: Double) -> ChatMessage {
        ChatMessage(id: id, role: "assistant", blocks: [
            ChatContentBlock(type: "text", text: "Attached.", thinking: nil, name: nil, mimeType: nil, fileName: nil),
            ChatContentBlock(type: "file", text: nil, thinking: nil, name: nil, mimeType: "image/png", fileName: nil,
                             attachment: ManagedChatAttachment(artifactId: artifactId, label: "states.png",
                                                               mimeType: "image/png", sizeBytes: 4_000)),
        ], timestamp: timestamp)
    }

    private func listed(_ artifactId: String, seq: Int) throws -> GatewayArtifact {
        try JSONDecoder().decode(GatewayArtifact.self, from: Data("""
        {"id":"\(artifactId)","title":"states.png","type":"file","sessionKey":"\(key)","mimeType":"image/png",
         "sizeBytes":4000,"messageSeq":\(seq),"download":{"mode":"url"}}
        """.utf8))
    }

    func testReviewMarkSurvivesScanListRescanRoundTrip() throws {
        var ledger = DeliverableLedger()
        let messages = [self.message(id: "m-42", artifactId: "art_1", at: 1_784_600_000_000)]
        ledger.ingest(messages: messages, sessionKey: self.key)
        let scanned = try XCTUnwrap(ledger.items.first { $0.artifactID == "art_1" })
        let reviewed: Set<String> = [scanned.reviewID]
        func unreviewed() -> Int { ResultArtifactCounts.index(ledger: ledger.items, reviewed: reviewed)[self.key]?.unreviewed ?? -1 }
        XCTAssertEqual(unreviewed(), 0, "Marked reviewed after the transcript scan")

        ledger.ingest(artifacts: [try self.listed("art_1", seq: 7)], sessionKey: self.key)
        XCTAssertEqual(ledger.items.filter { $0.artifactID == "art_1" }.count, 1)
        XCTAssertEqual(unreviewed(), 0, "artifacts.list refresh must not reopen a reviewed artifact")

        ledger.ingest(messages: messages, sessionKey: self.key)
        XCTAssertEqual(unreviewed(), 0, "A later transcript rescan must not reopen it either")
        XCTAssertTrue(ChatResultSummary(sessionKey: self.key, ledger: ledger.items, reviewed: reviewed, progressCard: nil)
            .nothingLeftMarkedHere)
    }

    func testMarkFromListedIdentityAlsoHolds() throws {
        var ledger = DeliverableLedger()
        ledger.ingest(artifacts: [try self.listed("art_2", seq: 3)], sessionKey: self.key)
        let reviewed: Set<String> = [try XCTUnwrap(ledger.items.first).reviewID]
        ledger.ingest(messages: [self.message(id: "m-9", artifactId: "art_2", at: 1_784_600_000_000)], sessionKey: self.key)
        XCTAssertEqual(ResultArtifactCounts.index(ledger: ledger.items, reviewed: reviewed)[self.key]?.unreviewed, 0)
    }

    func testPlainLinkIdentityStillIncludesTheMessage() {
        // A link shared again in a later message deserves a fresh review (unchanged semantics).
        let first = Deliverable(id: "L", sessionKey: self.key, messageID: "m1", title: "r", target: "https://e.com/r.pdf",
                                kind: "Document", sharedAt: 1)
        let again = Deliverable(id: "L", sessionKey: self.key, messageID: "m2", title: "r", target: "https://e.com/r.pdf",
                                kind: "Document", sharedAt: 2)
        XCTAssertNotEqual(first.reviewID, again.reviewID)
        XCTAssertEqual(first.reviewID, "L:m1")
    }
}
