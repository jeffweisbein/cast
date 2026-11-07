import QuickLook
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct DeliverablesView: View {
    let store: ChatStore
    var sessionKey: String? = nil
    var initialItemID: String? = nil
    var startsWithDownloads = false
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var downloadsOnly = false
    @State private var syncing = false
    @State private var syncError: String?

    private var allItems: [Deliverable] {
        var indexed = Dictionary(store.deliverableLedger.items.map { (DownloadCenter.key($0), $0) }, uniquingKeysWith: { first, _ in first })
        for entry in store.downloads.sorted { indexed[entry.id] = entry.item }
        return indexed.values.sorted { ($0.sharedAt ?? 0, $0.id) > ($1.sharedAt ?? 0, $1.id) }
    }
    private var items: [Deliverable] {
        allItems.filter {
            (initialItemID == nil || $0.id == initialItemID) && (sessionKey == nil || SessionKeyMatcher.matches(sessionKey, $0.sessionKey))
                && (query.isEmpty || ($0.title + " " + $0.kind).localizedCaseInsensitiveContains(query))
                && (!downloadsOnly || store.downloads.entry(for: $0) != nil)
        }.sorted { left, right in
            let a = store.downloads.entry(for: left), b = store.downloads.entry(for: right)
            if a?.phase.isActive != b?.phase.isActive { return a?.phase.isActive == true }
            if downloadsOnly { return (a?.updatedAt ?? .distantPast) > (b?.updatedAt ?? .distantPast) }
            return (left.sharedAt ?? 0, left.id) > (right.sharedAt ?? 0, right.id)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Show", selection: $downloadsOnly) {
                        Text("All files & links").tag(false)
                        Text("Downloads").tag(true)
                    }.pickerStyle(.segmented)
                    Text("Downloads stay on this device. You can close this window while a file downloads; keep Cast open. Attempts are not resumed automatically after quitting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(syncing ? "Refreshing attachments…" : "Refresh gateway attachments") { Task { await sync() } }.disabled(syncing)
                    if let syncError { Text(syncError).font(.caption).foregroundStyle(.secondary) }
                    Text("Refresh checks the selected conversation and up to 12 recent conversations. Open an older chat to include it.").font(.caption).foregroundStyle(.secondary)
                }
                if self.items.isEmpty {
                    ContentUnavailableView(downloadsOnly ? "No downloads yet" : "No deliverables yet", systemImage: "tray",
                        description: Text(downloadsOnly ? "Choose All files & links to download a file. Saved files from this workspace appear here after checking the local cache." : "Open a conversation containing a report or file link to add it here."))
                }
                ForEach(self.items) { item in
                    DeliverableRow(item: item, store: self.store) {
                        self.store.selectedSessionKey = item.sessionKey
                        self.dismiss()
                    }
                    .id("\(item.reviewID):\(item.sizeBytes ?? -1):\(item.title):\(item.mimeType ?? "")") // Revisions/metadata changes cannot reuse an old row's download state.
                }
            }
            .onAppear { downloadsOnly = startsWithDownloads }
            .task {
                for item in allItems where item.webURL == nil {
                    if Task.isCancelled { return }
                    await store.downloads.inspect(item) { await store.localDeliverableURL(item) }
                }
                await sync()
            }
            .refreshable { await sync() }
            .searchable(text: self.$query, prompt: "Search deliverables")
            .navigationTitle(downloadsOnly ? "Downloads" : "Deliverables")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { self.dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 480)
        #endif
    }
    private func sync() async {
        guard !syncing else { return }; syncing = true; defer { syncing = false }
        guard store.gatewayMethods.contains("artifacts.list") else { syncError = "This gateway does not expose downloadable attachments. Existing file links are still shown."; return }
        var keys = sessionKey.map { [$0] } ?? ([store.selectedSessionKey].compactMap { $0 } + store.sessions.prefix(12).map(\.key))
        var seen = Set<String>(); keys = keys.filter { seen.insert($0).inserted }
        var failures = 0
        for key in keys {
            if Task.isCancelled { return }
            do { try await store.refreshArtifacts(sessionKey: key) }
            catch is CancellationError { return }
            catch { failures += 1 }
        }
        syncError = failures == 0 ? nil : "Some attachments could not be refreshed. Check the connection and try again."
    }

}

struct DeliverableRow: View {
    let item: Deliverable
    let store: ChatStore
    let openConversation: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var previewURL: URL?
    @State private var error: String?
    private var entry: DownloadCenter.Entry? { store.downloads.entry(for: item) }
    private var cachedURL: URL? {
        if case .saved(let url) = entry?.phase { return url }; return nil
    }
    @State private var exporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.item.title).font(.headline).textSelection(.enabled)
            HStack {
                Text(self.item.kind)
                if let ms = self.item.sharedAt {
                    Text("· Shared")
                    Text(Date(timeIntervalSince1970: ms / 1000), style: .date)
                }
                if self.store.reviewedWork.ids.contains(self.item.reviewID) {
                    Label("Reviewed", systemImage: "checkmark.circle")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { self.actions }
                VStack(alignment: .leading) { self.actions }
            }
            if let error = self.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 6)
        .task(id: self.item.reviewID) {
            await store.downloads.inspect(item) { await store.localDeliverableURL(item) }
        }
        .quickLookPreview(self.$previewURL)
        .fileExporter(isPresented: $exporting, document: cachedURL.map { DownloadExport(url: $0) },
                      contentType: .data, defaultFilename: cachedURL?.lastPathComponent) { result in
            if case .failure = result { error = "Couldn’t save the file to that location. Try another folder." }
        }
    }

    private var canDownload: Bool {
        guard case .connected = store.connectionState else { return false }
        return store.gatewayMethods.contains(item.artifactID == nil ? "sessions.files.get" : "artifacts.download")
    }

    @ViewBuilder private var actions: some View {
        if let url = self.item.webURL {
            Button("Open", systemImage: "arrow.up.right.square") { self.openURL(url) }
            ShareLink(item: url)
        } else if let url = self.cachedURL {
            Button("Preview", systemImage: "doc.text.magnifyingglass") { self.previewURL = url }
            #if os(macOS)
            Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            #endif
            Button("Save as…", systemImage: "square.and.arrow.down") { exporting = true }
            ShareLink(item: url)
            Text("On this device").font(.caption2).foregroundStyle(.secondary)
        } else {
            if let entry {
                switch entry.phase {
                case .downloading:
                    VStack(alignment: .leading, spacing: 4) {
                        if let total = entry.total, total > 0 {
                            ProgressView(value: Double(min(entry.received, total)), total: Double(total))
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(entry.received), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))")
                        } else { ProgressView("Downloading…") }
                    }.font(.caption).frame(maxWidth: 230)
                    Button("Cancel") { store.downloads.cancel(item) }
                case .failed(let message): Text(message).font(.caption).foregroundStyle(.red)
                case .cancelled: Text("Cancelled — retry when you’re ready.").font(.caption).foregroundStyle(.secondary)
                case .saved: EmptyView()
                }
            }
            if entry?.phase.isActive != true {
                Button(entry == nil ? "Get file" : "Retry download", systemImage: "arrow.down.doc") {
                    error = nil; store.startDownload(item)
                }
                .disabled(!canDownload)
                .help("Download this attachment from its authorized conversation")
                if !canDownload { Text("Reconnect to download this file.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        Button("Conversation", action: self.openConversation)
        if !self.store.reviewedWork.ids.contains(self.item.reviewID) {
            Button("Mark reviewed") { self.store.markDeliverableReviewed(self.item.reviewID) }
        }
    }
}

private struct DownloadExport: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let url: URL
    init(url: URL) { self.url = url }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}
