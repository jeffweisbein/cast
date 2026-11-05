import Foundation
import CryptoKit

/// Stable gateway identity only. Never cache or use unsigned/signed transport URLs
/// from a transcript; artifacts.download authorizes a fresh transfer for this session.
public struct ManagedChatAttachment: Codable, Sendable, Hashable, Identifiable {
    public let artifactId: String
    public let label: String
    public let mimeType: String?
    public let sizeBytes: Int?
    public var id: String { artifactId }

    static func decodeBlock(from decoder: Decoder) -> Self? {
        guard let value = try? AnyCodable(from: decoder),
              ["image", "audio", "video", "file", "attachment"].contains(value["type"]?.stringValue ?? "") else { return nil }
        let source = value["attachment"] ?? value
        guard let id = source["artifactId"]?.stringValue, !id.isEmpty,
              id.count <= 256, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return Self(artifactId: id,
                    label: source["label"]?.stringValue ?? source["alt"]?.stringValue ?? source["fileName"]?.stringValue ?? "Attachment",
                    mimeType: source["mimeType"]?.stringValue, sizeBytes: source["sizeBytes"]?.intValue)
    }

    public func deliverable(sessionKey: String, messageID: String = "attachment", sharedAt: Double? = nil) -> Deliverable {
        let id = SHA256.hash(data: Data((sessionKey + "\n" + artifactId).utf8)).map { String(format: "%02x", $0) }.joined()
        return Deliverable(id: id, sessionKey: sessionKey, messageID: messageID,
                    title: label, target: "artifact:" + artifactId,
                    kind: mimeType?.hasPrefix("image/") == true ? "Image" : "Attachment", sharedAt: sharedAt,
                    artifactID: artifactId, sizeBytes: sizeBytes, mimeType: mimeType, downloadMode: "url")
    }
}
