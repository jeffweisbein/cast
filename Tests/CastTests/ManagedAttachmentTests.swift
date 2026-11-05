import Foundation
import XCTest
@testable import Cast

final class ManagedAttachmentTests: XCTestCase {
    func message(_ id: String = "artifact_managed_image_123") throws -> ChatMessage {
        try JSONDecoder().decode(ChatMessage.self, from: Data("""
        {"role":"assistant","timestamp":1234,"content":[{"type":"image","artifactId":"\(id)","url":"/api/chat/media/outgoing/session/123/full","alt":"cover.png","mimeType":"image/png","sizeBytes":123}]}
        """.utf8))
    }
    func testActualGatewayImageSurvivesHistoryCacheAndAnswerFiltering() throws {
        let original = try message()
        let cached = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(cached.managedAttachments, original.managedAttachments)
        XCTAssertEqual(cached.managedAttachments.first?.label, "cover.png")
        XCTAssertEqual(TranscriptBuilder.answers(from: [cached]).count, 1)
        var builder = IncrementalTranscriptBuilder()
        builder.append(cached)
        XCTAssertFalse(builder.items.isEmpty)
        let scanned = DeliverableScanner.scan(messages: [cached], sessionKey: "session-a")
        XCTAssertEqual(scanned.first?.artifactID, "artifact_managed_image_123")
        XCTAssertEqual(scanned.first?.sessionKey, "session-a")
        XCTAssertEqual(scanned.first?.sizeBytes, 123)
    }
    func testDistinctImagesAreNotCollapsedAsIdenticalEmptyReplies() throws {
        let a = try message("artifact_a"), b = try message("artifact_b")
        XCTAssertNotEqual(ChatMessage.contentAddressedID(for: a, positionSalt: 0), ChatMessage.contentAddressedID(for: b, positionSalt: 0))
        XCTAssertFalse(ChatStore.isSameTranscriptEntry(a, b))
    }
    func testNestedDocumentAttachmentAndMalformedBlocks() throws {
        let json = """
        {"role":"assistant","content":[{"type":"attachment","attachment":{"artifactId":"artifact_doc","label":"report.pdf","mimeType":"application/pdf","sizeBytes":42}},{"type":"image","artifactId":"../../private"},{"type":"image","url":"https://example.com/untrusted.png"}]}
        """
        let msg = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.managedAttachments.count, 1)
        XCTAssertEqual(msg.managedAttachments.first?.artifactId, "artifact_doc")
    }
}
