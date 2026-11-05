import Foundation

/// Ordinary human questions only. Deliberately does not decode returned answers: a
/// question.list response can also contain secrets, which belong to secure entry.
public struct QuestionRequest: Decodable, Identifiable, Equatable, Sendable {
    public struct Question: Decodable, Equatable, Sendable {
        public struct Option: Decodable, Equatable, Sendable {
            public let label: String
            public let description: String?
        }
        public let questionId: String
        public let header: String?
        public let question: String
        public let url: String?
        public let options: [Option]
        public let multiSelect: Bool?
        public let isOther: Bool?
        public let isSecret: Bool?
        public let secretStore: SecretRequest.Question.Binding?
        public var allowsText: Bool { options.isEmpty || isOther == true }
    }
    public let id: String
    public let sessionKey: String?
    public let agentId: String?
    public let questions: [Question]
    public let createdAtMs: Double?
    public let expiresAtMs: Double
    public var status: String
    public var isOrdinary: Bool {
        !questions.isEmpty && questions.allSatisfy { $0.isSecret != true && $0.secretStore == nil } &&
        Set(questions.map(\.questionId)).count == questions.count
    }
    public func isPending(at date: Date = Date()) -> Bool {
        status == "pending" && expiresAtMs > date.timeIntervalSince1970 * 1000
    }
    public func belongs(to session: String?) -> Bool {
        guard let sessionKey, let session else { return false }
        return SessionKeyMatcher.matches(sessionKey, session)
    }
}

public struct QuestionDraft: Equatable, Sendable {
    public var selections: [String: Set<String>] = [:]
    public var text: [String: String] = [:]
    public var usingOther: Set<String> = []
    public init() {}
    public func answers(for request: QuestionRequest) -> [String: [String]]? {
        guard request.isOrdinary else { return nil }
        var result: [String: [String]] = [:]
        for question in request.questions {
            var values = question.options.map(\.label).filter { selections[question.questionId, default: []].contains($0) }
            if question.options.isEmpty || usingOther.contains(question.questionId) {
                guard question.allowsText else { return nil }
                let value = text[question.questionId, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                if question.multiSelect != true { values = [] }
                if !values.contains(value) { values.append(value) }
            }
            guard !values.isEmpty, question.multiSelect == true || values.count == 1 else { return nil }
            result[question.questionId] = values
        }
        return result
    }
}

/// In-memory and workspace-scoped. Reconnects and view changes preserve drafts;
/// terminal records clear them. No question text/answers are written into transcripts.
public struct QuestionInbox: Sendable {
    public struct Entry: Identifiable, Sendable {
        public var id: String { request.id }
        public var request: QuestionRequest
        public var draft = QuestionDraft()
        public var submitting = false
        public var uncertain = false
        public var error: String?
        public var resolutionID = UUID().uuidString
        public var attemptedAnswers: [String: [String]]?
    }
    public private(set) var entries: [String: Entry] = [:]
    private var terminalIDs: Set<String> = []
    private var locallyExpiredIDs: Set<String> = []
    public init() {}
    public var sorted: [Entry] {
        entries.values.sorted { ($0.request.createdAtMs ?? 0, $0.id) < ($1.request.createdAtMs ?? 0, $1.id) }
    }
    public func needsReconciliation(id: String) -> Bool {
        guard let entry = entries[id] else { return false }
        return entry.request.isPending() || locallyExpiredIDs.contains(id)
    }
    public mutating func receive(_ request: QuestionRequest) {
        guard request.isOrdinary else { return }
        if terminalIDs.contains(request.id) {
            // A local clock expiry must not hide an authoritative answer that
            // arrived while reconnect/get was in flight. Never revive pending
            // replays or cards the user already dismissed.
            if locallyExpiredIDs.contains(request.id), entries[request.id] != nil,
               ["answered", "cancelled", "expired", "unavailable"].contains(request.status) {
                resolve(id: request.id, status: request.status)
            }
            return
        }
        var entry = entries[request.id] ?? Entry(request: request)
        entry.request = request
        entries[request.id] = entry
        if request.status != "pending" { resolve(id: request.id, status: request.status) }
    }
    public mutating func resolve(id: String, status: String) {
        guard ["answered", "cancelled", "expired", "unavailable"].contains(status) else { return }
        terminalIDs.insert(id)
        locallyExpiredIDs.remove(id)
        guard var entry = entries[id] else { return }
        entry.request.status = status
        entry.draft = QuestionDraft()
        entry.submitting = false
        entry.uncertain = false
        entry.error = nil
        entry.attemptedAnswers = nil
        entries[id] = entry
    }
    public mutating func updateDraft(id: String, draft: QuestionDraft) {
        guard var entry = entries[id], entry.request.isPending(), !entry.submitting, !entry.uncertain else { return }
        entry.draft = draft
        entry.error = nil
        entries[id] = entry
    }
    public mutating func begin(id: String) -> Entry? {
        guard var entry = entries[id], entry.request.isPending(), !entry.submitting,
              let answers = entry.draft.answers(for: entry.request) else { return nil }
        // An explicit retry after a lost acknowledgement uses exactly the same token
        // and payload. Never retry automatically on reconnect.
        if entry.uncertain && answers != entry.attemptedAnswers { return nil }
        if entry.attemptedAnswers != answers { entry.resolutionID = UUID().uuidString }
        entry.attemptedAnswers = answers
        entry.submitting = true
        entry.error = nil
        entries[id] = entry
        return entry
    }
    public mutating func failed(id: String) {
        guard var entry = entries[id], entry.request.status == "pending" else { return }
        entry.submitting = false
        entry.uncertain = true
        entry.error = "Answer not confirmed. Your draft is kept. Refresh status or retry the same answer."
        entries[id] = entry
    }
    public mutating func confirmPending(id: String) {
        guard var entry = entries[id], entry.request.status == "pending" else { return }
        entry.uncertain = false
        entries[id] = entry
    }
    public mutating func expire(at date: Date = Date()) {
        for entry in sorted where entry.request.status == "pending" && !entry.request.isPending(at: date) {
            resolve(id: entry.id, status: "expired")
            locallyExpiredIDs.insert(entry.id)
        }
    }
    public mutating func dismiss(id: String) {
        guard let entry = entries[id], !entry.request.isPending() else { return }
        terminalIDs.insert(id)
        locallyExpiredIDs.remove(id)
        entries.removeValue(forKey: id)
    }
}
struct QuestionRequestList: Decodable { let questions: [QuestionRequest] }
struct QuestionRequestResult: Decodable { let question: QuestionRequest }
struct QuestionRequestResolution: Decodable { let status: String }
