import Foundation
import XCTest
@testable import Cast

final class DocumentLinkTests: XCTestCase {
    func testRemoteDocumentPathsDecodeOnceAndRemoveSourceLineSuffix() throws {
        let link = try XCTUnwrap(DocumentLink(url: URL(string: "/Users/author/reports/Meeting%20brief.pdf")!, sessionKey: "session-a"))
        XCTAssertEqual(link.path, "/Users/author/reports/Meeting brief.pdf")
        XCTAssertEqual(DocumentLink(url: URL(string: "file:///Users/author/notes.md:12:4")!, sessionKey: "a")?.path, "/Users/author/notes.md")
        XCTAssertEqual(DocumentLink(url: URL(string: "/tmp/100%2520.pdf")!, sessionKey: "a")?.path, "/tmp/100%20.pdf")
    }
    func testWebLinksRemainSystemLinksAndNetworkFilesAreRejected() {
        for raw in ["https://example.com/report.pdf", "mailto:person@example.com", "https://example.com/#section"] {
            XCTAssertFalse(DocumentLink.intercepts(URL(string: raw)!))
        }
        for raw in ["file://other-host/share/report.pdf", "//other-host/share/report.pdf", "/tmp/report.pdf?token=no", "/tmp/bad%00.pdf"] {
            XCTAssertNil(DocumentLink(url: URL(string: raw)!, sessionKey: "a"), raw)
        }
    }
    func testLookupNeverUsesAnotherSessionsIdenticalPath() throws {
        let link = try XCTUnwrap(DocumentLink(url: URL(string: "/tmp/report.pdf")!, sessionKey: "a"))
        let wrong = Deliverable(id: "wrong", sessionKey: "b", messageID: "old", title: "Report", target: "/tmp/report.pdf", kind: "Document", sharedAt: nil)
        XCTAssertEqual(link.deliverable(in: [wrong]).sessionKey, "a")
        XCTAssertNotEqual(link.deliverable(in: [wrong]).id, wrong.id)
        let right = Deliverable(id: "right", sessionKey: "a", messageID: "new", title: "Report", target: "/tmp/report.pdf", kind: "Document", sharedAt: nil)
        XCTAssertEqual(link.deliverable(in: [wrong, right]).id, "right")
    }
    func testArtifactIDIsPreservedWithoutGuessingFromFilename() throws {
        let link = try XCTUnwrap(DocumentLink(url: URL(string: "artifact:artifact_exact")!, sessionKey: "a"))
        XCTAssertEqual(link.deliverable(in: []).artifactID, "artifact_exact")
        XCTAssertNil(DocumentLink(url: URL(string: "/tmp/report.pdf")!, sessionKey: "a")?.deliverable(in: []).artifactID)
    }
}
