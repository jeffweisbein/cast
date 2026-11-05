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
    @State private var localURL: URL?
    @State private var previewURL: URL?
    @State private var error: String?
    @State private var loading = false
    @State private var attachments = false
    @State private var transfer: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label((link.path as NSString).lastPathComponent, systemImage: "doc")
                    .font(.headline).textSelection(.enabled)
                if loading { ProgressView("Downloading to this device…") }
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
        .onAppear { download() }
        .onDisappear { transfer?.cancel() }
        .quickLookPreview($previewURL)
        .sheet(isPresented: $attachments) { DeliverablesView(store: store, sessionKey: link.sessionKey) }
    }

    private func download() {
        guard !loading else { return }
        loading = true; error = nil
        transfer = Task {
            defer { loading = false }
            do {
                let item = link.deliverable(in: store.deliverableLedger.items)
                let url = try await store.fetchDeliverable(item)
                try Task.checkCancellation()
                localURL = url
                previewURL = url
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
