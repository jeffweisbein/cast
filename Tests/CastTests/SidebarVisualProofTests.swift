#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import Cast

/// Actual production sidebar in a native split view; no gateway/client or credentials.
@MainActor final class SidebarVisualProofTests: XCTestCase {
    func testRenderProductionSidebarLightDarkAtCompactWidths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cast-sidebar-proof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = WorkspaceProfile(id: "sidebar-proof", name: "Offline fixture", gatewayURL: URL(string: "ws://127.0.0.1:1")!, accent: "orange")
        var archive = SideChatArchive()
        for (suffix, title) in [("11111111-1111-4111-8111-111111111111", "Also can you look into switching on captions being faster?"), ("22222222-2222-4222-8222-222222222222", "It’s just sitting in the room and chatting and listening, no video")] {
            let key = "agent:main:cast-side-" + suffix
            archive.chats[key] = SavedSideChat(sessionKey: key, sourceSessionKey: "agent:main:main", context: "Offline saved passage.", title: title, created: true)
        }
        try SideChatArchive.store(root: root, profile: profile).save(archive)
        let store = ChatStore(profile: profile, transcriptCacheRoot: root, operationsLedgerRoot: root)
        XCTAssertEqual(store.sideChatAutoArchiveDays, 0)
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)] {
            for width in [250.0, 300.0] {
                let content = NavigationSplitView {
                    SessionListView(store: store)
                        .navigationSplitViewColumnWidth(min: width, ideal: width, max: width)
                } detail: {
                    Text("Main conversation is unchanged")
                }.environment(\.colorScheme, scheme)
                let hosting = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = hosting
                window.orderFront(nil)
                try await Task.sleep(for: .seconds(1))
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(bytes.count, 10000)
                let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.png")
                attachment.name = "mac-sidebar-\(name)-\(Int(width))"
                attachment.lifetime = .keepAlways
                add(attachment)
                window.close()
            }
        }
        XCTAssertEqual(store.savedSideChats.count, 2)
        XCTAssertNil(store.selectedSessionKey)
    }
}
#endif
