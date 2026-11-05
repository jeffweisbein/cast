// Cast — sidebar taxonomy: deterministic session classification, naming, and grouping.
// Gateway RPC rows carry typed status/provenance fields; key matching remains as a compatibility
// fallback for older gateways. Two vocabularies are fixed by the gateway and must not be widened
// here without checking it first:
//   `status` is "running" | "done" | "failed" | "killed" | "timeout" (SessionRunStatus,
//   src/gateway/session-utils.types.ts) — note "failed" is what an ordinary errored run reports.
//   `kind` is only "direct" | "group" | "global" | "unknown" (classifySessionKey), so it can never
//   say "cron" or "spawn-child"; those are read off the session key instead.
import Foundation

public enum SessionCategory: String, CaseIterable, Sendable {
    case main
    case activity
    case chat
    case task
    case automation
}

/// Read-only operational state derived from fields already returned by `sessions.list`.
/// This deliberately does not imply that Cast can mutate task or cron state.
public enum SessionOperationalStatus: String, CaseIterable, Sendable, Equatable {
    case needsAttention
    case running
    case failed
    case done
    case healthy
    case idle

    public var label: String {
        switch self {
        case .needsAttention: return "Needs attention"
        case .running: return "Running"
        case .failed: return "Failed"
        case .done: return "Done"
        case .healthy: return "Healthy"
        case .idle: return "Idle"
        }
    }
}

public struct SessionDomainSummary: Sendable, Equatable {
    public let total: Int
    public let needsAttention: Int
    public let running: Int
    public let failed: Int
    public let done: Int
    public let healthy: Int

    public init(statuses: [SessionOperationalStatus]) {
        self.total = statuses.count
        self.needsAttention = statuses.count(where: { $0 == .needsAttention })
        self.running = statuses.count(where: { $0 == .running })
        self.failed = statuses.count(where: { $0 == .failed })
        self.done = statuses.count(where: { $0 == .done })
        self.healthy = statuses.count(where: { $0 == .healthy })
    }
}

public struct SidebarActivitySummary: Sendable, Equatable {
    public let running: Int
    public let failed: Int
    public let doneToday: Int

    public init(running: Int, failed: Int, doneToday: Int) {
        self.running = running
        self.failed = failed
        self.doneToday = doneToday
    }

    public var text: String {
        var parts: [String] = []
        if self.running > 0 { parts.append("\(self.running) running") }
        if self.failed > 0 { parts.append("\(self.failed) failed") }
        if self.doneToday > 0 { parts.append("\(self.doneToday) done today") }
        return parts.isEmpty ? "No recent activity" : parts.joined(separator: " · ")
    }
}

/// Finer-grained visual identity than SessionCategory: each accent maps to one SF Symbol
/// + tint so the sidebar reads by color without turning into rainbow rows.
public enum SessionAccent: String, CaseIterable, Sendable {
    case spark      // the agent's main session — orange
    case channel    // human channel chats (iMessage/Telegram/…) — blue
    case task       // subagent tasks — purple
    case cron       // scheduled automation — teal
    case dreaming   // dreaming jobs — indigo
    case terminal   // scratch/dev sessions — gray
}

public struct SidebarSection: Identifiable, Sendable, Equatable {
    public let category: SessionCategory
    public let title: String
    public let sessions: [SessionRow]

    public var id: String { self.category.rawValue }
}

public enum SidebarGrouper {
    static let fallbackMainKey = "agent:main:main"

    // MARK: - Classification

    public static func category(for session: SessionRow, mainSessionKey: String?) -> SessionCategory {
        let key = session.key
        if key.contains(":cron:") { return .automation }
        if self.tailSegment(of: key).hasPrefix("dreaming-") { return .automation }
        if key.contains(":subagent:") { return .task }
        // Human channel conversations: 1:1, group, or a Slack/Discord channel. These are
        // conversations the operator is part of, not machine work, so they belong in Chats — the
        // Work zones drop anything quiet for 24h, which would make a slow thread disappear from
        // the sidebar. The gateway collapses `:group:` and `:channel:` into kind "group"
        // (openclaw src/gateway/session-utils.ts classifySessionKey), so both are handled here.
        if self.isHumanConversation(key) { return .main }
        if SessionKeyMatcher.matches(key, mainSessionKey ?? self.fallbackMainKey) { return .main }
        return .chat
    }

    public static func accent(for session: SessionRow, mainSessionKey: String?) -> SessionAccent {
        let key = session.key
        if key.contains(":cron:") { return .cron }
        if self.tailSegment(of: key).hasPrefix("dreaming-") { return .dreaming }
        if key.contains(":subagent:") { return .task }
        if self.isHumanConversation(key) { return .channel }
        if SessionKeyMatcher.matches(key, mainSessionKey ?? self.fallbackMainKey) { return .spark }
        return session.channel == nil ? .terminal : .channel
    }

    /// A conversation with people in it, as opposed to machine work. The gateway's own
    /// `classifySessionKey` treats `:group:` and `:channel:` identically (both become kind
    /// "group"), so Cast must too, or a quiet Slack/Discord channel silently drops out of the
    /// sidebar after 24h the way group chats used to.
    static func isHumanConversation(_ key: String) -> Bool {
        key.contains(":direct:") || key.contains(":group:") || key.contains(":channel:")
    }

    /// Three fixed zones: human chats, one activity strip, and recent machine work.
    /// Local pins precede Agent Inbox; otherwise it stays first regardless of operational state.
    public static func sections(
        _ sessions: [SessionRow],
        mainSessionKey: String?,
        now: Date,
        pinnedSessionKeys: Set<String> = []
    ) -> [SidebarSection] {
        func isPinned(_ session: SessionRow) -> Bool {
            pinnedSessionKeys.contains { SessionKeyMatcher.matches($0, session.key) }
        }
        var buckets: [SessionCategory: [SessionRow]] = [:]
        for session in sessions {
            if isPinned(session) || self.isAgentInbox(session, mainSessionKey: mainSessionKey) {
                buckets[.main, default: []].append(session)
                continue
            }
            let destination = self.category(for: session, mainSessionKey: mainSessionKey)
            if destination != .main, !self.isLiveOrRecent(session, now: now) { continue }
            if destination == .main, self.isStaleChat(session, mainSessionKey: mainSessionKey, now: now) {
                buckets[.chat, default: []].append(session)
                continue
            }
            buckets[destination, default: []].append(session)
        }
        if let main = buckets[.main] {
            buckets[.main] = main.sorted { lhs, rhs in
                if isPinned(lhs) != isPinned(rhs) { return isPinned(lhs) }
                let lhsInbox = self.isAgentInbox(lhs, mainSessionKey: mainSessionKey) ? 0 : 1
                let rhsInbox = self.isAgentInbox(rhs, mainSessionKey: mainSessionKey) ? 0 : 1
                if lhsInbox != rhsInbox { return lhsInbox < rhsInbox }
                if lhs.updatedAt != rhs.updatedAt { return (lhs.updatedAt ?? 0) > (rhs.updatedAt ?? 0) }
                return lhs.key < rhs.key
            }
        }
        for category in [SessionCategory.task, .automation, .chat] {
            buckets[category]?.sort { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return (lhs.updatedAt ?? 0) > (rhs.updatedAt ?? 0) }
                return lhs.key < rhs.key
            }
        }
        return [
            SidebarSection(category: .main, title: "Chats", sessions: buckets[.main] ?? []),
            SidebarSection(category: .activity, title: "Activity", sessions: []),
            SidebarSection(category: .task, title: "Tasks", sessions: buckets[.task] ?? []),
            SidebarSection(category: .automation, title: "Automation", sessions: buckets[.automation] ?? []),
            SidebarSection(category: .chat, title: "Other sessions", sessions: buckets[.chat] ?? []),
        ].filter { $0.category == .main || $0.category == .activity || !$0.sessions.isEmpty }
    }

    // MARK: - Operational status

    public static func isAgentInbox(_ session: SessionRow, mainSessionKey: String?) -> Bool {
        SessionKeyMatcher.matches(session.key, mainSessionKey ?? self.fallbackMainKey)
    }

    public static func operationalStatus(
        for session: SessionRow,
        mainSessionKey: String?,
        now: Date,
        acknowledgedFailures: Set<SessionAttentionIdentifier> = []
    ) -> SessionOperationalStatus {
        let normalizedStatus = session.status?.lowercased()
        if normalizedStatus == "done" { return .done }

        let signal = self.failureSignal(for: session)
        let running = normalizedStatus == "running" || session.hasActiveRun == true
        // `abortedLastRun` describes the PREVIOUS run, so it must never outrank live state: a
        // session running right now is running, whatever its last run did. A typed failure status
        // does describe the current run, so it keeps its precedence.
        let failed = signal.status || (signal.abortedOnly && !running)
        let acknowledged = self.isFailureAcknowledged(
            session,
            signal: signal,
            acknowledgedFailures: acknowledgedFailures)
        let recent = self.isRecent(session, now: now)
        if recent && (session.isUnread || (failed && !acknowledged)) {
            return .needsAttention
        }
        if failed { return .failed }
        if running { return .running }
        return self.category(for: session, mainSessionKey: mainSessionKey) == .automation ? .healthy : .idle
    }

    public static func requiresOperatorAttention(
        _ session: SessionRow,
        mainSessionKey: String?,
        now: Date,
        acknowledgedFailures: Set<SessionAttentionIdentifier> = []
    ) -> Bool {
        let status = self.operationalStatus(
            for: session,
            mainSessionKey: mainSessionKey,
            now: now,
            acknowledgedFailures: acknowledgedFailures)
        return status == .needsAttention
    }

    public static func summary(
        for sessions: [SessionRow],
        mainSessionKey: String?,
        now: Date,
        acknowledgedFailures: Set<SessionAttentionIdentifier> = []
    ) -> SessionDomainSummary {
        SessionDomainSummary(statuses: sessions.map {
            self.operationalStatus(
                for: $0,
                mainSessionKey: mainSessionKey,
                now: now,
                acknowledgedFailures: acknowledgedFailures)
        })
    }

    /// The two very different failure signals a row can carry.
    ///
    /// `status` is the gateway's verdict on the run that just ended and is replaced by the next
    /// run. `abortedLastRun` is sticky persisted state about the *previous* run that stays true
    /// until a run succeeds, so it needs weaker precedence and stickier acknowledgement.
    struct FailureSignal: Equatable {
        /// A typed terminal failure (or, on gateways that predate `status`, an actionable preview).
        let status: Bool
        /// Only `abortedLastRun` is set — the gateway is not reporting a failed run.
        let abortedOnly: Bool

        var any: Bool { self.status || self.abortedOnly }
    }

    static func failureSignal(for session: SessionRow) -> FailureSignal {
        let normalizedStatus = session.status?.lowercased()
        // "failed" is the status an ordinary errored run reports; "killed" needs an explicit kill
        // and "timeout" needs the clock to expire. Omitting it silently rendered crashes as idle.
        let status = normalizedStatus == "killed"
            || normalizedStatus == "timeout"
            || normalizedStatus == "failed"
            || (normalizedStatus == nil && self.hasActionablePreview(session.lastMessagePreview))
        return FailureSignal(status: status, abortedOnly: !status && session.abortedLastRun == true)
    }

    /// A typed failure is acknowledged for one exact observation, so a later `updatedAt` re-raises
    /// it — that is a genuinely new failure. A bare `abortedLastRun` is sticky state the gateway
    /// keeps re-sending, while every unrelated message mints a new `updatedAt`; keying its
    /// acknowledgement on the timestamp meant a dismissed self-inflicted abort came back on every
    /// turn, forever. So a bare abort is dismissed for the session, not for one timestamp.
    static func isFailureAcknowledged(
        _ session: SessionRow,
        signal: FailureSignal,
        acknowledgedFailures: Set<SessionAttentionIdentifier>
    ) -> Bool {
        if signal.abortedOnly {
            return acknowledgedFailures.contains(where: { $0.sessionKey == session.key })
        }
        return SessionAttentionIdentifier(
            sessionKey: session.key,
            updatedAt: session.updatedAt).map(acknowledgedFailures.contains) ?? false
    }

    public static func hasFailureSignal(_ session: SessionRow) -> Bool {
        self.failureSignal(for: session).any
    }

    public static func activitySummary(
        for sessions: [SessionRow],
        mainSessionKey: String?,
        now: Date,
        acknowledgedFailures: Set<SessionAttentionIdentifier> = []
    ) -> SidebarActivitySummary {
        let work = sessions.filter {
            let category = self.category(for: $0, mainSessionKey: mainSessionKey)
            return category == .task || category == .automation || category == .chat
        }
        let running = work.count(where: {
            $0.status?.lowercased() == "running" || $0.hasActiveRun == true
        })
        let failed = work.count(where: { session in
            guard session.status?.lowercased() != "done", self.isRecent(session, now: now) else {
                return false
            }
            let signal = self.failureSignal(for: session)
            guard signal.any else { return false }
            return !self.isFailureAcknowledged(
                session,
                signal: signal,
                acknowledgedFailures: acknowledgedFailures)
        })
        let doneToday = work.count(where: {
            $0.status?.lowercased() == "done" && self.isRecent($0, now: now)
        })
        return SidebarActivitySummary(running: running, failed: failed, doneToday: doneToday)
    }

    public static func activitySessions(
        _ sessions: [SessionRow],
        mainSessionKey: String?
    ) -> [SessionRow] {
        sessions.filter {
            let category = self.category(for: $0, mainSessionKey: mainSessionKey)
            return category == .task || category == .automation || category == .chat
        }.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return (lhs.updatedAt ?? 0) > (rhs.updatedAt ?? 0) }
            return lhs.key < rhs.key
        }
    }

    static func isLiveOrRecent(_ session: SessionRow, now: Date) -> Bool {
        session.status?.lowercased() == "running"
            || session.hasActiveRun == true
            || self.isRecent(session, now: now)
    }

    /// How long a human chat may sit silent before it stops holding a row in Chats. Chats is the
    /// one zone with no recency filter, so a one-off direct session used to pin a row there
    /// forever. Aging only re-buckets a row into "Other sessions" — nothing is ever dropped.
    static let chatAgingWindow: TimeInterval = 14 * 24 * 60 * 60

    /// Anything the operator might still be waiting on stays in Chats regardless of age: the
    /// agent's own session, live work, unread rows, and rows carrying a failure signal.
    static func isStaleChat(_ session: SessionRow, mainSessionKey: String?, now: Date) -> Bool {
        if SessionKeyMatcher.matches(session.key, mainSessionKey ?? self.fallbackMainKey) { return false }
        if self.isLiveOrRecent(session, now: now) { return false }
        if session.isUnread || self.hasFailureSignal(session) { return false }
        guard let updatedDate = session.updatedDate else { return false }
        return now.timeIntervalSince(updatedDate) > self.chatAgingWindow
    }

    /// A timestamp in the future is by definition recent. The gateway host stamps `updatedAt` from
    /// its own clock, so a fleet host running seconds ahead of this Mac used to classify every
    /// just-touched session as not-recent: live rows dropped out of the Work zones and a fresh
    /// failure quietly downgraded from "Needs attention" to "Failed". Only staleness is a reason
    /// to hide a row, so age is clamped at the old end only.
    static func isRecent(_ session: SessionRow, now: Date) -> Bool {
        guard let updatedDate = session.updatedDate else { return false }
        return now.timeIntervalSince(updatedDate) <= 24 * 60 * 60
    }

    /// Compatibility fallback for gateways that predate typed status fields.
    static func hasActionablePreview(_ preview: String?) -> Bool {
        guard let preview else { return false }
        let normalized = preview.lowercased()
        return [
            "needs attention",
            "action required",
            "approval required",
            "failed",
            "failure",
            "fatal error",
        ].contains(where: normalized.contains)
    }

    // MARK: - Naming

    public static func displayTitle(for session: SessionRow, mainSessionKey: String? = nil) -> String {
        let key = session.key
        let raw = self.rawName(for: session)
        if key.contains(":cron:") {
            if let raw { return self.humanize(self.stripCronPrefix(raw)) }
            return key.contains(":run:") ? "Cron Run" : "Cron Job"
        }
        let tail = self.tailSegment(of: key)
        if tail.hasPrefix("dreaming-") {
            return self.humanize(self.stripTrailingID(tail))
        }
        if key.contains(":subagent:") {
            if let raw, !raw.hasPrefix("[Subagent Context]") { return raw }
            return "Subagent Task"
        }
        if key.contains(":direct:"), let address = key.components(separatedBy: ":direct:").last, !address.isEmpty {
            // Only a deliberately set `label` may outrank the address. `displayName` cannot be
            // trusted here: this gateway returns the connecting client's name ("Cast") for one
            // direct row and the channel-prefixed key ("imessage:+1...") for another, and titling
            // a person's chat after the app they were last read in is worse than a phone number.
            if let label = session.label, !label.isEmpty, label != address { return label }
            return self.formatAddress(address)
        }
        if SessionKeyMatcher.matches(key, mainSessionKey ?? self.fallbackMainKey) { return "Agent Inbox" }
        if let raw { return raw }
        if tail == "main", let agent = SessionKeyMatcher.agentID(from: key) { return self.humanize(agent) }
        return self.humanize(self.stripTrailingID(tail))
    }

    /// Small secondary label carrying what used to be raw key noise ("Cron", "Subagent",
    /// the channel name). Nil when the title alone is enough.
    /// Two agents talking to the same person produce two rows with the same title, so a row
    /// belonging to any agent other than the default one names its agent here.
    public static func subtitle(
        for session: SessionRow,
        mainSessionKey: String? = nil,
        allSessions: [SessionRow] = []
    ) -> String? {
        let base = self.baseSubtitle(for: session, mainSessionKey: mainSessionKey, allSessions: allSessions)
        guard let agent = SessionKeyMatcher.agentID(from: session.key),
              agent != SessionKeyMatcher.agentID(from: mainSessionKey ?? self.fallbackMainKey)
        else {
            return base
        }
        guard let base else { return agent }
        return "\(base) · \(agent)"
    }

    static func baseSubtitle(
        for session: SessionRow,
        mainSessionKey: String?,
        allSessions: [SessionRow]
    ) -> String? {
        let key = session.key
        if key.contains(":cron:") { return "Cron" }
        let tail = self.tailSegment(of: key)
        if tail.hasPrefix("dreaming-") { return "Dreaming" }
        if key.contains(":subagent:") {
            if let origin = self.originTitle(
                spawnedBy: session.spawnedBy,
                allSessions: allSessions,
                mainSessionKey: mainSessionKey)
            {
                return "from \(origin)"
            }
            return "Subagent"
        }
        if let channel = session.channel, tail.hasPrefix("\(channel):") { return self.channelName(channel) }
        if SessionKeyMatcher.matches(key, mainSessionKey ?? self.fallbackMainKey) { return "Main agent session" }
        if tail == "main" { return "Agent session" }
        return nil
    }

    /// Rewrites machine noise previews into quiet human labels; passes real text through.
    public static func cleanPreview(_ preview: String?) -> String? {
        guard let raw = preview?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw == "HEARTBEAT_OK" { return "Heartbeat OK" }
        if raw.hasPrefix("[OpenClaw heartbeat poll]") { return "Heartbeat poll" }
        if raw.hasPrefix("[Subagent Context]") { return "Task briefing received" }
        return raw.replacingOccurrences(of: "\n", with: " ")
    }

    public static func matchesSearch(_ session: SessionRow, query: String, mainSessionKey: String?) -> Bool {
        if session.title.localizedCaseInsensitiveContains(query) { return true }
        if self.displayTitle(for: session, mainSessionKey: mainSessionKey).localizedCaseInsensitiveContains(query) { return true }
        if session.lastMessagePreview?.localizedCaseInsensitiveContains(query) == true { return true }
        return session.key.localizedCaseInsensitiveContains(query)
    }

    // MARK: - Helpers

    static func tailSegment(of key: String) -> String {
        let parts = key.split(separator: ":", maxSplits: 2).map(String.init)
        return parts.count == 3 && parts[0] == "agent" ? parts[2] : key
    }

    static func rawName(for session: SessionRow) -> String? {
        if let name = session.displayName, !name.isEmpty { return name }
        if let label = session.label, !label.isEmpty { return label }
        if let derived = session.derivedTitle, !derived.isEmpty { return derived }
        return nil
    }

    static func originTitle(
        spawnedBy: String?,
        allSessions: [SessionRow],
        mainSessionKey: String?
    ) -> String? {
        guard let spawnedBy, !spawnedBy.isEmpty else { return nil }
        if SessionKeyMatcher.matches(spawnedBy, mainSessionKey ?? self.fallbackMainKey) {
            return "Agent Inbox"
        }
        let parent = allSessions.first(where: {
            SessionKeyMatcher.matches($0.key, spawnedBy)
        })
        let parentKey = parent?.key ?? spawnedBy
        for channel in ["imessage", "whatsapp", "telegram", "discord", "signal", "slack"]
        where parentKey.contains(":\(channel):direct:")
        {
            return self.channelName(channel)
        }
        guard let parent else { return nil }
        return self.displayTitle(for: parent, mainSessionKey: mainSessionKey)
    }

    static func stripCronPrefix(_ name: String) -> String {
        guard name.lowercased().hasPrefix("cron:") else { return name }
        return String(name.dropFirst("cron:".count)).trimmingCharacters(in: .whitespaces)
    }

    /// "heartbeat-reaper" → "Heartbeat Reaper"; words already carrying uppercase
    /// (OCA, iMessage) are left untouched.
    static func humanize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word -> String in
                let text = String(word)
                if text.contains(where: \.isUppercase) { return text }
                return text.prefix(1).uppercased() + text.dropFirst()
            }
            .joined(separator: " ")
    }

    /// Drops trailing hex/uuid-ish id segments: "dreaming-narrative-deep-ed4c370462d8"
    /// → "dreaming-narrative-deep".
    static func stripTrailingID(_ raw: String) -> String {
        var parts = raw.split(separator: "-").map(String.init)
        while parts.count > 1, let last = parts.last, last.count >= 8, last.allSatisfy(\.isHexDigit) {
            parts.removeLast()
        }
        return parts.joined(separator: "-")
    }

    static func formatAddress(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return trimmed }
        if digits.count == 11, digits.hasPrefix("1") {
            return "+1 (\(digits.dropFirst().prefix(3))) \(digits.dropFirst(4).prefix(3))-\(digits.suffix(4))"
        }
        if digits.count == 10 {
            return "(\(digits.prefix(3))) \(digits.dropFirst(3).prefix(3))-\(digits.suffix(4))"
        }
        return trimmed
    }

    static func channelName(_ channel: String) -> String {
        switch channel {
        case "imessage": return "iMessage"
        case "whatsapp": return "WhatsApp"
        case "telegram": return "Telegram"
        case "discord": return "Discord"
        case "signal": return "Signal"
        case "slack": return "Slack"
        default: return channel.prefix(1).uppercased() + channel.dropFirst()
        }
    }
}
