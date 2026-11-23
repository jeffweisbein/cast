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

/// Production composition: split view, ChatView detail, one outer SideChatInspector that also
/// hosts Result review, bound to the store exactly as ContentView binds it.
private struct SharedInspectorFixture: View {
    let store: ChatStore
    var body: some View {
        NavigationSplitView {
            Text("Fixture conversations").navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
        } detail: {
            ChatView(store: store, allowsSending: false,
                     showingSideChat: Binding(get: { store.isSideChatPresented }, set: { store.isSideChatPresented = $0 }))
                .environment(\.scenePhase, .active)
        }
        .modifier(SideChatInspector(store: store, isPresented: Binding(
            get: { store.isSideChatPresented }, set: { store.isSideChatPresented = $0 })))
    }
}

final class MacOSWindowSizingTests: XCTestCase {
    /// Runtime check for the shared trailing inspector in the real split view. Result review and a
    /// real restored Side chat alternate in the one outer inspector slot (a detail-column inspector
    /// previously crashed macOS 15 with a duplicate window separator).
    ///
    /// Window size: on macOS 27 / Xcode 27.1 the pre-existing Side chat inspector (baseline b0a31ff,
    /// same host) widens a 1100x784 window once to 1480x784 on first open and keeps that size after
    /// closing and across later cycles; macOS 15 does not resize. The window may therefore expand
    /// at most once, by no more than one inspector column, without changing height or shrinking;
    /// every later open, swap and close must keep that size (no repeated growth or oscillation).
    @MainActor
    func testResultReviewAndRealSideChatShareOneInspectorWithBoundedOneTimeExpansion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = WorkspaceProfile(id: "window-sizing-\(UUID().uuidString)", name: "Window sizing",
                                       gatewayURL: URL(string: "ws://127.0.0.1:9")!, accent: "orange")
        let key = "agent:main:main"
        // A real offline Side chat restored from its archive, closed initially (as after relaunch).
        let sideKey = "agent:main:cast-side-22222222-2222-4222-8222-222222222222"
        var archive = SideChatArchive()
        archive.chats[sideKey] = SavedSideChat(sessionKey: sideKey, sourceSessionKey: key,
                                               context: "Quoted passage.", title: "Fixture side chat", created: true)
        archive.selectedKey = sideKey
        archive.isPresented = false
        try SideChatArchive.store(root: root, profile: profile).save(archive)
        let store = ChatStore(profile: profile, transcriptCacheRoot: root, operationsLedgerRoot: root)
        store.selectedSessionKey = key
        let sideChat = try XCTUnwrap(store.sideChat, "Real Side chat restored from the archive")
        XCTAssertEqual(sideChat.sessionKey, sideKey)
        XCTAssertFalse(store.isSideChatPresented)
        let turn = 1_784_600_000_000.0
        store.installOfflineDiagnosticTranscript([
            ChatMessage(id: "u", role: "user", blocks: [ChatContentBlock(type: "text", text: "Make the chat list clearer.",
                thinking: nil, name: nil, mimeType: nil, fileName: nil)], timestamp: turn - 60_000),
            ChatMessage(id: "a", role: "assistant", blocks: [ChatContentBlock(type: "text", text: "Done; the files are attached.",
                thinking: nil, name: nil, mimeType: nil, fileName: nil)], timestamp: turn),
        ])
        let host = NSHostingView(rootView: SharedInspectorFixture(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .milliseconds(500))
        // Cold ledger insertion after first paint: the card appears for the latest turn.
        store.installDeliverablesForTesting([
            Deliverable(id: "f1", sessionKey: key, messageID: "a", title: "chat-states.png", target: "artifact:f1",
                        kind: "Image", sharedAt: turn, artifactID: "f1", sizeBytes: 40_000, mimeType: "image/png"),
        ])
        try await Task.sleep(for: .milliseconds(400))
        let initial = window.frame.size
        // Largest inspectorColumnWidth max across both occupants of the shared slot (SideChatInspector).
        let inspectorColumnMax: CGFloat = 560
        var previous = initial
        var sizeChanges: [String] = []
        func checkFrame(_ step: String) {
            let size = window.frame.size
            print("CAST_INSPECTOR_FRAME step=\(step) frame=\(size) result=\(store.isResultReviewPresented) side=\(store.isSideChatPresented)")
            XCTAssertEqual(size.height, initial.height, accuracy: 1, "Inspector changes must not change window height (\(step))")
            XCTAssertGreaterThanOrEqual(size.width, initial.width - 1, "Inspector changes must not shrink the window (\(step))")
            XCTAssertLessThanOrEqual(size.width - initial.width, inspectorColumnMax + 1,
                                     "Any expansion is bounded by one inspector column (\(step))")
            if abs(size.width - previous.width) > 1 || abs(size.height - previous.height) > 1 {
                sizeChanges.append("\(step): \(previous) -> \(size)")
            }
            previous = size
        }
        func capture(_ name: String) {
            guard let dir = ProcessInfo.processInfo.environment["CAST_FIXTURE_OUTPUT"],
                  let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        capture("mac-real-chatview-card.png")
        checkFrame("initial")
        for cycle in 0..<3 {
            store.presentResultReview()
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(store.isResultReviewPresented)
            XCTAssertFalse(store.isSideChatPresented)
            if cycle == 0 { capture("mac-real-inspector-result.png") }
            checkFrame("cycle\(cycle)-result")
            store.isSideChatPresented = true
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(store.isSideChatPresented)
            XCTAssertFalse(store.isResultReviewPresented, "Side chat replaces Result review in the one inspector")
            XCTAssertEqual(store.sideChat?.sessionKey, sideKey, "The real Side chat occupies the slot")
            if cycle == 0 { capture("mac-real-inspector-sidechat.png") }
            checkFrame("cycle\(cycle)-sidechat")
            store.presentResultReview()
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(store.isResultReviewPresented)
            XCTAssertFalse(store.isSideChatPresented, "Result review replaces Side chat")
            checkFrame("cycle\(cycle)-result-again")
            store.presentResultReview(false)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertFalse(store.isResultReviewPresented)
            XCTAssertFalse(store.isSideChatPresented)
            checkFrame("cycle\(cycle)-closed")
        }
        XCTAssertLessThanOrEqual(sizeChanges.count, 1,
                                 "The window may expand at most once; later inspector changes must keep its size: \(sizeChanges)")
        print("CAST_INSPECTOR_FRAME summary initial=\(initial) final=\(window.frame.size) changes=\(sizeChanges)")
        // Reviewing ends the in-chat card.
        store.markDeliverablesReviewed(["f1"])
        XCTAssertEqual(store.resultArtifactCounts(for: key)?.unreviewed, 0)
        try await Task.sleep(for: .milliseconds(300))
        capture("mac-real-chatview-after-review.png")
    }

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
