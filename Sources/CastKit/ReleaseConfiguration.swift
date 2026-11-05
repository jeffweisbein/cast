import Foundation

public enum ReleaseConfiguration {
    /// A build without a real feed is usable, but must never attempt update requests.
    public static func updatesConfigured(feed: String?, publicKey: String?) -> Bool {
        guard let feed, let url = URL(string: feed), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let publicKey, Data(base64Encoded: publicKey)?.count == 32 else { return false }
        return !feed.contains("$(") && !feed.contains("example.")
    }
}
