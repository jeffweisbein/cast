import QuickLook
import SwiftUI

/// Inline attachments of one message: bounded image thumbnails and stable chips for
/// videos/files, including paths that only exist on the gateway host.
struct MessageMediaView: View {
    let message: ChatMessage
    let onOpen: (URL) -> Void
    var downloadAttachment: (@MainActor (ManagedChatAttachment) async throws -> URL)? = nil

    private var items: [MediaItem] {
        LibraryScanner.mediaItems(of: self.message)
    }

    var body: some View {
        ForEach(message.managedAttachments) { attachment in
            ManagedAttachmentView(attachment: attachment, download: downloadAttachment, onOpen: onOpen)
        }
        ForEach(self.items) { item in
            InlineMediaThumbnail(item: item, onOpen: self.onOpen)
        }
    }
}

struct InlineMediaThumbnail: View {
    let item: MediaItem
    let onOpen: (URL) -> Void
    @State private var image: CGImage?
    @State private var failed = false
    @State private var previewURL: URL?
    @State private var previewChecked = false

    private var accessibilityKind: String {
        if self.item.isVideo { return "Video" }
        if self.item.isImage { return "Image" }
        if self.item.isAudio { return "Voice message" }
        return "File"
    }

    var body: some View {
        Group {
            if self.item.isAudio, let previewURL = self.previewURL {
                // Readable audio plays inline; unreadable (remote gateway) paths fall
                // through to the disabled chip below like any other file.
                VoicePlaybackBubble(url: previewURL)
            } else {
                self.openButton
            }
        }
        .task(id: self.item.id) {
            async let preview = MediaThumbnailLoader.shared.previewURL(for: self.item)
            if self.item.isImage, self.image == nil, !self.failed {
                if let thumbnail = await MediaThumbnailLoader.shared.thumbnail(for: self.item, maxPixel: 640) {
                    self.image = thumbnail
                } else {
                    self.failed = true
                }
            }
            self.previewURL = await preview
            self.previewChecked = true
        }
    }

    private var openButton: some View {
        Button {
            if let previewURL = self.previewURL { self.onOpen(previewURL) }
        } label: {
            Group {
                if let image = self.image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 320, maxHeight: 240, alignment: .leading)
                } else if self.failed || !self.item.isImage {
                    MediaChip(item: self.item, unavailable: self.previewChecked && self.previewURL == nil)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.quaternary.opacity(0.4))
                        .frame(width: 180, height: 130)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(self.previewChecked && self.previewURL == nil)
        .accessibilityLabel("\(self.accessibilityKind) attachment")
    }
}

/// Fallback affordance when bytes aren't decodable here: videos, audio, and image paths
/// that only exist on a remote gateway host.
struct MediaChip: View {
    let item: MediaItem
    var unavailable = false

    private var kind: (icon: String, label: String) {
        if self.item.isVideo { return ("video.fill", "Video") }
        if self.item.isImage { return ("photo", "Image") }
        if self.item.isAudio { return ("waveform", "Voice message") }
        return ("doc.fill", "File")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: self.kind.icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(self.item.fileName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(self.unavailable ? "Available on gateway only" : self.kind.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}

/// Per-chat media & links library — a computed view over loaded messages (spec: no new
/// persistence, no indexer).
struct LibraryView: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var tab: Tab = .media
    @State private var previewURL: URL?

    enum Tab: Hashable { case media, links }

    private var media: [MediaItem] { LibraryScanner.media(in: self.store.messages) }
    private var links: [LinkItem] { LibraryScanner.links(in: self.store.messages) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: self.$tab) {
                    Text("Media").tag(Tab.media)
                    Text("Links").tag(Tab.links)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .labelsHidden()
                Spacer()
                Button("Done") { self.dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            switch self.tab {
            case .media: self.mediaGrid
            case .links: self.linkList
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 460)
        #endif
        .quickLookPreview(self.$previewURL)
    }

    private var mediaGrid: some View {
        Group {
            if self.media.isEmpty {
                ContentUnavailableView(
                    "No media yet",
                    systemImage: "photo.on.rectangle",
                    description: Text("Images and videos from this chat show up here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], spacing: 8) {
                        ForEach(self.media) { item in
                            LibraryMediaCell(item: item) { url in
                                self.previewURL = url
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var linkList: some View {
        Group {
            if self.links.isEmpty {
                ContentUnavailableView(
                    "No links yet",
                    systemImage: "link",
                    description: Text("URLs mentioned in this chat show up here."))
            } else {
                List(self.links) { link in
                    LibraryLinkRow(link: link) { self.openURL(link.url) }
                }
                .listStyle(.plain)
            }
        }
    }
}

struct LibraryMediaCell: View {
    let item: MediaItem
    let onOpen: (URL) -> Void
    @State private var image: CGImage?
    @State private var previewURL: URL?
    @State private var previewChecked = false

    var body: some View {
        Button {
            if let previewURL = self.previewURL { self.onOpen(previewURL) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
                if let image = self.image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: self.item.isVideo ? "video.fill" : "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                if self.item.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 3)
                }
                VStack {
                    HStack {
                        Label(
                            self.item.isVideo ? "Video" : "Image",
                            systemImage: self.item.isVideo ? "video.fill" : "photo.fill")
                            .font(.system(size: 9, weight: .bold))
                            .textCase(.uppercase)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.ultraThinMaterial))
                        Spacer()
                    }
                    Spacer()
                    if self.previewChecked, self.previewURL == nil {
                        Text("On gateway")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.ultraThinMaterial))
                    }
                }
                .padding(7)
            }
            .frame(minWidth: 116, minHeight: 116)
            .aspectRatio(1, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(self.previewChecked && self.previewURL == nil)
        .accessibilityLabel(self.item.isVideo ? "Video \(self.item.fileName)" : "Image \(self.item.fileName)")
        .task(id: self.item.id) {
            async let preview = MediaThumbnailLoader.shared.previewURL(for: self.item)
            if self.item.isImage, self.image == nil {
                self.image = await MediaThumbnailLoader.shared.thumbnail(for: self.item, maxPixel: 320)
            }
            self.previewURL = await preview
            self.previewChecked = true
        }
    }
}

struct LibraryLinkRow: View {
    let link: LinkItem
    let onOpen: () -> Void
    @State private var title: String?
    @State private var favicon: CGImage?
    @State private var hovered = false

    private var domain: String {
        let host = self.link.url.host() ?? self.link.url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var detail: String {
        let lead = self.title == nil ? self.link.url.absoluteString : self.domain
        guard let date = self.link.date else { return lead }
        return "\(lead) · \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    var body: some View {
        Button(action: self.onOpen) {
            HStack(spacing: 11) {
                self.domainChip
                VStack(alignment: .leading, spacing: 3) {
                    Text(self.title ?? self.domain)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(self.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(self.hovered ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { self.hovered = $0 }
        #endif
        .task(id: self.link.id) {
            async let fetchedTitle = LinkMetadataStore.shared.title(for: self.link.url)
            async let fetchedFavicon = LinkMetadataStore.shared.favicon(for: self.link.url)
            self.title = await fetchedTitle
            self.favicon = await fetchedFavicon
        }
        .accessibilityLabel("Open \(self.title ?? self.domain)")
    }

    @ViewBuilder
    private var domainChip: some View {
        if let favicon = self.favicon {
            Image(decorative: favicon, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(6)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.45)))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            Circle()
                .fill(self.fallbackColor.opacity(0.18))
                .frame(width: 36, height: 36)
                .overlay {
                    Text(String(self.domain.first ?? "?" ).uppercased())
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(self.fallbackColor)
                }
        }
    }

    private var fallbackColor: Color {
        let colors: [Color] = [.blue, .teal, .indigo, .orange, .purple, .pink]
        let value = self.domain.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return colors[value % colors.count]
    }
}
