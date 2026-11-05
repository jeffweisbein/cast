import Foundation
import XCTest
@testable import Cast

final class LocalDictationTests: XCTestCase {
    func testFinalTranscriptPreservesEditedDraftAndWhitespace() {
        XCTAssertEqual(DictationDraft.inserting(" hello ", into: "existing edit"), "existing edit hello")
        XCTAssertEqual(DictationDraft.inserting("hello", into: "line\n"), "line\nhello")
        XCTAssertEqual(DictationDraft.inserting("  \n", into: "untouched"), "untouched")
        XCTAssertEqual(DictationDraft.inserting("hello", into: ""), "hello")
    }

    func testPreferredSpellingsRespectWordBoundariesAndLiteralReplacement() {
        XCTAssertEqual(DictationDraft.corrected("Open claw uses run pr and cackles.", rules: DictationDraft.defaultCorrections), "OpenClaw uses RunPR and Cackles.")
        XCTAssertEqual(DictationDraft.corrected("broadcaster cast", rules: "cast=$Cast"), "broadcaster $Cast")
    }

    @MainActor
    func testHexRejectsRemoteOrCredentialBearingHandshake() throws {
        func data(_ url: String, pid: Int = 42, api: String = "2") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type":"ready", "url":url, "token":"hex_test", "pid":pid, "apiVersion":api])
        }
        XCTAssertNoThrow(try HexService.validateHandshake(data("http://127.0.0.1:49731"), pid: 42))
        for url in ["https://evil.example:80", "http://localhost:80", "http://127.0.0.1.evil.example:80", "http://user@127.0.0.1:80", "http://127.0.0.1:80/path", "http://127.0.0.1:80?token=x"] {
            XCTAssertThrowsError(try HexService.validateHandshake(data(url), pid: 42), url)
        }
        XCTAssertThrowsError(try HexService.validateHandshake(data("http://127.0.0.1:80", pid: 43), pid: 42))
        XCTAssertThrowsError(try HexService.validateHandshake(data("http://127.0.0.1:80", api: "1"), pid: 42))
    }

    @MainActor
    func testCancellationKeepsIdleAndDiscardsResults() {
        let controller = LocalDictation()
        controller.cancel()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.output)
        controller.finish()
        XCTAssertEqual(controller.phase, .idle)
    }
}
