#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Cast

@MainActor
private final class WindowSizingSidebar: ObservableObject {
    @Published var visibility: NavigationSplitViewVisibility = .all
}

private struct WindowSizingFixture: View {
    let store: ChatStore
    @ObservedObject var sidebar: WindowSizingSidebar
    @State private var showingSideChat = false
    var body: some View {
        NavigationSplitView(columnVisibility: $sidebar.visibility) {
            Text("Fixture conversations").navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
        } detail: {
            ChatView(store: store, showingSideChat: $showingSideChat).environment(\.scenePhase, .active)
        }
        .modifier(SideChatInspector(store: store, isPresented: $showingSideChat))
    }
}

final class MacOSWindowSizingTests: XCTestCase {
    @MainActor
    func testComposerSendsAndSidebarPreserveManuallyResizedWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ChatStore(transcriptCacheRoot: root, operationsLedgerRoot: root)
        store.selectedSessionKey = "agent:test:window-sizing"
        let config = GatewayClientConfig(
            url: URL(string: "ws://127.0.0.1:9")!, workspaceID: "window-sizing-test",
            credential: GatewayCredential(kind: .deviceToken, token: "unused"),
            deviceCredentialProvider: { nil }, onDeviceToken: { _ in }, clientId: "cast-tests",
            platform: "macOS", deviceFamily: "Mac", displayName: "Cast Tests")
        // Exercise the real local echo/composer reset; sendChat attempts only this
        // unreachable loopback endpoint, with an inert credential (never a live gateway).
        store.installClientForTesting(GatewayClient(config: config, onEvent: { _ in }, onState: { _ in }))
        let sidebar = WindowSizingSidebar()
        let host = NSHostingView(rootView: WindowSizingFixture(store: store, sidebar: sidebar))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; try? FileManager.default.removeItem(at: root) }
        func composers(_ view: NSView) -> [MacOSComposerTextView] {
            (view as? MacOSComposerTextView).map { [$0] } ?? view.subviews.flatMap(composers)
        }
        try await Task.sleep(for: .milliseconds(500))
        let composer = try XCTUnwrap(composers(host).first)
        window.makeFirstResponder(composer)
        var sent = 0
        // AppKit constrains windows to the runner's visible screen. A hosted
        // 768pt display cannot fit 700pt of content plus title/toolbar chrome.
        // Pick two genuinely user-selectable sizes, then keep every stability
        // and exact-size assertion below (do not accept a silently clamped size).
        let screen = try XCTUnwrap(window.screen)
        let chromeHeight = window.frame.height - window.contentLayoutRect.height
        let availableHeight = floor(screen.visibleFrame.height - chromeHeight - 16)
        let availableWidth = floor(screen.visibleFrame.width - 16)
        let sizes = [NSSize(width: min(1000, availableWidth), height: min(700, availableHeight)),
                     NSSize(width: min(900, availableWidth - 100), height: min(650, availableHeight - 50))]
        print("CAST_WINDOW_SCREEN visible=\(screen.visibleFrame) chrome=\(chromeHeight) sizes=\(sizes)")
        for size in sizes {
            window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(250))
            let expected = window.frame.size
            XCTAssertEqual(window.contentLayoutRect.size, size, "The user must be able to choose this window size")
            for text in ["Short message", String(repeating: "A long wrapped draft. ", count: 160), "One more message"] {
                composer.insertText(text, replacementRange: NSRange(location: 0, length: composer.string.utf16.count))
                composer.didChangeText()
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertEqual(window.frame.size, expected, "Typing must not change the user's window size")
                composer.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                sent += 1
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(store.messages.count, sent, "Return must exercise the real local send path")
                XCTAssertEqual(composer.string, "", "Successful local submission clears the field")
                print("CAST_WINDOW_SEND sent=\(sent) expected=\(expected) actual=\(window.frame.size) min=\(window.contentMinSize)")
                XCTAssertEqual(window.frame.size, expected, "Sending must not change the user's window size")
                XCTAssertLessThanOrEqual(window.contentMinSize.height, size.height)
            }
            for visibility in [NavigationSplitViewVisibility.detailOnly, .all] {
                sidebar.visibility = visibility
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(window.frame.size, expected, "Sidebar changes must not resize the window")
            }
        }
    }

    @MainActor
    func testTranscriptGrowthPreservesUserWindowSize() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ChatStore(transcriptCacheRoot: root, operationsLedgerRoot: root)
        func rows(_ count: Int) -> [ChatMessage] {
            (0..<count).map { index in
                ChatMessage(id: "size-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                    blocks: [ChatContentBlock(type: "text", text: "Message \(index). " + String(repeating: "A message that wraps onto several lines. ", count: 20), thinking: nil, name: nil, mimeType: nil, fileName: nil)],
                    timestamp: Double(index) * 600_000)
            }
        }
        store.installOfflineDiagnosticTranscript(rows(0))
        let host = NSHostingView(rootView: ChatView(store: store, allowsSending: false)
            .environment(\.scenePhase, .active))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .milliseconds(500))
        window.setContentSize(NSSize(width: 900, height: 650))
        try await Task.sleep(for: .milliseconds(250))
        let expected = window.frame.size
        for count in [1, 2, 3, 6, 12, 24] {
            store.installOfflineDiagnosticTranscript(rows(count))
            try await Task.sleep(for: .milliseconds(300))
            print("CAST_WINDOW_SIZE count=\(count) expected=\(expected) actual=\(window.frame.size) min=\(window.contentMinSize)")
            XCTAssertLessThanOrEqual(window.contentMinSize.height, 650, "Transcript content must not impose its full height as the window minimum")
            XCTAssertEqual(window.frame.width, expected.width, accuracy: 1, "Appending message \(count) must not widen the window")
            XCTAssertEqual(window.frame.height, expected.height, accuracy: 1, "Appending message \(count) must not grow the window")
        }
    }
}
#endif
