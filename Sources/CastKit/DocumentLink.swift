import CryptoKit
import Foundation

/// A filesystem link in a remote conversation names a gateway file, not a file
/// on this device. Resolve it through the same scoped transfer path as Deliverables.
public struct DocumentLink: Identifiable, Sendable {
    public let sessionKey: String
    public let path: String
    public var id: String { sessionKey + "\n" + path }

    public static func intercepts(_ url: URL) -> Bool {
        url.isFileURL || (url.scheme == nil && url.absoluteString.hasPrefix("/"))
            || url.scheme?.lowercased() == "artifact"
    }

    public init?(url: URL, sessionKey: String) {
        guard !sessionKey.isEmpty, Self.intercepts(url),
              url.user == nil, url.password == nil, url.query == nil else { return nil }
        if url.isFileURL {
            guard url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        } else if url.scheme == nil {
            guard url.host == nil, !url.absoluteString.hasPrefix("//") else { return nil }
        }
        let raw = url.scheme?.lowercased() == "artifact" ? url.absoluteString : url.path
        let path = raw.replacingOccurrences(of: #":\d+(?::\d+)?$"#, with: "", options: .regularExpression)
        guard !path.isEmpty, !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        self.sessionKey = sessionKey
        self.path = path
    }

    public func deliverable(in items: [Deliverable]) -> Deliverable {
        if let item = items.first(where: {
            guard SessionKeyMatcher.matches($0.sessionKey, sessionKey) else { return false }
            if path.hasPrefix("artifact:") { return $0.target == path }
            guard let url = URL(string: $0.target), let other = DocumentLink(url: url, sessionKey: sessionKey) else { return false }
            return other.path == path
        }) { return item }
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return Deliverable(id: hash, sessionKey: sessionKey, messageID: "document-link",
            title: (path as NSString).lastPathComponent, target: path, kind: "Document", sharedAt: nil,
            artifactID: path.hasPrefix("artifact:") ? String(path.dropFirst(9)) : nil)
    }
}
