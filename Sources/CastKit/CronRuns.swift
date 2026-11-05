// Cast — cron run-log models. Shapes verified live against an OpenClaw gateway 2026-07-27:
// `cron.runs` with `scope: "all"` is an `operator.read` method and returns one entry per
// finished run, each carrying the isolated session key that run wrote its transcript to.
import Foundation

public enum CronRunOutcome: String, CaseIterable, Sendable {
    case running
    case succeeded
    case failed
    case timedOut
    case skipped
    case unknown

    /// Gateway status strings, mapped once so the UI never switches on raw wire values.
    /// "running" is not a ledger status — Cast synthesizes it from a live `cron` event's
    /// `action:"started"` until that run's `finished` arrives.
    public static func from(status: String?) -> CronRunOutcome {
        switch status?.lowercased() {
        case "running": return .running
        case "ok": return .succeeded
        case "error": return .failed
        case "timeout": return .timedOut
        case "skipped": return .skipped
        default: return .unknown
        }
    }

    public var label: String {
        switch self {
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .timedOut: return "Timed out"
        case .skipped: return "Skipped"
        case .unknown: return "Unknown"
        }
    }

    /// Only outright failures deserve the reader's attention; a skipped run is the
    /// scheduler declining to fire, not a problem.
    public var needsAttention: Bool {
        self == .failed || self == .timedOut
    }
}

public struct CronRun: Decodable, Identifiable, Sendable, Equatable {
    public let ts: Double
    public let jobId: String
    public let jobName: String?
    public let status: String?
    public let summary: String?
    public let runAtMs: Double?
    public let durationMs: Double?
    public let model: String?
    public let provider: String?
    /// The isolated session this run wrote to. Cast can open it directly even though
    /// short-lived run sessions do not survive in `sessions.list`.
    public let sessionKey: String?
    public let deliveryStatus: String?

    public var id: String { "\(self.jobId)@\(Int(self.ts))" }
    public var outcome: CronRunOutcome { CronRunOutcome.from(status: self.status) }
    public var date: Date { Date(timeIntervalSince1970: self.ts / 1000) }
    public var title: String { self.jobName ?? self.jobId }

    /// Run summaries are whole agent replies; the list shows the first meaningful line and
    /// the run's own transcript carries the rest.
    public var previewLine: String? {
        guard let summary = self.summary else { return nil }
        let line = summary
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
        guard let line, !line.isEmpty else { return nil }
        return line
    }

    public var durationLabel: String? {
        guard let durationMs, durationMs > 0 else { return nil }
        let seconds = durationMs / 1000
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }

    public init(
        ts: Double,
        jobId: String,
        jobName: String? = nil,
        status: String? = nil,
        summary: String? = nil,
        runAtMs: Double? = nil,
        durationMs: Double? = nil,
        model: String? = nil,
        provider: String? = nil,
        sessionKey: String? = nil,
        deliveryStatus: String? = nil)
    {
        self.ts = ts
        self.jobId = jobId
        self.jobName = jobName
        self.status = status
        self.summary = summary
        self.runAtMs = runAtMs
        self.durationMs = durationMs
        self.model = model
        self.provider = provider
        self.sessionKey = sessionKey
        self.deliveryStatus = deliveryStatus
    }
}

public struct CronRunsPage: Decodable, Sendable {
    public let entries: [CronRun]
    public let total: Int?
    public let hasMore: Bool?
    public let nextOffset: Int?
}

/// Live `cron` broadcast payload. Verified against the installed dist's cron service
/// `emit(...)` call sites: `started` carries `{jobId, action, job, runAtMs}`; `finished`
/// adds `{status, error?, summary?, sessionKey?, durationMs?, deliveryStatus?, model?,
/// provider?}`. Other actions (`added`/`updated`/`removed`) describe job definitions, not
/// runs. Unlike the run-log ledger, the broadcast has no `ts` — the receiver supplies one.
public struct CronEventPayload: Decodable, Sendable {
    public struct Job: Decodable, Sendable {
        public let id: String?
        public let name: String?
    }

    public let jobId: String?
    public let action: String?
    public let job: Job?
    public let status: String?
    public let error: String?
    public let summary: String?
    public let runAtMs: Double?
    public let durationMs: Double?
    public let sessionKey: String?
    public let deliveryStatus: String?
    public let model: String?
    public let provider: String?
}

extension CronRun {
    /// Folds one live `cron` event into the run list so the Activity view moves without a
    /// `cron.runs` refetch: `started` inserts a synthetic "running" row, `finished`
    /// replaces that row (or prepends, when the start was missed) with the real outcome.
    /// A job has at most one active run, so the running row is matched by jobId alone.
    public static func merging(
        _ runs: [CronRun],
        event: CronEventPayload,
        nowMs: Double = Date().timeIntervalSince1970 * 1000) -> [CronRun]
    {
        guard let jobId = event.jobId, !jobId.isEmpty else { return runs }
        switch event.action {
        case "started":
            let started = CronRun(
                ts: event.runAtMs ?? nowMs,
                jobId: jobId,
                jobName: event.job?.name,
                status: "running",
                runAtMs: event.runAtMs)
            var merged = runs.filter { !($0.jobId == jobId && $0.outcome == .running) }
            merged.insert(started, at: 0)
            return merged
        case "finished":
            let runningIndex = runs.firstIndex { $0.jobId == jobId && $0.outcome == .running }
            let finished = CronRun(
                ts: event.runAtMs ?? runningIndex.map { runs[$0].ts } ?? nowMs,
                jobId: jobId,
                jobName: event.job?.name ?? runningIndex.map { runs[$0].jobName } ?? nil,
                status: event.status,
                summary: event.summary ?? event.error,
                runAtMs: event.runAtMs,
                durationMs: event.durationMs,
                model: event.model,
                provider: event.provider,
                sessionKey: event.sessionKey,
                deliveryStatus: event.deliveryStatus)
            var merged = runs
            if let runningIndex {
                merged[runningIndex] = finished
            } else {
                merged.insert(finished, at: 0)
            }
            return merged
        default:
            // Job add/update/remove and future actions are definition changes; the run list
            // has nothing to show for them.
            return runs
        }
    }
}

/// Counts for the runs header. Kept separate from the view so the "3 failed" line is
/// testable without a gateway.
public struct CronRunDigest: Sendable, Equatable {
    public let total: Int
    public let succeeded: Int
    public let failed: Int
    public let skipped: Int

    public init(runs: [CronRun]) {
        self.total = runs.count
        self.succeeded = runs.count(where: { $0.outcome == .succeeded })
        self.failed = runs.count(where: { $0.outcome.needsAttention })
        self.skipped = runs.count(where: { $0.outcome == .skipped })
    }

    public var summaryText: String {
        guard self.total > 0 else { return "No runs yet" }
        var parts = ["\(self.total) runs"]
        if self.failed > 0 { parts.append("\(self.failed) failed") }
        if self.skipped > 0 { parts.append("\(self.skipped) skipped") }
        return parts.joined(separator: " · ")
    }
}

public enum AutomationRunsState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}
