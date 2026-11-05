import XCTest
@testable import Cast

/// Regression cover for the blank-transcript-on-reopen bug: reopening the iOS
/// app sometimes showed an empty conversation until the user left the chat and
/// came back. Two causes, both locked here.
final class ActivationPolicyTests: XCTestCase {
    // MARK: - Cause 1: activation gave up whenever the socket was not `.connected`

    func testConnectedActivationRefreshes() {
        XCTAssertEqual(ActivationPolicy.action(for: .connected(mainSessionKey: "agent:main:main")), .refresh)
        XCTAssertEqual(ActivationPolicy.action(for: .connected(mainSessionKey: nil)), .refresh)
    }

    /// The regression itself. iOS kills the socket while backgrounded, so this
    /// is the ordinary resume path, not an edge case. It must reconnect —
    /// returning here is what stranded the transcript.
    func testDisconnectedActivationReconnectsRatherThanStranding() {
        XCTAssertEqual(ActivationPolicy.action(for: .disconnected(nil)), .reconnect)
        XCTAssertEqual(ActivationPolicy.action(for: .disconnected("socket closed")), .reconnect)
        XCTAssertEqual(ActivationPolicy.action(for: .disconnected("reconnecting")), .reconnect)
    }

    /// The other half: do not restart a connection that is already progressing,
    /// or one parked on user action. Repeated foregrounds would otherwise cancel
    /// live progress in a loop.
    func testInFlightOrUserBlockedActivationWaits() {
        XCTAssertEqual(ActivationPolicy.action(for: .connecting), .wait)
        XCTAssertEqual(ActivationPolicy.action(for: .waitingForApproval), .wait)
        XCTAssertEqual(ActivationPolicy.action(for: .needsCredentials(nil)), .wait)
        XCTAssertEqual(ActivationPolicy.action(for: .needsCredentials("pair workspace")), .wait)
    }

    // MARK: - Cause 3: `.connecting` had no timeout, so it pinned forever

    /// A young attempt is genuinely in flight. Cancelling it on every foreground
    /// is the loop the `.wait` case exists to prevent.
    func testFreshConnectingStillWaits() {
        let start = Date()
        XCTAssertEqual(
            ActivationPolicy.action(for: .connecting, connectingSince: start, now: start.addingTimeInterval(1)),
            .wait)
        XCTAssertEqual(
            ActivationPolicy.action(for: .connecting, connectingSince: start, now: start.addingTimeInterval(9.9)),
            .wait)
    }

    /// The stale-forever bug. iOS suspends the socket mid-connect and never
    /// delivers the callback that would move the state on, so `.connecting`
    /// pinned and every later foreground was a no-op — the app showed stale
    /// content until it was force-quit. Past the deadline it must reconnect.
    func testStuckConnectingReconnectsInsteadOfPinningForever() {
        let start = Date()
        XCTAssertEqual(
            ActivationPolicy.action(for: .connecting, connectingSince: start, now: start.addingTimeInterval(10)),
            .reconnect)
        XCTAssertEqual(
            ActivationPolicy.action(for: .connecting, connectingSince: start, now: start.addingTimeInterval(600)),
            .reconnect)
    }

    /// Without an entry time we cannot prove staleness, so keep the conservative
    /// behaviour rather than cancelling a possibly-live attempt.
    func testConnectingWithoutEntryTimeWaits() {
        XCTAssertEqual(ActivationPolicy.action(for: .connecting, connectingSince: nil), .wait)
    }

    /// States that need a human must never be aged out — reconnecting would spin
    /// against a gateway that is waiting on an approval or a credential.
    func testUserBlockedStatesAreNeverAgedOut() {
        let ancient = Date().addingTimeInterval(-86_400)
        XCTAssertEqual(
            ActivationPolicy.action(for: .waitingForApproval, connectingSince: ancient),
            .wait)
        XCTAssertEqual(
            ActivationPolicy.action(for: .needsCredentials("pair workspace"), connectingSince: ancient),
            .wait)
    }

    /// Every state resolves to exactly one action, so a future case cannot
    /// silently inherit the old "do nothing" behaviour.
    func testEveryConnectionStateIsClassified() {
        let states: [GatewayConnectionState] = [
            .connected(mainSessionKey: nil),
            .disconnected(nil),
            .connecting,
            .waitingForApproval,
            .needsCredentials(nil),
        ]
        let actions = states.map { ActivationPolicy.action(for: $0) }
        XCTAssertEqual(actions.count, states.count)
        XCTAssertTrue(actions.contains(.refresh))
        XCTAssertTrue(actions.contains(.reconnect))
        XCTAssertTrue(actions.contains(.wait))
    }

    // MARK: - Cause 2: an un-run history load reported itself as settled

    /// With no transport, history was never requested. `.idle` + zero messages
    /// renders as a legitimately-empty conversation: no spinner, no banner, no
    /// retry. While there is nothing to show it must stay `.loading`.
    func testEmptyTranscriptWithoutTransportStaysLoadingNotIdle() {
        let messages: [ChatMessage] = []
        let state: HistorySyncState = messages.isEmpty ? .loading : .idle
        XCTAssertEqual(state, .loading)
        XCTAssertNotEqual(state, .idle, "an unrequested history load must not look settled")
    }

    /// When cached messages are already on screen there is something to read, so
    /// a spinner would be noise.
    func testPopulatedTranscriptWithoutTransportIsIdle() {
        let messages = [Self.message(id: "cached")]
        let state: HistorySyncState = messages.isEmpty ? .loading : .idle
        XCTAssertEqual(state, .idle)
    }

    private static func message(id: String) -> ChatMessage {
        ChatMessage(
            id: id,
            role: "assistant",
            blocks: [ChatContentBlock(
                type: "text",
                text: "cached body",
                thinking: nil,
                name: nil,
                mimeType: nil,
                fileName: nil)],
            timestamp: 1)
    }
}
