import SwiftUI

/// Generated attachments use the existing bounded, session-authorized downloader.
/// A failed transfer stays visible and retryable, including image-only replies.
struct ManagedAttachmentView: View {
    let attachment: ManagedChatAttachment
    let download: (@MainActor (ManagedChatAttachment) async throws -> URL)?
    let onOpen: (URL) -> Void
    @State private var localURL: URL?
    @State private var image: CGImage?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let localURL {
                Button { onOpen(localURL) } label: {
                    if let image {
                        Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 320, maxHeight: 240)
                    } else {
                        Label(attachment.label, systemImage: "doc")
                    }
                }.buttonStyle(.plain).accessibilityLabel("Preview \(attachment.label)")
                ShareLink(item: localURL) { Label("Save or share", systemImage: "square.and.arrow.up") }
            } else if let error {
                Label(attachment.label, systemImage: "paperclip")
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("Retry download") { attempt += 1 }
            } else {
                ProgressView("Loading \(attachment.label)…")
            }
        }
        .task(id: "\(attachment.id):\(attempt)") {
            error = nil
            do {
                guard let download else { throw ArtifactTransferError.unavailable }
                let url = try await download(attachment)
                try Task.checkCancellation()
                localURL = url
                if attachment.mimeType?.hasPrefix("image/") == true {
                    image = await MediaThumbnailLoader.shared.thumbnail(for:
                        MediaItem(id: url.path, path: url.path, mimeType: attachment.mimeType, date: nil), maxPixel: 640)
                }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
