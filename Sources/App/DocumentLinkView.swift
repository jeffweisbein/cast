import QuickLook
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Never forwards a gateway filesystem URL to NSWorkspace/UIApplication.
struct DocumentLinkView: View {
    let link: DocumentLink
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var item: Deliverable
    init(link: DocumentLink, store: ChatStore) {
        self.link = link; self.store = store
        _item = State(initialValue: link.deliverable(in: store.deliverableLedger.items))
    }
    private var entry: DownloadCenter.Entry? { store.downloads.entry(for: item) }
    private var localURL: URL? { if case .saved(let url) = entry?.phase { return url }; return nil }
    private var loading: Bool { entry?.phase.isActive == true }
    private var error: String? {
        switch entry?.phase {
        case .failed(let text): return text
        case .cancelled: return "Download cancelled. You can retry."
        default: return nil
        }
    }
    @State private var previewURL: URL?
    @State private var attachments = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label((link.path as NSString).lastPathComponent, systemImage: "doc")
                    .font(.headline).textSelection(.enabled)
                if loading {
                    ProgressView("Downloading to this device…")
                    Button("Cancel download") { store.downloads.cancel(item) }
                    Text("You can close this sheet. Follow progress in Downloads.").font(.caption)
                }
                if let error { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
                if let localURL {
                    Text("Saved on this device.").foregroundStyle(.secondary)
                    HStack {
                        Button("Preview") { previewURL = localURL }
                        #if os(macOS)
                        Button("Open") { NSWorkspace.shared.open(localURL) }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([localURL]) }
                        #endif
                        ShareLink(item: localURL)
                    }
                } else if !loading {
                    Button("Retry download") { download() }
                    Button("View conversation attachments") { attachments = true }
                }
                Spacer(minLength: 0)
            }.padding(24)
            .navigationTitle("Document")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 280)
        #endif
        .task {
            await store.inspectDownload(item)
            if !Task.isCancelled, entry == nil { download() }
        }
        .quickLookPreview($previewURL)
        .sheet(isPresented: $attachments) { DeliverablesView(store: store, sessionKey: link.sessionKey) }
    }

    private func download() { store.startDownload(item) }
}
