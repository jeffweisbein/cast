import Foundation
import XCTest
@testable import Cast

final class TranscriptBuilderTests: XCTestCase {
    private static let dayMs: Double = 24 * 60 * 60 * 1000

    private static func text(_ text: String, role: String = "assistant", id: String = UUID().uuidString, ts: Double = 1_784_600_000_000) -> ChatMessage {
        ChatMessage(
            id: id,
            role: role,
            blocks: [ChatContentBlock(type: "text", text: text, thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: ts)
    }

    private static func toolCall(_ name: String, args: [String: Any?] = [:], blockId: String = UUID().uuidString, ts: Double = 1_784_600_000_000) -> ChatMessage {
        ChatMessage(
            role: "assistant",
            blocks: [ChatContentBlock(
                type: "toolCall", text: nil, thinking: nil, name: name, mimeType: nil, fileName: nil,
                id: blockId, arguments: AnyCodable(args.mapValues { AnyCodable($0) }))],
            timestamp: ts)
    }

    private static func toolResult(ts: Double = 1_784_600_000_000) -> ChatMessage {
        ChatMessage(
            role: "toolResult",
            blocks: [ChatContentBlock(type: "toolResult", text: "ok", thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: ts)
    }

    func testConsecutiveToolCallsAcrossMessagesCollapseIntoOneRun() {
        let base: Double = 1_784_600_000_000
        let items = TranscriptBuilder.items(from: [
            Self.text("Let me look.", ts: base),
            Self.toolCall("Bash", ts: base + 1000),
            Self.toolResult(ts: base + 2000),
            Self.toolCall("Bash", ts: base + 3000),
            Self.toolResult(ts: base + 4000),
            Self.toolCall("Edit", ts: base + 5000),
            Self.text("Done.", ts: base + 6000),
        ])
        let runs = items.compactMap { if case let .toolRun(run) = $0 { return run } else { return nil } }
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].steps.map(\.name), ["Bash", "Bash", "Edit"])
        XCTAssertEqual(runs[0].headline, "3 steps · Bash ×2, Edit")
    }

    func testAssistantTextBetweenToolCallsBreaksTheRun() {
        let base: Double = 1_784_600_000_000
        let items = TranscriptBuilder.items(from: [
            Self.toolCall("Bash", ts: base),
            Self.text("Found it.", ts: base + 1000),
            Self.toolCall("Edit", ts: base + 2000),
        ])
        let runs = items.compactMap { if case let .toolRun(run) = $0 { return run } else { return nil } }
        XCTAssertEqual(runs.count, 2)
    }

    func testMixedTextAndToolMessageEmitsTextThenJoinsRun() {
        let base: Double = 1_784_600_000_000
        let mixed = ChatMessage(
            role: "assistant",
            blocks: [
                ChatContentBlock(type: "text", text: "Checking.", thinking: nil, name: nil, mimeType: nil, fileName: nil),
                ChatContentBlock(type: "toolCall", text: nil, thinking: nil, name: "Read", mimeType: nil, fileName: nil, id: "b1", arguments: nil),
            ],
            timestamp: base)
        let items = TranscriptBuilder.items(from: [mixed, Self.toolCall("Bash", ts: base + 1000)])
        guard items.count == 3, case .group = items[1], case let .toolRun(run) = items[2] else {
            return XCTFail("expected [day, group, toolRun], got \(items.map(\.id))")
        }
        XCTAssertEqual(run.steps.map(\.name), ["Read", "Bash"])
    }

    func testDaySeparatorsSplitDaysAndRuns() {
        let day1: Double = 1_784_600_000_000
        let day2 = day1 + Self.dayMs
        let items = TranscriptBuilder.items(from: [
            Self.toolCall("Bash", ts: day1),
            Self.toolCall("Bash", ts: day2),
            Self.text("hello", role: "user", ts: day2 + 1000),
        ])
        let separators = items.filter { if case .daySeparator = $0 { return true } else { return false } }
        let runs = items.compactMap { if case let .toolRun(run) = $0 { return run } else { return nil } }
        XCTAssertEqual(separators.count, 2)
        XCTAssertEqual(runs.count, 2)
    }

    func testUserMessagesGroupWithinWindowAndSplitRoles() {
        let base: Double = 1_784_600_000_000
        let items = TranscriptBuilder.items(from: [
            Self.text("one", role: "user", ts: base),
            Self.text("two", role: "user", ts: base + 1000),
            Self.text("reply", role: "assistant", ts: base + 2000),
            Self.text("later", role: "user", ts: base + 2000 + 8 * 60 * 1000),
        ])
        let groups = items.compactMap { if case let .group(group) = $0 { return group } else { return nil } }
        XCTAssertEqual(groups.map { $0.messages.count }, [2, 1, 1])
        XCTAssertEqual(groups.map(\.role), ["user", "assistant", "user"])
    }

    func testMediaOnlyMessageStillRendersAsGroup() {
        let message = ChatMessage(
            role: "user",
            blocks: [],
            timestamp: 1_784_600_000_000,
            mediaPaths: ["/tmp/x.jpg"],
            mediaTypes: ["image/jpeg"])
        let items = TranscriptBuilder.items(from: [message])
        let groups = items.compactMap { if case let .group(group) = $0 { return group } else { return nil } }
        XCTAssertEqual(groups.count, 1)
    }

    func testToolRunIdStableAcrossRebuilds() {
        let base: Double = 1_784_600_000_000
        let build = {
            TranscriptBuilder.items(from: [
                Self.toolCall("Bash", blockId: "exec-abc", ts: base),
                Self.toolCall("Edit", blockId: "exec-def", ts: base + 1000),
            ])
        }
        let first = build().compactMap { if case let .toolRun(run) = $0 { return run.id } else { return nil } }
        let second = build().compactMap { if case let .toolRun(run) = $0 { return run.id } else { return nil } }
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, ["run-exec-abc"])
    }

    // MARK: - Incremental builder equivalence
    //
    // `ChatStore` extends a retained builder when a message is appended instead of
    // re-walking the transcript, so "extend, then materialize" has to land on exactly the
    // list a full walk produces — at every prefix, not just at the end.

    /// Structural identity, not just item ids: a group that silently lost a message or a
    /// run that lost a step would keep the same id.
    private static func fingerprint(_ items: [TranscriptItem]) -> [String] {
        items.map { item in
            switch item {
            case let .daySeparator(id, date):
                return "day|\(id)|\(date.timeIntervalSince1970)"
            case let .toolRun(run):
                return "run|\(run.id)|" + run.steps
                    .map { "\($0.id)~\($0.name)~\($0.summary ?? "-")" }
                    .joined(separator: ",")
            case let .group(group):
                return "group|\(group.id)|\(group.role)|"
                    + group.messages.map(\.id).joined(separator: ",")
                    + "|\(group.date?.timeIntervalSince1970 ?? -1)"
            }
        }
    }

    /// Feeds `messages` in one message at a time, materializing after every single one, and
    /// asserts each prefix matches the equivalent full rebuild.
    private func assertIncrementalMatchesFullRebuild(
        _ messages: [ChatMessage],
        file: StaticString = #filePath,
        line: UInt = #line)
    {
        var builder = IncrementalTranscriptBuilder()
        for (index, message) in messages.enumerated() {
            builder.append(message)
            let prefix = Array(messages[0 ... index])
            XCTAssertEqual(
                Self.fingerprint(builder.items),
                Self.fingerprint(TranscriptBuilder.items(from: prefix)),
                "prefix of \(index + 1) message(s) diverged",
                file: file,
                line: line)
            XCTAssertEqual(builder.consumedMessageCount, index + 1, file: file, line: line)
            XCTAssertEqual(builder.itemCount, builder.items.count, file: file, line: line)
        }
    }

    func testIncrementalAppendMatchesFullRebuildAcrossGroupsRunsAndDays() {
        let base: Double = 1_784_600_000_000
        self.assertIncrementalMatchesFullRebuild([
            // Day one: a grouped user turn, a collapsed run, an answer.
            Self.text("Can you check the build?", role: "user", id: "u-1", ts: base),
            Self.text("And the tests too.", role: "user", id: "u-2", ts: base + 1000),
            Self.text("Looking now.", id: "a-1", ts: base + 2000),
            Self.toolCall("Bash", args: ["command": "swift build"], blockId: "t-1", ts: base + 3000),
            Self.toolResult(ts: base + 4000),
            Self.toolCall("Bash", args: ["command": "swift test"], blockId: "t-2", ts: base + 5000),
            Self.toolCall("Edit", args: ["file_path": "/tmp/a.swift"], blockId: "t-3", ts: base + 6000),
            Self.text("Both green.", id: "a-2", ts: base + 7000),
            // A run that a user turn breaks rather than assistant text.
            Self.toolCall("Read", args: ["path": "/tmp/b.swift"], blockId: "t-4", ts: base + 8000),
            Self.text("Thanks.", role: "user", id: "u-3", ts: base + 9000),
            // A gap wider than the grouping window splits same-role messages.
            Self.text("Anything else?", role: "user", id: "u-4", ts: base + 9000 + 8 * 60 * 1000),
            // A role Cast never renders, dropped by both paths alike.
            Self.toolResult(ts: base + 9000 + 8 * 60 * 1000 + 1000),
            // Day two: forces a separator that also has to flush the open group.
            Self.text("Morning.", role: "user", id: "u-5", ts: base + Self.dayMs),
            Self.toolCall("Bash", args: ["command": "git pull"], blockId: "t-5", ts: base + Self.dayMs + 1000),
            Self.text("Up to date.", id: "a-3", ts: base + Self.dayMs + 2000),
            // Media-only and empty rows: one renders, one is skipped entirely.
            ChatMessage(
                id: "m-1",
                role: "user",
                blocks: [],
                timestamp: base + Self.dayMs + 3000,
                mediaPaths: ["/tmp/x.jpg"],
                mediaTypes: ["image/jpeg"]),
            Self.text("", id: "a-4", ts: base + Self.dayMs + 4000),
        ])
    }

    /// The case the incremental path exists for: a transcript long enough that re-walking it
    /// per appended row is what stalls the main thread.
    func testIncrementalAppendMatchesFullRebuildOverALongHistory() {
        let base: Double = 1_784_600_000_000
        var messages: [ChatMessage] = []
        for index in 0 ..< 600 {
            // Deterministic mix: user turns, answers, tool runs, and day rollovers.
            let timestamp = base + Double(index) * 90_000
            switch index % 5 {
            case 0:
                messages.append(Self.text("ask \(index)", role: "user", id: "u-\(index)", ts: timestamp))
            case 1, 2:
                messages.append(Self.toolCall(
                    index.isMultiple(of: 2) ? "Bash" : "Edit",
                    args: ["command": "step \(index)"],
                    blockId: "t-\(index)",
                    ts: timestamp))
            case 3:
                messages.append(Self.toolResult(ts: timestamp))
            default:
                messages.append(Self.text("answer \(index)", id: "a-\(index)", ts: timestamp))
            }
        }
        // 90 s steps over 600 rows cross several day boundaries and many grouping gaps.
        let expected = TranscriptBuilder.items(from: messages)
        XCTAssertGreaterThan(
            expected.filter { if case .daySeparator = $0 { return true } else { return false } }.count,
            1)
        XCTAssertGreaterThan(
            expected.filter { if case .toolRun = $0 { return true } else { return false } }.count,
            50)

        // Extend in the shape ChatStore actually uses: a materialized cache, then one more
        // message, over and over.
        var builder = IncrementalTranscriptBuilder()
        builder.append(contentsOf: messages.prefix(400))
        var materialized: [TranscriptItem] = []
        _ = builder.materialize(into: &materialized)
        var largestTailUpdate = 0
        for message in messages.dropFirst(400) {
            builder.append(message)
            largestTailUpdate = max(
                largestTailUpdate,
                builder.materialize(into: &materialized))
        }
        XCTAssertEqual(builder.consumedMessageCount, messages.count)
        // One appended message can replace the open tail, finalize it, add a day separator,
        // and open a new tail. It must never rewrite the hundreds of earlier items.
        XCTAssertLessThanOrEqual(largestTailUpdate, 4)
        XCTAssertEqual(Self.fingerprint(materialized), Self.fingerprint(expected))
    }

    /// Materializing mid-stream must not consume the open group or run: the very next
    /// message still has to be able to join them.
    func testMaterializingBetweenAppendsDoesNotCloseTheOpenGroupOrRun() {
        let base: Double = 1_784_600_000_000
        var builder = IncrementalTranscriptBuilder()
        builder.append(Self.text("one", role: "user", id: "u-1", ts: base))
        _ = builder.items
        builder.append(Self.text("two", role: "user", id: "u-2", ts: base + 1000))
        _ = builder.items
        let groups = builder.items.compactMap {
            if case let .group(group) = $0 { return group } else { return nil }
        }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].messages.map(\.id), ["u-1", "u-2"])

        builder.append(Self.toolCall("Bash", blockId: "t-1", ts: base + 2000))
        _ = builder.items
        builder.append(Self.toolCall("Edit", blockId: "t-2", ts: base + 3000))
        let runs = builder.items.compactMap {
            if case let .toolRun(run) = $0 { return run } else { return nil }
        }
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].steps.map(\.id), ["t-1", "t-2"])
        XCTAssertEqual(
            Self.fingerprint(builder.items),
            Self.fingerprint(TranscriptBuilder.items(from: [
                Self.text("one", role: "user", id: "u-1", ts: base),
                Self.text("two", role: "user", id: "u-2", ts: base + 1000),
                Self.toolCall("Bash", blockId: "t-1", ts: base + 2000),
                Self.toolCall("Edit", blockId: "t-2", ts: base + 3000),
            ])))
    }

    func testToolSummaryPrefersDescriptionThenPathThenCommand() {
        XCTAssertEqual(
            TranscriptBuilder.toolSummary(
                name: "Bash",
                arguments: AnyCodable(["description": AnyCodable("List files"), "command": AnyCodable("ls -la")])),
            "List files")
        XCTAssertEqual(
            TranscriptBuilder.toolSummary(
                name: "bash",
                arguments: AnyCodable(["command": AnyCodable("git status\ngit log")])),
            "git status")
        XCTAssertEqual(
            TranscriptBuilder.toolSummary(
                name: "Edit",
                arguments: AnyCodable(["file_path": AnyCodable("/tmp/a.swift"), "old_string": AnyCodable("x")])),
            "/tmp/a.swift")
        XCTAssertNil(TranscriptBuilder.toolSummary(name: "Bash", arguments: nil))
    }

    func testDaySeparatorSurvivesAbsurdTimestamps() {
        // A corrupt history row (timestamp: 1e300) must render a separator, not
        // trap in an Int() conversion — the cache would replay the trap on every open.
        let items = TranscriptBuilder.items(from: [
            Self.text("from the far future", ts: 1e300),
            Self.text("normal", ts: 1_784_600_000_000),
        ])
        let separators = items.filter { if case .daySeparator = $0 { return true } else { return false } }
        XCTAssertEqual(separators.count, 2)
    }

    func testToolDisplayNameCapitalizesLowercaseNames() {
        XCTAssertEqual(ToolStep(id: "1", name: "bash", summary: nil).displayName, "Bash")
        XCTAssertEqual(ToolStep(id: "2", name: "Read", summary: nil).displayName, "Read")
        XCTAssertEqual(ToolStep(id: "3", name: "heartbeat_respond", summary: nil).displayName, "Heartbeat_respond")
    }

    func testAnswersOnlyKeepsUsersFinalAssistantTextAndMedia() {
        let base: Double = 1_784_600_000_000
        let userMedia = ChatMessage(
            role: "user",
            blocks: [ChatContentBlock(type: "text", text: "Please check", thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: base,
            mediaPaths: ["/tmp/input.jpg"],
            mediaTypes: ["image/jpeg"])
        let thinking = ChatMessage(
            role: "assistant",
            blocks: [ChatContentBlock(type: "thinking", text: nil, thinking: "private chain", name: nil, mimeType: nil, fileName: nil)],
            timestamp: base + 500)
        let assistantMedia = ChatMessage(
            role: "assistant",
            blocks: [ChatContentBlock(type: "text", text: "An intermediate caption", thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: base + 3500,
            mediaPaths: ["/tmp/result.png"],
            mediaTypes: ["image/png"])

        let items = TranscriptBuilder.items(from: [
            userMedia,
            Self.text("I'll inspect it.", ts: base + 1000),
            thinking,
            Self.toolCall("Bash", ts: base + 2000),
            Self.toolResult(ts: base + 3000),
            assistantMedia,
            Self.text("The final answer.", ts: base + 4000),
        ], showAgentWork: false)

        XCTAssertTrue(items.allSatisfy { if case .toolRun = $0 { return false }; return true })
        let messages = items.compactMap { item -> [ChatMessage]? in
            if case let .group(group) = item { return group.messages }
            return nil
        }.flatMap { $0 }
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "assistant"])
        XCTAssertEqual(messages.map(\.text), ["Please check", "", "The final answer."])
        XCTAssertEqual(messages[0].mediaPaths, ["/tmp/input.jpg"])
        XCTAssertEqual(messages[1].mediaPaths, ["/tmp/result.png"])
        XCTAssertFalse(messages.contains { $0.text == "I'll inspect it." })
        XCTAssertTrue(messages.flatMap(\.blocks).allSatisfy {
            !$0.isToolCall && $0.normalizedType != "thinking" && $0.normalizedType != "toolresult"
        })
    }

    func testActiveTurnStatusRemainsVisibleWhenDetailsAreHidden() {
        let presentation = AgentTurnPresentation(
            isActive: true,
            showDetails: false,
            assistantText: "intermediate answer",
            reasoningText: "structured progress",
            toolName: "bash")

        XCTAssertTrue(presentation.isActive)
        XCTAssertEqual(presentation.statusLabel, "Thinking…")
        XCTAssertEqual(presentation.visibleAssistantText, "intermediate answer")
        XCTAssertEqual(presentation.visibleReasoningText, "")
        XCTAssertNil(presentation.visibleToolName)
        XCTAssertFalse(presentation.showsActivityIndicator)
    }

    func testActiveTurnDetailsRenderOnlyWhenPreferenceIsEnabled() {
        let presentation = AgentTurnPresentation(
            isActive: true,
            showDetails: true,
            assistantText: "intermediate answer",
            reasoningText: "structured progress",
            toolName: "bash")

        XCTAssertEqual(presentation.statusLabel, "Working: Bash…")
        XCTAssertEqual(presentation.visibleAssistantText, "intermediate answer")
        XCTAssertEqual(presentation.visibleReasoningText, "structured progress")
        XCTAssertEqual(presentation.visibleToolName, "bash")
        XCTAssertFalse(presentation.showsActivityIndicator)
    }

    func testImmediateActivityIsUnconditionalUntilVisibleContentArrives() {
        let hidden = AgentTurnPresentation(
            isActive: true,
            showDetails: false,
            assistantText: "",
            reasoningText: "gateway reasoning",
            toolName: "bash",
            workItems: [AgentWorkItem(id: "tool", title: "Running Bash")])
        let shown = AgentTurnPresentation(
            isActive: true,
            showDetails: true,
            assistantText: "",
            reasoningText: "gateway reasoning",
            toolName: "bash",
            workItems: [AgentWorkItem(id: "tool", title: "Running Bash")])

        XCTAssertTrue(hidden.showsActivityIndicator)
        XCTAssertEqual(hidden.statusLabel, "Thinking…")
        XCTAssertTrue(hidden.visibleWorkItems.isEmpty)
        XCTAssertFalse(shown.showsActivityIndicator)
        XCTAssertEqual(shown.visibleWorkItems.map(\.title), ["Running Bash"])
    }

    func testGatewayWorkProjectionUsesOnlySafeStructuredFields() {
        let tool = AgentWorkProjector.reducing(
            [],
            runId: "run-1",
            stream: "tool",
            data: AnyCodable([
                "phase": AnyCodable("start"),
                "toolCallId": AnyCodable("call-1"),
                "name": AnyCodable("bash"),
                "args": AnyCodable(["description": AnyCodable("Inspect repository")]),
                "result": AnyCodable("private output must not render"),
            ]))
        let progress = AgentWorkProjector.reducing(
            tool,
            runId: "run-1",
            stream: "item",
            data: AnyCodable([
                "kind": AnyCodable("preamble"),
                "itemId": AnyCodable("progress-1"),
                "progressText": AnyCodable("Checking the failing path"),
            ]))
        let ignored = AgentWorkProjector.reducing(
            progress,
            runId: "run-1",
            stream: "item",
            data: AnyCodable([
                "kind": AnyCodable("internal"),
                "progressText": AnyCodable("hidden chain of thought"),
            ]))

        XCTAssertEqual(tool, [AgentWorkItem(
            id: "call-1",
            title: "Running Bash",
            detail: "Inspect repository")])
        let completedTool = AgentWorkProjector.reducing(
            tool,
            runId: "run-1",
            stream: "tool",
            data: AnyCodable([
                "phase": AnyCodable("result"),
                "toolCallId": AnyCodable("call-1"),
                "name": AnyCodable("bash"),
            ]))
        XCTAssertEqual(completedTool.first?.title, "Finished Bash")
        XCTAssertEqual(completedTool.first?.detail, "Inspect repository")
        XCTAssertEqual(progress.map(\.title), ["Running Bash", "Checking the failing path"])
        XCTAssertEqual(ignored, progress)
        XCTAssertFalse(ignored.contains { $0.title.contains("chain of thought") })
    }

    func testRecoverableToolFailureStaysInWorkDetailWithoutRawOutput() {
        let running = AgentWorkProjector.reducing(
            [],
            runId: "run-1",
            stream: "tool",
            data: AnyCodable([
                "phase": AnyCodable("start"),
                "toolCallId": AnyCodable("call-1"),
                "name": AnyCodable("bash"),
                "args": AnyCodable(["description": AnyCodable("Search the repository")]),
            ]))
        let failed = AgentWorkProjector.reducing(
            running,
            runId: "run-1",
            stream: "tool",
            data: AnyCodable([
                "phase": AnyCodable("result"),
                "toolCallId": AnyCodable("call-1"),
                "name": AnyCodable("bash"),
                "isError": AnyCodable(true),
                "result": AnyCodable("/private/path: rg: command not found"),
            ]))

        XCTAssertEqual(failed, [AgentWorkItem(
            id: "call-1",
            title: "Bash failed",
            detail: "Search the repository",
            isComplete: true)])
        XCTAssertFalse(failed.contains { $0.detail?.contains("/private/path") == true })
    }
    /// `materialize` used to `precondition` when the cache had lost the open tail it was
    /// about to strip. That made a bookkeeping slip a crash at the moment a chat opened,
    /// which relaunching would only reproduce. It must rebuild from builder state instead.
    func testMaterializeRebuildsWhenCacheLostItsTail() {
        let messages = (0 ..< 40).map { index in
            Self.text(
                "m\(index)",
                role: index.isMultiple(of: 3) ? "user" : "assistant",
                id: "m\(index)",
                ts: 1_784_600_000_000 + Double(index) * 60_000)
        }
        let expected = TranscriptBuilder.items(from: messages)

        var builder = IncrementalTranscriptBuilder()
        builder.append(contentsOf: messages)
        var materialized: [TranscriptItem] = []
        builder.materialize(into: &materialized)
        XCTAssertEqual(Self.fingerprint(materialized), Self.fingerprint(expected))

        // The cache is emptied out from under a builder that believes it owns a tail.
        materialized.removeAll()
        let recovered = builder.materialize(into: &materialized)
        XCTAssertEqual(recovered, expected.count)
        XCTAssertEqual(Self.fingerprint(materialized), Self.fingerprint(expected))

        // Recovery has to leave the builder incremental, not permanently rebuilding.
        let extra = Self.text(
            "extra",
            role: "assistant",
            id: "extra",
            ts: 1_784_600_000_000 + 40 * 60_000)
        builder.append(extra)
        let tailUpdate = builder.materialize(into: &materialized)
        XCTAssertLessThanOrEqual(tailUpdate, 4)
        XCTAssertEqual(
            Self.fingerprint(materialized),
            Self.fingerprint(TranscriptBuilder.items(from: messages + [extra])))
    }

    /// The other desync shape: a cache holding more than the builder ever wrote. Stripping
    /// one item would have silently kept the surplus and corrupted every later append.
    func testMaterializeRebuildsWhenCacheHasSurplusItems() {
        let messages = (0 ..< 12).map { index in
            Self.text(
                "s\(index)",
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                id: "s\(index)",
                ts: 1_784_600_000_000 + Double(index) * 60_000)
        }
        let expected = TranscriptBuilder.items(from: messages)

        var builder = IncrementalTranscriptBuilder()
        builder.append(contentsOf: messages)
        var materialized: [TranscriptItem] = []
        builder.materialize(into: &materialized)

        materialized.append(contentsOf: expected.prefix(2))
        XCTAssertGreaterThan(materialized.count, expected.count)
        builder.materialize(into: &materialized)
        XCTAssertEqual(Self.fingerprint(materialized), Self.fingerprint(expected))
    }
}

final class TranscriptFollowStateTests: XCTestCase {
    func testReturningToTailClearsWheelActivityBeforeNextContentGrowth() {
        var state = TranscriptFollowState()
        state.scrollPhaseChanged(userDriven: true, isNearBottom: false)
        state.geometryChanged(isNearBottom: true)
        state.geometryChanged(isNearBottom: false)
        XCTAssertTrue(state.followsLatest)
    }

    func testContentGrowthDoesNotPoisonAutoFollow() {
        var state = TranscriptFollowState()

        state.geometryChanged(isNearBottom: false)

        XCTAssertTrue(state.followsLatest)
    }

    func testOnlyUserScrollPausesAndExplicitPathsResume() {
        var state = TranscriptFollowState()

        state.scrollPhaseChanged(userDriven: true, isNearBottom: true)
        state.geometryChanged(isNearBottom: false)
        XCTAssertFalse(state.followsLatest)

        state.scrollPhaseChanged(userDriven: false, isNearBottom: false)
        XCTAssertFalse(state.followsLatest)

        state.geometryChanged(isNearBottom: true)
        XCTAssertTrue(state.followsLatest)

        state.scrollPhaseChanged(userDriven: true, isNearBottom: false)
        XCTAssertFalse(state.followsLatest)
        state.resume()
        XCTAssertTrue(state.followsLatest)
    }
}

final class TranscriptReaderScrollTests: XCTestCase {
    func testSmallUpwardWheelMovementPausesEvenInsideBottomTolerance() {
        var state = TranscriptFollowState()
        state.geometryChanged(isNearBottom: true, readerScrolledAway: true)
        XCTAssertFalse(state.followsLatest, "Do not anchor against the first wheel delta")
        state.scrollPhaseChanged(userDriven: false, isNearBottom: true)
        XCTAssertFalse(state.followsLatest, "An idle phase is not intent to jump back")
    }

    func testTouchingScrollPausesBeforeStreamingCanReanchor() {
        var state = TranscriptFollowState()
        state.scrollPhaseChanged(userDriven: true, isNearBottom: true)
        XCTAssertFalse(state.followsLatest)
    }

    func testUnchangedGeometryCannotTriggerAnotherReanchor() {
        let away = self.reading(offset: 2_000)
        XCTAssertFalse(TranscriptReanchorPolicy.shouldNudge(
            previous: away, current: away, followsLatest: true, attempts: 0, limit: 3))
    }

    private func reading(
        container: CGFloat = 600,
        content: CGFloat = 4_000,
        offset: CGFloat) -> TranscriptScrollReading
    {
        TranscriptScrollReading(containerHeight: container, contentHeight: content, offset: offset)
    }

    func testOffsetMovingUpWithStableHeightsIsAReaderScroll() {
        let atTail = self.reading(offset: 3_400)
        XCTAssertTrue(self.reading(offset: 3_000).indicatesReaderScroll(from: atTail))
        XCTAssertTrue(self.reading(offset: 3_399).indicatesReaderScroll(from: atTail))
    }

    func testContentGrowthResizeAndJumpsTowardTheTailAreNotReaderScrolls() {
        let atTail = self.reading(offset: 3_400)
        XCTAssertFalse(self.reading(content: 4_600, offset: 3_400).indicatesReaderScroll(from: atTail))
        XCTAssertFalse(self.reading(container: 500, offset: 3_400).indicatesReaderScroll(from: atTail))
        XCTAssertFalse(self.reading(content: 4_600, offset: 2_000).indicatesReaderScroll(from: atTail))
        XCTAssertFalse(self.reading(offset: 3_600).indicatesReaderScroll(from: atTail))
        XCTAssertFalse(self.reading(offset: 3_400).indicatesReaderScroll(from: atTail))
    }

    func testUnsettledSamplesNeverCountAsReaderScrolls() {
        let unsettled = self.reading(container: 0, content: 0, offset: 0)
        XCTAssertFalse(self.reading(offset: 0).indicatesReaderScroll(from: unsettled))
        XCTAssertFalse(unsettled.indicatesReaderScroll(from: self.reading(offset: 3_400)))
    }

    func testReaderScrollPausesFollowingWithoutAPhaseEvent() {
        var state = TranscriptFollowState()
        state.geometryChanged(isNearBottom: false, readerScrolledAway: true)
        XCTAssertFalse(state.followsLatest)
        // Later idle phases and geometry samples keep it paused until the reader returns.
        state.scrollPhaseChanged(userDriven: false, isNearBottom: false)
        state.geometryChanged(isNearBottom: false)
        XCTAssertFalse(state.followsLatest)
        state.geometryChanged(isNearBottom: true)
        XCTAssertTrue(state.followsLatest)
    }

    func testNudgeOnlyWhenLayoutStrandsAFollowingReader() {
        let atTail = self.reading(offset: 3_400)
        let grown = self.reading(content: 4_600, offset: 3_400)
        let scrolledUp = self.reading(offset: 2_000)

        XCTAssertTrue(TranscriptReanchorPolicy.shouldNudge(
            previous: atTail, current: grown, followsLatest: true, attempts: 0, limit: 3))
        XCTAssertFalse(TranscriptReanchorPolicy.shouldNudge(
            previous: atTail, current: scrolledUp, followsLatest: true, attempts: 0, limit: 3))
        XCTAssertFalse(TranscriptReanchorPolicy.shouldNudge(
            previous: atTail, current: grown, followsLatest: false, attempts: 0, limit: 3))
        XCTAssertFalse(TranscriptReanchorPolicy.shouldNudge(
            previous: atTail, current: grown, followsLatest: true, attempts: 3, limit: 3))
        XCTAssertFalse(TranscriptReanchorPolicy.shouldNudge(
            previous: atTail, current: atTail, followsLatest: true, attempts: 0, limit: 3))
    }
}

final class TranscriptWindowTests: XCTestCase {
    func testEarlierExpansionAfterManyUnreadMessagesUsesReadingAnchor() {
        var window = TranscriptWindow(initialItemCount: 200, expansionItemCount: 200)
        window.showEarlier(totalItemCount: 1300, anchoredStartIndex: 800)
        let selection = window.selection(totalItemCount: 1300, anchoredStartIndex: 800, anchoredEndIndex: 1000)
        XCTAssertEqual(selection.range, 600..<1000)
        XCTAssertEqual(selection.visibleItemCount, 400)
    }

    func testFrozenReadingWindowDoesNotRenderAnUnboundedUnreadTail() {
        let window = TranscriptWindow(initialItemCount: 200)
        XCTAssertEqual(window.selection(totalItemCount: 100000, anchoredStartIndex: 800, anchoredEndIndex: 1000).range, 800..<1000)
    }

    func testReadingWindowDoesNotEvictRowsWhenMessagesArrive() {
        let window = TranscriptWindow(initialItemCount: 3)
        let original = window.selection(totalItemCount: 10)
        let reading = window.selection(totalItemCount: 12, anchoredStartIndex: original.range.lowerBound)
        XCTAssertEqual(reading.range, 7..<12)
        XCTAssertEqual(window.selection(totalItemCount: 12).range, 9..<12)
    }

    func testInvalidOldAnchorClampsAfterHistoryReplacement() {
        let window = TranscriptWindow(initialItemCount: 3)
        XCTAssertEqual(window.selection(totalItemCount: 2, anchoredStartIndex: 99).range, 0..<2)
        XCTAssertEqual(window.selection(totalItemCount: 0, anchoredStartIndex: -1).range, 0..<0)
    }

    func testInitialSelectionIsTheLatestBoundedSuffix() {
        let window = TranscriptWindow(initialItemCount: 3, expansionItemCount: 2)
        let selection = window.selection(totalItemCount: 8)

        XCTAssertEqual(selection.range, 5..<8)
        XCTAssertEqual(selection.visibleItemCount, 3)
        XCTAssertEqual(selection.hiddenItemCount, 5)
        XCTAssertEqual(selection.nextExpansionItemCount, 2)
        XCTAssertEqual(Array(selection.items(from: Array(0..<8))), [5, 6, 7])
    }

    func testShowEarlierExpandsInChunksAndStopsAtTheBeginning() {
        var window = TranscriptWindow(initialItemCount: 3, expansionItemCount: 2)

        window.showEarlier(totalItemCount: 8)
        XCTAssertEqual(window.selection(totalItemCount: 8).range, 3..<8)

        window.showEarlier(totalItemCount: 8)
        let all = window.selection(totalItemCount: 8)
        XCTAssertEqual(all.range, 1..<8)
        XCTAssertEqual(all.nextExpansionItemCount, 1)

        window.showEarlier(totalItemCount: 8)
        let exhausted = window.selection(totalItemCount: 8)
        XCTAssertEqual(exhausted.range, 0..<8)
        XCTAssertFalse(exhausted.canShowEarlier)
        XCTAssertEqual(exhausted.nextExpansionItemCount, 0)
    }

    func testTailGrowthAlwaysKeepsTheLatestItemsVisible() {
        var window = TranscriptWindow(initialItemCount: 3, expansionItemCount: 2)
        window.showEarlier(totalItemCount: 8)

        let grown = window.selection(totalItemCount: 10)

        XCTAssertEqual(grown.range, 5..<10)
        XCTAssertEqual(Array(grown.items(from: Array(0..<10))), [5, 6, 7, 8, 9])
    }

    func testResetRestoresInitialBoundAfterExpansion() {
        var window = TranscriptWindow(initialItemCount: 3, expansionItemCount: 2)
        window.showEarlier(totalItemCount: 8)
        window.reset()

        XCTAssertEqual(window.requestedItemCount, 3)
        XCTAssertEqual(window.selection(totalItemCount: 8).range, 5..<8)
    }

    func testCountsAreSanitizedAndSelectionHandlesEmptyInput() {
        let window = TranscriptWindow(initialItemCount: 0, expansionItemCount: -5)
        let empty = window.selection(totalItemCount: -10)

        XCTAssertEqual(window.initialItemCount, 1)
        XCTAssertEqual(window.expansionItemCount, 1)
        XCTAssertEqual(empty.range, 0..<0)
        XCTAssertFalse(empty.canShowEarlier)
        XCTAssertTrue(empty.items(from: [Int]()).isEmpty)
    }
}

final class TranscriptScrollMetricsTests: XCTestCase {
    func testNearBottomToleranceScalesWithTheVisibleContainer() {
        // iPhone SE with the keyboard up: the old fixed 160pt was most of the transcript.
        XCTAssertEqual(TranscriptScrollMetrics.nearBottomTolerance(containerHeight: 300), 44)
        XCTAssertEqual(TranscriptScrollMetrics.nearBottomTolerance(containerHeight: 800), 96)
        // iPad, clamped so the tolerance never swallows a screenful.
        XCTAssertEqual(TranscriptScrollMetrics.nearBottomTolerance(containerHeight: 2_000), 160)
    }

    func testNearBottomToleranceIsSafeForDegenerateContainers() {
        XCTAssertEqual(TranscriptScrollMetrics.nearBottomTolerance(containerHeight: 0), 44)
        XCTAssertEqual(TranscriptScrollMetrics.nearBottomTolerance(containerHeight: -500), 44)
    }
}

final class TranscriptScrollReadingTests: XCTestCase {
    func testUnsettledGeometryReportsNothingRatherThanScrolledAway() {
        // The layout pass during a navigation push. Believing this one turned the Latest pill
        // on over a transcript nobody had scrolled, and let the next scroll phase latch
        // following off — the blank-transcript bug.
        let pushing = TranscriptScrollReading(containerHeight: 0, contentHeight: 8_000, offset: 0)
        XCTAssertFalse(pushing.isSettled)
        XCTAssertNil(pushing.isNearBottom)

        let unmeasured = TranscriptScrollReading(containerHeight: 700, contentHeight: 0, offset: 0)
        XCTAssertFalse(unmeasured.isSettled)
        XCTAssertNil(unmeasured.isNearBottom)
    }

    func testSettledGeometryStillDistinguishesTheTailFromTheBacklog() {
        let atTail = TranscriptScrollReading(
            containerHeight: 700, contentHeight: 8_000, offset: 7_300)
        XCTAssertEqual(atTail.isNearBottom, true)

        // 84pt short of the bottom, inside the 84pt tolerance for a 700pt container.
        let nearTail = TranscriptScrollReading(
            containerHeight: 700, contentHeight: 8_000, offset: 7_216)
        XCTAssertEqual(nearTail.isNearBottom, true)

        let readingBackwards = TranscriptScrollReading(
            containerHeight: 700, contentHeight: 8_000, offset: 2_000)
        XCTAssertEqual(readingBackwards.isNearBottom, false)
    }

    func testAnEmptyTranscriptInARealContainerIsNeverScrolledAway() {
        // An empty transcript reports a real container and zero content — settled by height,
        // but there is nothing to be away from, so the pill must not appear.
        let empty = TranscriptScrollReading(containerHeight: 700, contentHeight: 0, offset: 0)
        XCTAssertNil(empty.isNearBottom)
    }
}

final class TranscriptLayoutStrategyTests: XCTestCase {
    func testProductionLayoutUsesPlatformAppropriateTranscript() {
        let strategy = TranscriptLayoutStrategy.productionDefault

        #if os(macOS)
        // Was .detachedComposerLazy until the macOS LazyVStack placement livelock was
        // bisected (docs/diagnostics/README.md). Eager is the freeze-free macOS default.
        XCTAssertEqual(strategy, .detachedComposerEager)
        XCTAssertFalse(strategy.usesLazyTranscript)
        #else
        // The macOS livelock has not reproduced on iOS; preserve lazy rendering there.
        XCTAssertEqual(strategy, .detachedComposerLazy)
        XCTAssertTrue(strategy.usesLazyTranscript)
        #endif
        XCTAssertTrue(strategy.usesDetachedComposer)
        // Windowing is no longer tied to eager rendering: an unwindowed LazyVStack still has
        // to estimate offsets across hundreds of unrealized rows, which is what left the iOS
        // transcript short of the tail.
        XCTAssertTrue(strategy.usesWindowedTranscript)
    }

    func testEveryLayoutStrategyBoundsTheRenderedTranscript() {
        for strategy in TranscriptLayoutStrategy.allCases {
            XCTAssertTrue(strategy.usesWindowedTranscript, "\(strategy) must window the transcript")
        }
    }

    func testDiagnosticStrategiesDescribeTheTwoFeedbackLoopBoundaries() {
        XCTAssertFalse(TranscriptLayoutStrategy.safeAreaComposerLazy.usesDetachedComposer)
        XCTAssertTrue(TranscriptLayoutStrategy.safeAreaComposerLazy.usesLazyTranscript)
        XCTAssertTrue(TranscriptLayoutStrategy.detachedComposerEager.usesDetachedComposer)
        XCTAssertFalse(TranscriptLayoutStrategy.detachedComposerEager.usesLazyTranscript)
    }

    #if os(macOS) && DEBUG
    func testOfflineStressConfigurationIsExplicitBoundedAndOfflineByDefault() {
        let disabled = OfflineLayoutStressConfiguration.resolve(environment: [:])
        XCTAssertFalse(disabled.isEnabled)
        // Follows the macOS productionDefault, now eager. Reproduce the lazy livelock with
        // CAST_LAYOUT_STRATEGY=detached-lazy.
        XCTAssertEqual(disabled.strategy, .detachedComposerEager)

        let configured = OfflineLayoutStressConfiguration.resolve(environment: [
            "CAST_OFFLINE_LAYOUT_STRESS": "1",
            "CAST_LAYOUT_STRATEGY": "safe-area-lazy",
            "CAST_LAYOUT_STRESS_ITERATIONS": "999999",
            "CAST_LAYOUT_STRESS_INTERVAL_MS": "0",
            "CAST_LAYOUT_STRESS_WATCHDOG_MS": "250",
        ])
        XCTAssertTrue(configured.isEnabled)
        XCTAssertEqual(configured.strategy, .safeAreaComposerLazy)
        XCTAssertEqual(configured.iterations, 20_000)
        XCTAssertEqual(configured.intervalMilliseconds, 5)
        XCTAssertEqual(configured.watchdogMilliseconds, 1_000)
    }
    #endif

}

#if os(macOS)
import AppKit
import SwiftUI

final class TranscriptRealtimeLayoutTests: XCTestCase {
    @MainActor
    func testArrivingAssistantRowsStayVisibleWithoutLatestButton() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ChatStore(transcriptCacheRoot: root, operationsLedgerRoot: root)
        func rows(_ count: Int) -> [ChatMessage] {
            (0..<count).map { index in
                ChatMessage(id: "realtime-\(index)", role: "assistant",
                    blocks: [ChatContentBlock(type: "text", text: "Incoming reply \(index). " + String(repeating: "Readable message content. ", count: 12), thinking: nil, name: nil, mimeType: nil, fileName: nil)],
                    timestamp: Double(index) * 600_000)
            }
        }
        store.installOfflineDiagnosticTranscript(rows(12))
        let host = NSHostingView(rootView: ChatView(store: store, allowsSending: false, showsComposer: false)
            .environment(\.scenePhase, .active))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; try? FileManager.default.removeItem(at: root) }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        try await Task.sleep(for: .milliseconds(400))
        let scroll = try XCTUnwrap(scrollViews(host).first)
        // AppKit can report an interaction phase without a wheel movement. Only
        // actual input, not a framework phase, may freeze the displayed window.
        let phase = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                          wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0))
        phase.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: phase)))
        try await Task.sleep(for: .milliseconds(100))
        var previousHeight = try XCTUnwrap(scroll.documentView).bounds.height
        for count in [13, 20, 30] {
            store.installOfflineDiagnosticTranscript(rows(count))
            try await Task.sleep(for: .milliseconds(350))
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThan(document.bounds.height, previousHeight,
                                 "Arriving rows must enter the visible window")
            previousHeight = document.bounds.height
            XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
            XCTAssertLessThanOrEqual(document.bounds.maxY - scroll.documentVisibleRect.maxY, 2,
                                     "New reply \(count) must be visible without clicking Latest")
        }
    }
}
#endif
