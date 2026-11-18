#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Cast

/// Measures how long the main thread is unavailable after a conversation is selected, the
/// same quantity the production `MainThreadWatchdog` persists. A background timer pings the
/// main queue; the time each ping waits is main-thread work the reader experiences as a
/// frozen window.
final class MainThreadStallProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private var pingOutstanding = false
    private var longest: Double = 0
    private var lastBusyEnd: UInt64 = 0
    private var firstBusyEnd: UInt64 = 0
    private static let busyThresholdMilliseconds: Double = 34

    init() {
        self.timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        self.timer.schedule(deadline: .now(), repeating: .milliseconds(4))
        self.timer.setEventHandler { [weak self] in self?.ping() }
        self.timer.resume()
    }

    deinit { self.timer.cancel() }

    private func ping() {
        self.lock.lock()
        guard !self.pingOutstanding else { self.lock.unlock(); return }
        self.pingOutstanding = true
        self.lock.unlock()
        let enqueued = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async {
            let now = DispatchTime.now().uptimeNanoseconds
            let waited = Double(now - enqueued) / 1_000_000
            self.lock.lock()
            self.pingOutstanding = false
            self.longest = max(self.longest, waited)
            if waited >= Self.busyThresholdMilliseconds {
                if self.firstBusyEnd == 0 { self.firstBusyEnd = now }
                self.lastBusyEnd = now
            }
            self.lock.unlock()
        }
    }

    func reset() {
        self.lock.lock()
        self.longest = 0
        self.lastBusyEnd = 0
        self.firstBusyEnd = 0
        self.lock.unlock()
    }

    /// Longest single main-thread stall since `reset`, and when the last stall ended.
    func reading() -> (longestMilliseconds: Double, firstBusyEnd: UInt64, lastBusyEnd: UInt64) {
        self.lock.lock()
        defer { self.lock.unlock() }
        return (self.longest, self.firstBusyEnd, self.lastBusyEnd)
    }
}

/// Hosts the production `ChatView` in a real window and rotates through more conversations
/// than the in-memory snapshot cache holds. Everything is synthetic and offline: no gateway,
/// no reader data.
@MainActor
final class ChatSwitchRenderLatencyTests: XCTestCase {
    struct Sample {
        let round: Int
        let chat: Int
        /// Longest single main-thread freeze after the selection.
        let stallMilliseconds: Double
        /// Selection until the first main-thread freeze ended: the first frame of the new
        /// conversation. Hosted-view timing, not a physical click or a display refresh.
        let firstPaintMilliseconds: Double
        /// Selection until the main thread stayed quiet: the whole window is restored.
        let settledMilliseconds: Double
        let firstPaintDocumentHeight: CGFloat
        let settledDocumentHeight: CGFloat
        let distanceFromBottom: CGFloat
    }

    static let chatCount = 7
    static let messagesPerChat = 1_500

    static func key(_ chat: Int) -> String { "agent:main:render-latency-\(chat)" }

    /// Deterministic assistant prose shaped like real replies: headings, lists, inline code,
    /// fenced code and tables, so each row pays representative Markdown layout cost.
    static func assistantText(chat: Int, index: Int) -> String {
        var parts = [
            "## Update \(index) for workspace \(chat)",
            "The build finished and the **verification** step reported `exit 0` for target `module-\(index % 9)`. "
                + String(repeating: "Each stage keeps its receipt next to the artifact it describes. ", count: 4),
            "- First finding with a [reference](https://example.com/\(index))\n- Second finding about `cache-\(index % 5)`\n- Third finding that spans a slightly longer line of synthetic text",
        ]
        if index.isMultiple(of: 3) {
            parts.append("```swift\nfunc step\(index)() -> Int {\n    let value = \(index) * 2\n    return value + 1\n}\n```")
        }
        if index.isMultiple(of: 7) {
            parts.append("| Check | Result |\n| --- | --- |\n| unit | pass |\n| release | pass |")
        }
        parts.append(String(repeating: "Closing paragraph with ordinary sentence structure. ", count: 3))
        return parts.joined(separator: "\n\n")
    }

    static func transcript(chat: Int, count: Int = messagesPerChat) -> [ChatMessage] {
        (0..<count).map { index in
            let isUser = index.isMultiple(of: 2)
            let text = isUser
                ? "Synthetic request \(index) in chat \(chat): please continue."
                : Self.assistantText(chat: chat, index: index)
            return ChatMessage(
                id: "render-\(chat)-\(index)",
                role: isUser ? "user" : "assistant",
                blocks: [ChatContentBlock(
                    type: "text", text: text, thinking: nil, name: nil, mimeType: nil, fileName: nil)],
                timestamp: Double(index) * 60_000)
        }
    }

    private func makeStore() async -> ChatStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastRenderLatency-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(workspaceID: "render-latency", root: root)
        for chat in 0..<Self.chatCount {
            await cache.save(Self.transcript(chat: chat), sessionKey: Self.key(chat))
        }
        return ChatStore(
            profile: .init(
                id: "render-latency", name: "Test",
                gatewayURL: URL(string: "wss://example.invalid")!, accent: "blue"),
            transcriptCacheRoot: root,
            operationsLedgerRoot: root.appendingPathComponent("operations"))
    }

    /// Growth is paced by reader input in production. Tests pin that signal so results do
    /// not depend on whether someone is using the machine running them.
    private func setReaderIdle(_ idle: Bool) {
        TranscriptGrowthPacing.secondsSinceUserInput = { idle ? .infinity : 0 }
    }

    override func setUp() async throws {
        let original = TranscriptGrowthPacing.secondsSinceUserInput
        addTeardownBlock { @MainActor in TranscriptGrowthPacing.secondsSinceUserInput = original }
        self.setReaderIdle(true)
    }

    private func host(_ store: ChatStore) -> NSWindow {
        let view = NSHostingView(rootView: ChatView(store: store, allowsSending: false, showsComposer: false)
            .environment(\.scenePhase, .active))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
            window.contentView = nil
        }
        return window
    }

    private func scrollView(in window: NSWindow) -> NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)
    }

    private func documentHeight(_ window: NSWindow) -> CGFloat {
        self.scrollView(in: window)?.documentView?.bounds.height ?? 0
    }

    private func distanceFromBottom(_ window: NSWindow) -> CGFloat {
        guard let scroll = self.scrollView(in: window), let document = scroll.documentView else { return .infinity }
        let visible = scroll.documentVisibleRect
        return document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
    }

    /// Selects `chat` and waits until its transcript is loaded and the main thread has been
    /// continuously responsive for `quietMilliseconds`.
    private func measureSwitch(
        to chat: Int, round: Int, store: ChatStore, window: NSWindow, probe: MainThreadStallProbe,
        quietMilliseconds: Double = 400) async throws -> Sample
    {
        probe.reset()
        let start = DispatchTime.now().uptimeNanoseconds
        store.selectedSessionKey = Self.key(chat)
        let deadline = start + 20_000_000_000
        var firstPaintHeight: CGFloat?
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(for: .milliseconds(10))
            let reading = probe.reading()
            let now = DispatchTime.now().uptimeNanoseconds
            let loaded = store.historySyncState == .idle && store.messages.count == Self.messagesPerChat
            // The previous chat's full window stays on screen until the new chat's first
            // frame replaces it, so the first paint is the smallest document seen since.
            if loaded, reading.firstBusyEnd > start {
                let height = self.documentHeight(window)
                if height > 0 { firstPaintHeight = min(firstPaintHeight ?? height, height) }
            }
            let quietSince = max(reading.lastBusyEnd, start)
            if loaded, Double(now - quietSince) / 1_000_000 >= quietMilliseconds {
                func elapsed(_ end: UInt64) -> Double { end > start ? Double(end - start) / 1_000_000 : 0 }
                return Sample(
                    round: round, chat: chat,
                    stallMilliseconds: reading.longestMilliseconds,
                    firstPaintMilliseconds: elapsed(reading.firstBusyEnd),
                    settledMilliseconds: elapsed(reading.lastBusyEnd),
                    firstPaintDocumentHeight: firstPaintHeight ?? self.documentHeight(window),
                    settledDocumentHeight: self.documentHeight(window),
                    distanceFromBottom: self.distanceFromBottom(window))
            }
        }
        XCTFail("Chat \(chat) did not settle after selection")
        return Sample(
            round: round, chat: chat, stallMilliseconds: .infinity, firstPaintMilliseconds: .infinity,
            settledMilliseconds: .infinity, firstPaintDocumentHeight: 0, settledDocumentHeight: 0,
            distanceFromBottom: .infinity)
    }

    private func report(_ sample: Sample) {
        print(String(
            format: "CHAT_SWITCH_RENDER round=%d chat=%d stall_ms=%.0f first_paint_ms=%.0f settled_ms=%.0f "
                + "first_paint_height=%.0f settled_height=%.0f from_bottom=%.0f",
            sample.round, sample.chat, sample.stallMilliseconds, sample.firstPaintMilliseconds,
            sample.settledMilliseconds, Double(sample.firstPaintDocumentHeight),
            Double(sample.settledDocumentHeight), Double(sample.distanceFromBottom)))
    }

    /// Rotating through seven conversations exceeds the five-entry snapshot cache, so every
    /// later round mixes warm restores with evicted disk restores.
    func testRotatingThroughMoreChatsThanTheSnapshotCacheStaysResponsive() async throws {
        let store = await makeStore()
        let window = host(store)
        let probe = MainThreadStallProbe()
        try await Task.sleep(for: .milliseconds(300))

        var samples: [Sample] = []
        for round in 0..<3 {
            for chat in 0..<Self.chatCount {
                let sample = try await measureSwitch(
                    to: chat, round: round, store: store, window: window, probe: probe)
                samples.append(sample)
                self.report(sample)
                XCTAssertEqual(store.selectedSessionKey, Self.key(chat))
                XCTAssertEqual(store.messages.last?.id, "render-\(chat)-\(Self.messagesPerChat - 1)")
            }
        }
        // A warm A/B flip is the most common real gesture; measure it separately.
        for flip in 0..<6 {
            let sample = try await measureSwitch(
                to: flip.isMultiple(of: 2) ? 5 : 6, round: 3, store: store, window: window, probe: probe)
            samples.append(sample)
            self.report(sample)
        }
        let later = samples.filter { $0.round > 0 }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let medianFirstPaint = median(later.map(\.firstPaintMilliseconds))
        let medianSettled = median(later.map(\.settledMilliseconds))
        print(String(
            format: "CHAT_SWITCH_RENDER_SUMMARY switches=%d median_stall_ms=%.0f worst_stall_ms=%.0f "
                + "median_first_paint_ms=%.0f worst_first_paint_ms=%.0f median_settled_ms=%.0f",
            later.count, median(later.map(\.stallMilliseconds)), later.map(\.stallMilliseconds).max() ?? 0,
            medianFirstPaint, later.map(\.firstPaintMilliseconds).max() ?? 0, medianSettled))
        // Machine-independent form of "the switch no longer waits for the whole window":
        // the first frame must land in a fraction of the time the full window takes. Before
        // staging, the first frame *was* the full window and this ratio sat near one.
        XCTAssertLessThan(
            medianFirstPaint, medianSettled / 3,
            "The first frame of a switched conversation must not wait for the whole window")
        for sample in later {
            XCTAssertLessThan(
                sample.firstPaintMilliseconds, sample.settledMilliseconds / 2,
                "Warm and evicted opens alike must paint before the window is complete (chat \(sample.chat))")
            // Staging must not cost the reader any transcript or their place at the tail.
            XCTAssertGreaterThan(
                sample.settledDocumentHeight, sample.firstPaintDocumentHeight * 2,
                "The window must grow back after the first paint (chat \(sample.chat))")
            XCTAssertLessThan(
                sample.distanceFromBottom, 4,
                "Growth above the viewport must leave the newest row in view (chat \(sample.chat))")
        }
    }

    /// Growth is main-thread work, so it must wait while the reader is using the Mac and
    /// resume once they stop, without losing the tail.
    func testWindowGrowthWaitsForTheReaderToBeIdle() async throws {
        let store = await makeStore()
        let window = host(store)
        try await Task.sleep(for: .milliseconds(300))
        self.setReaderIdle(false)
        store.selectedSessionKey = Self.key(3)
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertEqual(store.messages.count, Self.messagesPerChat)
        let firstPaintHeight = self.documentHeight(window)
        XCTAssertGreaterThan(firstPaintHeight, 0)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(
            self.documentHeight(window), firstPaintHeight, accuracy: 1,
            "No rows may be built while the reader is active")
        XCTAssertLessThan(self.distanceFromBottom(window), 4)

        self.setReaderIdle(true)
        var grownHeight = firstPaintHeight
        for _ in 0..<400 {
            try await Task.sleep(for: .milliseconds(50))
            let height = self.documentHeight(window)
            if height == grownHeight, height > firstPaintHeight * 2 { break }
            grownHeight = height
        }
        print(String(
            format: "CHAT_SWITCH_RENDER_IDLE first_paint_height=%.0f grown_height=%.0f",
            Double(firstPaintHeight), Double(grownHeight)))
        XCTAssertGreaterThan(grownHeight, firstPaintHeight * 2, "Growth must resume once the reader is idle")
        XCTAssertLessThan(self.distanceFromBottom(window), 4)
    }

    /// Selecting another conversation while the previous one is still growing must cancel
    /// that growth: the next chat starts from its own first paint and shows only its rows.
    func testSwitchingDuringStagedGrowthSettlesOnTheLastSelectedChat() async throws {
        let store = await makeStore()
        let window = host(store)
        let probe = MainThreadStallProbe()
        try await Task.sleep(for: .milliseconds(300))
        let reference = try await measureSwitch(to: 2, round: 0, store: store, window: window, probe: probe)
        _ = try await measureSwitch(to: 0, round: 0, store: store, window: window, probe: probe)

        // Interrupt at several points of the staging, including before the first paint.
        for (step, delay) in [0, 40, 150, 260, 420, 90].enumerated() {
            store.selectedSessionKey = Self.key(step.isMultiple(of: 2) ? 1 : 0)
            try await Task.sleep(for: .milliseconds(delay))
        }
        let settled = try await measureSwitch(to: 2, round: 1, store: store, window: window, probe: probe)
        self.report(settled)
        XCTAssertEqual(store.selectedSessionKey, Self.key(2))
        XCTAssertEqual(store.messages.first?.id, "render-2-0")
        XCTAssertEqual(store.messages.last?.id, "render-2-\(Self.messagesPerChat - 1)")
        XCTAssertEqual(
            settled.settledDocumentHeight, reference.settledDocumentHeight, accuracy: 1,
            "An interrupted growth must not leave a short or oversized window behind")
        XCTAssertLessThan(settled.distanceFromBottom, 4)
        XCTAssertLessThan(
            settled.firstPaintMilliseconds, settled.settledMilliseconds / 2,
            "A chat reopened after interrupted growth still paints its tail first")
    }
}
#endif
