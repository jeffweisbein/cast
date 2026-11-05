// Cast — link metadata for the Library panel: pure HTML title parsing plus a bounded
// async fetch/cache layer (memory + small disk cache) so link rows show page titles and
// favicons instantly on reopen and never block on a slow or dead host.
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

public enum LinkMetadataPolicy {
    /// Link rows may come from remote agent output, so preview enrichment must not turn
    /// arbitrary message text into automatic requests to loopback/LAN services. Opening a
    /// link remains an explicit user action; only silent title/favicon fetches are gated.
    public static func canFetch(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              let rawHost = url.host?.lowercased(), !rawHost.isEmpty
        else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return false
        }
        if host == "::1" || host == "0:0:0:0:0:0:0:1"
            || host.hasPrefix("::ffff:")
            || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
            || host.hasPrefix("fc") || host.hasPrefix("fd")
        {
            return false
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, octets.allSatisfy({ (0 ... 255).contains($0) }) {
            let first = octets[0], second = octets[1]
            return !(first == 0 || first == 10 || first == 127 || first >= 224
                || (first == 100 && (64 ... 127).contains(second))
                || (first == 169 && second == 254)
                || (first == 172 && (16 ... 31).contains(second))
                || (first == 192 && second == 168)
                || (first == 198 && (second == 18 || second == 19)))
        }
        return true
    }
}

public enum LinkTitleParser {
    /// og:title beats <title>; entities decoded, whitespace collapsed. nil when the
    /// document offers neither.
    public static func pageTitle(inHTML html: String) -> String? {
        if let og = self.ogTitle(in: html) { return og }
        return self.documentTitle(in: html)
    }

    static func ogTitle(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<meta\\b[^>]*>", options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex ..< html.endIndex, in: html)
        for match in regex.matches(in: html, options: [], range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            let key = self.attribute("property", in: tag) ?? self.attribute("name", in: tag)
            guard key?.lowercased() == "og:title",
                  let content = self.attribute("content", in: tag),
                  let title = self.normalize(content) else { continue }
            return title
        }
        return nil
    }

    static func documentTitle(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<title[^>]*>(.*?)</title>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(html.startIndex ..< html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let titleRange = Range(match.range(at: 1), in: html) else { return nil }
        return self.normalize(String(html[titleRange]))
    }

    /// Quoted attribute value from a single tag, either quote style, attributes in any order.
    static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')",
            options: [.caseInsensitive]) else { return nil }
        let range = NSRange(tag.startIndex ..< tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, options: [], range: range) else { return nil }
        for group in 1 ... 2 {
            if let valueRange = Range(match.range(at: group), in: tag) { return String(tag[valueRange]) }
        }
        return nil
    }

    static func normalize(_ raw: String) -> String? {
        let collapsed = self.decodeHTMLEntities(raw)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ndash": "–", "mdash": "—", "hellip": "…",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "middot": "·",
        "bull": "•", "laquo": "«", "raquo": "»", "times": "×",
    ]

    static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "&",
               let semicolon = text[index...].firstIndex(of: ";"),
               text.distance(from: index, to: semicolon) <= 12,
               let decoded = self.decodeEntity(String(text[text.index(after: index) ..< semicolon]))
            {
                result.append(decoded)
                index = text.index(after: semicolon)
                continue
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    static func decodeEntity(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32? = digits.hasPrefix("x") || digits.hasPrefix("X")
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return self.namedEntities[body]
    }
}

/// Async title + favicon lookups behind memory and disk caches. Failures are cached for
/// the process lifetime so a dead link is fetched at most once per launch.
public actor LinkMetadataStore {
    public static let shared = LinkMetadataStore()

    struct TitleEntry: Codable {
        let title: String
        let fetchedAtMs: Double
    }

    static let bodyByteCap = 128 * 1024
    static let faviconByteCap = 256 * 1024
    static let diskEntryCap = 400
    static let faviconDiskEntryCap = 200

    private var titles: [String: String?] = [:]
    private var titleTasks: [String: Task<String?, Never>] = [:]
    private var favicons: [String: CGImage?] = [:]
    private var faviconTasks: [String: Task<CGImage?, Never>] = [:]
    private var diskTitles: [String: TitleEntry] = [:]
    private var diskLoaded = false

    private let root: URL
    private let session: URLSession

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.root = base.appendingPathComponent("Cast/LinkMetadata", isDirectory: true)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Titles

    public func title(for url: URL) async -> String? {
        guard LinkMetadataPolicy.canFetch(url) else { return nil }
        let key = url.absoluteString
        if let cached = self.titles[key] { return cached }
        if let hit = self.cachedTitle(key: key) { return hit }
        if let inflight = self.titleTasks[key] { return await inflight.value }
        let task = Task { await self.fetchTitle(for: url) }
        self.titleTasks[key] = task
        let title = await task.value
        self.titleTasks[key] = nil
        if let title {
            self.recordFetchedTitle(title, key: key)
        } else {
            self.titles[key] = .some(nil)
        }
        return title
    }

    /// Memory-then-disk lookup; promotes disk hits into memory.
    func cachedTitle(key: String) -> String? {
        if let cached = self.titles[key] { return cached }
        self.ensureDiskLoaded()
        guard let entry = self.diskTitles[key] else { return nil }
        self.titles[key] = entry.title
        return entry.title
    }

    func recordFetchedTitle(_ title: String, key: String) {
        self.titles[key] = title
        self.persistTitle(title, key: key)
    }

    private func fetchTitle(for url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let data = await self.boundedBody(for: request, cap: Self.bodyByteCap) else { return nil }
        return LinkTitleParser.pageTitle(inHTML: String(decoding: data, as: UTF8.self))
    }

    /// Streams at most `cap` bytes, stopping early once </head> has arrived (og:title and
    /// <title> both live in head), so huge pages cost a few dozen KB, not a download.
    private func boundedBody(for request: URLRequest, cap: Int) async -> Data? {
        do {
            let (bytes, response) = try await self.session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) { return nil }
            var data = Data()
            data.reserveCapacity(min(cap, 64 * 1024))
            let headClose = Data("</head>".utf8)
            for try await byte in bytes {
                data.append(byte)
                if data.count >= cap { break }
                if byte == UInt8(ascii: ">"), data.suffix(8).range(of: headClose) != nil { break }
            }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Favicons

    public func favicon(for url: URL) async -> CGImage? {
        guard LinkMetadataPolicy.canFetch(url) else { return nil }
        guard let host = url.host() else { return nil }
        if let cached = self.favicons[host] { return cached }
        if let data = try? Data(contentsOf: self.faviconFileURL(host: host)),
           let image = self.decodeFavicon(data)
        {
            self.favicons[host] = image
            return image
        }
        if let inflight = self.faviconTasks[host] { return await inflight.value }
        let task = Task { await self.fetchFavicon(for: url, host: host) }
        self.faviconTasks[host] = task
        let image = await task.value
        self.faviconTasks[host] = nil
        self.favicons[host] = .some(image)
        return image
    }

    private func fetchFavicon(for url: URL, host: String) async -> CGImage? {
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = host
        components.port = url.port
        components.path = "/favicon.ico"
        guard let faviconURL = components.url,
              let data = await self.boundedBody(for: URLRequest(url: faviconURL), cap: Self.faviconByteCap),
              let image = self.decodeFavicon(data) else { return nil }
        try? FileManager.default.createDirectory(at: self.faviconDirectory, withIntermediateDirectories: true)
        try? data.write(to: self.faviconFileURL(host: host), options: .atomic)
        self.pruneFaviconsIfNeeded()
        return image
    }

    private func decodeFavicon(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return MediaThumbnailLoader.downsample(source: source, maxPixel: 64)
    }

    // MARK: - Disk cache

    private var titlesFileURL: URL { self.root.appendingPathComponent("titles.json") }
    private var faviconDirectory: URL { self.root.appendingPathComponent("favicons", isDirectory: true) }

    private func faviconFileURL(host: String) -> URL {
        let digest = SHA256.hash(data: Data(host.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return self.faviconDirectory.appendingPathComponent("\(digest).img")
    }

    private func ensureDiskLoaded() {
        guard !self.diskLoaded else { return }
        self.diskLoaded = true
        guard let data = try? Data(contentsOf: self.titlesFileURL),
              let entries = try? JSONDecoder().decode([String: TitleEntry].self, from: data) else { return }
        self.diskTitles = entries
    }

    private func persistTitle(_ title: String, key: String) {
        self.ensureDiskLoaded()
        self.diskTitles[key] = TitleEntry(title: title, fetchedAtMs: Date().timeIntervalSince1970 * 1000)
        if self.diskTitles.count > Self.diskEntryCap {
            let keep = self.diskTitles.sorted { $0.value.fetchedAtMs > $1.value.fetchedAtMs }.prefix(Self.diskEntryCap)
            self.diskTitles = Dictionary(uniqueKeysWithValues: Array(keep))
        }
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(self.diskTitles)
            try data.write(to: self.titlesFileURL, options: .atomic)
        } catch {
            // Cache persistence is best-effort; memory cache still covers this session.
        }
    }

    private func pruneFaviconsIfNeeded() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: self.faviconDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]),
            files.count > Self.faviconDiskEntryCap else { return }
        let oldestFirst = files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        for url in oldestFirst.prefix(files.count - Self.faviconDiskEntryCap) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
