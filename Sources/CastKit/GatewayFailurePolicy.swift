import Foundation

public struct GatewayTimeoutError: Error, LocalizedError, Equatable, Sendable {
    public let context: String

    public init(context: String) {
        self.context = context
    }

    public var errorDescription: String? { "timed out: \(self.context)" }
}

public enum GatewayFailurePolicy {
    public static let maximumAutomaticHistoryRetries = 3
    public static let messageSendAlert = "Your message couldn’t be sent. Check the connection and try again."
    public static let agentRunAlert = "The agent couldn’t finish, and the gateway did not report a specific cause. Check the conversation and Needs you before retrying; some actions may already have completed. Cast has not automatically resent this request."

    /// One, three, then eight seconds. A single scheduled task in ChatStore
    /// coalesces all reload triggers during each delay.
    public static func historyRetryDelayNanoseconds(attempt: Int) -> UInt64? {
        let seconds = [1, 3, 8]
        guard attempt > 0, attempt <= seconds.count else { return nil }
        return UInt64(seconds[attempt - 1]) * 1_000_000_000
    }

    /// Matches the per-session `sessions.messages.subscribe` ladder: three tries total.
    public static let maximumSessionsSubscribeAttempts = 3

    /// Half a second, then one second — the same `attempt × 500 ms` shape the per-session
    /// subscribe uses. `nil` after the last attempt that is allowed to be followed by a
    /// wait, which is what bounds the ladder: there is no delay to take, so it ends.
    public static func sessionsSubscribeRetryDelayNanoseconds(attempt: Int) -> UInt64? {
        guard attempt > 0, attempt < self.maximumSessionsSubscribeAttempts else { return nil }
        return UInt64(attempt) * 500_000_000
    }

    public static func isRecoverable(_ error: Error) -> Bool {
        if error is GatewayTimeoutError { return true }
        if let urlError = error as? URLError {
            return [
                .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
                .callIsActive, .dataNotAllowed,
            ].contains(urlError.code)
        }
        if let gateway = error as? GatewayRequestError {
            let code = (gateway.code ?? "").uppercased()
            return code.contains("TIMEOUT")
                || code.contains("UNAVAILABLE")
                || code.contains("RATE_LIMIT")
                || code.contains("OVERLOADED")
                || gateway.retryAfterMs != nil
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }

    /// A gateway `aborted` terminal can carry the last tool-validation summary even when
    /// that diagnostic was internal to the run. Only a true terminal run error should
    /// interrupt the user, and its raw gateway detail must stay out of the modal.
    ///
    /// `runAlreadyAnswered` guards the late-terminal race: once the turn has produced a
    /// valid answer, a straggling error/aborted/timeout terminal for that same run must not
    /// raise a blocking modal over a result the user can already see. A run that never
    /// reached a successful terminal still surfaces its failure.
    ///
    /// `errorKind` is the gateway's normalized failure category
    /// (`refusal | timeout | rate_limit | context_length | unknown`). Each gets a message
    /// that tells the operator what to actually do; an unrecognized kind falls back to the
    /// generic alert rather than being dropped.
    public static func agentRunAlertMessage(
        for state: String?,
        errorKind: String? = nil,
        errorDetail: GatewayChatErrorDetail? = nil,
        runAlreadyAnswered: Bool) -> String?
    {
        guard !runAlreadyAnswered, state == "error" else { return nil }
        return RunFailureCategory.resolve(kind: errorKind, detail: errorDetail).message
    }

    /// Recognizable anchor: ChatStore pairs this exact message with a one-tap
    /// `sessions.compact` offer, turning the one recoverable failure kind into a fix.
    public static let contextLengthAlert =
        "This conversation no longer fits the model’s context window. Compact it to continue."
}

public enum HistorySyncState: Equatable, Sendable {
    case idle
    case loading
    case stale(message: String, retryScheduled: Bool)
}

/// What a foreground/activation should do, given the connection state observed
/// at resume. Split out from `ChatStore` so the decision is testable without a
/// live socket.
public enum ActivationAction: Equatable, Sendable {
    /// Transport is believed live: reassert subscriptions and reload history.
    case refresh
    /// No attempt in flight; reconnect, then reload once connected.
    case reconnect
    /// An attempt is already running, or the user must act. Do nothing.
    case wait
}

public enum ActivationPolicy {
    /// A connect attempt that has been in flight this long when the app comes back
    /// is not in flight at all. Healthy connects settle in well under a second; the
    /// only thing that holds `.connecting` for longer is a socket iOS already tore
    /// down without telling us.
    public static let connectingStaleAfter: TimeInterval = 10

    /// iOS tears sockets down in the background without always delivering a
    /// disconnect callback, so a resume that is not `.connected` is routine.
    /// Treating it as "do nothing" strands the open transcript on a blank view,
    /// because nothing else re-drives history on foreground.
    ///
    /// `.connecting` is the sharp edge. It reads as "an attempt is already
    /// running, leave it alone", but a suspended socket never delivers the
    /// callback that would move it on, and nothing times it out. The state
    /// then pins forever and every later foreground is a no-op, so the app
    /// shows stale content until it is force-quit. Age the state out: past
    /// `connectingStaleAfter` the attempt is presumed dead and we reconnect.
    ///
    /// `.waitingForApproval` and `.needsCredentials` still wait unconditionally —
    /// those genuinely need a human, and reconnecting would spin.
    public static func action(
        for state: GatewayConnectionState,
        connectingSince: Date? = nil,
        now: Date = Date(),
        staleAfter: TimeInterval = ActivationPolicy.connectingStaleAfter) -> ActivationAction
    {
        switch state {
        case .connected: .refresh
        case .disconnected: .reconnect
        case .connecting:
            // No entry time recorded means we cannot prove it is stale, so keep the
            // conservative behaviour rather than cancelling a live attempt.
            if let connectingSince, now.timeIntervalSince(connectingSince) >= staleAfter {
                .reconnect
            } else {
                .wait
            }
        case .waitingForApproval, .needsCredentials: .wait
        }
    }
}

/// Bounded retry ladder for a subscribe RPC.
///
/// `sessions.subscribe` was a bare `try?`: a subscribe lost to a reconnect race left the
/// sidebar unrouted with no retry, no banner, and no symptom until relaunch. This expresses
/// the per-session subscribe's fixed-attempt/short-backoff shape as a value, so the schedule
/// and — more importantly — its termination are testable without a socket.
public struct BoundedSubscribeRetry: Sendable {
    public let attempts: Int
    public let delayNanoseconds: @Sendable (Int) -> UInt64?

    /// The ladder used for the workspace-wide `sessions.subscribe`.
    public static let sessions = BoundedSubscribeRetry(
        attempts: GatewayFailurePolicy.maximumSessionsSubscribeAttempts,
        delayNanoseconds: { attempt in
            GatewayFailurePolicy.sessionsSubscribeRetryDelayNanoseconds(attempt: attempt)
        })

    public init(attempts: Int, delayNanoseconds: @escaping @Sendable (Int) -> UInt64?) {
        self.attempts = max(1, attempts)
        self.delayNanoseconds = delayNanoseconds
    }

    /// Runs `perform` (1-based attempt number) until it succeeds or the ladder is spent.
    ///
    /// `isCurrent` is checked around every wait so the ladder abandons work that stopped
    /// mattering — a swapped client, a background suspend, a cancelled task — rather than
    /// finishing a schedule nobody is waiting on. Main-actor bound because both the store
    /// state it guards and its callers are.
    @MainActor
    @discardableResult
    public func run(
        isCurrent: () -> Bool = { true },
        sleep: (UInt64) async -> Void = { _ = try? await Task.sleep(nanoseconds: $0) },
        perform: (Int) async -> Bool) async -> Bool
    {
        for attempt in 1 ... self.attempts {
            if await perform(attempt) { return true }
            guard isCurrent(), let delay = self.delayNanoseconds(attempt) else { return false }
            await sleep(delay)
            guard isCurrent() else { return false }
        }
        return false
    }
}
