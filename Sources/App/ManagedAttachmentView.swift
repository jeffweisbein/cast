import SwiftUI

/// Generated attachments use the existing bounded, session-authorized downloader.
/// A failed transfer stays visible and retryable, including image-only replies.
struct ManagedAttachmentView: View {
    let attachment: ManagedChatAttachment
    let download: (@MainActor (ManagedChatAttachment) async throws -> URL)?
    let onOpen: (URL) -> Void
    @State private var load = ManagedAttachmentLoadState()
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let localURL = load.localURL {
                Button { onOpen(localURL) } label: {
                    if let image = load.image {
                        Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 320, maxHeight: 240)
                    } else {
                        Label(attachment.label, systemImage: "doc")
                    }
                }.buttonStyle(.plain).accessibilityLabel("Preview \(attachment.label)")
                ShareLink(item: localURL) { Label("Save or share", systemImage: "square.and.arrow.up") }
            } else if let error = load.error {
                Label(attachment.label, systemImage: "paperclip")
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("Retry download") { attempt += 1 }
            } else {
                ProgressView("Loading \(attachment.label)…")
            }
        }
        .task(id: ManagedAttachmentLoadState.ID(attachment: attachment, attempt: attempt)) {
            load.begin(.init(attachment: attachment, attempt: attempt))
            do {
                guard let download else { throw ArtifactTransferError.unavailable }
                let url = try await download(attachment)
                try Task.checkCancellation()
                load.localURL = url
                if attachment.mimeType?.hasPrefix("image/") == true {
                    let thumbnail = await MediaThumbnailLoader.shared.thumbnail(for:
                        MediaItem(id: url.path, path: url.path, mimeType: attachment.mimeType, date: nil), maxPixel: 640)
                    try Task.checkCancellation()
                    load.image = thumbnail
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.load.localURL = nil; self.load.error = error.localizedDescription } }
        }
    }
}

// Owns the state that must survive a lazy row disappearing/reappearing. A new
// attachment/retry resets it; re-running the same SwiftUI task keeps its geometry.
struct ManagedAttachmentLoadState {
    struct ID: Equatable { let attachment: ManagedChatAttachment; let attempt: Int }
    private(set) var id: ID?
    var localURL: URL?
    var image: CGImage?
    var error: String?
    mutating func begin(_ id: ID) {
        if self.id != id { self = Self(id: id) }
        error = nil
    }
}
