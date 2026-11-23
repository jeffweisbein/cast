import ImageIO
import SwiftUI

/// What the composer has attached, is still preparing, or could not attach, in one compact
/// horizontal row above the text field. Nothing here is decorative: a thumbnail is a real
/// prepared attachment, a spinner is real work that can be cancelled, and a warning carries
/// the actual reason.
struct ComposerAttachmentTray: View {
    let attachments: [PreparedAttachment]
    let imports: [ComposerImportQueue.Item]
    let upload: AttachmentUploadProgress?
    let deliversExternally: Bool
    let onRemove: (PreparedAttachment) -> Void
    let onCancelImport: (UUID) -> Void
    let onCancelUpload: () -> Void
    let onDisableExternalDelivery: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let tileSide: CGFloat = 56

    private var preparingCount: Int { self.imports.filter(\.isPreparing).count }

    private var hasTiles: Bool { !self.attachments.isEmpty || !self.imports.isEmpty }

    private var tileIDs: [UUID] { self.attachments.map(\.id) + self.imports.map(\.id) }

    private var tileTransition: AnyTransition {
        self.reduceMotion ? .opacity : .scale(scale: 0.86).combined(with: .opacity)
    }

    var body: some View {
        if self.hasTiles || self.upload != nil || self.deliversExternally {
            VStack(alignment: .leading, spacing: 8) {
                if let upload = self.upload {
                    ComposerUploadRow(progress: upload, onCancel: self.onCancelUpload)
                        .padding(.horizontal, 12)
                }
                if self.hasTiles {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(self.attachments) { attachment in
                                ComposerAttachmentTile(attachment: attachment) { self.onRemove(attachment) }
                                    .transition(self.tileTransition)
                            }
                            ForEach(self.imports) { item in
                                ComposerImportTile(item: item) { self.onCancelImport(item.id) }
                                    .transition(self.tileTransition)
                            }
                        }
                        .padding(.horizontal, 12)
                        // Scoped to the row's own contents. The tray's arrival changes the
                        // composer's height, which is never animated: the transcript above
                        // re-anchors on that frame change.
                        .animation(self.reduceMotion ? nil : .snappy(duration: 0.22), value: self.tileIDs)
                    }
                    .accessibilityIdentifier("composer-attachment-tray")
                }
                if self.preparingCount > 0 {
                    Label(ComposerSendGate.waitingLabel(count: self.preparingCount), systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .accessibilityIdentifier("composer-send-waiting")
                }
                if self.deliversExternally {
                    ComposerExternalDeliveryChip(onDisable: self.onDisableExternalDelivery)
                        .padding(.horizontal, 12)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 2)
        }
    }
}

/// Visible only while replies will leave Cast. Turning the option on is a deliberate menu
/// choice; turning it off is one tap here. Sending still asks for confirmation.
private struct ComposerExternalDeliveryChip: View {
    let onDisable: () -> Void

    var body: some View {
        Button(action: self.onDisable) {
            HStack(spacing: 6) {
                Image(systemName: "paperplane.fill")
                Text("External delivery on")
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.red)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(Capsule().fill(.red.opacity(0.12)))
            // The capsule stays compact; the safety off-switch keeps a full 44pt hit area.
            .frame(minHeight: ComposerSendGate.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("External delivery enabled")
        .accessibilityHint("Replies may be sent to a linked channel. Tap to keep replies in Cast.")
        .accessibilityIdentifier("composer-external-delivery-chip")
    }
}

private struct ComposerUploadRow: View {
    let progress: AttachmentUploadProgress
    let onCancel: () -> Void

    private var fraction: Double {
        min(1, Double(self.progress.completedBytes) / Double(max(1, self.progress.totalBytes)))
    }

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: self.fraction)
                .frame(maxWidth: .infinity)
            Text("Uploading \(Int((self.fraction * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Cancel", action: self.onCancel)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Uploading original files")
    }
}

/// Corner remove control shared by every tile. The glyph is small; the hit area is not.
private struct ComposerTileRemoveButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.black.opacity(0.62)))
                .padding(6)
                .frame(width: ComposerSendGate.minimumHitTarget, height: ComposerSendGate.minimumHitTarget,
                       alignment: .topTrailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(self.label)
    }
}

private struct ComposerTileCard<Leading: View>: View {
    let title: String
    let detail: String
    let detailIsWarning: Bool
    @ViewBuilder let leading: () -> Leading
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var textWidth: CGFloat {
        let base: CGFloat = self.detailIsWarning ? 230 : 150
        return self.dynamicTypeSize.isAccessibilitySize ? base * 1.6 : base
    }

    var body: some View {
        HStack(spacing: 8) {
            self.leading()
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(self.detail)
                    .font(.caption2)
                    .foregroundStyle(self.detailIsWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(self.dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: self.textWidth, alignment: .leading)
        }
        .padding(.leading, 10)
        .padding(.trailing, 38)
        .padding(.vertical, 6)
        // Grows with Dynamic Type instead of clipping the name and reason.
        .frame(minHeight: ComposerAttachmentTray.tileSide)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.6)))
    }
}

/// A prepared attachment: thumbnail for images, name and size for everything else.
struct ComposerAttachmentTile: View {
    let attachment: PreparedAttachment
    let onRemove: () -> Void

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(self.attachment.byteCount), countStyle: .file)
    }

    private var symbol: String {
        if self.attachment.mimeType.hasPrefix("video/") { return "video.fill" }
        if self.attachment.type == "audio" { return "waveform" }
        return "doc"
    }

    var body: some View {
        Group {
            if self.attachment.type == "image" {
                ComposerAttachmentThumbnail(attachment: self.attachment)
            } else {
                ComposerTileCard(title: self.attachment.fileName, detail: self.sizeText, detailIsWarning: false) {
                    Image(systemName: self.symbol)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            ComposerTileRemoveButton(label: "Remove \(self.attachment.fileName)", action: self.onRemove)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachment \(self.attachment.fileName), \(self.sizeText)")
    }
}

/// Decodes a small thumbnail once, off the main actor. The composer body re-evaluates on
/// every keystroke, so decoding the full prepared JPEG there would be paid per character.
private struct ComposerAttachmentThumbnail: View {
    let attachment: PreparedAttachment
    @State private var thumbnail: CGImage?

    var body: some View {
        let side = ComposerAttachmentTray.tileSide
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.6))
            if let thumbnail = self.thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: self.attachment.id) {
            let data = self.attachment.data
            let image = await Task.detached(priority: .userInitiated) {
                ComposerThumbnailDecoder.thumbnail(from: data, maxPixelSize: 224)
            }.value
            guard !Task.isCancelled else { return }
            self.thumbnail = image
        }
    }
}

enum ComposerThumbnailDecoder {
    static func thumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// An import that is not an attachment yet: still preparing, or failed with its reason.
struct ComposerImportTile: View {
    let item: ComposerImportQueue.Item
    let onCancel: () -> Void

    private var failure: String? {
        if case let .failed(message) = self.item.phase { return message }
        return nil
    }

    var body: some View {
        ComposerTileCard(
            title: self.item.title,
            detail: self.failure ?? "Preparing…",
            detailIsWarning: self.failure != nil)
        {
            if self.failure != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.orange)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .overlay(alignment: .topTrailing) {
            ComposerTileRemoveButton(
                label: self.failure == nil ? "Cancel \(self.item.title)" : "Dismiss \(self.item.title)",
                action: self.onCancel)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(self.failure.map { "Could not attach \(self.item.title). \($0)" }
            ?? "Preparing \(self.item.title)")
    }
}
