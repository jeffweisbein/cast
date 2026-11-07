import CryptoKit
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
    public init() {}
    public var sorted: [Entry] { entries.values.sorted { $0.updatedAt > $1.updatedAt } }
    public var activeCount: Int { entries.values.filter { $0.phase.isActive }.count }
    public static func key(_ item: Deliverable) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(item)) ?? Data(item.reviewID.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
                let url = try await operation { [weak self] received, total in
                    await self?.progress(key: key, attempt: attempt, received: received, total: total)
                }
                try Task.checkCancellation()
                self?.finish(key: key, attempt: attempt, phase: .saved(url))
            } catch is CancellationError {
                self?.finish(key: key, attempt: attempt, phase: .cancelled)
            } catch {
                self?.finish(key: key, attempt: attempt, phase: .failed(error.localizedDescription))
            }
        }
    }
    private func progress(key: String, attempt: UUID, received: Int, total: Int?) {
        guard entries[key]?.attempt == attempt, entries[key]?.phase.isActive == true else { return }
        entries[key]?.received = max(0, received)
        entries[key]?.total = total
    }
    private func finish(key: String, attempt: UUID, phase: Phase) {
        guard entries[key]?.attempt == attempt, entries[key]?.phase.isActive == true else { return }
        entries[key]?.phase = phase; entries[key]?.updatedAt = Date(); tasks[key] = nil
    }
    public func cancel(_ item: Deliverable) {
        let key = Self.key(item)
        guard entries[key]?.phase.isActive == true else { return }
        entries[key]?.phase = .cancelled; entries[key]?.updatedAt = Date()
        tasks.removeValue(forKey: key)?.cancel()
    }
    /// Recheck cached files after reopening. A stale lookup cannot overwrite a new attempt.
    public func inspect(_ item: Deliverable, lookup: () async -> URL?) async {
        let key = Self.key(item), capturedEpoch = epoch, previous = entries[Self.key(item)]
        guard previous?.phase.isActive != true else { return }
        let url = await lookup()
        guard !Task.isCancelled, capturedEpoch == epoch, entries[key] == previous else { return }
        if let url {
            entries[key] = Entry(id: key, item: item, attempt: UUID(), phase: .saved(url))
            trim()
        } else if case .saved = previous?.phase { entries[key] = nil }
    }
    public func reset() {
        epoch = UUID()
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); entries.removeAll()
    }
    private func trim() {
        for entry in sorted.dropFirst(100) where !entry.phase.isActive { entries[entry.id] = nil }
    }
}
