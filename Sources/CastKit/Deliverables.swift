import CryptoKit
import Foundation

public struct Deliverable: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionKey: String
    public let messageID: String
    public let title: String
    public let target: String
    public let kind: String
    public let sharedAt: Double?
    public var artifactID: String? = nil
    public var sizeBytes: Int? = nil
    public var mimeType: String? = nil
    public var downloadMode: String? = nil
    /// A revised handoff to the same URL deserves a fresh review.
    public var reviewID: String { self.id + ":" + self.messageID }

    public var webURL: URL? {
        guard let url = URL(string: self.target), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

public struct DeliverableLedger: Codable, Sendable, Equatable {
    public private(set) var items: [Deliverable] = []
    public init() {}

    public mutating func ingest(artifacts: [GatewayArtifact], sessionKey: String) {
        var indexed = Dictionary(self.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for artifact in artifacts {
            guard artifact.sessionKey == nil || SessionKeyMatcher.matches(artifact.sessionKey, sessionKey) else { continue }
            let id = SHA256.hash(data: Data((sessionKey + "\n" + artifact.id).utf8)).map { String(format: "%02x", $0) }.joined()
            indexed[id] = Deliverable(id: id, sessionKey: sessionKey, messageID: "artifact:\(artifact.id):\(artifact.messageSeq ?? 0)",
                title: artifact.title, target: "artifact:" + artifact.id,
                kind: artifact.mimeType == "application/zip" ? "Package" : "Attachment", sharedAt: indexed[id]?.sharedAt,
                artifactID: artifact.id, sizeBytes: artifact.sizeBytes, mimeType: artifact.mimeType, downloadMode: artifact.download.mode)
        }
        self.items = indexed.values.sorted { ($0.sharedAt ?? 0, $0.id) > ($1.sharedAt ?? 0, $1.id) }.prefix(1000).map { $0 }
    }

    public mutating func ingest(messages: [ChatMessage], sessionKey: String) {
        var indexed = Dictionary(self.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in DeliverableScanner.scan(messages: messages, sessionKey: sessionKey) {
            if let old = indexed[item.id], (old.sharedAt ?? 0) > (item.sharedAt ?? 0) { continue }
            indexed[item.id] = item
        }
        self.items = indexed.values.sorted {
            if $0.sharedAt != $1.sharedAt { return ($0.sharedAt ?? 0) > ($1.sharedAt ?? 0) }
            return $0.id < $1.id
        }.prefix(1000).map { $0 }
    }
}

public enum DeliverableScanner {
    public static func scan(messages: [ChatMessage], sessionKey: String) -> [Deliverable] {
        var results: [Deliverable] = []
        let pattern = #"\[([^\]]+)\]\((<[^>]+>|[^\s\)]+)\)"#
        let regex = try? NSRegularExpression(pattern: pattern)
        for message in messages where message.role == "assistant" {
            results.append(contentsOf: message.managedAttachments.map {
                $0.deliverable(sessionKey: sessionKey, messageID: message.id, sharedAt: message.timestamp)
            })
            var candidates: [(String, String)] = message.mediaPaths.map { (($0 as NSString).lastPathComponent, $0) }
            let text = message.text
            for match in regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
                guard let title = Range(match.range(at: 1), in: text), let target = Range(match.range(at: 2), in: text) else { continue }
                candidates.append((String(text[title]), String(text[target]).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))))
            }
            for url in LibraryScanner.links(in: [message]).map(\.url) { candidates.append((url.lastPathComponent, url.absoluteString)) }
            var seen = Set<String>()
            for (title, raw) in candidates {
                var target = raw
                if target.hasPrefix("/") {
                    target = target.replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
                }
                let url = target.hasPrefix("/") ? URL(fileURLWithPath: target) : URL(string: target)
                guard let url, url.user == nil, url.password == nil,
                      ["file", "https", "http"].contains(url.scheme?.lowercased() ?? "") else { continue }
                let kind: String
                if ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? ""), url.path.contains("/pull/") { kind = "Pull request" }
                else if url.path.contains("/releases/") { kind = "Release" }
                else {
                    switch url.pathExtension.lowercased() {
                    case "zip", "dmg", "tar", "gz", "ipa": kind = "Package"
                    case "md", "pdf", "html", "txt", "csv", "json", "docx", "xlsx", "pptx": kind = "Document"
                    case "png", "jpg", "jpeg", "webp": kind = "Image"
                    default: continue
                    }
                }
                let identity = sessionKey + "\n" + target
                guard seen.insert(identity).inserted else { continue }
                let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
                results.append(Deliverable(id: id, sessionKey: sessionKey, messageID: message.id,
                    title: title.isEmpty ? url.lastPathComponent : title, target: target, kind: kind, sharedAt: message.timestamp))
            }
        }
        return results
    }
}
