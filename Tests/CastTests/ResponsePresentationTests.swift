import XCTest
@testable import Cast

final class ResponsePresentationTests: XCTestCase {
    func testCommitsRequireRealRepositoryURLAndDeduplicate() {
        let text = "commit abcdef1 [review](https://github.com/acme/app/commit/abcdef1234) https://github.com/acme/app/commit/abcdef1234"
        let links = CommitReference.references(in: text)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.shortHash, "abcdef1")
        XCTAssertEqual(links.first?.repository, "acme/app")
        XCTAssertTrue(CommitReference.references(in: "commit abcdef1").isEmpty)
    }
    func testCodeSamplesAndInvalidHashesDoNotBecomeCommitChips() {
        XCTAssertTrue(CommitReference.references(in: "```\nhttps://github.com/acme/app/commit/abcdef123\n```").isEmpty)
        XCTAssertTrue(CommitReference.references(in: "https://github.com/acme/app/commit/abcdefg").isEmpty)
        XCTAssertTrue(CommitReference.references(in: "https://github.com.evil.com/acme/app/commit/abcdef1").isEmpty)
    }
    func testDeletedFilesRemainInDiffSummary() {
        let summary = DiffSummary("--- a/Old.swift\n+++ /dev/null\n-removed")
        XCTAssertEqual(summary.files, ["Old.swift"])
        XCTAssertEqual(summary.deletions, 1)
    }
    func testDiffCountsExcludeHeadersAndKeepPaths() {
        let diff = DiffSummary("--- a/Sources/A.swift\n+++ b/Sources/A.swift\n@@ -1 +1,2 @@\n-old\n+new\n+extra\n context")
        XCTAssertEqual(diff.additions, 2)
        XCTAssertEqual(diff.deletions, 1)
        XCTAssertEqual(diff.files, ["Sources/A.swift"])
    }
}

@MainActor final class SideChatTests: XCTestCase {
    func testSendCreatesIndependentSessionNeverMutatesParentAndDoesNotDeliverExternally() async {
        var calls: [(String, [String: Any?])] = []
        let parent = "agent:research:main"
        let chat = SideChat(sourceSessionKey: parent, context: "The quoted explanation") { method, params in
            calls.append((method, params))
            if method == "sessions.create" {
                return try JSONSerialization.data(withJSONObject: ["key": params["key"]!!])
            }
            if method == "chat.history" { return Data(#"{"messages":[]}"#.utf8) }
            return Data(#"{"runId":"side-run"}"#.utf8)
        }
        chat.draft = "What does that mean?"
        await chat.send()
        XCTAssertNotEqual(chat.sessionKey, parent)
        XCTAssertTrue(chat.sessionKey.hasPrefix("agent:research:cast-side-"))
        XCTAssertFalse(calls.contains { $0.0 == "sessions.patch" })
        let send = calls.first { $0.0 == "chat.send" }!.1
        XCTAssertEqual(send["sessionKey"] as? String, chat.sessionKey)
        XCTAssertEqual(send["deliver"] as? Bool, false)
        XCTAssertTrue((send["message"] as? String)?.contains("The quoted explanation") == true)
        XCTAssertEqual(chat.draft, "")
    }
    func testUncertainSendReusesIdempotencyKeyAndPreservesQuestion() async {
        var ids: [String] = []
        let chat = SideChat(sourceSessionKey: "agent:main:main", context: "passage") { method, params in
            if method == "sessions.create" { return try JSONSerialization.data(withJSONObject: ["key": params["key"]!!]) }
            if method == "chat.send" {
                ids.append(params["idempotencyKey"] as! String)
                throw URLError(.timedOut)
            }
            return Data("{}".utf8)
        }
        chat.draft = "Question"
        await chat.send()
        XCTAssertEqual(chat.draft, "Question")
        await chat.send()
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], ids[1])
        chat.draft = "A different question"
        await chat.send()
        XCTAssertEqual(ids.count, 2)
    }
    func testMainSessionEventsCannotEnterSideChat() {
        let chat = SideChat(sourceSessionKey: "agent:main:main", context: "passage") { _, _ in Data("{}".utf8) }
        chat.receive(EventFrame(event: "chat", payload: AnyCodable(["sessionKey": "agent:main:main", "state": "delta", "deltaText": "Main task"].mapValues { AnyCodable($0) }), seq: nil))
        XCTAssertEqual(chat.streamingText, "")
        XCTAssertFalse(chat.isBusy)
        chat.receive(EventFrame(event: "chat", payload: AnyCodable(["sessionKey": chat.sessionKey, "state": "delta", "deltaText": "Side answer"].mapValues { AnyCodable($0) }), seq: nil))
        XCTAssertEqual(chat.streamingText, "Side answer")
    }
    func testDifferentSessionReturnedByGatewayFailsClosed() async {
        var didSend = false
        let chat = SideChat(sourceSessionKey: "agent:main:main", context: "passage") { method, _ in
            if method == "chat.send" { didSend = true }
            return Data(#"{"key":"agent:main:main"}"#.utf8)
        }
        chat.draft = "Question"
        await chat.send()
        XCTAssertFalse(didSend)
        XCTAssertFalse(chat.created)
        XCTAssertNotNil(chat.error)
    }
}

#if os(macOS)
import SwiftUI
import AppKit
@MainActor final class ResponseVisualProofTests: XCTestCase {
    func testRenderActualResponseViewsLightDarkAndNarrow() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("cast-response-ui-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let message = """
        ## Ready to review
        The change is in [`6148699`](https://github.com/jeffweisbein/cast/commit/61486996aad88a7638460e0f56b533ffa67423b8).

        **What changed**
        - Workspace tools collapse to give conversations more room.
        - Your current conversation stays in place.

        | Platform | Status |
        | --- | --- |
        | iPhone | Ready to review |
        | Mac | Ready to review |
        """
        for (name, width, scheme) in [("wide-light", 680.0, ColorScheme.light), ("narrow-light", 390.0, .light), ("wide-dark", 680.0, .dark)] {
            let content = VStack(alignment: .leading, spacing: 14) {
                Text("Cast").font(.title2.bold())
                ToolRunView(run: ToolRun(id: "proof", steps: [ToolStep(id: "1", name: "read", summary: "Sources/App/ContentView.swift"), ToolStep(id: "2", name: "edit", summary: "Sources/App/ContentView.swift")]), isExpanded: false, onToggle: {})
                MarkdownBody(text: message)
                CodeBlockView(language: "diff", code: "--- a/ContentView.swift\n+++ b/ContentView.swift\n@@ -1 +1 @@\n-Text(\"Workspace tools\")\n+DisclosureGroup(\"Workspace tools\")")
            }.padding(20).frame(width: width).background(scheme == .dark ? Color(white: 0.12) : .white)
                .environment(\.colorScheme, scheme)
            try await capture(content, width: width, height: 1000, to: output.appendingPathComponent(name + ".png"))
        }
        let chat = SideChat(sourceSessionKey: "agent:main:proof", context: "The highest SCOP measures seasonal efficiency.") { _, _ in Data("{}".utf8) }
        try await capture(SideChatView(chat: chat, onClose: {}).frame(width: 380, height: 720).background(.white).environment(\.colorScheme, .light), width: 380, height: 720, to: output.appendingPathComponent("side-chat.png"))
        print("CAST_UI_PROOF_DIR=\(output.path)")
    }
    private func capture<V: View>(_ content: V, width: Double, height: Double, to url: URL) async throws {
        let view = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

}
#endif
