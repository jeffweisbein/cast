import Foundation
import OSLog
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

public enum CastLifecycleDiagnostics {
    private static let logger = Logger(subsystem: "com.besttechie.cast", category: "lifecycle")
    private static let signposter = OSSignposter(subsystem: "com.besttechie.cast", category: "lifecycle")

    public static func appStarted() {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let sha = Bundle.main.object(forInfoDictionaryKey: "CastGitSHA") as? String ?? "unknown"
        self.logger.notice("Cast started build=\(build, privacy: .public) sha=\(sha, privacy: .public)")
        let environment = ProcessInfo.processInfo.environment
        // The DEBUG stress fixture owns a terminating watchdog with a caller-selected
        // timeout. Do not let release sampling/symbolication perturb that timing oracle.
        if environment["XCTestConfigurationFilePath"] == nil,
           environment["CAST_OFFLINE_LAYOUT_STRESS"] != "1"
        {
            MainThreadWatchdog.shared.start()
        }
        #if canImport(MetricKit) && os(iOS)
        _ = CastMetricSubscriber.shared
        #endif
    }

    public static func transition(_ phase: String) {
        self.logger.info("scene phase=\(phase, privacy: .public)")
        self.signposter.emitEvent("scene-phase", "\(phase, privacy: .public)")
    }

    public static func recorderStoppedForBackground() {
        self.logger.notice("recorder stopped for background")
        self.signposter.emitEvent("recorder-background-stop")
    }

    public static func recorderTransition(_ transition: String) {
        self.signposter.emitEvent("recorder-state", "\(transition, privacy: .public)")
    }

    public static func gatewayTransition(_ transition: String) {
        self.logger.info("gateway lifecycle=\(transition, privacy: .public)")
        self.signposter.emitEvent("gateway-lifecycle", "\(transition, privacy: .public)")
    }

    /// A subscribe RPC that exhausted its bounded retry ladder. Logged at notice level:
    /// the socket is up, so nothing else in the log says why live updates stopped arriving.
    public static func subscriptionFailed(scope: String, attempts: Int) {
        self.logger.notice(
            "subscribe gave up scope=\(scope, privacy: .public) attempts=\(attempts, privacy: .public)")
        self.signposter.emitEvent("subscribe-failed", "\(scope, privacy: .public)")
    }

    public static func connectionState(_ state: String) {
        self.signposter.emitEvent("connection-state", "\(state, privacy: .public)")
    }

    public static func transcriptPublished(count: Int) {
        self.signposter.emitEvent("transcript-published", "count=\(count, privacy: .public)")
    }

    public static func transcriptCacheDesynced(cachedItems: Int, expectedItems: Int) {
        self.signposter.emitEvent(
            "transcript-cache-desync",
            "cached=\(cachedItems, privacy: .public) expected=\(expectedItems, privacy: .public)")
    }

    public static func scrollRequested(deferred: Bool) {
        self.signposter.emitEvent("scroll-request", "deferred=\(deferred, privacy: .public)")
    }

    public static func composerFocusChanged(focused: Bool) {
        self.signposter.emitEvent("composer-focus", "focused=\(focused, privacy: .public)")
    }

    public static func diagnosticsExportURL() -> URL {
        let manager = FileManager.default
        let output = manager.temporaryDirectory.appendingPathComponent("Cast-Diagnostics.json")
        let directory = self.diagnosticsDirectory
        let files = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        let payloads: [Any] = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONSerialization.jsonObject(with: $0) }
        let export: [String: Any] = [
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "gitSHA": Bundle.main.object(forInfoDictionaryKey: "CastGitSHA") as? String ?? "unknown",
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "metricKitPayloads": payloads,
            "mainThreadStalls": (try? Data(contentsOf: MainThreadWatchdog.fileURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) }
                ?? NSNull(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: export, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
        return output
    }

    static var diagnosticsDirectory: URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        return base
            .appendingPathComponent("Cast", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }
}

#if canImport(MetricKit) && os(iOS)
private final class CastMetricSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = CastMetricSubscriber()
    private let logger = Logger(subsystem: "com.besttechie.cast", category: "metrickit")

    override private init() {
        super.init()
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        self.logger.notice("received metric payloads count=\(payloads.count, privacy: .public)")
        self.persist(payloads.map { $0.jsonRepresentation() }, kind: "metrics")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        self.logger.notice("received diagnostic payloads count=\(payloads.count, privacy: .public)")
        self.persist(payloads.map { $0.jsonRepresentation() }, kind: "diagnostics")
    }

    private func persist(_ payloads: [Data], kind: String) {
        let manager = FileManager.default
        let directory = CastLifecycleDiagnostics.diagnosticsDirectory
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, payload) in payloads.enumerated() {
                let stamp = Int(Date().timeIntervalSince1970 * 1000)
                let url = directory.appendingPathComponent("\(kind)-\(stamp)-\(index).json")
                try payload.write(to: url, options: .atomic)
            }
        } catch {
            self.logger.error("failed to persist MetricKit payload: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
