import XCTest
@testable import Cast

@MainActor final class DemoWorkspaceTests: XCTestCase {
    func testSideChatAndApprovalStayInSampleAndResetForAnotherConversation() {
        let demo = DemoWorkspace()
        let originalResponse = demo.sample.response
        demo.openSideChat()
        demo.ask(.why)
        demo.approveSample()
        XCTAssertTrue(demo.approved)
        XCTAssertEqual(demo.exchanges.count, 1)
        XCTAssertEqual(demo.sample.response, originalResponse)
        demo.closeSideChat()
        XCTAssertEqual(demo.exchanges.count, 1, "Hiding the panel should not discard the current demonstration")
        demo.select(.research)
        XCTAssertFalse(demo.approved)
        XCTAssertFalse(demo.showingSideChat)
        XCTAssertTrue(demo.exchanges.isEmpty)
        demo.ask(.why)
        XCTAssertEqual(demo.exchanges.first?.answer, DemoWorkspace.Sample.research.explanation)
    }
    func testFreshDemoDoesNotRetainQuestionsOrApprovals() {
        let first = DemoWorkspace()
        first.ask(.next)
        first.approveSample()
        let reopened = DemoWorkspace()
        XCTAssertTrue(reopened.exchanges.isEmpty)
        XCTAssertFalse(reopened.approved)
        XCTAssertEqual(reopened.sample, .change)
    }
    func testRepeatedExplorationIsBoundedAndSamplesHaveNoRemoteContent() {
        let demo = DemoWorkspace()
        for _ in 0..<30 { demo.ask(.checks) }
        XCTAssertEqual(demo.exchanges.count, 12)
        for sample in DemoWorkspace.Sample.allCases {
            for text in [sample.response, sample.context, sample.question, sample.explanation, sample.checks] {
                XCTAssertFalse(text.contains("https://"))
                XCTAssertFalse(text.contains("http://"))
                XCTAssertFalse(text.contains("!["), "Offline sample must not load remote images")
            }
        }
        let summary = DiffSummary(DemoWorkspace.diff)
        XCTAssertEqual(summary.additions, 3)
        XCTAssertEqual(summary.deletions, 2)
    }
}

#if os(macOS)
import AppKit
import SwiftUI
@MainActor final class DemoVisualProofTests: XCTestCase {
    func testRenderDemoAndSideChatWithActualNativeViews() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("cast-demo-ui-proof")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await capture(DemoWorkspaceView(), width: 1000, height: 900, to: output.appendingPathComponent("demo-main.png"))
        let demo = DemoWorkspace()
        demo.openSideChat()
        demo.ask(.why)
        try await capture(DemoSideChatView(demo: demo), width: 390, height: 820, to: output.appendingPathComponent("demo-side.png"))
        demo.select(.research)
        try await capture(MarkdownBody(text: demo.sample.response).padding(), width: 390, height: 800, to: output.appendingPathComponent("demo-research-narrow.png"))
        print("CAST_DEMO_PROOF_DIR=\(output.path)")
    }
    private func capture<V: View>(_ content: V, width: Double, height: Double, to url: URL) async throws {
        let view = NSHostingView(rootView: content.frame(width: width, height: height).background(Color.white).environment(\.colorScheme, .light))
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
