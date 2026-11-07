import Foundation
import Observation

/// Workspace-owned transfers outlive sheets/rows, never a workspace endpoint change.
/// Files themselves use the existing verified cache; transient attempts are not replayed.
@MainActor @Observable
public final class DownloadCenter {
    public enum Phase: Equatable, Sendable {
        case downloading, saved(URL), cancelled, failed(String)
        public var isActive: Bool { if case .downloading = self { return true }; return false }
    }
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: String
        public let item: Deliverable
        public let attempt: UUID
        public var phase: Phase
        public var received = 0
        public var total: Int?
        public var updatedAt = Date()
    }
    public private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var progressDates: [String: Date] = [:]
    public init() {}
    public var sorted: [Entry] { entries.values.sorted { $0.updatedAt > $1.updatedAt } }
    public var activeCount: Int { entries.values.filter { $0.phase.isActive }.count }
    public static func key(_ item: Deliverable) -> String {
        // Length prefixes make the full revision identity collision-free without per-frame
        // JSON encoders, cryptographic hashing or delimiter ambiguities.
        [item.id, item.sessionKey, item.messageID, item.target, item.title,
         item.artifactID ?? "", item.mimeType ?? "", item.downloadMode ?? "", item.sizeBytes.map(String.init) ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
    public struct Row: Identifiable {
        public let id: String
        public let item: Deliverable
        public let entry: Entry?
    }
    public func rows(ledger: [Deliverable]) -> [Row] {
        var indexed = Dictionary(ledger.map { (Self.key($0), $0) }, uniquingKeysWith: { first, _ in first })
        for entry in entries.values { indexed[entry.id] = entry.item }
        return indexed.map { Row(id: $0.key, item: $0.value, entry: entries[$0.key]) }
    }
    public func entry(for item: Deliverable) -> Entry? { entries[Self.key(item)] }

    public func start(_ item: Deliverable,
                      operation: @escaping @MainActor (@escaping @Sendable (Int, Int?) async -> Void) async throws -> URL) {
        let key = Self.key(item)
        guard entries[key]?.phase.isActive != true else { return }
        let attempt = UUID()
        guard activeCount < 3 else {
            entries[key] = Entry(id: key, item: item, attempt: attempt,
                phase: .failed("Three files are already downloading. Finish or cancel one, then retry."))
            trim(); return
        }
        entries[key] = Entry(id: key, item: item, attempt: attempt, phase: .downloading, total: item.sizeBytes)
        trim()
        tasks[key] = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let url = try await operation { [weak self] received, total in
                    await self?.progress(key: key, attempt: attempt, received: received, total: total)
                }
                try Task.checkCancellation()
                self?.finish(key: key, attempt: attempt, phase: .saved(url))
            } catch is CancellationError {
                self?.finish(key: key, attempt: attempt, phase: .cancelled)
            } catch {
                self?.finish(key: key, attempt: attempt, phase: .failed(Self.message(for: error)))
            }
        }
    }
    private func progress(key: String, attempt: UUID, received: Int, total: Int?) {
        guard entries[key]?.attempt == attempt, entries[key]?.phase.isActive == true else { return }
        let now = Date()
        guard progressDates[key].map({ now.timeIntervalSince($0) >= 0.25 }) ?? true else { return }
        progressDates[key] = now
        entries[key]?.received = max(0, received)
        entries[key]?.total = total
    }
    private func finish(key: String, attempt: UUID, phase: Phase) {
        guard entries[key]?.attempt == attempt, entries[key]?.phase.isActive == true else { return }
        entries[key]?.phase = phase; entries[key]?.updatedAt = Date(); tasks[key] = nil; progressDates[key] = nil
    }
    public func cancel(_ item: Deliverable) {
        let key = Self.key(item)
        guard entries[key]?.phase.isActive == true else { return }
        entries[key]?.phase = .cancelled; entries[key]?.updatedAt = Date()
        tasks.removeValue(forKey: key)?.cancel(); progressDates[key] = nil
    }
    /// Recheck cached files after reopening. A stale lookup cannot overwrite a new attempt.
    public func inspect(_ item: Deliverable, lookup: () async throws -> URL?) async {
        let key = Self.key(item), capturedEpoch = epoch, previous = entries[Self.key(item)]
        guard previous?.phase.isActive != true else { return }
        let url: URL?
        do { url = try await lookup() } catch { return } // Unavailable is not missing.
        guard !Task.isCancelled, capturedEpoch == epoch, entries[key] == previous else { return }
        if let url {
            if case .saved(let existing) = previous?.phase, existing == url { return }
            entries[key] = Entry(id: key, item: item, attempt: UUID(), phase: .saved(url))
            trim()
        } else if case .saved = previous?.phase { entries[key] = nil }
    }
    public func reset() {
        epoch = UUID()
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); entries.removeAll(); progressDates.removeAll()
    }
    public static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost: return "Connection lost. Reconnect, then retry this download."
            case .timedOut: return "The download timed out. Try again when the connection is stable."
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return "Couldn’t reach the file server. Check your connection and retry."
            default: return "The file could not be downloaded. Check your connection and retry."
            }
        }
        return error.localizedDescription
    }
    private func trim() {
        for entry in sorted.dropFirst(100) where !entry.phase.isActive { entries[entry.id] = nil }
    }
}
