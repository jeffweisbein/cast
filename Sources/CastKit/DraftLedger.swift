import Foundation

/// Durable, per-session composer drafts.
///
/// Keys are session keys; the ledger itself lives in a per-workspace operations root, so
/// workspace scoping comes from the store location rather than the key. Whitespace-only
/// text is treated as "no draft" so a stray newline never resurrects an empty composer.
public struct DraftLedger: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public private(set) var drafts: [String: String]

    public init(drafts: [String: String] = [:]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.drafts = drafts
    }

    public func draft(forSession sessionKey: String) -> String? {
        self.drafts[sessionKey]
    }

    /// Stores `text` for the session, or removes the entry when the text has no content.
    /// Returns whether the ledger changed, so callers can skip a redundant persist.
    @discardableResult
    public mutating func setDraft(_ text: String, forSession sessionKey: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return self.clearDraft(forSession: sessionKey)
        }
        guard self.drafts[sessionKey] != text else { return false }
        self.drafts[sessionKey] = text
        return true
    }

    @discardableResult
    public mutating func clearDraft(forSession sessionKey: String) -> Bool {
        self.drafts.removeValue(forKey: sessionKey) != nil
    }
}
