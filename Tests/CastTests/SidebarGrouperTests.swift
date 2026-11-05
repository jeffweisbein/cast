import XCTest
@testable import Cast

/// Fixtures mirror representative rows from a live gateway. `kind` is deliberately limited to the
/// gateway's real vocabulary ("direct" | "group" | "global" | "unknown"); cron and subagent rows
/// are identified by their session key, which is all the gateway ever gives us.
final class SidebarGrouperTests: XCTestCase {
    private func row(
        key: String,
        displayName: String? = nil,
        derivedTitle: String? = nil,
        preview: String? = nil,
        channel: String? = nil,
        updatedAt: Double? = nil,
        unread: Bool? = nil,
        kind: String? = "direct",
        status: String? = nil,
        abortedLastRun: Bool? = nil,
        hasActiveRun: Bool? = nil,
        spawnedBy: String? = nil,
        label: String? = nil) -> SessionRow
    {
        SessionRow(
            key: key,
            kind: kind,
            displayName: displayName,
            derivedTitle: derivedTitle,
            lastMessagePreview: preview,
            channel: channel,
            updatedAt: updatedAt,
            unread: unread,
            pinned: nil,
            hasActiveRun: hasActiveRun,
            model: nil,
            status: status,
            abortedLastRun: abortedLastRun,
            spawnedBy: spawnedBy,
            label: label)
    }

    private let mainKey = "agent:main:main"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var recentUpdatedAt: Double {
        (self.now.timeIntervalSince1970 - 60) * 1000
    }

    private func updatedAt(daysAgo days: Double) -> Double {
        (self.now.timeIntervalSince1970 - days * 24 * 60 * 60) * 1000
    }

    // MARK: - Classification

    func testUnreadStateIsExplicitAndCanBeClearedLocallyAfterGatewayPatch() {
        let unread = self.row(key: "agent:main:main", unread: true)
        XCTAssertTrue(unread.isUnread)
        XCTAssertFalse(unread.settingUnread(false).isUnread)
        XCTAssertFalse(self.row(key: "agent:main:main", unread: nil).isUnread)
    }

    func testClassificationMatchesLiveTaxonomy() {
        let cases: [(String, SessionCategory)] = [
            ("agent:main:imessage:direct:+12025550143", .main),
            ("agent:main:imessage:direct:alex@example.com", .main),
            ("agent:main:main", .main),
            ("agent:main:cast-dev", .chat),
            ("agent:patches:main", .chat),
            // A group thread is a human conversation, so it belongs with the other chats.
            ("agent:main:imessage:group:ABC123", .main),
            ("agent:main:subagent:027b34e7-57ee-4a7c-94d7-a6e42dce17f9", .task),
            ("agent:main:cron:4a2655c9-49de-403d-beca-de0dc29398bd", .automation),
            ("agent:main:cron:34f7f411-5c39-409e-b487-d2f7b187b4e0:run:1784666453709", .automation),
            ("agent:main:dreaming-narrative-deep-ed4c370462d8", .automation),
        ]
        for (key, expected) in cases {
            XCTAssertEqual(
                SidebarGrouper.category(for: self.row(key: key), mainSessionKey: self.mainKey),
                expected,
                "wrong category for \(key)")
        }
    }

    func testMainChatOutranksHeartbeatTouchedMainSession() {
        // Agent Inbox is fixed first even when another human chat is newer.
        let sessions = [
            self.row(key: "agent:main:main", preview: "HEARTBEAT_OK", updatedAt: 2000),
            self.row(key: "agent:main:cron:abc", displayName: "Cron: heartbeat-reaper", updatedAt: 1500),
            self.row(
                key: "agent:main:imessage:direct:+12025550143",
                channel: "imessage",
                updatedAt: self.recentUpdatedAt),
        ]
        let sections = SidebarGrouper.sections(sessions, mainSessionKey: self.mainKey, now: self.now)
        XCTAssertEqual(sections.first?.category, .main)
        XCTAssertEqual(
            sections.first?.sessions.map(\.key),
            ["agent:main:main", "agent:main:imessage:direct:+12025550143"])
        XCTAssertEqual(sections.map(\.category), [.main, .activity])
    }

    func testSectionsOmitEmptyBucketsAndKeepFixedOrder() {
        let sessions = [
            self.row(
                key: "agent:main:cron:abc",
                displayName: "Cron: clawd-auto-backup",
                updatedAt: self.recentUpdatedAt),
            self.row(key: "agent:main:imessage:direct:+12025550143", channel: "imessage"),
            self.row(
                key: "agent:main:subagent:xyz",
                displayName: "cast M2.1 ui polish",
                updatedAt: self.recentUpdatedAt),
        ]
        let sections = SidebarGrouper.sections(sessions, mainSessionKey: self.mainKey, now: self.now)
        XCTAssertEqual(sections.map(\.category), [.main, .activity, .task, .automation])
        XCTAssertEqual(sections.map(\.title), ["Chats", "Activity", "Tasks", "Automation"])
    }

    func testAccentsFollowSessionTaxonomy() {
        let cases: [(SessionRow, SessionAccent)] = [
            (self.row(key: "agent:main:main"), .spark),
            (self.row(key: "agent:main:imessage:direct:+12025550143", channel: "imessage"), .channel),
            (self.row(key: "agent:main:imessage:group:ABC123", channel: "imessage"), .channel),
            (self.row(key: "agent:main:subagent:xyz"), .task),
            (self.row(key: "agent:main:cron:abc"), .cron),
            (self.row(key: "agent:main:dreaming-narrative-deep-ed4c370462d8"), .dreaming),
            (self.row(key: "agent:main:cast-dev"), .terminal),
        ]
        for (session, expected) in cases {
            XCTAssertEqual(
                SidebarGrouper.accent(for: session, mainSessionKey: self.mainKey),
                expected,
                "wrong accent for \(session.key)")
        }
    }

    // MARK: - Naming

    func testCronTitlesDropPrefixAndHumanize() {
        let reaper = self.row(key: "agent:main:cron:abc", displayName: "Cron: heartbeat-reaper")
        XCTAssertEqual(SidebarGrouper.displayTitle(for: reaper), "Heartbeat Reaper")
        XCTAssertEqual(SidebarGrouper.subtitle(for: reaper), "Cron")

        let acronym = self.row(key: "agent:main:cron:def", displayName: "Cron: OCA lead signal monitor")
        XCTAssertEqual(SidebarGrouper.displayTitle(for: acronym), "OCA Lead Signal Monitor")

        let unnamedRun = self.row(key: "agent:main:cron:def:run:1784666453709")
        XCTAssertEqual(SidebarGrouper.displayTitle(for: unnamedRun), "Cron Run")
    }

    func testDirectSessionTitlesFormatAddresses() {
        let phone = self.row(
            key: "agent:main:imessage:direct:+12025550143",
            displayName: "+12025550143",
            channel: "imessage")
        XCTAssertEqual(SidebarGrouper.displayTitle(for: phone), "+1 (202) 555-0143")
        XCTAssertEqual(SidebarGrouper.subtitle(for: phone), "iMessage")

        let email = self.row(
            key: "agent:main:imessage:direct:alex@example.com",
            displayName: "alex@example.com",
            channel: "imessage")
        XCTAssertEqual(SidebarGrouper.displayTitle(for: email), "alex@example.com")
    }

    /// A deliberately set label should read as that name, not as the phone number.
    func testDirectSessionPrefersADeliberateLabelOverTheAddress() {
        let named = self.row(
            key: "agent:main:imessage:direct:+15166334684",
            channel: "imessage",
            label: "Jeff Weisbein")
        XCTAssertEqual(SidebarGrouper.displayTitle(for: named), "Jeff Weisbein")
    }

    /// `displayName` is not a contact name on this gateway. It hands back the name of the client
    /// that last read the session for one direct row and the channel-prefixed key for another;
    /// neither may title a person's chat.
    func testDirectSessionIgnoresUntrustworthyDisplayNames() {
        let clientNamed = self.row(
            key: "agent:main:imessage:direct:+15166334684",
            displayName: "Cast",
            channel: "imessage")
        XCTAssertEqual(SidebarGrouper.displayTitle(for: clientNamed), "+1 (516) 633-4684")

        let keyNamed = self.row(
            key: "agent:patches:imessage:direct:+15166334684",
            displayName: "imessage:+15166334684",
            channel: "imessage")
        XCTAssertEqual(SidebarGrouper.displayTitle(for: keyNamed), "+1 (516) 633-4684")
    }

    func testDirectSessionWithoutANameStillFormatsTheAddress() {
        let anonymous = self.row(
            key: "agent:main:imessage:direct:+15166334684",
            channel: "imessage")
        XCTAssertEqual(SidebarGrouper.displayTitle(for: anonymous), "+1 (516) 633-4684")
        XCTAssertEqual(SidebarGrouper.subtitle(for: anonymous), "iMessage")
    }

    /// Two agents talking to the same person used to render two visually identical rows.
    func testSameContactOnTwoAgentsProducesDistinguishableRows() {
        let mainAgent = self.row(
            key: "agent:main:imessage:direct:+15166334684",
            channel: "imessage")
        let otherAgent = self.row(
            key: "agent:patches:imessage:direct:+15166334684",
            channel: "imessage")

        XCTAssertEqual(
            SidebarGrouper.displayTitle(for: mainAgent, mainSessionKey: self.mainKey),
            SidebarGrouper.displayTitle(for: otherAgent, mainSessionKey: self.mainKey))
        XCTAssertEqual(SidebarGrouper.subtitle(for: mainAgent, mainSessionKey: self.mainKey), "iMessage")
        XCTAssertEqual(
            SidebarGrouper.subtitle(for: otherAgent, mainSessionKey: self.mainKey),
            "iMessage · patches")
        XCTAssertNotEqual(
            SidebarGrouper.subtitle(for: mainAgent, mainSessionKey: self.mainKey),
            SidebarGrouper.subtitle(for: otherAgent, mainSessionKey: self.mainKey))
    }

    /// "Main" is only the default agent id, so the agent tag follows whichever agent owns the
    /// operator's own session.
    func testAgentTagFollowsTheOperatorsOwnAgentRatherThanTheLiteralMainID() {
        let janeMain = "agent:jane:main"
        let jane = self.row(key: "agent:jane:imessage:direct:+15166334684", channel: "imessage")
        let patches = self.row(key: "agent:patches:imessage:direct:+15166334684", channel: "imessage")

        XCTAssertEqual(SidebarGrouper.subtitle(for: jane, mainSessionKey: janeMain), "iMessage")
        XCTAssertEqual(SidebarGrouper.subtitle(for: patches, mainSessionKey: janeMain), "iMessage · patches")
    }

    func testMainSessionAndAgentTitles() {
        let main = self.row(key: "agent:main:main", derivedTitle: "[OpenClaw heartbeat poll]", channel: "imessage")
        XCTAssertEqual(SidebarGrouper.displayTitle(for: main, mainSessionKey: self.mainKey), "Agent Inbox")
        XCTAssertEqual(SidebarGrouper.subtitle(for: main, mainSessionKey: self.mainKey), "Main agent session")

        let named = self.row(key: "agent:main:cast-dev", displayName: "Cast")
        XCTAssertEqual(SidebarGrouper.displayTitle(for: named, mainSessionKey: self.mainKey), "Cast")
    }

    func testSubagentTitlesFallBackWhenLabelIsMissing() {
        let labeled = self.row(key: "agent:main:subagent:aaa", displayName: "cast M2.1 ui polish")
        XCTAssertEqual(SidebarGrouper.displayTitle(for: labeled), "cast M2.1 ui polish")
        XCTAssertEqual(SidebarGrouper.subtitle(for: labeled), "Subagent")

        let unlabeled = self.row(
            key: "agent:main:subagent:bbb",
            derivedTitle: "[Subagent Context] You are running as a subagent (depth…")
        XCTAssertEqual(SidebarGrouper.displayTitle(for: unlabeled), "Subagent Task")

        let gatewayLabel = self.row(
            key: "agent:main:subagent:ccc",
            derivedTitle: "[Subagent Context] You are running…",
            label: "Review sidebar")
        XCTAssertEqual(SidebarGrouper.displayTitle(for: gatewayLabel), "Review sidebar")
    }

    func testSubagentSubtitleShowsItsHumanOrigin() {
        let imessage = self.row(
            key: "agent:main:imessage:direct:+12025550143",
            channel: "imessage")
        let fromMessage = self.row(
            key: "agent:main:subagent:message",
            spawnedBy: imessage.key)
        let fromInbox = self.row(
            key: "agent:main:subagent:inbox",
            spawnedBy: self.mainKey)

        XCTAssertEqual(
            SidebarGrouper.subtitle(
                for: fromMessage,
                mainSessionKey: self.mainKey,
                allSessions: [imessage]),
            "from iMessage")
        XCTAssertEqual(
            SidebarGrouper.subtitle(
                for: fromInbox,
                mainSessionKey: self.mainKey,
                allSessions: []),
            "from Agent Inbox")
    }

    func testDreamingSessionTitlesStripTrailingIDs() {
        let dreaming = self.row(key: "agent:main:dreaming-narrative-deep-ed4c370462d8")
        XCTAssertEqual(SidebarGrouper.displayTitle(for: dreaming), "Dreaming Narrative Deep")
        XCTAssertEqual(SidebarGrouper.subtitle(for: dreaming), "Dreaming")
    }

    // MARK: - Previews and search

    func testNoisePreviewsBecomeQuietLabels() {
        XCTAssertEqual(SidebarGrouper.cleanPreview("HEARTBEAT_OK"), "Heartbeat OK")
        XCTAssertEqual(SidebarGrouper.cleanPreview("[OpenClaw heartbeat poll] status ok"), "Heartbeat poll")
        XCTAssertEqual(SidebarGrouper.cleanPreview("[Subagent Context] You are running…"), "Task briefing received")
        XCTAssertEqual(SidebarGrouper.cleanPreview("line one\nline two"), "line one line two")
        XCTAssertNil(SidebarGrouper.cleanPreview("   "))
        XCTAssertNil(SidebarGrouper.cleanPreview(nil))
    }

    func testSearchMatchesHumanizedTitlesAndRawKeys() {
        let reaper = self.row(key: "agent:main:cron:abc", displayName: "Cron: heartbeat-reaper")
        XCTAssertTrue(SidebarGrouper.matchesSearch(reaper, query: "Heartbeat Reaper", mainSessionKey: self.mainKey))
        XCTAssertTrue(SidebarGrouper.matchesSearch(reaper, query: "cron:abc", mainSessionKey: self.mainKey))
        XCTAssertFalse(SidebarGrouper.matchesSearch(reaper, query: "polymarket", mainSessionKey: self.mainKey))

        let phone = self.row(key: "agent:main:imessage:direct:+12025550143", displayName: "+12025550143", channel: "imessage")
        XCTAssertTrue(SidebarGrouper.matchesSearch(phone, query: "(202)", mainSessionKey: self.mainKey))
    }

    // MARK: - Operations console

    func testAgentInboxAlwaysRemainsFirstChatRegardlessOfOperationalState() {
        let quiet = self.row(key: self.mainKey, preview: "HEARTBEAT_OK")
        let unread = self.row(
            key: self.mainKey,
            preview: "A reply",
            updatedAt: self.recentUpdatedAt,
            unread: true)
        let active = SessionRow(
            key: self.mainKey,
            kind: "direct",
            displayName: nil,
            derivedTitle: nil,
            lastMessagePreview: "Working",
            channel: nil,
            updatedAt: self.recentUpdatedAt,
            unread: false,
            pinned: nil,
            hasActiveRun: true,
            model: nil,
            status: "running")

        for inbox in [quiet, unread, active] {
            let sections = SidebarGrouper.sections([inbox], mainSessionKey: self.mainKey, now: self.now)
            XCTAssertEqual(sections.map(\.category), [.main, .activity])
            XCTAssertEqual(sections.first?.sessions.map(\.key), [self.mainKey])
        }
    }

    func testAttentionDoesNotHoistRowsOutOfTheirWorkGroups() {
        let unreadChat = self.row(
            key: "agent:main:imessage:group:ABC",
            preview: "New reply",
            channel: "imessage",
            updatedAt: self.recentUpdatedAt,
            unread: true)
        let failedTask = self.row(
            key: "agent:main:subagent:failed",
            displayName: "Build failed",
            preview: "Action required after failure",
            updatedAt: self.recentUpdatedAt,
            status: "timeout")
        let quietTask = self.row(
            key: "agent:main:subagent:quiet",
            displayName: "Finished",
            preview: "Finished")

        let sections = SidebarGrouper.sections(
            [unreadChat, failedTask, quietTask],
            mainSessionKey: self.mainKey,
            now: self.now)

        XCTAssertEqual(sections.map(\.category), [.main, .activity, .task])
        XCTAssertEqual(
            sections.first(where: { $0.category == .task })?.sessions.map(\.key),
            [failedTask.key])
        XCTAssertEqual(
            sections.first(where: { $0.category == .main })?.sessions.map(\.key),
            [unreadChat.key])
        XCTAssertEqual(
            sections.flatMap(\.sessions).map(\.key).count,
            Set(sections.flatMap(\.sessions).map(\.key)).count)
    }

    func testWorkFiltersOldCompletedRowsButKeepsRecentAndRunningRows() {
        let old = (self.now.timeIntervalSince1970 - 25 * 60 * 60) * 1000
        let oldDone = self.row(
            key: "agent:main:subagent:old",
            updatedAt: old,
            status: "done")
        let recentDone = self.row(
            key: "agent:main:subagent:recent",
            updatedAt: self.recentUpdatedAt,
            status: "done")
        let oldRunning = self.row(
            key: "agent:main:cron:running",
            updatedAt: old,
            status: "running")
        let oldOther = self.row(key: "agent:main:scratch", updatedAt: old, status: "done")

        let sections = SidebarGrouper.sections(
            [oldDone, recentDone, oldRunning, oldOther],
            mainSessionKey: self.mainKey,
            now: self.now)

        XCTAssertEqual(
            sections.first(where: { $0.category == .task })?.sessions.map(\.key),
            [recentDone.key])
        XCTAssertEqual(
            sections.first(where: { $0.category == .automation })?.sessions.map(\.key),
            [oldRunning.key])
        XCTAssertNil(sections.first(where: { $0.category == .chat }))
        XCTAssertEqual(
            SidebarGrouper.activitySessions(
                [oldDone, recentDone, oldRunning, oldOther],
                mainSessionKey: self.mainKey).count,
            4)
    }

    func testActivitySummaryCountsLiveFailuresAndDoneToday() {
        let sessions = [
            self.row(
                key: "agent:main:subagent:running",
                updatedAt: self.recentUpdatedAt,
                status: "running"),
            self.row(
                key: "agent:main:subagent:failed",
                updatedAt: self.recentUpdatedAt,
                status: "timeout"),
            self.row(
                key: "agent:main:cron:done",
                updatedAt: self.recentUpdatedAt,
                status: "done"),
        ]

        let summary = SidebarGrouper.activitySummary(
            for: sessions,
            mainSessionKey: self.mainKey,
            now: self.now)
        XCTAssertEqual(summary, SidebarActivitySummary(running: 1, failed: 1, doneToday: 1))
        XCTAssertEqual(summary.text, "1 running · 1 failed · 1 done today")
    }

    func testOperationalStatusIsDeterministicForTaskAndAutomationRows() {
        let runningTask = SessionRow(
            key: "agent:main:subagent:running",
            kind: "direct",
            displayName: "Build Cast",
            derivedTitle: nil,
            lastMessagePreview: "Implementing",
            channel: nil,
            updatedAt: nil,
            unread: false,
            pinned: nil,
            hasActiveRun: true,
            model: nil,
            status: nil)
        let completedTask = self.row(
            key: "agent:main:subagent:done",
            preview: "Finished",
            status: "done")
        let healthyCron = self.row(key: "agent:main:cron:healthy", preview: "Last run succeeded")
        let failedCron = self.row(
            key: "agent:main:cron:failed",
            preview: "Last run failed",
            updatedAt: self.recentUpdatedAt,
            status: "killed")

        XCTAssertEqual(SidebarGrouper.operationalStatus(for: runningTask, mainSessionKey: self.mainKey, now: self.now), .running)
        XCTAssertEqual(SidebarGrouper.operationalStatus(for: completedTask, mainSessionKey: self.mainKey, now: self.now), .done)
        XCTAssertEqual(SidebarGrouper.operationalStatus(for: healthyCron, mainSessionKey: self.mainKey, now: self.now), .healthy)
        XCTAssertEqual(SidebarGrouper.operationalStatus(for: failedCron, mainSessionKey: self.mainKey, now: self.now), .needsAttention)

        let summary = SidebarGrouper.summary(
            for: [runningTask, completedTask, healthyCron, failedCron],
            mainSessionKey: self.mainKey,
            now: self.now)
        XCTAssertEqual(summary.total, 4)
        XCTAssertEqual(summary.running, 1)
        XCTAssertEqual(summary.done, 1)
        XCTAssertEqual(summary.healthy, 1)
        XCTAssertEqual(summary.needsAttention, 1)
    }

    func testDoneStaleFailurePreviewNeverNeedsAttention() {
        let twentyFiveDaysAgo = (self.now.timeIntervalSince1970 - 25 * 24 * 60 * 60) * 1000
        let session = self.row(
            key: "agent:main:subagent:stale",
            preview: "Build failed and needs attention",
            updatedAt: twentyFiveDaysAgo,
            unread: true,
            status: "done")

        XCTAssertEqual(
            SidebarGrouper.operationalStatus(
                for: session,
                mainSessionKey: self.mainKey,
                now: self.now),
            .done)
        XCTAssertFalse(SidebarGrouper.requiresOperatorAttention(
            session,
            mainSessionKey: self.mainKey,
            now: self.now))
    }

    func testAcknowledgedFailureClearsUntilSessionUpdates() {
        let session = self.row(
            key: "agent:main:subagent:failed",
            updatedAt: self.recentUpdatedAt,
            status: "timeout")
        var ledger = AcknowledgementLedger()
        XCTAssertTrue(ledger.acknowledge(
            workspaceID: "workspace",
            sessionKey: session.key,
            updatedAt: session.updatedAt))

        XCTAssertEqual(
            SidebarGrouper.operationalStatus(
                for: session,
                mainSessionKey: self.mainKey,
                now: self.now,
                acknowledgedFailures: ledger.identifiers(workspaceID: "workspace")),
            .failed)

        let updated = self.row(
            key: session.key,
            updatedAt: self.recentUpdatedAt + 1,
            status: "timeout")
        XCTAssertEqual(
            SidebarGrouper.operationalStatus(
                for: updated,
                mainSessionKey: self.mainKey,
                now: self.now,
                acknowledgedFailures: ledger.identifiers(workspaceID: "workspace")),
            .needsAttention)
    }

    /// "failed" is the gateway's status for a run that errored out — the most common way work
    /// dies. Missing it here rendered every crashed subagent as a grey "Idle" row with no badge,
    /// and hid it from the Failures-only filter.
    func testErroredRunStatusRaisesAttentionAndReadsAsAFailure() {
        let crashed = self.row(
            key: "agent:main:subagent:crashed",
            displayName: "Build Cast",
            preview: "Running the build",
            updatedAt: self.recentUpdatedAt,
            status: "failed")

        XCTAssertEqual(
            SidebarGrouper.operationalStatus(
                for: crashed,
                mainSessionKey: self.mainKey,
                now: self.now),
            .needsAttention)
        XCTAssertTrue(SidebarGrouper.hasFailureSignal(crashed))
        XCTAssertEqual(
            SidebarGrouper.activitySummary(
                for: [crashed],
                mainSessionKey: self.mainKey,
                now: self.now),
            SidebarActivitySummary(running: 0, failed: 1, doneToday: 0))
    }

    /// A gateway host whose clock runs ahead of this Mac stamps `updatedAt` in our future.
    func testSessionStampedByAClockRunningAheadIsStillRecent() {
        let future = (self.now.timeIntervalSince1970 + 30) * 1000
        let justFailed = self.row(
            key: "agent:main:subagent:skewed",
            updatedAt: future,
            status: "failed")

        XCTAssertEqual(
            SidebarGrouper.operationalStatus(
                for: justFailed,
                mainSessionKey: self.mainKey,
                now: self.now),
            .needsAttention)
        XCTAssertEqual(
            SidebarGrouper.sections([justFailed], mainSessionKey: self.mainKey, now: self.now)
                .first(where: { $0.category == .task })?.sessions.map(\.key),
            [justFailed.key])
    }

    /// The Activity strip counts background work, so it has to know which session is the
    /// operator's own — and that is not always `agent:main:main`.
    func testActivitySummaryExcludesTheMainSessionOfANonDefaultAgent() {
        let janeMain = "agent:jane:main"
        let sessions = [
            self.row(key: janeMain, updatedAt: self.recentUpdatedAt, status: "running"),
            self.row(key: "agent:jane:subagent:build", updatedAt: self.recentUpdatedAt, status: "running"),
        ]

        XCTAssertEqual(
            SidebarGrouper.activitySummary(for: sessions, mainSessionKey: janeMain, now: self.now),
            SidebarActivitySummary(running: 1, failed: 0, doneToday: 0))
    }

    func testLiveRunOutranksAnAbortFromThePreviousRun() {
        let retrying = self.row(
            key: "agent:main:subagent:retry",
            updatedAt: self.recentUpdatedAt,
            status: "running",
            abortedLastRun: true)
        let settled = self.row(
            key: "agent:main:subagent:retry",
            updatedAt: self.recentUpdatedAt,
            abortedLastRun: true)

        XCTAssertEqual(
            SidebarGrouper.operationalStatus(for: retrying, mainSessionKey: self.mainKey, now: self.now),
            .running)
        XCTAssertEqual(
            SidebarGrouper.operationalStatus(for: settled, mainSessionKey: self.mainKey, now: self.now),
            .needsAttention)
    }

    /// `abortedLastRun` stays true until a run succeeds, while every later message mints a new
    /// `updatedAt`. Keying its dismissal on the timestamp re-raised a deliberate Esc-abort forever.
    func testDismissedAbortStaysDismissedWhileTheSessionKeepsTalking() {
        let aborted = self.row(
            key: "agent:main:cast-dev",
            updatedAt: self.recentUpdatedAt,
            abortedLastRun: true)
        var ledger = AcknowledgementLedger()
        XCTAssertTrue(ledger.acknowledge(
            workspaceID: "workspace",
            sessionKey: aborted.key,
            updatedAt: aborted.updatedAt))
        let acknowledged = ledger.identifiers(workspaceID: "workspace")

        let laterTurn = self.row(
            key: aborted.key,
            preview: "Sure, here is that summary",
            updatedAt: self.recentUpdatedAt + 5000,
            abortedLastRun: true)

        XCTAssertEqual(
            SidebarGrouper.operationalStatus(
                for: laterTurn,
                mainSessionKey: self.mainKey,
                now: self.now,
                acknowledgedFailures: acknowledged),
            .failed)
        XCTAssertEqual(
            SidebarGrouper.activitySummary(
                for: [laterTurn],
                mainSessionKey: self.mainKey,
                now: self.now,
                acknowledgedFailures: acknowledged).failed,
            0)
    }

    func testGenuinelyNewFailureStillRaisesAfterAnAbortWasDismissed() {
        let aborted = self.row(
            key: "agent:main:cast-dev",
            updatedAt: self.recentUpdatedAt,
            abortedLastRun: true)
        var ledger = AcknowledgementLedger()
        ledger.acknowledge(
            workspaceID: "workspace",
            sessionKey: aborted.key,
            updatedAt: aborted.updatedAt)
        let acknowledged = ledger.identifiers(workspaceID: "workspace")

        let crashedLater = self.row(
            key: aborted.key,
            updatedAt: self.recentUpdatedAt + 5000,
            status: "failed",
            abortedLastRun: true)

        XCTAssertEqual(
            SidebarGrouper.operationalStatus(
                for: crashedLater,
                mainSessionKey: self.mainKey,
                now: self.now,
                acknowledgedFailures: acknowledged),
            .needsAttention)
        XCTAssertEqual(
            SidebarGrouper.activitySummary(
                for: [crashedLater],
                mainSessionKey: self.mainKey,
                now: self.now,
                acknowledgedFailures: acknowledged).failed,
            1)
    }

    /// Group threads used to land in Work, which drops anything quiet for a day — so a slow human
    /// conversation disappeared from the sidebar overnight.
    func testQuietHumanGroupChatStaysInChats() {
        let quietGroup = self.row(
            key: "agent:main:imessage:group:ABC123",
            displayName: "Family",
            channel: "imessage",
            updatedAt: (self.now.timeIntervalSince1970 - 25 * 60 * 60) * 1000)

        let sections = SidebarGrouper.sections([quietGroup], mainSessionKey: self.mainKey, now: self.now)
        XCTAssertEqual(
            sections.first(where: { $0.category == .main })?.sessions.map(\.key),
            [quietGroup.key])
        XCTAssertNil(sections.first(where: { $0.category == .chat }))
    }

    /// The gateway collapses `:group:` and `:channel:` into the same kind, so a quiet Slack or
    /// Discord channel must survive the Work zone's 24h filter exactly like a group chat does.
    func testQuietChannelConversationStaysInChats() {
        let quietChannel = self.row(
            key: "agent:main:discord:channel:998877",
            displayName: "#general",
            channel: "discord",
            updatedAt: (self.now.timeIntervalSince1970 - 25 * 60 * 60) * 1000)

        let sections = SidebarGrouper.sections([quietChannel], mainSessionKey: self.mainKey, now: self.now)
        XCTAssertEqual(
            sections.first(where: { $0.category == .main })?.sessions.map(\.key),
            [quietChannel.key])
        XCTAssertNil(sections.first(where: { $0.category == .chat }))
        XCTAssertEqual(SidebarGrouper.accent(for: quietChannel, mainSessionKey: self.mainKey), .channel)
    }

    /// Chats never dropped anything, so a one-off text pinned a row there forever. A long-dead
    /// chat moves to Other sessions — it is re-bucketed, never dropped.
    func testLongDeadChatAgesIntoOtherSessions() {
        let dead = self.row(
            key: "agent:main:imessage:direct:+12025550143",
            channel: "imessage",
            updatedAt: self.updatedAt(daysAgo: 15))
        let stillWarm = self.row(
            key: "agent:main:imessage:direct:+12025550199",
            channel: "imessage",
            updatedAt: self.updatedAt(daysAgo: 13))

        let sections = SidebarGrouper.sections(
            [dead, stillWarm],
            mainSessionKey: self.mainKey,
            now: self.now)

        XCTAssertEqual(
            sections.first(where: { $0.category == .main })?.sessions.map(\.key),
            [stillWarm.key])
        XCTAssertEqual(
            sections.first(where: { $0.category == .chat })?.sessions.map(\.key),
            [dead.key])
        XCTAssertEqual(sections.flatMap(\.sessions).count, 2)
    }

    /// Age never removes a row the operator may still be waiting on.
    func testAgingSparesTheAgentInboxAndAnythingStillAskingForAttention() {
        let inbox = self.row(key: self.mainKey, updatedAt: self.updatedAt(daysAgo: 30))
        let unread = self.row(
            key: "agent:main:imessage:direct:+12025550111",
            channel: "imessage",
            updatedAt: self.updatedAt(daysAgo: 30),
            unread: true)
        let failed = self.row(
            key: "agent:main:imessage:direct:+12025550122",
            channel: "imessage",
            updatedAt: self.updatedAt(daysAgo: 30),
            status: "failed")
        let running = self.row(
            key: "agent:main:imessage:direct:+12025550133",
            channel: "imessage",
            updatedAt: self.updatedAt(daysAgo: 30),
            status: "running")

        let sections = SidebarGrouper.sections(
            [inbox, unread, failed, running],
            mainSessionKey: self.mainKey,
            now: self.now)

        XCTAssertEqual(
            sections.first(where: { $0.category == .main })?.sessions.map(\.key).sorted(),
            [inbox, unread, failed, running].map(\.key).sorted())
        XCTAssertNil(sections.first(where: { $0.category == .chat }))
    }

    func testSessionRowLenientlyDecodesNewGatewayFields() throws {
        let data = Data(#"{"key":"agent:main:subagent:abc","kind":"direct","status":"timeout","abortedLastRun":true,"spawnedBy":"agent:main:imessage:direct:+1","label":"Build Cast","subagentRole":"worker","unread":42}"#.utf8)
        let session = try JSONDecoder().decode(SessionRow.self, from: data)

        XCTAssertEqual(session.kind, "direct")
        XCTAssertEqual(session.status, "timeout")
        XCTAssertEqual(session.abortedLastRun, true)
        XCTAssertEqual(session.spawnedBy, "agent:main:imessage:direct:+1")
        XCTAssertEqual(session.label, "Build Cast")
        XCTAssertEqual(session.subagentRole, "worker")
        XCTAssertNil(session.unread)
    }
}
