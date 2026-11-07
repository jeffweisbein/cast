#if os(macOS) && DEBUG
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct OfflineLayoutStressConfiguration: Equatable {
    let isEnabled: Bool
    let strategy: TranscriptLayoutStrategy
    let iterations: Int
    let intervalMilliseconds: Int
    let watchdogMilliseconds: Int

    static func resolve(environment: [String: String]) -> Self {
        func bounded(_ key: String, default fallback: Int, range: ClosedRange<Int>) -> Int {
            guard let raw = environment[key], let value = Int(raw) else { return fallback }
            return min(max(value, range.lowerBound), range.upperBound)
        }

        return Self(
            isEnabled: environment["CAST_OFFLINE_LAYOUT_STRESS"] == "1",
            strategy: environment["CAST_LAYOUT_STRATEGY"]
                .flatMap(TranscriptLayoutStrategy.init(rawValue:))
                ?? .productionDefault,
            iterations: bounded("CAST_LAYOUT_STRESS_ITERATIONS", default: 360, range: 1 ... 20_000),
            intervalMilliseconds: bounded("CAST_LAYOUT_STRESS_INTERVAL_MS", default: 20, range: 5 ... 1_000),
            watchdogMilliseconds: bounded("CAST_LAYOUT_STRESS_WATCHDOG_MS", default: 5_000, range: 1_000 ... 60_000))
    }
}

/// Real-app, in-memory reproduction path for transcript/composer layout feedback. The
/// background timer never waits on the main actor, so a SwiftUI placement fixed point
/// terminates the process with a distinct failure instead of silently pinning a core.
private final class OfflineLayoutWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let timeoutNanoseconds: UInt64
    private var lastIteration = 0
    private lazy var heartbeatWatchdog = BackgroundHeartbeatWatchdog(
        interval: .milliseconds(250),
        queue: .global(qos: .userInitiated))
    { [weak self] elapsed in
        self?.check(elapsedNanoseconds: elapsed)
    }

    init(timeoutMilliseconds: Int) {
        self.timeoutNanoseconds = UInt64(timeoutMilliseconds) * 1_000_000
    }

    func start() {
        self.heartbeatWatchdog.start()
    }

    func heartbeat(iteration: Int) {
        self.lock.lock()
        self.lastIteration = iteration
        self.lock.unlock()
        self.heartbeatWatchdog.heartbeat()
    }

    func complete() {
        self.heartbeatWatchdog.complete()
    }

    private func check(elapsedNanoseconds: UInt64) {
        self.lock.lock()
        let iteration = self.lastIteration
        self.lock.unlock()
        guard elapsedNanoseconds > self.timeoutNanoseconds else { return }

        let message = "CAST_LAYOUT_STRESS_WATCHDOG_TIMEOUT iteration=\(iteration)\n"
        _ = message.withCString { write(STDERR_FILENO, $0, strlen($0)) }
        _exit(70)
    }
}

@MainActor
struct OfflineLayoutStressView: View {
    let store: ChatStore
    let configuration: OfflineLayoutStressConfiguration
    @State private var stressTask: Task<Void, Never>?

    var body: some View {
        if let mode = ProcessInfo.processInfo.environment["CAST_RELIABILITY_FIXTURE"] {
            ReliabilityFixtureView(store: store, mode: mode)
        } else {
        ChatView(
            store: self.store,
            layoutStrategy: self.configuration.strategy,
            allowsSending: ProcessInfo.processInfo.environment["CAST_LOCAL_TOOLS_FIXTURE"] == "1")
            .overlay(alignment: .topLeading) {
                Text("offline layout stress · \(self.configuration.strategy.rawValue)")
                    .font(.caption2.monospaced())
                    .padding(6)
                    .background(.regularMaterial)
                    .allowsHitTesting(false)
            }
            .task {
                guard self.stressTask == nil else { return }
                let task = Task { @MainActor in await self.runStress() }
                self.stressTask = task
                await task.value
            }
            .onDisappear {
                self.stressTask?.cancel()
                self.stressTask = nil
            }
    }

    }

    private func runStress() async {
        // Local tools can be exercised without a gateway, credentials, or live conversations.
        // This DEBUG-only branch deliberately leaves sending disconnected.
        if ProcessInfo.processInfo.environment["CAST_LOCAL_TOOLS_FIXTURE"] == "1" {
            self.store.installOfflineDiagnosticTranscript([])
            return
        }
        let watchdog = OfflineLayoutWatchdog(timeoutMilliseconds: self.configuration.watchdogMilliseconds)
        self.store.installOfflineDiagnosticTranscript(OfflineLayoutStressData.messages(phase: 0))
        watchdog.start()

        print("CAST_LAYOUT_STRESS_START strategy=\(self.configuration.strategy.rawValue) iterations=\(self.configuration.iterations)")
        fflush(stdout)

        for iteration in 1 ... self.configuration.iterations {
            guard !Task.isCancelled else { return }

            // Re-key media periodically so ImageIO resolves fresh placeholder-to-thumbnail
            // heights while the composer independently grows and collapses below it.
            if iteration.isMultiple(of: 25) {
                self.store.installOfflineDiagnosticTranscript(
                    OfflineLayoutStressData.messages(phase: (iteration / 25) % 4))
            }
            self.store.pendingAttachments = OfflineLayoutStressData.pendingAttachments(
                phase: iteration % 4)
            watchdog.heartbeat(iteration: iteration)

            if iteration.isMultiple(of: 20) {
                print("CAST_LAYOUT_STRESS_HEARTBEAT iteration=\(iteration)")
                fflush(stdout)
            }
            try? await Task.sleep(
                nanoseconds: UInt64(self.configuration.intervalMilliseconds) * 1_000_000)
        }

        watchdog.complete()
        self.store.pendingAttachments = []
        print("CAST_LAYOUT_STRESS_COMPLETE strategy=\(self.configuration.strategy.rawValue) iterations=\(self.configuration.iterations)")
        fflush(stdout)
        try? await Task.sleep(nanoseconds: 100_000_000)
        exit(EXIT_SUCCESS)
    }
}

private enum OfflineLayoutStressData {
    private static let wideImage = png(width: 640, height: 120, color: (0.18, 0.50, 0.92))
    private static let tallImage = png(width: 180, height: 640, color: (0.93, 0.35, 0.24))

    static func messages(phase: Int) -> [ChatMessage] {
        (0 ..< 240).map { index in
            let role = index.isMultiple(of: 2) ? "user" : "assistant"
            let base = ChatContentBlock(
                type: "text",
                text: role == "user"
                    ? "Offline fixture message \(index) with deterministic wrapping content."
                    : "Fixture response **\(index)** keeps Markdown and row placement active without links or external content.",
                thinking: nil,
                name: nil,
                mimeType: nil,
                fileName: nil)
            let timestamp = 1_750_000_000_000 + Double(index * 1_000)

            if index.isMultiple(of: 15) {
                let isWide = (index / 15 + phase).isMultiple(of: 2)
                return ChatMessage(
                    id: "offline-image-\(phase)-\(index)",
                    role: role,
                    blocks: [base],
                    timestamp: timestamp,
                    mediaPaths: ["/__cast_offline__/image-\(phase)-\(index).png"],
                    mediaTypes: ["image/png"],
                    localImageData: [isWide ? self.wideImage : self.tallImage])
            }
            if index.isMultiple(of: 22) {
                return ChatMessage(
                    id: "offline-video-\(phase)-\(index)",
                    role: role,
                    blocks: [base],
                    timestamp: timestamp,
                    mediaPaths: ["/__cast_offline__/clip-\(phase)-\(index).mov"],
                    mediaTypes: ["video/quicktime"])
            }
            if index.isMultiple(of: 26) {
                return ChatMessage(
                    id: "offline-file-\(phase)-\(index)",
                    role: role,
                    blocks: [base],
                    timestamp: timestamp,
                    mediaPaths: ["/__cast_offline__/report-\(phase)-\(index).pdf"],
                    mediaTypes: ["application/pdf"])
            }
            return ChatMessage(
                id: "offline-text-\(phase)-\(index)",
                role: role,
                blocks: [base],
                timestamp: timestamp)
        }
    }

    static func pendingAttachments(phase: Int) -> [PreparedAttachment] {
        switch phase {
        case 1:
            return [PreparedAttachment(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                type: "image",
                mimeType: "image/png",
                fileName: "wide-fixture.png",
                data: self.wideImage)]
        case 2:
            return [
                PreparedAttachment(
                    id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                    type: "image",
                    mimeType: "image/png",
                    fileName: "wide-fixture.png",
                    data: self.wideImage),
                PreparedAttachment(
                    id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                    type: "file",
                    mimeType: "application/pdf",
                    fileName: "fixture-report.pdf",
                    data: Data("offline fixture".utf8)),
                PreparedAttachment(
                    id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                    type: "file",
                    mimeType: "video/quicktime",
                    fileName: "fixture-video.mov",
                    data: Data("offline video fixture".utf8)),
            ]
        default:
            return []
        }
    }

    private static func png(
        width: Int,
        height: Int,
        color: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> Data
    {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { preconditionFailure("Could not create offline fixture context") }
        context.setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { preconditionFailure("Could not create offline fixture image") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil)
        else { preconditionFailure("Could not create offline fixture encoder") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { preconditionFailure("Could not encode offline fixture image") }
        return output as Data
    }
}
#endif
