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

    private var rows: [DownloadCenter.Row] {
        store.downloads.rows(ledger: store.deliverableLedger.items).filter { row in
            let item = row.item
            return (initialItemID == nil || item.id == initialItemID) && (sessionKey == nil || SessionKeyMatcher.matches(sessionKey, item.sessionKey))
                && (query.isEmpty || (item.title + " " + item.kind).localizedCaseInsensitiveContains(query))
                && (!downloadsOnly || row.entry != nil)
        }.sorted { left, right in
            let a = left.entry, b = right.entry
            if (a?.phase.isActive == true) != (b?.phase.isActive == true) { return a?.phase.isActive == true }
            if downloadsOnly { return (a?.updatedAt ?? .distantPast, left.id) > (b?.updatedAt ?? .distantPast, right.id) }
            return (left.item.sharedAt ?? 0, left.id) > (right.item.sharedAt ?? 0, right.id)
        }
    }

    var body: some View {
        NavigationStack {
            let rows = self.rows
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
                if rows.isEmpty {
                    ContentUnavailableView(downloadsOnly ? "No downloads yet" : "No deliverables yet", systemImage: "tray",
                        description: Text(downloadsOnly ? "Choose All files & links to download a file. Saved files from this workspace appear here after checking the local cache." : "Open a conversation containing a report or file link to add it here."))
                }
                ForEach(rows) { row in
                    let item = row.item
                    DeliverableRow(item: item, store: self.store) {
                        self.store.selectedSessionKey = item.sessionKey
                        self.dismiss()
                    }
                    .id(row.id)
                }
            }
            .onAppear { downloadsOnly = startsWithDownloads }
            .task {
                for item in store.deliverableLedger.items where item.webURL == nil {
                    if Task.isCancelled { return }
                    await store.inspectDownload(item)
                }
            }
            .task { await sync() }
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
        guard let outcome = await DeliverableSync.run(store: store, sessionKey: sessionKey) else { return }
        syncError = outcome.message
    }

}

/// One refresh path for the Deliverables sheet and the Results library: the selected chat plus
/// up to 12 recent conversations, each through its own authorized `artifacts.list` call.
enum DeliverableSync {
    enum Outcome: Equatable {
        case refreshed, unsupported, partialFailure
        var message: String? {
            switch self {
            case .refreshed: return nil
            case .unsupported: return "This gateway does not expose downloadable attachments. Existing file links are still shown."
            case .partialFailure: return "Some attachments could not be refreshed. Check the connection and try again."
            }
        }
    }

    static let recentConversationLimit = 12

    /// Returns nil when cancelled, so a dismissed screen never reports a stale failure.
    @MainActor static func run(store: ChatStore, sessionKey: String?) async -> Outcome? {
        guard store.gatewayMethods.contains("artifacts.list") else { return .unsupported }
        var keys = sessionKey.map { [$0] }
            ?? ([store.selectedSessionKey].compactMap { $0 } + store.sessions.prefix(Self.recentConversationLimit).map(\.key))
        var seen = Set<String>(); keys = keys.filter { seen.insert($0).inserted }
        var failures = 0
        for key in keys {
            if Task.isCancelled { return nil }
            do { try await store.refreshArtifacts(sessionKey: key) }
            catch is CancellationError { return nil }
            catch { failures += 1 }
        }
        return failures == 0 ? .refreshed : .partialFailure
    }
}

struct DeliverableRow: View {
    let item: Deliverable
    let store: ChatStore
    let openConversation: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var previewURL: URL?
    @State private var exporting = false
    @State private var exportResultMessage: String?
    private var entry: DownloadCenter.Entry? { store.downloads.entry(for: item) }
    private var cachedURL: URL? {
        if case .saved(let url) = entry?.phase { return url }; return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(self.item.title).font(.headline).textSelection(.enabled)
            } icon: {
                Image(systemName: ResultsLibrary.systemImage(for: self.item))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
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
        }
        .padding(.vertical, 6)
        .task(id: self.item.reviewID) {
            await store.inspectDownload(item)
        }
        .quickLookPreview(self.$previewURL)
        .modifier(DownloadExportPresenter(url: cachedURL, exporting: $exporting, resultMessage: $exportResultMessage))
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
            DownloadSaveButton(exporting: $exporting, resultMessage: $exportResultMessage)
            ShareLink(item: url)
            Text("Downloaded inside Cast").font(.caption2).foregroundStyle(.secondary)
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
            if entry?.phase.isActive != true && entry?.canRetry != false {
                Button(entry == nil ? "Get file" : "Retry download", systemImage: "arrow.down.doc") {
                    store.startDownload(item)
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

/// Shared by the chat link sheet and Downloads. A completed transfer is a private
/// cache entry, not a user-visible Files/Downloads export until this action succeeds.
struct DownloadSaveButton: View {
    @Binding var exporting: Bool
    @Binding var resultMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Save as…", systemImage: "square.and.arrow.down") { resultMessage = nil; exporting = true }
                .accessibilityIdentifier("download.save-copy")
            if let resultMessage { Text(resultMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// The presenter and its bindings belong to the stable document/row, never a
/// ViewThatFits alternative. Export feedback can itself change the chosen layout.
struct DownloadExportPresenter: ViewModifier {
    let url: URL?
    @Binding var exporting: Bool
    @Binding var resultMessage: String?
    func body(content: Content) -> some View {
        content.fileExporter(isPresented: $exporting, document: url.map { DownloadExport(url: $0) },
                      contentType: url.flatMap { UTType(filenameExtension: $0.pathExtension) } ?? .data,
                      defaultFilename: url?.lastPathComponent) { result in
            switch result {
            case .success: resultMessage = "Saved a copy to your selected folder."
            case .failure(let error):
                let cocoa = error as NSError
                if cocoa.domain != NSCocoaErrorDomain || cocoa.code != NSUserCancelledError {
                    resultMessage = "Couldn’t save the file to that location. Try another folder."
                }
            }
        }
    }
}

struct DownloadExport: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let url: URL
    init(url: URL) { self.url = url }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }
    func snapshot() throws -> FileWrapper { try FileWrapper(url: url, options: .immediate) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { try snapshot() }
}
