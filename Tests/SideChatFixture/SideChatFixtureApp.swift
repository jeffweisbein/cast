import SwiftUI

/// Native offline fixture: production sidebar, inspector and disk store. No manager,
/// credentials, client, push registration or startup task can reach a gateway.
@main struct SideChatFixtureApp: App {
    let store: ChatStore
    init() {
        // This standalone offline UI-test host uses the same guarded snapshot seam as XCTest.
        if ProcessInfo.processInfo.arguments.contains("--project-fixture") {
            setenv("XCTestConfigurationFilePath", "CastSideChatFixture", 1)
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SideChatRecoveryFixture")
        if ProcessInfo.processInfo.arguments.contains("--reset-fixture") { try? FileManager.default.removeItem(at: root) }
        let profile = WorkspaceProfile(id: "side-chat-fixture", name: "Offline fixture",
                                       gatewayURL: URL(string: "ws://127.0.0.1:1")!, accent: "orange")
        let key = "agent:main:cast-side-11111111-1111-4111-8111-111111111111"
        let disk = SideChatArchive.store(root: root, profile: profile)
        if ProcessInfo.processInfo.arguments.contains("--reset-fixture") || !FileManager.default.fileExists(atPath: disk.fileURL.path) {
            var archive = SideChatArchive()
            archive.chats[key] = SavedSideChat(sessionKey: key, sourceSessionKey: "agent:main:main",
                context: "Saved original passage about captions.", title: "Also can you look into switching on captions being faster?", created: true)
            let secondKey = "agent:main:cast-side-22222222-2222-4222-8222-222222222222"
            archive.chats[secondKey] = SavedSideChat(sessionKey: secondKey, sourceSessionKey: "agent:main:main",
                context: "A separate saved passage.", title: "It’s just sitting in the room and chatting and listening, no video", created: true)
            try! disk.save(archive)
        }
        store = ChatStore(profile: profile, transcriptCacheRoot: root, operationsLedgerRoot: root)
        if ProcessInfo.processInfo.arguments.contains("--project-fixture") {
            var rows: [[String: Any]] = [
                ["key": "agent:main:cast-chat-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "sessionId": "cast-id", "displayName": "Cast"],
                ["key": "agent:main:cast-chat-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "sessionId": "cackles-id", "displayName": "Cackles"],
                ["key": "agent:main:cast-chat-cccccccc-cccc-4ccc-8ccc-cccccccccccc", "sessionId": "runpr-id", "displayName": "RunPR"],
                ["key": "agent:main:main", "sessionId": "general-id", "displayName": "General"]
            ]
            if ProcessInfo.processInfo.arguments.contains("--results-fixture") {
                // Fictional offline signals: Cackles reports an active run, RunPR an agent
                // attention note. Not connected, so "working" must read as last known.
                rows[1]["hasActiveRun"] = true
                rows[2]["agentStatus"] = ["note": "Pick a headline", "attention": "input",
                                          "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000]
            }
            for index in 0..<100 { rows.append(["key": "agent:main:probe-\(index)", "sessionId": "probe-\(index)", "displayName": "Unrelated diagnostic probe \(index)", "category": "General"]) }
            rows.append(["key": "agent:main:subagent:background", "spawnedBy": "agent:main:main", "displayName": "Background reviewer", "isBackground": true])
            store.installSessionSnapshotForTesting(try! JSONDecoder().decode(SessionsListResponse.self, from: JSONSerialization.data(withJSONObject: ["sessions": rows])).sessions)
            if ProcessInfo.processInfo.arguments.contains("--results-fixture") {
                let cast = "agent:main:cast-chat-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                let now = Date().timeIntervalSince1970 * 1000
                // Fictional turn: the assistant reply precedes the artifacts it shared, so the
                // in-chat card belongs to the latest turn. RunPR's reply is newer than any file.
                func text(_ id: String, _ role: String, _ body: String, _ at: Double) -> ChatMessage {
                    ChatMessage(id: id, role: role, blocks: [ChatContentBlock(type: "text", text: body, thinking: nil,
                        name: nil, mimeType: nil, fileName: nil)], timestamp: at)
                }
                let transcripts = TranscriptCache(workspaceID: profile.id, root: root)
                let castTurn = [text("u1", "user", "Make it easier to see which chats need me.", now - 300_000),
                                text("a1", "assistant", "I put the state beside each chat. Files are attached.", now - 180_000)]
                Task { await transcripts.save(castTurn, sessionKey: cast) }
                store.installDeliverablesForTesting([
                    Deliverable(id: "fixture-a1", sessionKey: cast, messageID: "m2", title: "sidebar-states.png",
                                target: "artifact:fixture-a1", kind: "Image", sharedAt: now - 60_000,
                                artifactID: "fixture-a1", sizeBytes: 482_113, mimeType: "image/png"),
                    Deliverable(id: "fixture-a2", sessionKey: cast, messageID: "m1", title: "verification-notes.md",
                                target: "artifact:fixture-a2", kind: "Attachment", sharedAt: now - 120_000,
                                artifactID: "fixture-a2", sizeBytes: 6_204, mimeType: "text/markdown"),
                    // An ordinary link in General's prose: must not produce a review state.
                    Deliverable(id: "fixture-link", sessionKey: "agent:main:main", messageID: "m9", title: "Release notes",
                                target: "https://example.com/notes.pdf", kind: "Document", sharedAt: now - 30_000),
                ])
            }
            if ProcessInfo.processInfo.arguments.contains("--reset-fixture") {
                for (index, row) in rows.prefix(4).enumerated() {
                    store.updatePersonalChat(row["key"] as! String) { $0.kept = true; $0.pinned = true; $0.rank = Double(index) }
                }
            }
        }

    }
    var body: some Scene {
        WindowGroup {
            Group {
                if ProcessInfo.processInfo.arguments.contains("--landscape-sidebar-fixture") {
                    LandscapeSidebarFixture(store: store)
                } else if ProcessInfo.processInfo.arguments.contains("--download-fixture") {
                    DownloadDocumentFixture(store: store)
                } else if ProcessInfo.processInfo.arguments.contains("--keyboard-fixture") {
                    SideChatKeyboardFixture()
                } else { SideChatFixtureRoot(store: store) }
            }
                .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--dark") ? .dark : .light)
        }
        #if os(macOS)
        .defaultSize(width: ProcessInfo.processInfo.arguments.contains("--narrow") ? 720 : 1100, height: 740)
        #endif
    }
}
struct SideChatFixtureRoot: View {
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    let store: ChatStore
    var presentation: Binding<Bool> {
        Binding(get: { store.isSideChatPresented }, set: { store.isSideChatPresented = $0 })
    }
    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            SessionListView(store: store).navigationTitle("Cast fixture")
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
                #endif
        } detail: {
            if ProcessInfo.processInfo.arguments.contains("--project-fixture"), store.selectedSessionKey != nil {
                ChatView(store: store)
            } else {
                Text("Main conversation is unchanged").accessibilityIdentifier("main-unchanged")
            }
        }
        .onChange(of: store.detailNavigationRequest) { _, _ in preferredCompactColumn = .detail }
        #if os(iOS)
        .onChange(of: preferredCompactColumn) { _, column in if column == .sidebar { store.selectFromSidebar(nil) } }
        #endif
        .modifier(SideChatInspector(store: store, isPresented: presentation))
    }
}

@MainActor @Observable final class KeyboardFixtureState {
    var sends = 0
    var lastMessage = ""
    @ObservationIgnored lazy var chat = SideChat(sourceSessionKey: "agent:main:main", context: "Offline keyboard test") { [weak self] method, params in
        guard let self else { return Data("{}".utf8) }
        if method == "sessions.create" {
            return try JSONSerialization.data(withJSONObject: ["key": params["key"] as? String ?? ""])
        }
        if method == "chat.send" {
            self.sends += 1; self.lastMessage = params["message"] as? String ?? ""
            return Data("{\"runId\":\"offline-run\"}".utf8)
        }
        if method == "chat.history" { return Data("{\"messages\":[],\"sessionInfo\":{\"hasActiveRun\":false}}".utf8) }
        return Data("{}".utf8)
    }
}
struct SideChatKeyboardFixture: View {
    @State private var state = KeyboardFixtureState()
    var body: some View {
        VStack {
            Text("Sends: \(state.sends)").accessibilityIdentifier("keyboard-send-count")
            Text(state.lastMessage).accessibilityIdentifier("keyboard-last-message")
            SideChatView(chat: state.chat, onClose: {})
        }.frame(minWidth: 400, minHeight: 500)
    }
}

/// Exercises the real chat-link sheet against a fixture-owned local file only.
/// No client is created or connected, and no account/session content is loaded.
struct DownloadDocumentFixture: View {
    let store: ChatStore
    @State private var link: DocumentLink?
    @State private var sourceURL: URL?
    @State private var verification = "Not checked"
    private let bytes = Data("Franklin offline export fixture\n".utf8)
    var body: some View {
        VStack {
            if let link { DocumentLinkView(link: link, store: store) }
            else { ProgressView("Preparing offline download") }
            Button("Verify downloaded source") {
                verification = sourceURL.flatMap { try? Data(contentsOf: $0) } == bytes ? "Source intact" : "Source missing or changed"
            }.accessibilityIdentifier("download-fixture.verify-source")
            Text(verification).accessibilityIdentifier("download-fixture.source-status")
        }
        .task {
            guard link == nil else { return }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CastDownloadFixture", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("Franklin-test.txt")
                try bytes.write(to: url, options: .atomic)
                let document = DocumentLink(url: url, sessionKey: "agent:main:offline-download-fixture")!
                await store.downloads.inspect(document.deliverable(in: [])) { url }
                sourceURL = url; link = document
            } catch { verification = "Fixture setup failed" }
        }
    }
}

/// Full production navigation with isolated defaults and no credentials/startup/connect call.
struct LandscapeSidebarFixture: View {
    let store: ChatStore
    @StateObject private var manager = WorkspaceManager(
        defaults: UserDefaults(suiteName: "CastLandscapeOfflineFixture")!,
        credentialProvider: { _ in nil }, includeDevelopmentWorkspaces: false,
        legacyLocalCredentialAvailable: false)
    @State private var pairing = false
    var body: some View {
        WorkspaceContentView(store: store, manager: manager, showingPairing: $pairing)
            .overlay(alignment: .topTrailing) {
                Text(store.selectedSessionKey ?? "none")
                    .font(.system(size: 1)).allowsHitTesting(false)
                    .accessibilityIdentifier("fixture-selected-chat")
            }
    }
}
