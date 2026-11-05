// Cast — computed media & links library: pure scans over loaded messages, no persistence.
import Foundation
import UniformTypeIdentifiers

public struct MediaItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let path: String?
    public let mimeType: String?
    public let date: Date?
    public let localData: Data?

    public init(id: String, path: String?, mimeType: String?, date: Date?, localData: Data? = nil) {
        self.id = id
        self.path = path
        self.mimeType = mimeType
        self.date = date
        self.localData = localData
    }

    private var inferredType: UTType? {
        if let mimeType {
            let normalized = mimeType.split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased() ?? mimeType
            if let type = UTType(mimeType: normalized) { return type }
        }
        guard let path else { return self.localData == nil ? nil : .image }
        let ext: String
        if let url = URL(string: path), url.isFileURL {
            ext = url.pathExtension
        } else {
            ext = (path as NSString).pathExtension
        }
        return UTType(filenameExtension: ext)
    }

    public var isImage: Bool { self.localData != nil || self.inferredType?.conforms(to: .image) == true }
    public var isVideo: Bool { self.inferredType?.conforms(to: .movie) == true }
    /// Voice messages and other audio attachments. The gateway may report a sniffed mime
    /// (audio/x-m4a) rather than the sent one (audio/mp4); both conform to `.audio`.
    public var isAudio: Bool { self.inferredType?.conforms(to: .audio) == true }

    public var fileName: String {
        guard let path = self.path else { return "Image" }
        if let url = URL(string: path), url.isFileURL { return url.lastPathComponent }
        return (path as NSString).lastPathComponent
    }
}

public struct LinkItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let url: URL
    public let date: Date?

    public init(url: URL, date: Date?) {
        self.id = url.absoluteString
        self.url = url
        self.date = date
    }
}

public enum LibraryScanner {
    /// Image/video attachments across the transcript, newest first, deduped by path.
    public static func media(in messages: [ChatMessage]) -> [MediaItem] {
        var seen = Set<String>()
        var items: [MediaItem] = []
        for message in messages.reversed() {
            for item in self.mediaItems(of: message) where item.isImage || item.isVideo {
                guard seen.insert(item.id).inserted else { continue }
                items.append(item)
            }
        }
        return items
    }

    /// Media refs of a single message: gateway paths first, then optimistic local bytes.
    public static func mediaItems(of message: ChatMessage) -> [MediaItem] {
        var items: [MediaItem] = message.mediaPaths.enumerated().map { index, path in
            MediaItem(
                id: path,
                path: path,
                mimeType: index < message.mediaTypes.count
                    ? message.mediaTypes[index]
                    : (message.mediaTypes.count == 1 ? message.mediaTypes[0] : nil),
                date: message.date,
                localData: index < message.localImageData.count ? message.localImageData[index] : nil)
        }
        // Local echo bytes render until the gateway echo (with its MediaPath) replaces them.
        if items.isEmpty {
            items = message.localImageData.enumerated().map { index, data in
                MediaItem(
                    id: "\(message.id)-local-\(index)",
                    path: nil,
                    mimeType: "image/jpeg",
                    date: message.date,
                    localData: data)
            }
        }
        return items
    }

    /// http(s) URLs in message text, deduped keeping the newest occurrence, newest first.
    public static func links(in messages: [ChatMessage]) -> [LinkItem] {
        var seen = Set<String>()
        var items: [LinkItem] = []
        for message in messages.reversed() {
            guard message.role == "user" || message.role == "assistant" else { continue }
            let text = message.text
            guard !text.isEmpty else { continue }
            for detectedURL in self.urls(in: text) {
                let identity = self.canonicalURL(detectedURL).absoluteString
                guard seen.insert(identity).inserted else { continue }
                // Use the newest occurrence's original URL so fragment navigation remains
                // intact; canonicalization is identity-only.
                items.append(LinkItem(url: detectedURL, date: message.date))
            }
        }
        return items
    }

    static func urls(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return url
        }
    }

    /// Fragment-only variants point at the same page and otherwise produce duplicate
    /// Library rows and duplicate metadata fetches. Normalize only identity-safe URL parts;
    /// paths and queries remain untouched.
    static func canonicalURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80)
        {
            components.port = nil
        }
        return components.url ?? url
    }
}
