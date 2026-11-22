import ImageIO
import SwiftUI

/// Visual library of what agents shared: images, files, pull requests and links, from the
/// existing deliverable ledger. Nothing is fetched automatically from the open web; image
/// thumbnails decode only from files already downloaded inside Cast.
struct ResultsLibraryView: View {
    let store: ChatStore
    let openConversation: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var kind: ResultKind?
    @State private var syncing = false
    @State private var hasSynced = false
    @State private var syncError: String?
    @State private var selected: Deliverable?
    @State private var lastAutomaticSyncAt: Date?

    private var isConnected: Bool { if case .connected = self.store.connectionState { return true }; return false }

    var body: some View {
        NavigationStack {
            let ledger = self.store.deliverableLedger.items
            let items = ResultsLibrary.items(ledger, kind: self.kind, query: self.query)
            let counts = ResultsLibrary.counts(ledger)
            let phase = ResultsLibrary.phase(
                itemCount: counts.values.reduce(0, +),
                syncing: self.syncing, hasSynced: self.hasSynced, syncError: self.syncError,
                supportsArtifacts: self.store.gatewayMethods.contains("artifacts.list"),
                connected: self.isConnected)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch phase {
                    case .content:
                        self.banner
                        self.filterBar(counts)
                        if items.isEmpty {
                            ContentUnavailableView.search(text: self.query)
                                .padding(.top, 40)
                        } else {
                            self.grid(items)
                        }
                    case .loading:
                        ProgressView("Checking recent conversations…")
                            .frame(maxWidth: .infinity).padding(.top, 120)
                    case let .failed(message):
                        ContentUnavailableView {
                            Label("Couldn’t load results", systemImage: "exclamationmark.triangle")
                        } description: { Text(message) } actions: {
                            Button("Try again") { Task { await self.sync() } }.buttonStyle(.bordered)
                        }
                        .padding(.top, 60)
                    case let .empty(reason):
                        ContentUnavailableView {
                            Label(reason == .offline ? "Offline" : "No results yet",
                                  systemImage: reason == .offline ? "wifi.exclamationmark" : "square.grid.2x2")
                        } description: {
                            Text(Self.emptyMessage(reason))
                        }
                        .padding(.top, 60)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle("Results")
            .searchable(text: self.$query, prompt: "Search results")
            .refreshable { await self.sync() }
            // Re-runs on reconnect so an offline launch does not stay stale.
            .task(id: self.isConnected) { await self.sync(automatic: true) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if self.syncing {
                        ProgressView().accessibilityLabel("Refreshing results")
                    } else {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await self.sync() } }
                            .disabled(!self.isConnected)
                    }
                }
            }
            .sheet(item: self.$selected) { item in
                ResultDetailSheet(store: self.store, item: item) { key in
                    self.selected = nil
                    self.openConversation(key)
                }
            }
        }
    }

    static func emptyMessage(_ reason: ResultsLibraryPhase.EmptyReason) -> String {
        switch reason {
        case .offline:
            return "Reconnect to check your conversations. Results already saved on this device appear here."
        case .unsupported:
            return "This gateway doesn’t list attachments. Files and links your agent mentions still appear after you open that chat."
        case .none:
            return "Images, files and pull requests your agent shares will collect here. Cast checks the open chat and up to \(DeliverableSync.recentConversationLimit) recent conversations."
        }
    }

    @ViewBuilder private var banner: some View {
        if !self.isConnected {
            Label("Offline — showing results saved on this device.", systemImage: "wifi.exclamationmark")
                .font(.footnote).foregroundStyle(.secondary)
        } else if let syncError {
            HStack {
                Label(syncError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { Task { await self.sync() } }.font(.footnote).buttonStyle(.borderless)
            }
        }
    }

    private func filterBar(_ counts: [ResultKind: Int]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                self.chip(nil, title: "All", count: nil)
                ForEach(ResultKind.allCases) { option in
                    let count = counts[option] ?? 0
                    if count > 0 || self.kind == option { self.chip(option, title: option.title, count: count) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter results")
    }

    private func chip(_ option: ResultKind?, title: String, count: Int?) -> some View {
        let selected = self.kind == option
        return Button {
            if self.reduceMotion { self.kind = option } else { withAnimation(.snappy(duration: 0.22)) { self.kind = option } }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if let count, count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: selected ? 0 : 1))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? "All results")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("results-filter-" + (option?.rawValue ?? "all"))
    }

    private func grid(_ items: [Deliverable]) -> some View {
        let titles = self.conversationTitles(for: items)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 158, maximum: 260), spacing: 12)], spacing: 12) {
            ForEach(items) { item in
                Button { self.selected = item } label: {
                    ResultCard(item: item, store: self.store,
                               conversation: titles[SessionKeyMatcher.canonical(item.sessionKey)] ?? "Conversation",
                               isNew: !self.store.reviewedWork.ids.contains(item.reviewID))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("result-library-card-" + item.id)
                .contextMenu {
                    Button("Open chat", systemImage: "bubble.left") { self.openConversation(item.sessionKey) }
                    if !self.store.reviewedWork.ids.contains(item.reviewID) {
                        Button("Mark reviewed", systemImage: "checkmark.circle") { self.store.markDeliverableReviewed(item.reviewID) }
                    }
                    if let url = item.webURL { ShareLink(item: url) }
                }
            }
        }
        .animation(self.reduceMotion ? nil : .snappy(duration: 0.22), value: items.map(\.id))
    }

    /// One pass over known sessions, only for the conversations on screen.
    private func conversationTitles(for items: [Deliverable]) -> [String: String] {
        let wanted = Set(items.map { SessionKeyMatcher.canonical($0.sessionKey) })
        var titles: [String: String] = [:]
        for row in self.store.personalChats + self.store.sessions {
            let key = SessionKeyMatcher.canonical(row.key)
            guard wanted.contains(key), titles[key] == nil else { continue }
            titles[key] = self.store.chatTitle(row)
        }
        return titles
    }

    private func sync(automatic: Bool = false) async {
        guard !self.syncing else { return }
        guard self.isConnected else {
            self.hasSynced = true
            self.lastAutomaticSyncAt = nil
            return
        }
        // Re-entering a tab should not refetch every conversation. Manual refresh and
        // a reconnect remain immediate, while appearance refreshes are bounded.
        if automatic, let last = self.lastAutomaticSyncAt, Date().timeIntervalSince(last) < 60 { return }
        self.lastAutomaticSyncAt = Date()
        self.syncing = true; defer { self.syncing = false }
        guard let outcome = await DeliverableSync.run(store: self.store, sessionKey: nil) else { return }
        self.syncError = outcome == .unsupported ? nil : outcome.message
        self.hasSynced = true
    }
}

// MARK: - Card

struct ResultCard: View {
    let item: Deliverable
    let store: ChatStore
    let conversation: String
    let isNew: Bool

    private var kind: ResultKind { ResultKind.of(self.item) }
    private var cachedURL: URL? {
        if case .saved(let url) = self.store.downloads.entry(for: self.item)?.phase { return url }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ResultPreviewSurface(item: self.item, localURL: self.kind == .image ? self.cachedURL : nil, compact: true)
                    .frame(height: 112)
                    .frame(maxWidth: .infinity)
                    .clipped()
                if self.isNew {
                    Text("New")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                        .accessibilityLabel("Not yet reviewed on this device")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(self.item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                Text(ResultsLibrary.subtitle(for: self.item))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left").imageScale(.small).accessibilityHidden(true)
                    Text(self.conversation).lineLimit(1)
                    if let ms = self.item.sharedAt {
                        Text("·")
                        Text(Date(timeIntervalSince1970: ms / 1000), format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .lineLimit(1).fixedSize()
                    }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(self.kind.singular): \(self.item.title), from \(self.conversation)")
        .accessibilityHint("Shows actions for this result.")
        .task(id: self.item.reviewID) {
            // Inspect each visible image locally, even on an offline launch. This does not
            // download files and is not limited to the first page of the ledger.
            if self.kind == .image && self.item.webURL == nil {
                await self.store.inspectDownload(self.item)
            }
        }
    }
}

/// Thumbnail when a local file is already on this device; otherwise a calm typed glyph.
struct ResultPreviewSurface: View {
    let item: Deliverable
    let localURL: URL?
    var compact = true
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Self.tint(for: self.item).opacity(0.12))
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: self.compact ? .fill : .fit)
                    .transition(.opacity)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: ResultsLibrary.systemImage(for: self.item))
                        .font(.system(size: self.compact ? 28 : 44, weight: .regular))
                        .foregroundStyle(Self.tint(for: self.item))
                    if ResultKind.of(self.item) == .pullRequest, let pr = PullRequestReference.parse(self.item.target) {
                        Text("#\(pr.number)").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                    } else if ResultKind.of(self.item) == .image, self.localURL == nil, !self.compact {
                        Text("Get the file to preview it here.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .task(id: self.localURL) {
            guard let url = self.localURL else { self.image = nil; return }
            let maxPixel = self.compact ? 480 : 1600
            self.image = await Task.detached(priority: .utility) { Self.thumbnail(url: url, maxPixel: maxPixel) }.value
        }
    }

    static func tint(for item: Deliverable) -> Color {
        switch ResultKind.of(item) {
        case .image: return .teal
        case .file: return .blue
        case .pullRequest: return .purple
        case .link: return .gray
        }
    }

    nonisolated static func thumbnail(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }
}

// MARK: - Detail

/// Large preview plus the existing Deliverables row, so download, preview, save-as, share and
/// review behave exactly as they do everywhere else in Cast.
struct ResultDetailSheet: View {
    let store: ChatStore
    let item: Deliverable
    let openConversation: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var cachedURL: URL? {
        if case .saved(let url) = self.store.downloads.entry(for: self.item)?.phase { return url }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ResultPreviewSurface(item: self.item, localURL: ResultKind.of(self.item) == .image ? self.cachedURL : nil, compact: false)
                        .frame(height: 240)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
                Section {
                    DeliverableRow(item: self.item, store: self.store) {
                        self.openConversation(self.item.sessionKey)
                    }
                }
            }
            .navigationTitle(ResultKind.of(self.item).singular)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }
}
