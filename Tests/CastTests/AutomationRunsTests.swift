import Foundation
import XCTest
@testable import Cast

/// Live tails ride on events the gateway is allowed to drop. These cover the watchdog that
/// decides when to re-pull history, and the run-log decode that makes finished cron work
/// visible after its session has aged out of `sessions.list`.
final class TranscriptStalenessTests: XCTestCase {
    func testSessionActivityNewerThanTheLastMessageIsBehind() {
        XCTAssertTrue(ChatStore.transcriptIsBehind(
            sessionUpdatedAt: 1_785_163_097_000,
            newestMessageTimestamp: 1_785_162_000_000,
            isAgentTurnActive: false))
    }

    func testSettledTranscriptDoesNotRefetchOnEveryPoll() {
        // The session row is stamped a moment after the message it describes; that skew
        // must not read as a missed message or the watchdog polls history forever.
        XCTAssertFalse(ChatStore.transcriptIsBehind(
            sessionUpdatedAt: 1_785_163_097_400,
            newestMessageTimestamp: 1_785_163_097_000,
            isAgentTurnActive: false))
    }

    func testEmptyTranscriptForAnActiveSessionIsBehind() {
        // A wiped or never-loaded transcript is exactly the frozen-view case: the gateway
        // reports activity and Cast is showing nothing.
        XCTAssertTrue(ChatStore.transcriptIsBehind(
            sessionUpdatedAt: 1_785_163_097_000,
            newestMessageTimestamp: nil,
            isAgentTurnActive: false))
    }

    func testLiveRunOwnsTheTranscriptAndIsNotPolledOver() {
        XCTAssertFalse(ChatStore.transcriptIsBehind(
            sessionUpdatedAt: 1_785_163_097_000,
            newestMessageTimestamp: 1_785_160_000_000,
            isAgentTurnActive: true))
    }

    func testSessionWithoutATimestampIsNeverAssumedStale() {
        XCTAssertFalse(ChatStore.transcriptIsBehind(
            sessionUpdatedAt: nil,
            newestMessageTimestamp: nil,
            isAgentTurnActive: false))
    }
}

final class TranscriptPreviewReconcilerTests: XCTestCase {
    func testPreviewHeldByARecentRowIsNotBehind() {
        var reconciler = TranscriptPreviewReconciler()
        XCTAssertFalse(reconciler.transcriptIsMissingPreview(
            "**Done.** Merged PR #12",
            recentTexts: ["older reply", "Done. Merged PR #12"]))
    }

    func testPreviewMissingFromTranscriptReloadsOncePerPreview() {
        var reconciler = TranscriptPreviewReconciler()
        let stale = ["thanks", "on it"]
        XCTAssertTrue(reconciler.transcriptIsMissingPreview("Here is the update you asked for", recentTexts: stale))
        // The reload did not surface it: never poll history forever for one preview.
        XCTAssertFalse(reconciler.transcriptIsMissingPreview("Here is the update you asked for", recentTexts: stale))
        // A newer preview is a newly missed message.
        XCTAssertTrue(reconciler.transcriptIsMissingPreview("Second reply", recentTexts: stale))
        // Once the transcript holds it the attempt resets, so a later loss is caught again.
        XCTAssertFalse(reconciler.transcriptIsMissingPreview("Second reply", recentTexts: ["Second reply"]))
        XCTAssertTrue(reconciler.transcriptIsMissingPreview("Second reply", recentTexts: stale))
    }

    func testEmptyPreviewNeverReloadsAndEmptyTranscriptAlwaysDoes() {
        var reconciler = TranscriptPreviewReconciler()
        XCTAssertFalse(reconciler.transcriptIsMissingPreview(nil, recentTexts: []))
        XCTAssertFalse(reconciler.transcriptIsMissingPreview("  \n ", recentTexts: ["anything"]))
        XCTAssertTrue(reconciler.transcriptIsMissingPreview("First reply", recentTexts: []))
    }

    func testFlattenedMarkdownStillMatchesTheRawRow() {
        var reconciler = TranscriptPreviewReconciler()
        let raw = "## Status\n\n- `runpr.ai` is **live**\n- CI green ✅"
        XCTAssertFalse(reconciler.transcriptIsMissingPreview(
            "Status runpr.ai is live CI green",
            recentTexts: [raw]))
    }

    func testLongMessagesMatchOnTheirLeadingText() {
        var reconciler = TranscriptPreviewReconciler()
        let long = String(repeating: "word ", count: 400)
        XCTAssertFalse(reconciler.transcriptIsMissingPreview(long + " tail differs", recentTexts: [long]))
    }

    func testTinyRowsCannotVouchForALongerPreview() {
        var reconciler = TranscriptPreviewReconciler()
        XCTAssertTrue(reconciler.transcriptIsMissingPreview(
            "ok, the deploy finished and everything is green",
            recentTexts: ["ok"]))
    }
}

final class CronRunDecodingTests: XCTestCase {
    /// Captured from a live `cron.runs` response (OpenClaw gateway, 2026-07-27).
    private let payload = """
    {
      "entries": [
        {
          "ts": 1785161548081,
          "jobId": "4a2655c9-49de-403d-beca-de0dc29398bd",
          "action": "finished",
          "status": "ok",
          "summary": "HEARTBEAT_OK\\nsecond line",
          "runAtMs": 1785161503813,
          "durationMs": 44260,
          "nextRunAtMs": 1785163303813,
          "model": "qwen3-30b-instruct",
          "provider": "ollama",
          "usage": { "input_tokens": 33735, "output_tokens": 60 },
          "deliveryStatus": "not-requested",
          "delivery": { "fallbackUsed": false, "delivered": false },
          "sessionId": "c3abde76-e346-41c2-9db9-0fffcd82790b",
          "sessionKey": "agent:main:cron:4a2655c9:run:c3abde76",
          "jobName": "heartbeat-reaper",
          "tsIso": "2026-07-27T10:12:28.081-04:00"
        },
        {
          "ts": 1785161000000,
          "jobId": "job-2",
          "action": "finished",
          "status": "error",
          "summary": "   \\n  boom  ",
          "durationMs": 125000,
          "jobName": "medialyst-watch"
        }
      ],
      "total": 2,
      "hasMore": false,
      "nextOffset": null
    }
    """

    func testDecodesLiveRunLogPageAndIgnoresUnmodelledFields() throws {
        let page = try JSONDecoder().decode(
            CronRunsPage.self,
            from: XCTUnwrap(self.payload.data(using: .utf8)))

        XCTAssertEqual(page.entries.count, 2)
        XCTAssertEqual(page.hasMore, false)

        let heartbeat = page.entries[0]
        XCTAssertEqual(heartbeat.title, "heartbeat-reaper")
        XCTAssertEqual(heartbeat.outcome, .succeeded)
        XCTAssertEqual(heartbeat.previewLine, "HEARTBEAT_OK")
        XCTAssertEqual(heartbeat.durationLabel, "44s")
        // The session key is the whole point: it is how a finished run stays openable.
        XCTAssertEqual(heartbeat.sessionKey, "agent:main:cron:4a2655c9:run:c3abde76")
    }

    func testFailedRunSurfacesItsFirstMeaningfulLine() throws {
        let page = try JSONDecoder().decode(
            CronRunsPage.self,
            from: XCTUnwrap(self.payload.data(using: .utf8)))
        let failure = page.entries[1]

        XCTAssertEqual(failure.outcome, .failed)
        XCTAssertTrue(failure.outcome.needsAttention)
        XCTAssertEqual(failure.previewLine, "boom")
        XCTAssertEqual(failure.durationLabel, "2m 5s")
    }

    func testDigestCountsFailuresForTheHeader() throws {
        let page = try JSONDecoder().decode(
            CronRunsPage.self,
            from: XCTUnwrap(self.payload.data(using: .utf8)))
        let digest = CronRunDigest(runs: page.entries)

        XCTAssertEqual(digest.total, 2)
        XCTAssertEqual(digest.succeeded, 1)
        XCTAssertEqual(digest.failed, 1)
        XCTAssertEqual(digest.summaryText, "2 runs · 1 failed")
    }

    func testTimeoutIsTreatedAsNeedingAttentionAndSkippedIsNot() {
        XCTAssertTrue(CronRunOutcome.from(status: "timeout").needsAttention)
        XCTAssertFalse(CronRunOutcome.from(status: "skipped").needsAttention)
        XCTAssertEqual(CronRunOutcome.from(status: nil), .unknown)
    }

    func testEmptyDigestReadsAsNoRuns() {
        XCTAssertEqual(CronRunDigest(runs: []).summaryText, "No runs yet")
    }
}

/// Live `cron` events folding into the run list, so a job flips to Running and then to its
/// outcome while the Activity view is open — no `cron.runs` refetch per event. Payloads
/// mirror the installed gateway's cron `emit(...)` call sites, plus the malformed variants
/// a version-skewed gateway will eventually send.
final class CronEventMergeTests: XCTestCase {
    private func cronEvent(_ payload: [String: Any]) throws -> CronEventPayload {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(CronEventPayload.self, from: data)
    }

    func testStartedInsertsARunningRowAndFinishedReplacesItInPlace() throws {
        let started = try self.cronEvent([
            "jobId": "4a2655c9-49de-403d-beca-de0dc29398bd",
            "action": "started",
            "job": [
                "id": "4a2655c9-49de-403d-beca-de0dc29398bd",
                "name": "Morning brief",
                "enabled": true,
                "schedule": ["kind": "cron", "expr": "0 7 * * *"],
            ],
            "runAtMs": 1_785_161_503_813,
        ])
        let existing = CronRun(ts: 1_785_100_000_000, jobId: "other-job", status: "ok")
        var runs = CronRun.merging([existing], event: started)

        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.first?.outcome, .running)
        XCTAssertEqual(runs.first?.title, "Morning brief")

        let finished = try self.cronEvent([
            "jobId": "4a2655c9-49de-403d-beca-de0dc29398bd",
            "action": "finished",
            "job": ["id": "4a2655c9-49de-403d-beca-de0dc29398bd", "name": "Morning brief"],
            "status": "ok",
            "summary": "HEARTBEAT_OK\nsent brief",
            "delivered": true,
            "deliveryStatus": "sent",
            "runAtMs": 1_785_161_503_813,
            "durationMs": 42_000,
            "nextRunAtMs": 1_785_247_903_813,
            "sessionKey": "agent:main:cron-4a2655c9",
        ])
        runs = CronRun.merging(runs, event: finished)

        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.first?.outcome, .succeeded)
        XCTAssertEqual(runs.first?.previewLine, "HEARTBEAT_OK")
        XCTAssertEqual(runs.first?.sessionKey, "agent:main:cron-4a2655c9")
        XCTAssertEqual(runs.last?.jobId, "other-job")
    }

    /// The regression that motivated the malformed-payload rule: an unmodelled status must
    /// still terminate the Running row, not leave a crashed job looking alive.
    func testFinishedWithUnexpectedStatusStillEndsTheRunningRow() throws {
        let runs = CronRun.merging(
            [CronRun(ts: 1, jobId: "job-x", jobName: "Nightly", status: "running")],
            event: try self.cronEvent([
                "jobId": "job-x",
                "action": "finished",
                "status": "failed",
                "error": "agent crashed",
            ]))

        XCTAssertEqual(runs.count, 1)
        XCTAssertNotEqual(runs.first?.outcome, .running)
        XCTAssertEqual(runs.first?.outcome, .unknown)
        // The error text survives as the row's summary so the failure is readable.
        XCTAssertEqual(runs.first?.previewLine, "agent crashed")
        // Its synthesized name survives the terse finished payload.
        XCTAssertEqual(runs.first?.title, "Nightly")
    }

    func testFinishedWithoutAPriorStartedPrepends() throws {
        let runs = CronRun.merging([], event: try self.cronEvent([
            "jobId": "job-y",
            "action": "finished",
            "status": "error",
            "error": "boom",
            "runAtMs": 1_785_161_503_813,
        ]))
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.outcome, .failed)
    }

    func testDefinitionActionsAndGarbageAreIgnored() throws {
        let existing = [CronRun(ts: 1, jobId: "job-z", status: "ok")]
        // Job CRUD actions are not runs.
        for action in ["added", "updated", "removed", "someday-new"] {
            XCTAssertEqual(
                CronRun.merging(existing, event: try self.cronEvent([
                    "jobId": "job-z", "action": action,
                ])).map(\.id),
                existing.map(\.id))
        }
        // Missing jobId cannot be merged anywhere.
        XCTAssertEqual(
            CronRun.merging(existing, event: try self.cronEvent(["action": "started"])).count,
            1)
    }

    @MainActor
    func testCronEventsReachTheStoreRunList() throws {
        let store = ChatStore()
        let event = try JSONDecoder().decode(EventFrame.self, from: JSONSerialization.data(withJSONObject: [
            "event": "cron",
            "payload": [
                "jobId": "job-live",
                "action": "started",
                "job": ["id": "job-live", "name": "Watchdog"],
                "runAtMs": 1_785_161_503_813,
            ],
        ]))
        store.handleEvent(event)
        XCTAssertEqual(store.automationRuns.first?.outcome, .running)
        XCTAssertEqual(store.automationRuns.first?.title, "Watchdog")
    }
}
