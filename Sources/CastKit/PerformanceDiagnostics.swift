import Foundation
import OSLog

/// The timer/heartbeat primitive shared by the release watchdog and the destructive
/// offline-layout stress watchdog. The timer never waits on the main actor.
final class BackgroundHeartbeatWatchdog: @unchecked Sendable {
    typealias Check = @Sendable (_ elapsedNanoseconds: UInt64) -> Void

    private let lock = NSLock()
    private let interval: DispatchTimeInterval
    private let queue: DispatchQueue
    private let check: Check
    private var lastHeartbeat = DispatchTime.now().uptimeNanoseconds
    private var finished = false
    private var timer: DispatchSourceTimer?

    init(
        interval: DispatchTimeInterval,
        queue: DispatchQueue,
        check: @escaping Check)
    {
        self.interval = interval
        self.queue = queue
        self.check = check
    }

    func start() {
        self.lock.lock()
        guard self.timer == nil, !self.finished else {
            self.lock.unlock()
            return
        }
        self.lastHeartbeat = DispatchTime.now().uptimeNanoseconds
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        self.timer = timer
        self.lock.unlock()

        timer.schedule(deadline: .now() + self.interval, repeating: self.interval)
        timer.setEventHandler { [weak self] in self?.runCheck() }
        timer.resume()
    }

    func heartbeat() {
        self.lock.lock()
        self.lastHeartbeat = DispatchTime.now().uptimeNanoseconds
        self.lock.unlock()
    }

    func complete() {
        self.lock.lock()
        self.finished = true
        let timer = self.timer
        self.timer = nil
        self.lock.unlock()
        timer?.cancel()
    }

    private func runCheck() {
        self.lock.lock()
        let finished = self.finished
        let lastHeartbeat = self.lastHeartbeat
        self.lock.unlock()
        guard !finished else { return }
        self.check(DispatchTime.now().uptimeNanoseconds - lastHeartbeat)
    }
}

enum CastPerformanceOperation: String, Sendable {
    case openSelectedSession = "openSelectedSession"
    case resubscribeAndReloadOpenSession = "resubscribeAndReloadOpenSession"
    case reconcileOpenTranscript = "reconcileOpenTranscript"
    case reloadHistory = "reloadHistory"
    case historyBackfill = "historyBackfill"
    case transcriptBuilderItems = "TranscriptBuilder.items"
    case transcriptCache = "ChatStore.transcriptCache"
    case composerKeystroke = "composer.keystroke"

    fileprivate var signpostName: StaticString {
        switch self {
        case .openSelectedSession: "openSelectedSession"
        case .resubscribeAndReloadOpenSession: "resubscribeAndReloadOpenSession"
        case .reconcileOpenTranscript: "reconcileOpenTranscript"
        case .reloadHistory: "reloadHistory"
        case .historyBackfill: "historyBackfill"
        case .transcriptBuilderItems: "TranscriptBuilder.items"
        case .transcriptCache: "ChatStore.transcriptCache"
        case .composerKeystroke: "composer.keystroke"
        }
    }
}

struct CastPerformanceInterval: Sendable {
    fileprivate let id: UUID
    fileprivate let operation: CastPerformanceOperation
    fileprivate let signpostID: OSSignpostID
    fileprivate let startedAt: Date
}

struct CastPerformanceOperationRecord: Codable, Equatable, Sendable {
    let operationID: UUID
    let timestamp: Date
    let operation: String
    let phase: String
    let durationMilliseconds: Double?
    let metadata: String?
}

enum CastPerformanceDiagnostics {
    private static let signpostLog = OSLog(
        subsystem: "com.besttechie.cast",
        category: "performance")
    private static let operations = BoundedOperationHistory(capacity: 64)

    @discardableResult
    static func begin(
        _ operation: CastPerformanceOperation,
        metadata: String? = nil) -> CastPerformanceInterval
    {
        let id = UUID()
        let signpostID = OSSignpostID(log: self.signpostLog)
        let metadata = self.bounded(metadata)
        os_signpost(
            .begin,
            log: self.signpostLog,
            name: operation.signpostName,
            signpostID: signpostID,
            "metadata=%{public}s",
            metadata ?? "-")
        let interval = CastPerformanceInterval(
            id: id,
            operation: operation,
            signpostID: signpostID,
            startedAt: Date())
        self.operations.append(CastPerformanceOperationRecord(
            operationID: id,
            timestamp: interval.startedAt,
            operation: operation.rawValue,
            phase: "begin",
            durationMilliseconds: nil,
            metadata: metadata))
        return interval
    }

    static func end(_ interval: CastPerformanceInterval, metadata: String? = nil) {
        let endedAt = Date()
        let duration = endedAt.timeIntervalSince(interval.startedAt) * 1_000
        let metadata = self.bounded(metadata)
        os_signpost(
            .end,
            log: self.signpostLog,
            name: interval.operation.signpostName,
            signpostID: interval.signpostID,
            "duration_ms=%{public}.3f metadata=%{public}s",
            duration,
            metadata ?? "-")
        self.operations.append(CastPerformanceOperationRecord(
            operationID: interval.id,
            timestamp: endedAt,
            operation: interval.operation.rawValue,
            phase: "end",
            durationMilliseconds: duration,
            metadata: metadata))
    }

    static func recentOperations() -> [CastPerformanceOperationRecord] {
        self.operations.snapshot()
    }

    private static func bounded(_ metadata: String?) -> String? {
        metadata.map { String($0.prefix(200)) }
    }
}

private final class BoundedOperationHistory: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var records: [CastPerformanceOperationRecord] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func append(_ record: CastPerformanceOperationRecord) {
        self.lock.lock()
        self.records.append(record)
        if self.records.count > self.capacity {
            self.records.removeFirst(self.records.count - self.capacity)
        }
        self.lock.unlock()
    }

    func snapshot() -> [CastPerformanceOperationRecord] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.records
    }
}

enum MainThreadStallPhase: String, Codable, Sendable {
    case warning
    case hang
    case recovered
}

struct MainThreadStallRecord: Codable, Equatable, Sendable {
    let id: UUID
    let runID: UUID
    let stallID: UUID
    let timestamp: Date
    let phase: MainThreadStallPhase
    let observedDurationMilliseconds: Double
    let mainThreadBacktrace: [String]
    let recentOperations: [CastPerformanceOperationRecord]
}

struct MainThreadStallFile: Codable, Equatable, Sendable {
    var activeRunID: UUID?
    var records: [MainThreadStallRecord]
}

/// Atomic, bounded disk ring. It is intentionally independent of the app singleton so the
/// retention and prior-run summary behavior can be tested against a temporary directory.
final class MainThreadStallRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    let fileURL: URL
    private var payload: MainThreadStallFile

    init(fileURL: URL, capacity: Int = 50) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.payload = (try? Data(contentsOf: fileURL))
            .flatMap { try? decoder.decode(MainThreadStallFile.self, from: $0) }
            ?? MainThreadStallFile(activeRunID: nil, records: [])
        if self.payload.records.count > self.capacity {
            self.payload.records = Array(self.payload.records.suffix(self.capacity))
        }
    }

    func beginRun(_ runID: UUID) -> [MainThreadStallRecord] {
        self.lock.lock()
        let previousRunID = self.payload.activeRunID
        let previousRecords = previousRunID.map { previous in
            self.payload.records.filter { $0.runID == previous }
        } ?? []
        self.payload.activeRunID = runID
        self.persistLocked()
        self.lock.unlock()
        return previousRecords
    }

    func append(_ record: MainThreadStallRecord) {
        self.lock.lock()
        self.payload.records.append(record)
        if self.payload.records.count > self.capacity {
            self.payload.records.removeFirst(self.payload.records.count - self.capacity)
        }
        self.persistLocked()
        self.lock.unlock()
    }

    func snapshot() -> MainThreadStallFile {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.payload
    }

    private func persistLocked() {
        do {
            try FileManager.default.createDirectory(
                at: self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self.payload).write(to: self.fileURL, options: .atomic)
        } catch {
            Logger(subsystem: "com.besttechie.cast", category: "watchdog")
                .error("failed to persist main-thread stall: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Pure stall lifecycle state; owned under the watchdog's lock. Diagnostics must never
/// suspend another thread: Swift allocation and symbolication can require locks that
/// thread owns, turning a temporary stall into a permanent deadlock.
struct MainThreadStallTracker {
    static let warningMilliseconds: Double = 500
    static let hangMilliseconds: Double = 3_000
    private var stallID: UUID?
    private var warningRecorded = false
    private var hangRecorded = false

    mutating func check(durationMilliseconds: Double) -> MainThreadStallObservation? {
        guard durationMilliseconds >= Self.warningMilliseconds else { return nil }
        let stallID = self.stallID ?? UUID()
        self.stallID = stallID
        let phase: MainThreadStallPhase
        if !self.warningRecorded {
            self.warningRecorded = true
            phase = .warning
        } else if durationMilliseconds >= Self.hangMilliseconds, !self.hangRecorded {
            self.hangRecorded = true
            phase = .hang
        } else {
            return nil
        }
        return MainThreadStallObservation(
            stallID: stallID, phase: phase, durationMilliseconds: durationMilliseconds)
    }

    mutating func recover(durationMilliseconds: Double) -> MainThreadStallObservation? {
        let stallID = self.stallID
        self.stallID = nil
        self.warningRecorded = false
        self.hangRecorded = false
        guard let stallID, durationMilliseconds >= Self.warningMilliseconds else { return nil }
        return MainThreadStallObservation(
            stallID: stallID, phase: .recovered, durationMilliseconds: durationMilliseconds)
    }
}

struct MainThreadStallObservation {
    let stallID: UUID
    let phase: MainThreadStallPhase
    let durationMilliseconds: Double

    func record(runID: UUID, recentOperations: [CastPerformanceOperationRecord]) -> MainThreadStallRecord {
        MainThreadStallRecord(
            id: UUID(),
            runID: runID,
            stallID: self.stallID,
            timestamp: Date(),
            phase: self.phase,
            observedDurationMilliseconds: self.durationMilliseconds,
            mainThreadBacktrace: ["Not captured: in-process thread suspension is unsafe; use an external process sample for stacks."],
            recentOperations: recentOperations)
    }
}

/// Always-on main-thread watchdog. A background timer queues a heartbeat on the main
/// dispatch queue. At 500 ms it persists a warning sample; at 3 seconds it persists a hang
/// sample. Recovery adds the exact final duration. It never terminates the app.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()
    static let warningMilliseconds = MainThreadStallTracker.warningMilliseconds
    static let hangMilliseconds = MainThreadStallTracker.hangMilliseconds

    private let logger = Logger(subsystem: "com.besttechie.cast", category: "watchdog")
    private let diagnosticsQueue = DispatchQueue(
        label: "com.besttechie.cast.main-thread-watchdog",
        qos: .userInitiated)
    private let lock = NSLock()
    private let runID = UUID()
    private let ringBuffer: MainThreadStallRingBuffer
    private var heartbeatWatchdog: BackgroundHeartbeatWatchdog?
    private var stallTracker = MainThreadStallTracker()
    private var started = false

    private init() {
        self.ringBuffer = MainThreadStallRingBuffer(fileURL: Self.fileURL)
    }

    static var fileURL: URL {
        CastLifecycleDiagnostics.diagnosticsDirectory
            .appendingPathComponent("main-thread-stalls.json")
    }

    /// Must be called from app launch on the main thread to start its heartbeat.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        self.lock.lock()
        guard !self.started else {
            self.lock.unlock()
            return
        }
        self.started = true
        self.lock.unlock()

        let previousRecords = self.ringBuffer.beginRun(self.runID)
        if !previousRecords.isEmpty {
            let longest = previousRecords.map(\.observedDurationMilliseconds).max() ?? 0
            let stallCount = Set(previousRecords.map(\.stallID)).count
            let summary = String(
                format: "CAST_MAIN_THREAD_STALLS_LAST_RUN count=%d longest_ms=%.0f file=%@",
                stallCount,
                longest,
                Self.fileURL.path)
            print(summary)
            self.logger.notice("\(summary, privacy: .public)")
        }

        let watchdog = BackgroundHeartbeatWatchdog(
            interval: .milliseconds(100),
            queue: self.diagnosticsQueue)
        { [weak self] elapsed in
            self?.check(elapsedNanoseconds: elapsed)
        }
        self.heartbeatWatchdog = watchdog
        watchdog.start()
        Task { @MainActor [weak watchdog] in watchdog?.heartbeat() }
    }

    private func check(elapsedNanoseconds: UInt64) {
        let durationMilliseconds = Double(elapsedNanoseconds) / 1_000_000
        self.lock.lock()
        let observation = self.stallTracker.check(durationMilliseconds: durationMilliseconds)
        self.lock.unlock()

        if let observation { self.record(observation) }

        // Queue the heartbeat after evaluating elapsed time. During a stall these pings wait
        // harmlessly on the main queue; on recovery the first one closes the sample.
        Task { @MainActor [weak self] in self?.mainThreadResponded() }
    }

    @MainActor
    private func mainThreadResponded() {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = DispatchTime.now().uptimeNanoseconds
        self.lock.lock()
        let watchdog = self.heartbeatWatchdog
        let elapsed = watchdog?.elapsedSinceHeartbeat(at: now) ?? 0
        let observation = self.stallTracker.recover(durationMilliseconds: Double(elapsed) / 1_000_000)
        watchdog?.heartbeat()
        self.lock.unlock()

        if let observation {
            self.diagnosticsQueue.async { [weak self] in self?.record(observation) }
        }
    }

    private func record(_ observation: MainThreadStallObservation) {
        let record = observation.record(
            runID: self.runID,
            recentOperations: CastPerformanceDiagnostics.recentOperations())
        self.ringBuffer.append(record)
        self.logger.error(
            "main-thread stall phase=\(record.phase.rawValue, privacy: .public) duration_ms=\(record.observedDurationMilliseconds, privacy: .public) file=\(Self.fileURL.path, privacy: .public)")
    }
}

extension BackgroundHeartbeatWatchdog {
    fileprivate func elapsedSinceHeartbeat(at now: UInt64) -> UInt64 {
        self.lock.lock()
        defer { self.lock.unlock() }
        return now - self.lastHeartbeat
    }
}
