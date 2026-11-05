import Foundation

/// Metadata only. Secret values never enter ChatStore, history, or Codable models.
public struct SecretRequest: Decodable, Identifiable, Equatable, Sendable {
    public struct Question: Decodable, Equatable, Sendable {
        public struct Binding: Decodable, Equatable, Sendable {
            public let name: String
            public let kind: String
            public let allowedHosts: [String]?
        }
        public struct Existing: Decodable, Equatable, Sendable { public let updatedAtMs: Double }
        public let questionId: String
        public let question: String
        public let isSecret: Bool?
        public let secretStore: Binding?
        public let secretStoreExisting: Existing?
    }
    public let id: String
    public let sessionKey: String?
    public let questions: [Question]
    public let status: String
    public let expiresAtMs: Double
    public var isPendingSecret: Bool {
        status == "pending" && expiresAtMs > Date().timeIntervalSince1970 * 1000 &&
        questions.count == 1 && questions[0].isSecret == true &&
        questions[0].secretStore?.kind == "secret" && !(questions[0].secretStore?.name.isEmpty ?? true)
    }
    public func belongs(to session: String?) -> Bool {
        guard let sessionKey, let session else { return false }
        return SessionKeyMatcher.matches(sessionKey, session)
    }
    /// Only used for the direct RPC. Never append this dictionary to chat state.
    public func resolution(value: String?) -> [String: Any?] {
        guard let value else { return ["id": id, "cancel": true] }
        return ["id": id, "answers": ["answers": [questions[0].questionId: [value]]]]
    }
}
struct SecretRequestList: Decodable { let questions: [SecretRequest] }
struct SecretResolution: Decodable { let status: String }
