#if os(macOS) && DEBUG
import SwiftUI

/// Opt-in offline render fixture. No gateway or user workspace is started.
struct ReliabilityFixtureView: View {
    let store: ChatStore
    let mode: String
    var body: some View {
        Group {
            if mode == "downloads" { DeliverablesView(store: store, startsWithDownloads: true) }
            else if mode == "needs" { NeedsYouView(store: store) }
            else { ChatView(store: store, allowsSending: false) }
        }.frame(width: 1000, height: 760).task {
            store.installOfflineDiagnosticTranscript((0..<420).map { i in
                ChatMessage(id: "fixture-\(i)", role: i % 2 == 0 ? "user" : "assistant",
                    blocks: [ChatContentBlock(type: "text", text: i % 2 == 0 ? "Can you check the report \(i)?" : "Report \(i) is ready. The changes are verified locally; delivery still needs confirmation.", thinking: nil, name: nil, mimeType: nil, fileName: nil)], timestamp: Double(1_790_000_000_000 + i * 1000))
            })
            if mode == "downloads" {
                for i in 0..<3 {
                    let item = Deliverable(id: "fixture-download-\(i)", sessionKey: "fixture", messageID: "m", title: ["Release notes.pdf", "QA packet.zip", "Session report.txt"][i], target: "artifact:fixture-\(i)", kind: "Document", sharedAt: nil)
                    store.downloads.start(item) { progress in
                        if i == 1 { throw URLError(.notConnectedToInternet) }
                        await progress(2_400_000, 8_000_000)
                        try await Task.sleep(nanoseconds: 180_000_000_000)
                        throw CancellationError()
                    }
                    if i == 2 { store.downloads.cancel(item) }
                }
            }
            if mode == "needs" {
                let bytes = Data(#"{"type":"event","event":"exec.approval.requested","payload":{"id":"fixture-approval","expiresAtMs":9999999999999,"request":{"command":"Run the report verification","sessionKey":"fixture"}}}"#.utf8)
                if let event = try? JSONDecoder().decode(EventFrame.self, from: bytes) { store.handleEvent(event) }
            }
        }
    }
}
#endif
