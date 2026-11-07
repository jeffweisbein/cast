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
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var syncing = false
    @State private var syncError: String?

    private var items: [Deliverable] {
        self.store.deliverableLedger.items.filter {
            (initialItemID == nil || $0.id == initialItemID) && (self.sessionKey == nil || SessionKeyMatcher.matches(self.sessionKey, $0.sessionKey))
                && (self.query.isEmpty || ($0.title + " " + $0.kind).localizedCaseInsensitiveContains(self.query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Files and links from conversations you’ve opened. Downloads are saved on this device. Sharing a result is not proof it was deployed or approved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(syncing ? "Refreshing attachments…" : "Refresh gateway attachments") { Task { await sync() } }.disabled(syncing)
                    if let syncError { Text(syncError).font(.caption).foregroundStyle(.secondary) }
                    Text("Refresh checks the selected conversation and up to 12 recent conversations. Open an older chat to include it.").font(.caption).foregroundStyle(.secondary)
                }
                if self.items.isEmpty {
                    ContentUnavailableView("No deliverables yet", systemImage: "tray",
                        description: Text("Open a conversation containing a report or file link to add it here."))
                }
                ForEach(self.items) { item in
                    DeliverableRow(item: item, store: self.store) {
                        self.store.selectedSessionKey = item.sessionKey
                        self.dismiss()
                    }
                    .id("\(item.reviewID):\(item.sizeBytes ?? -1):\(item.title):\(item.mimeType ?? "")") // Revisions/metadata changes cannot reuse an old row's download state.
                }
            }
            .task { await sync() }
            .refreshable { await sync() }
            .searchable(text: self.$query, prompt: "Search deliverables")
            .navigationTitle("Deliverables")
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

private struct DeliverableRow: View {
    let item: Deliverable
    let store: ChatStore
    let openConversation: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var cachedURL: URL?
    @State private var previewURL: URL?
    @State private var loading = false
    @State private var error: String?
    @State private var downloadTask: Task<Void, Never>?
    @State private var received = 0
    @State private var total: Int?
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
            if let url = await self.store.localDeliverableURL(self.item), !Task.isCancelled { self.cachedURL = url }
        }
        .quickLookPreview(self.$previewURL)
        .onDisappear { downloadTask?.cancel() }
        .fileExporter(isPresented: $exporting, document: cachedURL.map { DownloadExport(url: $0) },
                      contentType: .data, defaultFilename: cachedURL?.lastPathComponent) { result in
            if case .failure = result { error = "Couldn’t save the file to that location. Try another folder." }
        }
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
            Button(self.loading ? "Fetching…" : "Get file", systemImage: "arrow.down.doc") {
                self.loading = true
                received = 0; total = item.sizeBytes; error = nil
                downloadTask = Task {
                    defer { self.loading = false }
                    do {
                        self.cachedURL = try await self.store.fetchDeliverable(self.item) { count, expected in
                            await MainActor.run { self.received = count; self.total = expected }
                        }
                        self.error = nil
                    } catch is CancellationError { self.error = "Download cancelled. You can retry." }
                    catch { self.error = error.localizedDescription }
                }
            }
            .disabled(self.loading || !(self.store.gatewayMethods.contains(item.artifactID == nil ? "sessions.files.get" : "artifacts.download")))
            .help("Download this attachment from its authorized conversation")
            if loading {
                if let total, total > 0 { ProgressView(value: Double(received), total: Double(total)).frame(width: 90) }
                else { ProgressView().controlSize(.small) }
                Button("Cancel") { downloadTask?.cancel() }
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
