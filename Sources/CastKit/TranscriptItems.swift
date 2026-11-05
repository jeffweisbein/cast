// Cast — pure transcript presentation logic: role grouping, tool-run collapsing, day
// separators. Views render the item list; all decisions live here so they stay testable.
import Foundation

public struct ToolStep: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let summary: String?

    public init(id: String, name: String, summary: String?) {
        self.id = id
        self.name = name
        self.summary = summary
    }

    /// "bash" (OpenClaw-native) and "Bash" (Claude Code) both display as "Bash".
    public var displayName: String {
        guard let first = self.name.first, first.isLowercase else { return self.name }
        return self.name.prefix(1).uppercased() + self.name.dropFirst()
    }
}

public struct ToolRun: Identifiable, Sendable, Equatable {
    public let id: String
    public let steps: [ToolStep]

    public init(id: String, steps: [ToolStep]) {
        self.id = id
        self.steps = steps
    }

    /// Distinct tool names in first-appearance order with counts: "Bash ×4, Edit ×2".
    public var countSummary: String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for step in self.steps {
            let name = step.displayName
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.map { name in
            let count = counts[name] ?? 0
            return count > 1 ? "\(name) ×\(count)" : name
        }.joined(separator: ", ")
    }

    public var headline: String {
        let count = self.steps.count
        return "\(count) \(count == 1 ? "step" : "steps") · \(self.countSummary)"
    }
}

/// A concise, gateway-authored update from the current turn. Cast deliberately projects
/// only structured progress/tool fields; it never invents or requests hidden reasoning.
public struct AgentWorkItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let detail: String?
    public let isComplete: Bool

    public init(id: String, title: String, detail: String? = nil, isComplete: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isComplete = isComplete
    }
}

/// Pure reducer for the safe work-event subset emitted by the gateway protocol.
public enum AgentWorkProjector {
    public static func reducing(
        _ current: [AgentWorkItem],
        runId: String,
        stream: String?,
        data: AnyCodable?) -> [AgentWorkItem]
    {
        guard let stream, let data else { return current }
        let projected: AgentWorkItem?
        switch stream {
        case "tool":
            let phase = data["phase"]?.stringValue ?? ""
            guard let rawName = data["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawName.isEmpty
            else { return current }
            let callId = data["toolCallId"]?.stringValue
                ?? data["itemId"]?.stringValue
                ?? "\(runId)-\(rawName)"
            let name = ToolStep(id: callId, name: rawName, summary: nil).displayName
            let detail = TranscriptBuilder.toolSummary(name: rawName, arguments: data["args"])
                ?? current.first(where: { $0.id == callId })?.detail
            let failed = phase == "result" && data["isError"]?.boolValue == true
            projected = AgentWorkItem(
                id: callId,
                title: phase == "result" ? (failed ? "\(name) failed" : "Finished \(name)") : "Running \(name)",
                detail: detail,
                isComplete: phase == "result")
        case "item":
            // `preamble` is the protocol's user-facing progress item. Other item kinds may
            // contain internal bookkeeping and are intentionally not rendered here.
            guard data["kind"]?.stringValue == "preamble" else { return current }
            let itemId = data["itemId"]?.stringValue ?? data["id"]?.stringValue ?? "\(runId)-preamble"
            let progress = data["progressText"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let progress, !progress.isEmpty, progress.uppercased() != "NO_REPLY" else {
                return current.filter { $0.id != itemId }
            }
            projected = AgentWorkItem(id: itemId, title: progress)
        case "plan":
            let itemId = data["itemId"]?.stringValue ?? "\(runId)-plan"
            let title = data["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let explanation = data["explanation"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let visibleTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Plan updated"
            projected = AgentWorkItem(
                id: itemId,
                title: visibleTitle,
                detail: explanation?.isEmpty == false ? explanation : nil)
        default:
            projected = nil
        }
        guard let projected else { return current }
        var next = current
        if let index = next.firstIndex(where: { $0.id == projected.id }) {
            next[index] = projected
        } else {
            next.append(projected)
        }
        return Array(next.suffix(20))
    }
}

public struct TranscriptGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let role: String
    public let messages: [ChatMessage]
    public let date: Date?

    public var isUser: Bool { self.role == "user" }
}

public enum TranscriptItem: Identifiable, Sendable, Equatable {
    case daySeparator(String, Date)
    case toolRun(ToolRun)
    case group(TranscriptGroup)

    public var id: String {
        switch self {
        case let .daySeparator(id, _): return id
        case let .toolRun(run): return run.id
        case let .group(group): return group.id
        }
    }
}

/// A deterministic suffix window for eager transcript rendering.
///
/// The macOS transcript intentionally uses `VStack` to avoid the `LazyVStack` placement
/// livelock documented in `docs/diagnostics/README.md`. This model bounds the eager rows
/// without changing transcript construction or dropping the live tail. Callers explicitly
/// expand the window in fixed-size chunks when the reader asks for earlier items.
public struct TranscriptWindow: Sendable, Equatable {
    public static func searchRange(index: Int, total: Int) -> Range<Int> {
        let count = max(0, total)
        let center = min(max(0, index), max(0, count - 1))
        return max(0, center - 50)..<min(count, center + 150)
    }
    public static let defaultInitialItemCount = 200
    public static let defaultExpansionItemCount = 200

    public let initialItemCount: Int
    public let expansionItemCount: Int
    public private(set) var requestedItemCount: Int

    public init(
        initialItemCount: Int = Self.defaultInitialItemCount,
        expansionItemCount: Int = Self.defaultExpansionItemCount)
    {
        self.initialItemCount = max(1, initialItemCount)
        self.expansionItemCount = max(1, expansionItemCount)
        self.requestedItemCount = max(1, initialItemCount)
    }

    public func selection(totalItemCount: Int, anchoredStartIndex: Int? = nil, anchoredEndIndex: Int? = nil) -> TranscriptWindowSelection {
        let total = max(0, totalItemCount)
        let visible = min(total, self.requestedItemCount)
        // Keep the top row stable while reading; a sliding suffix removes content above
        // the viewport on every arriving message, changing the reader's scroll offset.
        let start = min(total - visible, max(0, anchoredStartIndex ?? total))
        let end = min(total, max(start, anchoredEndIndex ?? total))
        return TranscriptWindowSelection(
            range: start..<end,
            hiddenItemCount: start,
            nextExpansionItemCount: min(start, self.expansionItemCount))
    }

    public mutating func showEarlier(totalItemCount: Int, anchoredStartIndex: Int? = nil) {
        let total = max(0, totalItemCount)
        self.requestedItemCount = min(
            total,
            max(self.requestedItemCount, total - (anchoredStartIndex ?? total)) + self.expansionItemCount)
    }

    public mutating func reset() {
        self.requestedItemCount = self.initialItemCount
    }
}

public struct TranscriptWindowSelection: Sendable, Equatable {
    public let range: Range<Int>
    public let hiddenItemCount: Int
    public let nextExpansionItemCount: Int

    public var visibleItemCount: Int { self.range.count }
    public var canShowEarlier: Bool { self.hiddenItemCount > 0 }

    public func items<Element>(from items: [Element]) -> ArraySlice<Element> {
        // A selection is normally paired with the count it was created from. Clamping also
        // makes the helper deterministic and safe if a SwiftUI update replaces the backing
        // transcript between computing the selection and applying it.
        let lowerBound = min(max(0, self.range.lowerBound), items.count)
        let upperBound = min(max(lowerBound, self.range.upperBound), items.count)
        return items[lowerBound..<upperBound]
    }
}

/// The append-only core of `TranscriptBuilder.items`, kept as state instead of recomputed.
///
/// `ChatStore` caches the render list and invalidates it on every `messages` write, so a
/// single streamed reply used to re-derive the whole transcript: re-filtering every block,
/// re-deriving every tool summary, and re-allocating every group for messages that had not
/// moved. This holds the exact intermediate state that walk leaves behind — the finalized
/// items, the group and tool run still open at the tail, and the day the cursor is on — so
/// a new message costs only its own work.
///
/// `TranscriptBuilder.items` is implemented on top of this, which is what makes the two
/// paths equivalent by construction rather than by agreement.
public struct IncrementalTranscriptBuilder: Sendable {
    private let calendar: Calendar
    /// Items no later message can still change.
    private var finalized: [TranscriptItem] = []
    /// The role group still accepting messages, if any.
    private var group: [ChatMessage] = []
    /// The tool run still accepting steps, if any. Never non-empty at the same time as
    /// `group`: a body flushes steps before grouping, and a tool call flushes the group.
    private var steps: [ToolStep] = []
    private var currentDay: Date?
    /// Source messages fed in so far, including ones that rendered nothing. Callers append
    /// `messages[consumedMessageCount...]` to extend a builder in step with a transcript.
    public private(set) var consumedMessageCount = 0
    /// How much of `finalized` has already been copied into ChatStore's materialized cache.
    /// The one open tail item is tracked separately because the next message may replace it.
    private var materializedFinalizedCount = 0
    private var hasMaterializedOpenItem = false

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// The single item at the tail that a later message can still change: the open role
    /// group, or the open tool run. Never both, since a body flushes steps before grouping
    /// and a tool call flushes the group. Every path that reasons about the tail reads it
    /// here instead of re-deriving the rule and risking disagreement.
    private var openItem: TranscriptItem? {
        if let first = self.group.first {
            return .group(TranscriptGroup(
                id: first.id,
                role: first.role,
                messages: self.group,
                date: first.date))
        }
        if let first = self.steps.first {
            return .toolRun(ToolRun(id: "run-\(first.id)", steps: self.steps))
        }
        return nil
    }

    /// The render list for everything consumed so far, flushing the open group and tool run
    /// exactly as the end of a full walk does.
    public var items: [TranscriptItem] {
        guard let openItem = self.openItem else { return self.finalized }
        return self.finalized + [openItem]
    }

    /// `items.count` without materializing the list.
    public var itemCount: Int {
        self.finalized.count + (self.group.isEmpty && self.steps.isEmpty ? 0 : 1)
    }

    /// Advances an existing materialized cache by changing only its open tail.
    ///
    /// Copying `items` after each append would still allocate and walk every rendered row,
    /// even though message reduction itself was incremental. The prior materialization is
    /// exactly `finalized-prefix + open-item`; remove that one replaceable item, append only
    /// newly finalized items, then append the current open item. The initial call starts
    /// from an empty cache and materializes the full history once.
    ///
    /// Returns the number of cached items removed or appended, for signpost evidence.
    @discardableResult
    mutating func materialize(into items: inout [TranscriptItem]) -> Int {
        let expectedCount = self.materializedFinalizedCount + (self.hasMaterializedOpenItem ? 1 : 0)
        guard items.count == expectedCount else {
            // The cache is not the prefix this builder last wrote, so the tail about to be
            // stripped is not the tail it put there. Trapping on that turns a bookkeeping
            // slip into a crash at the exact moment a chat opens, and relaunching replays
            // it from the same state. Builder state is authoritative: drop the cache,
            // rebuild it in full, and resume incremental updates from a known-good tail.
            CastLifecycleDiagnostics.transcriptCacheDesynced(
                cachedItems: items.count,
                expectedItems: expectedCount)
            items = self.items
            self.materializedFinalizedCount = self.finalized.count
            self.hasMaterializedOpenItem = self.openItem != nil
            return items.count
        }
        var updatedItemCount = 0
        if self.hasMaterializedOpenItem {
            items.removeLast()
            updatedItemCount += 1
        }
        if self.materializedFinalizedCount < self.finalized.count {
            let newlyFinalized = self.finalized[self.materializedFinalizedCount...]
            items.append(contentsOf: newlyFinalized)
            updatedItemCount += newlyFinalized.count
        }
        if let openItem = self.openItem {
            items.append(openItem)
            self.hasMaterializedOpenItem = true
            updatedItemCount += 1
        } else {
            self.hasMaterializedOpenItem = false
        }
        self.materializedFinalizedCount = self.finalized.count
        return updatedItemCount
    }

    public mutating func append(contentsOf messages: some Sequence<ChatMessage>) {
        for message in messages { self.append(message) }
    }

    public mutating func append(_ message: ChatMessage) {
        self.consumedMessageCount += 1
        guard message.role == "user" || message.role == "assistant" else { return }
        let toolBlocks = message.blocks.filter(\.isToolCall)
        let hasBody = !message.text.isEmpty || !message.mediaPaths.isEmpty || !message.localImageData.isEmpty || !message.managedAttachments.isEmpty
        guard hasBody || !toolBlocks.isEmpty else { return }

        if let date = message.date {
            let day = self.calendar.startOfDay(for: date)
            if self.currentDay != day {
                self.flushGroup()
                self.flushSteps()
                self.currentDay = day
                // No Int() here: a corrupt timestamp (e.g. 1e300) would trap while
                // rendering, and the cached transcript makes that a crash-on-open loop.
                self.finalized.append(.daySeparator("day-\(day.timeIntervalSince1970)", day))
            }
        }

        if hasBody {
            self.flushSteps()
            self.appendToGroup(message)
        }
        if !toolBlocks.isEmpty {
            self.flushGroup()
            for (index, block) in toolBlocks.enumerated() {
                self.steps.append(ToolStep(
                    id: block.id ?? "\(message.id)-tool-\(index)",
                    name: block.name ?? "Tool",
                    summary: TranscriptBuilder.toolSummary(
                        name: block.name ?? "",
                        arguments: block.arguments)))
            }
        }
    }

    private mutating func flushGroup() {
        guard let first = self.group.first else { return }
        self.finalized.append(.group(TranscriptGroup(
            id: first.id,
            role: first.role,
            messages: self.group,
            date: first.date)))
        self.group = []
    }

    private mutating func flushSteps() {
        guard let first = self.steps.first else { return }
        self.finalized.append(.toolRun(ToolRun(id: "run-\(first.id)", steps: self.steps)))
        self.steps = []
    }

    private mutating func appendToGroup(_ message: ChatMessage) {
        if let last = self.group.last {
            let gap = (message.timestamp ?? 0) - (last.timestamp ?? 0)
            if last.role != message.role || gap > TranscriptBuilder.groupGapMs { self.flushGroup() }
        }
        self.group.append(message)
    }
}

public enum TranscriptBuilder {
    static let groupGapMs: Double = 7 * 60 * 1000

    /// Builds the render list. Rules: user text and assistant text group by role within a
    /// 7-minute window; consecutive tool calls collapse into one ToolRun, surviving across
    /// adjacent assistant messages and interleaved toolResult rows; assistant text, user
    /// messages, and day changes break a run. Messages with something renderable — text,
    /// tool calls, or media — participate; everything else is skipped.
    ///
    /// `showAgentWork: false` is a whole-history filter (`answers(from:)` keeps only the
    /// last text of each assistant stretch), so it is applied up front and cannot be
    /// extended message by message. `showAgentWork: true` is the incremental path.
    public static func items(
        from sourceMessages: [ChatMessage],
        showAgentWork: Bool = true,
        calendar: Calendar = .current
    ) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        let performanceInterval = CastPerformanceDiagnostics.begin(
            .transcriptBuilderItems,
            metadata: "source_messages=\(sourceMessages.count) show_agent_work=\(showAgentWork)")
        defer {
            CastPerformanceDiagnostics.end(
                performanceInterval,
                metadata: "output_items=\(items.count)")
        }
        var builder = IncrementalTranscriptBuilder(calendar: calendar)
        builder.append(contentsOf: showAgentWork ? sourceMessages : self.answers(from: sourceMessages))
        items = builder.items
        return items
    }

    /// "Just the answer" filter: strips the agent's working process. Tool-call, thinking,
    /// and tool-result blocks are dropped everywhere, and of each stretch of assistant
    /// messages between user turns only the last one with text survives — plus any that
    /// carry media. User messages pass through untouched. Pure so views can apply it
    /// per-render off a persisted toggle.
    public static func answers(from messages: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var segment: [ChatMessage] = []

        func flushSegment() {
            guard !segment.isEmpty else { return }
            let finalTextIndex = segment.lastIndex { !$0.text.isEmpty }
            for (index, message) in segment.enumerated() {
                let hasMedia = !message.mediaPaths.isEmpty || !message.localImageData.isEmpty || !message.managedAttachments.isEmpty
                guard index == finalTextIndex || hasMedia else { continue }
                result.append(self.strippingWork(message, includeText: index == finalTextIndex))
            }
            segment = []
        }

        for message in messages {
            if message.role == "assistant" {
                segment.append(message)
            } else if message.role == "user" {
                flushSegment()
                result.append(self.strippingWork(message))
            }
        }
        flushSegment()
        return result
    }

    static func strippingWork(_ message: ChatMessage, includeText: Bool = true) -> ChatMessage {
        let kept = message.blocks.filter { block in
            !block.isToolCall
                && block.normalizedType != "thinking"
                && block.normalizedType != "toolresult"
                && (includeText || block.normalizedType != "text")
        }
        guard kept.count != message.blocks.count else { return message }
        return ChatMessage(
            id: message.id,
            role: message.role,
            blocks: kept,
            timestamp: message.timestamp,
            mediaPaths: message.mediaPaths,
            mediaTypes: message.mediaTypes,
            localImageData: message.localImageData,
            localDeliveryState: message.localDeliveryState,
            localIdempotencyKey: message.localIdempotencyKey)
    }

    /// Best one-line description of a tool call from its arguments: an explicit description
    /// wins, file tools show the path, exec tools the first command line, then a generic
    /// ladder of common argument keys.
    public static func toolSummary(name: String, arguments: AnyCodable?) -> String? {
        guard let args = arguments?.dictValue else { return nil }
        func value(_ key: String) -> String? {
            guard let raw = args[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return raw.components(separatedBy: .newlines).first
        }
        if let description = value("description") { return description }
        let lowered = name.lowercased()
        if ["read", "edit", "write", "notebookedit", "multiedit"].contains(lowered) {
            if let path = value("file_path") ?? value("path") ?? value("filePath") { return path }
        }
        if lowered.contains("bash") || lowered.contains("exec") || lowered.contains("shell") {
            if let command = value("command") { return command }
        }
        for key in ["file_path", "path", "command", "pattern", "query", "url", "prompt", "summary", "message", "text"] {
            if let hit = value(key) { return hit }
        }
        return nil
    }
}

/// Pure visibility policy for an active turn. The neutral activity indicator is independent
/// of the persisted detail preference; only gateway-provided reasoning/progress/tool detail
/// is gated by that preference. Streamed assistant output remains ordinary answer content.
public struct AgentTurnPresentation: Sendable, Equatable {
    public let isActive: Bool
    public let showDetails: Bool
    public let assistantText: String
    public let reasoningText: String
    public let toolName: String?
    public let workItems: [AgentWorkItem]

    public init(
        isActive: Bool,
        showDetails: Bool,
        assistantText: String,
        reasoningText: String,
        toolName: String?,
        workItems: [AgentWorkItem] = [])
    {
        self.isActive = isActive
        self.showDetails = showDetails
        self.assistantText = assistantText
        self.reasoningText = reasoningText
        self.toolName = toolName
        self.workItems = workItems
    }

    /// Assistant output is never work detail, so the preference must not suppress it.
    public var visibleAssistantText: String { self.assistantText }
    public var visibleReasoningText: String { self.showDetails ? self.reasoningText : "" }
    public var visibleToolName: String? { self.showDetails ? self.toolName : nil }
    public var visibleWorkItems: [AgentWorkItem] { self.showDetails ? self.workItems : [] }

    /// The immediate neutral indicator lasts until the user can see response/progress content.
    /// If details are hidden, hidden work cannot make the indicator disappear.
    public var showsActivityIndicator: Bool {
        self.isActive
            && self.visibleAssistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && self.visibleReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && self.visibleWorkItems.isEmpty
    }

    public var shouldRender: Bool {
        self.isActive || !self.visibleAssistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var statusLabel: String {
        guard let toolName = self.visibleToolName else { return "Thinking…" }
        return "Working: \(ToolStep(id: "", name: toolName, summary: nil).displayName)…"
    }
}

/// How close to the true bottom still counts as "reading the latest message".
///
/// A fixed constant is wrong at both ends of the device range: 160pt is a large share of an
/// iPhone transcript with the keyboard up, and a sliver of an iPad's. Scale with the visible
/// container instead, bounded so a very short or very tall container stays sensible.
public enum TranscriptScrollMetrics {
    public static let nearBottomFraction: CGFloat = 0.12
    public static let minimumNearBottomTolerance: CGFloat = 44
    public static let maximumNearBottomTolerance: CGFloat = 160

    public static func nearBottomTolerance(containerHeight: CGFloat) -> CGFloat {
        let proportional = max(0, containerHeight) * self.nearBottomFraction
        return min(
            max(proportional, self.minimumNearBottomTolerance),
            self.maximumNearBottomTolerance)
    }
}

/// One scroll-geometry sample, plus whether it is worth believing.
///
/// A transcript pushed onto the navigation stack gets laid out at least once against a
/// zero-height container. Read literally that sample says "not near the bottom", which turns
/// the Latest pill on and lets any scroll phase in that instant latch following off — killing
/// the size-change re-anchor that is the only thing landing a lazy transcript on its tail.
/// The reader is then parked in estimated, unrealized space: a blank canvas with a pill
/// floating over it. Those samples observe nothing, so they are dropped rather than believed.
public struct TranscriptScrollReading: Sendable, Equatable {
    public let containerHeight: CGFloat
    public let contentHeight: CGFloat
    public let offset: CGFloat

    public init(containerHeight: CGFloat, contentHeight: CGFloat, offset: CGFloat) {
        self.containerHeight = containerHeight
        self.contentHeight = contentHeight
        self.offset = offset
    }

    /// A container or content of no height means layout has not run yet, not that the
    /// transcript is empty — an empty transcript still reports a real container.
    public var isSettled: Bool {
        self.containerHeight > 0 && self.contentHeight > 0
    }

    /// Follow resumes at the actual tail, not the much wider "Latest" pill tolerance.
    public var isAtBottom: Bool {
        self.isSettled && self.offset + self.containerHeight >= self.contentHeight - 1
    }

    /// `nil` while unsettled, so callers must decide explicitly rather than inherit a `false`.
    public var isNearBottom: Bool? {
        guard self.isSettled else { return nil }
        let tolerance = TranscriptScrollMetrics.nearBottomTolerance(
            containerHeight: self.containerHeight)
        return self.offset + self.containerHeight >= self.contentHeight - tolerance
    }

    /// True when the only thing that moved between two settled samples is the offset, and it
    /// moved toward the top. Content growth, a lazy row settling, a keyboard or window
    /// resize, and every programmatic jump to the tail all change a height or move the offset
    /// down; a reader dragging the transcript up is the one thing left. This is what lets a
    /// wheel or trackpad scroll on macOS — which need not report an `.interacting` phase —
    /// pause following instead of being yanked back on the next streamed delta.
    public func indicatesReaderScroll(
        from previous: TranscriptScrollReading,
        slack: CGFloat = 0.5) -> Bool
    {
        guard self.isSettled, previous.isSettled else { return false }
        guard abs(self.contentHeight - previous.contentHeight) <= slack,
              abs(self.containerHeight - previous.containerHeight) <= slack
        else { return false }
        return self.offset < previous.offset - slack
    }
}

/// Decides whether a following reader who is not at the tail should be nudged back.
///
/// The `.sizeChanges` anchor catches content that grows; a lazy transcript also merely
/// settles, swapping estimated row heights for real ones without a growth event big enough
/// to land the tail. Only that kind of layout change may nudge. An offset-only move away
/// from the tail is the reader's, and nudging against it is exactly the "finicky" scroll
/// that fought every wheel scroll on macOS.
public enum TranscriptReanchorPolicy {
    public static func shouldNudge(
        previous: TranscriptScrollReading,
        current: TranscriptScrollReading,
        followsLatest: Bool,
        attempts: Int,
        limit: Int) -> Bool
    {
        guard followsLatest, attempts < limit, current.isNearBottom == false else { return false }
        return (current.contentHeight != previous.contentHeight
            || current.containerHeight != previous.containerHeight)
            && !current.indicatesReaderScroll(from: previous)
    }
}

/// Separates the reader's intent to follow the tail from transient scroll geometry.
/// Content growth may move the bottom away without meaning the reader scrolled away;
/// only a user-driven scroll can pause following.
public struct TranscriptFollowState: Sendable, Equatable {
    public private(set) var followsLatest = true
    private var userScrollActive = false

    public init() {}

    public mutating func scrollPhaseChanged(userDriven: Bool, isNearBottom: Bool) {
        self.userScrollActive = userDriven
        // Touch/wheel intent owns scrolling immediately, not only after the reader has
        // crossed the near-bottom tolerance. An idle phase never resumes following.
        if userDriven { self.followsLatest = false }
    }

    /// `readerScrolledAway` is the geometry-derived evidence of a user scroll (see
    /// `TranscriptScrollReading.indicatesReaderScroll(from:)`), for platforms and input
    /// devices whose scroll phases never say `.interacting`.
    public mutating func geometryChanged(isNearBottom: Bool, readerScrolledAway: Bool = false) {
        if readerScrolledAway {
            self.userScrollActive = true
            self.followsLatest = false
            return
        }
        if isNearBottom {
            self.resume()
        } else if self.userScrollActive {
            self.followsLatest = false
        }
    }

    public mutating func resume() {
        self.userScrollActive = false
        self.followsLatest = true
    }
}
