// Cast — gateway WS client, protocol v4. Mirrors OpenClawKit GatewayChannel (MIT, © 2025 Peter
// Steinberger — see ATTRIBUTION.md), updated for v4 and Cast's Keychain auth ladder.
import Foundation
import OSLog

public enum GatewayConnectionState: Equatable, Sendable {
    case disconnected(String?)
    case connecting
    case waitingForApproval
    case needsCredentials(String?)
    case connected(mainSessionKey: String?)
}

public struct GatewayClientConfig: Sendable {
    public var url: URL
    public var workspaceID: String
    public var credential: GatewayCredential
    public var deviceCredentialProvider: @Sendable () -> GatewayCredential?
    public var onDeviceToken: @Sendable (String) -> Void
    public var clientId: String
    public var platform: String
    public var deviceFamily: String
    public var displayName: String
    public var secretEntryEnabled: Bool
    public var questionsEnabled: Bool

    public init(
        url: URL,
        workspaceID: String,
        credential: GatewayCredential,
        deviceCredentialProvider: @escaping @Sendable () -> GatewayCredential?,
        onDeviceToken: @escaping @Sendable (String) -> Void,
        clientId: String,
        platform: String,
        deviceFamily: String,
        displayName: String,
        secretEntryEnabled: Bool = false,
        questionsEnabled: Bool = false)
    {
        self.url = url
        self.workspaceID = workspaceID
        self.credential = credential
        self.deviceCredentialProvider = deviceCredentialProvider
        self.onDeviceToken = onDeviceToken
        self.clientId = clientId
        self.platform = platform
        self.deviceFamily = deviceFamily
        self.displayName = displayName
        self.secretEntryEnabled = secretEntryEnabled
        self.questionsEnabled = questionsEnabled
    }
}

public actor GatewayClient {
    private let logger = Logger(subsystem: "com.besttechie.cast", category: "gateway")
    private let config: GatewayClientConfig
    private let onEvent: @Sendable (EventFrame) -> Void
    private let onState: @Sendable (GatewayConnectionState) -> Void

    private let session: URLSession = .init(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var pending: [String: CheckedContinuation<ResponseFrame, Error>] = [:]
    private var uploadMethods: Set<String> = []
    private var connected = false
    private var isConnecting = false
    private var connectionWaiters: [CheckedContinuation<Void, Error>] = []
    private var shouldRun = true
    private var backoffMs: Double = 500
    /// Set by the gateway's `shutdown` broadcast. Until this deadline, reconnect attempts
    /// keep a short fixed delay instead of doubling: the socket death that follows an
    /// announced restart is expected and brief, and walking the full backoff turned every
    /// routine gateway restart into up to half a minute of avoidable "offline".
    private var restartGraceDeadline: Date?
    private var lastSeq: Int?
    private var lastTick = Date()
    /// Whether the current socket has delivered a tick at all. Some gateways never emit
    /// them; on those, tick silence is normal and must not be read as a dead connection.
    private var hasObservedTick = false
    private var tickIntervalMs: Double = 30000
    private var keepaliveTask: Task<Void, Never>?
    private var tickWatchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var credential: GatewayCredential
    private var usedDeviceFallback = false
    private var connectedDeviceID: String?
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    // Setup-code bootstrap fails closed on any scope outside the gateway's
    // handoff profile (operator.read/write/approvals + talk.secrets), so
    // requesting operator.pairing here bricks pairing with a generic
    // "bootstrap token invalid". device.token.rotate needs operator.pairing
    // and therefore only works for devices granted it out-of-band.
    static let scopes = ["operator.read", "operator.write", "operator.approvals"]
    private var requestedScopes: [String] {
        // Bootstrap scope ceilings remain unchanged. A paired device must explicitly
        // request and receive the additional permission from its Gateway operator.
        Self.connectionScopes(secretEntryEnabled: config.secretEntryEnabled, credentialKind: credential.kind, questionsEnabled: config.questionsEnabled)
    }
    static func connectionScopes(secretEntryEnabled: Bool, credentialKind: GatewayCredentialKind, questionsEnabled: Bool = false) -> [String] {
        scopes + ((secretEntryEnabled || questionsEnabled) && credentialKind != .bootstrapToken ? ["operator.questions"] : [])
    }
    static let capabilities = ["tool-events"]

    public init(
        config: GatewayClientConfig,
        onEvent: @escaping @Sendable (EventFrame) -> Void,
        onState: @escaping @Sendable (GatewayConnectionState) -> Void)
    {
        self.config = config
        self.credential = config.credential
        self.onEvent = onEvent
        self.onState = onState
    }

    public func shutdown() {
        self.shouldRun = false
        self.connected = false
        self.keepaliveTask?.cancel()
        self.tickWatchdogTask?.cancel()
        self.reconnectTask?.cancel()
        self.reconnectTask = nil
        self.task?.cancel(with: .goingAway, reason: nil)
        self.task = nil
        self.resumeConnectionWaiters(with: .failure(GatewayTimeoutError(context: "shutdown")))
        self.failPending(GatewayTimeoutError(context: "shutdown"))
        // Shutdown is terminal for this client — ChatStore replaces it wholesale on
        // restart. An un-invalidated URLSession retains itself for its delegate lifetime,
        // which leaked one session per foreground-while-disconnected cycle.
        self.session.invalidateAndCancel()
    }

    // MARK: - Connect

    public func start() {
        self.shouldRun = true
        guard self.reconnectTask == nil, !self.connected else { return }
        self.reconnectTask = Task { [weak self] in
            await self?.runConnectionLoop()
        }
    }

    private func runConnectionLoop() async {
        defer { self.reconnectTask = nil }
        while self.shouldRun, !self.connected, !Task.isCancelled {
            do {
                try await self.connect()
                return
            } catch let error as GatewayRequestError {
                if error.code == "AUTH_TOKEN_MISMATCH",
                   self.credential.kind != .deviceToken,
                   !self.usedDeviceFallback,
                   let fallback = self.config.deviceCredentialProvider() {
                    self.usedDeviceFallback = true
                    self.credential = fallback
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                if error.code == "AUTH_TOKEN_MISMATCH" || error.code == "AUTH_SCOPE_MISMATCH" {
                    self.onState(.needsCredentials(error.message))
                    return
                }
                if error.code == "PAIRING_REQUIRED" { self.onState(.waitingForApproval) }
                let delayMs: Double
                if let retryAfter = error.retryAfterMs.map(Double.init) {
                    delayMs = Self.clampedMs(retryAfter, min: 250, max: 60_000) ?? self.backoffMs
                    self.backoffMs = min(max(delayMs, self.backoffMs) * 2, 30000)
                } else {
                    delayMs = self.nextReconnectDelayMs()
                }
                try? await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
            } catch {
                let delayMs = self.nextReconnectDelayMs()
                try? await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
            }
        }
    }

    public func connect() async throws {
        if self.connected, self.task?.state == .running { return }
        if self.isConnecting {
            try await withCheckedThrowingContinuation { continuation in
                self.connectionWaiters.append(continuation)
            }
            return
        }
        self.isConnecting = true
        defer { self.isConnecting = false }
        self.onState(.connecting)

        self.task?.cancel(with: .goingAway, reason: nil)
        let task = self.session.webSocketTask(with: self.config.url)
        task.maximumMessageSize = 32 * 1024 * 1024
        self.task = task
        task.resume()

        do {
            let nonce = try await self.withTimeout(
                seconds: 6,
                context: "connect.challenge",
                onTimeout: { task.cancel(with: .goingAway, reason: nil) }) {
                    try await self.waitForChallenge(task: task)
                }
            let helloPayload = try await self.withTimeout(
                seconds: 12,
                context: "connect",
                onTimeout: { task.cancel(with: .goingAway, reason: nil) }) {
                    try await self.performConnect(task: task, nonce: nonce)
                }
            self.uploadMethods = Set(helloPayload["features"]?["methods"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let mainSessionKey = helloPayload["snapshot"]?["sessionDefaults"]?["mainSessionKey"]?.stringValue
            if let tick = helloPayload["policy"]?["tickIntervalMs"]?.doubleValue,
               let clamped = Self.clampedMs(tick, min: 1_000, max: 600_000) {
                self.tickIntervalMs = clamped
            }
            self.connected = true
            self.backoffMs = 500
            self.restartGraceDeadline = nil
            self.usedDeviceFallback = false
            self.lastSeq = nil
            self.lastTick = Date()
            self.hasObservedTick = false
            self.listen(on: task)
            self.startKeepalive()
            self.startTickWatchdog()
            self.onEvent(EventFrame(event: "cast.hello", payload: helloPayload, seq: nil))
            if Self.canPersistIssuedToken(for: self.config.url),
               let issued = Self.operatorDeviceToken(from: helloPayload) {
                self.config.onDeviceToken(issued)
                if self.credential.kind == .bootstrapToken {
                    self.credential = GatewayCredential(kind: .deviceToken, token: issued)
                }
            }
            self.onState(.connected(mainSessionKey: mainSessionKey))
            self.resumeConnectionWaiters(with: .success(()))
        } catch {
            self.connected = false
            self.task?.cancel(with: .goingAway, reason: nil)
            if let requestError = error as? GatewayRequestError, requestError.code == "PAIRING_REQUIRED" {
                self.onState(.waitingForApproval)
            } else {
                self.onState(.disconnected(error.localizedDescription))
            }
            self.logger.error("connect failed: \(error.localizedDescription, privacy: .public)")
            self.resumeConnectionWaiters(with: .failure(error))
            throw error
        }
    }

    private func resumeConnectionWaiters(with result: Result<Void, Error>) {
        let waiters = self.connectionWaiters
        self.connectionWaiters.removeAll()
        for waiter in waiters {
            switch result {
            case .success:
                waiter.resume()
            case let .failure(error):
                waiter.resume(throwing: error)
            }
        }
    }

    private func waitForChallenge(task: URLSessionWebSocketTask) async throws -> String {
        while true {
            let msg = try await task.receive()
            guard let data = Self.messageData(msg),
                  let frame = try? self.decoder.decode(GatewayFrame.self, from: data),
                  case let .event(evt) = frame, evt.event == "connect.challenge",
                  let nonce = evt.payload?["nonce"]?.stringValue
            else { continue }
            return nonce
        }
    }

    private func performConnect(task: URLSessionWebSocketTask, nonce: String) async throws -> AnyCodable {
        let identity = try DeviceIdentityStore.loadOrCreate()
        self.connectedDeviceID = identity.deviceId
        let signedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        let payload = GatewayDeviceAuthPayload.buildV3(
            deviceId: identity.deviceId,
            clientId: self.config.clientId,
            clientMode: "ui",
            role: "operator",
            scopes: self.requestedScopes,
            signedAtMs: signedAtMs,
            token: self.credential.token,
            nonce: nonce,
            platform: self.config.platform,
            deviceFamily: self.config.deviceFamily)
        guard let signature = DeviceIdentityStore.signPayload(payload, identity: identity),
              let publicKey = DeviceIdentityStore.publicKeyBase64Url(identity)
        else {
            throw GatewayTimeoutError(context: "device signing failed")
        }

        let params: [String: Any?] = [
            "minProtocol": 4,
            "maxProtocol": 4,
            "client": [
                "id": self.config.clientId,
                "displayName": self.config.displayName,
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
                "platform": self.config.platform,
                "deviceFamily": self.config.deviceFamily,
                "mode": "ui",
                "instanceId": Self.instanceId,
            ] as [String: Any?],
            "role": "operator",
            "scopes": self.requestedScopes,
            // OpenClaw sends structured live tool/progress events only to clients that
            // advertise this capability. Session subscriptions remain a compatibility path.
            "caps": Self.capabilities,
            "locale": Locale.preferredLanguages.first ?? "en-US",
            "userAgent": "cast/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")",
            "auth": [self.credential.authKey: self.credential.token] as [String: Any?],
            "device": [
                "id": identity.deviceId,
                "publicKey": publicKey,
                "signature": signature,
                "signedAt": signedAtMs,
                "nonce": nonce,
            ] as [String: Any?],
        ]

        let reqId = UUID().uuidString
        let frame = RequestFrame(id: reqId, method: "connect", params: Self.jsonValue(params))
        let data = try self.encoder.encode(frame)
        try await task.send(.data(data))

        while true {
            let msg = try await task.receive()
            guard let data = Self.messageData(msg),
                  let decoded = try? self.decoder.decode(GatewayFrame.self, from: data)
            else { continue }
            if case let .res(res) = decoded, res.id == reqId {
                if res.ok == false {
                    let details = res.error?["details"]
                    let code = details?["code"]?.stringValue ?? res.error?["code"]?.stringValue
                    let message = res.error?["message"]?.stringValue
                    throw GatewayRequestError(
                        method: "connect",
                        code: code,
                        message: message,
                        recommendedNextStep: details?["recommendedNextStep"]?.stringValue,
                        retryAfterMs: details?["retryAfterMs"]?.intValue ?? res.error?["retryAfterMs"]?.intValue)
                }
                return res.payload ?? AnyCodable(nil)
            }
        }
    }

    // MARK: - Receive loop

    private func listen(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            Task {
                await self.handleReceiveResult(result, from: task)
            }
        }
    }

    /// Check the socket generation and consume its result in one actor turn. Splitting this
    /// into separate awaited actor calls lets a reconnect swap sockets between the check and
    /// failure handling, allowing an obsolete socket to tear down its healthy replacement.
    private func handleReceiveResult(
        _ result: Result<URLSessionWebSocketTask.Message, Error>,
        from task: URLSessionWebSocketTask)
    {
        guard self.task === task else { return }
        switch result {
        case let .failure(error):
            self.handleReceiveFailure(error)
        case let .success(message):
            self.handleMessage(message)
            self.listen(on: task)
        }
    }

    private func handleMessage(_ msg: URLSessionWebSocketTask.Message) {
        guard let data = Self.messageData(msg),
              let frame = try? self.decoder.decode(GatewayFrame.self, from: data)
        else { return }
        switch frame {
        case let .res(res):
            if let waiter = self.pending.removeValue(forKey: res.id) {
                waiter.resume(returning: res)
            }
        case let .event(evt):
            if evt.event == "connect.challenge" { return }
            if let seq = evt.seq {
                if let last = self.lastSeq, seq > last + 1 {
                    self.onEvent(EventFrame(event: "cast.seqGap", payload: nil, seq: seq))
                }
                self.lastSeq = seq
            }
            if evt.event == "tick" {
                self.lastTick = Date()
                self.hasObservedTick = true
            }
            if evt.event == "shutdown" {
                // The socket is about to die on purpose. Hold reconnects to a short fixed
                // cadence for the announced window (`restartExpectedMs`, bounded) so Cast is
                // back the moment the gateway is, instead of sleeping out a grown backoff.
                let expectedMs = evt.payload?["restartExpectedMs"]?.doubleValue
                let graceMs = Self.clampedMs(expectedMs ?? 30_000, min: 5_000, max: 180_000) ?? 30_000
                self.restartGraceDeadline = Date().addingTimeInterval(graceMs / 1000)
            }
            self.onEvent(evt)
        case .unknown:
            break
        }
    }

    private func handleReceiveFailure(_ error: Error) {
        guard self.shouldRun else { return }
        self.logger.error("receive failed: \(error.localizedDescription, privacy: .public)")
        self.connected = false
        self.onState(.disconnected(error.localizedDescription))
        self.failPending(error)
        self.start()
    }

    private func startKeepalive() {
        self.keepaliveTask?.cancel()
        self.keepaliveTask = Task { [weak self] in
            while let self, await self.isLive() {
                guard await Self.waitForPeriodicInterval(nanoseconds: 15_000_000_000),
                      await self.isLive()
                else { return }
                await self.sendPing()
            }
        }
    }

    private func startTickWatchdog() {
        self.tickWatchdogTask?.cancel()
        self.tickWatchdogTask = Task { [weak self] in
            while let self, await self.isLive() {
                let tolerance = await self.tickIntervalMs * 2
                guard await Self.waitForPeriodicInterval(
                    nanoseconds: UInt64(tolerance * 1_000_000)),
                    await self.isLive()
                else { return }
                await self.checkTick(toleranceMs: tolerance)
            }
        }
    }

    private func isLive() -> Bool { self.shouldRun && self.connected }

    /// Returns the next reconnect sleep and advances the backoff — except inside an
    /// announced-restart grace window, where the delay stays short and fixed so the grown
    /// backoff is preserved for genuine outages that outlive the window.
    private func nextReconnectDelayMs() -> Double {
        if let deadline = self.restartGraceDeadline, Date() < deadline {
            return 1_000
        }
        let delayMs = self.backoffMs
        self.backoffMs = min(self.backoffMs * 2, 30000)
        return delayMs
    }

    /// A canceled periodic task must terminate instead of swallowing the sleep error. If a
    /// reconnect has already made the replacement socket live, a `try?` loop sees `isLive`
    /// remain true and otherwise spins forever on an immediately-canceled sleep.
    nonisolated static func waitForPeriodicInterval(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func sendPing() {
        self.task?.sendPing { _ in }
    }

    private func checkTick(toleranceMs: Double) async {
        guard self.connected else { return }
        let deltaMs = Date().timeIntervalSince(self.lastTick) * 1000
        if Self.tickWatchdogShouldReconnect(
            hasObservedTick: self.hasObservedTick,
            msSinceLastTick: deltaMs,
            toleranceMs: toleranceMs)
        {
            self.logger.error("tick missed (\(Int(deltaMs))ms); reconnecting")
            self.connected = false
            self.task?.cancel(with: .goingAway, reason: nil)
            self.onState(.disconnected("tick missed"))
            self.failPending(GatewayTimeoutError(context: "tick missed"))
            self.start()
        }
    }

    /// The watchdog is armed only once the current socket has proven it carries ticks.
    /// `lastTick` is seeded at connect and refreshed exclusively by tick events, so against
    /// a gateway that never emits them the seed just aged: the "dead" verdict fired every
    /// other interval, tearing down a healthy connection and refiring a full history reload
    /// each cycle. Keepalive pings and receive failures still catch genuinely dead sockets.
    nonisolated static func tickWatchdogShouldReconnect(
        hasObservedTick: Bool,
        msSinceLastTick: Double,
        toleranceMs: Double) -> Bool
    {
        hasObservedTick && msSinceLastTick > toleranceMs
    }

    public func rotateDeviceToken() async throws {
        guard let deviceID = self.connectedDeviceID else { throw GatewayTimeoutError(context: "device identity unavailable") }
        let data = try await self.request(method: "device.token.rotate", params: [
            "deviceId": deviceID,
            "role": "operator",
            "scopes": self.requestedScopes,
        ])
        let payload = try self.decoder.decode(AnyCodable.self, from: data)
        guard let token = payload["token"]?.stringValue else { throw GatewayTimeoutError(context: "rotated token unavailable") }
        self.config.onDeviceToken(token)
        self.credential = GatewayCredential(kind: .deviceToken, token: token)
    }

    // MARK: - RPC

    public func request(method: String, params: [String: Any?]? = nil, timeoutMs: Double = 15000) async throws -> Data {
        if !self.connected {
            try await self.connect()
        }
        let id = UUID().uuidString
        let frame = RequestFrame(id: id, method: method, params: params.map { Self.jsonValue($0) })
        let data = try self.encoder.encode(frame)
        guard let task = self.task else { throw GatewayTimeoutError(context: "no socket") }

        let boundedTimeoutMs = Self.clampedMs(timeoutMs, min: 250, max: 120_000) ?? 15_000

        // Cancelled once the response lands: without that, every request left a task
        // sleeping out the full timeout, keeping a dead reference per RPC in flight.
        var timeoutTask: Task<Void, Never>?
        defer { timeoutTask?.cancel() }
        let response: ResponseFrame = try await withCheckedThrowingContinuation { cont in
            self.pending[id] = cont
            timeoutTask = Task { [weak self] in
                guard (try? await Task.sleep(nanoseconds: UInt64(boundedTimeoutMs * 1_000_000))) != nil
                else { return }
                await self?.timeoutRequest(id: id, method: method)
            }
            Task { [weak self] in
                do {
                    try await task.send(.data(data))
                } catch {
                    await self?.failRequest(id: id, error: error)
                }
            }
        }
        if response.ok == false {
            throw GatewayRequestError(
                method: method,
                code: response.error?["code"]?.stringValue,
                message: response.error?["message"]?.stringValue,
                recommendedNextStep: response.error?["details"]?["recommendedNextStep"]?.stringValue,
                retryAfterMs: response.error?["retryAfterMs"]?.intValue,
                reason: response.error?["details"]?["reason"]?.stringValue)
        }
        guard let payload = response.payload else { return Data("{}".utf8) }
        return try self.encoder.encode(payload)
    }

    /// Builds attachment base64 and the loosely typed RPC object on the gateway actor rather
    /// than ChatStore's main actor. A valid frame can approach 24 MB, so this work must not
    /// block AppKit/UIKit while the user presses Send.
    public func sendChat(
        sessionKey: String,
        message: String,
        idempotencyKey: String,
        deliver: Bool,
        attachments: [PreparedAttachment],
        sessionID: String? = nil,
        uploadProgress: @escaping @Sendable (AttachmentUploadProgress) -> Void = { _ in }) async throws -> Data
    {
        var params: [String: Any?] = [
            "sessionKey": sessionKey,
            "message": message,
            "idempotencyKey": idempotencyKey,
            "deliver": deliver,
        ]
        do { if !self.connected { try await self.connect() } }
        catch { throw SendAttemptError.notSubmitted }
        if try AttachmentProcessor.requiresUpload(message: message, attachments: attachments) {
            guard self.uploadMethods.isSuperset(of: ["chat.upload.policy", "chat.upload.begin", "chat.upload.chunk", "chat.upload.cancel"]),
                  let sessionID, !sessionID.isEmpty else { throw AttachmentError.uploadsUnavailable }
            params["sessionId"] = sessionID
            params["attachments"] = try await LargeAttachmentUpload.upload(sessionKey: sessionKey, sessionID: sessionID,
                batchID: idempotencyKey, attachments: attachments, request: { method, params in
                    try await self.request(method: method, params: params)
                }, progress: uploadProgress)
        } else if !attachments.isEmpty { params["attachments"] = try attachments.map { try $0.inlineRPCValue() } }
        try Task.checkCancellation()
        do { return try await self.request(method: "chat.send", params: params) }
        catch let error as GatewayRequestError { throw error }
        catch { throw SendAttemptError.uncertain }
    }

    func attachmentSessionID(sessionKey: String) async throws -> String {
        let data = try await request(method: "chat.history", params: ["sessionKey": sessionKey, "limit": 1])
        struct HistoryIdentity: Decodable { let sessionId: String? }
        guard let id = try decoder.decode(HistoryIdentity.self, from: data).sessionId, !id.isEmpty else {
            throw AttachmentError.uploadsUnavailable
        }
        return id
    }

    /// Returns the progress card for `sessionKey`, or `nil` when none is set.
    /// Throws `GatewayRequestError` when the gateway does not support the method.
    public func getProgressCard(sessionKey: String) async throws -> ProgressCard? {
        let data = try await self.request(method: "progressCard.get", params: ["sessionKey": sessionKey])
        struct Response: Decodable { let card: ProgressCard? }
        return try self.decoder.decode(Response.self, from: data).card
    }

    private func timeoutRequest(id: String, method: String) {
        guard let waiter = self.pending.removeValue(forKey: id) else { return }
        waiter.resume(throwing: GatewayTimeoutError(context: "\(method) request"))
    }

    private func failRequest(id: String, error: Error) {
        guard let waiter = self.pending.removeValue(forKey: id) else { return }
        waiter.resume(throwing: error)
    }

    private func failPending(_ error: Error) {
        let waiters = self.pending
        self.pending.removeAll()
        for (_, waiter) in waiters {
            waiter.resume(throwing: error)
        }
    }

    // MARK: - Helpers

    /// Gateway-supplied millisecond values must be clamped before any `UInt64(ms * 1_000_000)`
    /// conversion: negative, non-finite, or huge inputs trap instead of throwing.
    static func clampedMs(_ raw: Double, min minMs: Double, max maxMs: Double) -> Double? {
        guard raw.isFinite else { return nil }
        return Swift.min(Swift.max(raw, minMs), maxMs)
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        context: String,
        onTimeout: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                onTimeout()
                throw GatewayTimeoutError(context: context)
            }
            guard let result = try await group.next() else { throw GatewayTimeoutError(context: context) }
            group.cancelAll()
            return result
        }
    }

    private static func messageData(_ msg: URLSessionWebSocketTask.Message) -> Data? {
        switch msg {
        case let .data(data): return data
        case let .string(text): return text.data(using: .utf8)
        @unknown default: return nil
        }
    }

    /// Recursively wraps loosely-typed dictionaries into AnyCodable for encoding.
    static func jsonValue(_ value: Any?) -> AnyCodable {
        switch value {
        case let dict as [String: Any?]:
            return AnyCodable(dict.mapValues { jsonValue($0) })
        case let array as [Any?]:
            return AnyCodable(array.map { jsonValue($0) })
        default:
            return AnyCodable(value)
        }
    }

    private static func canPersistIssuedToken(for url: URL) -> Bool {
        if url.scheme?.lowercased() == "wss" { return true }
        let host = url.host?.lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func operatorDeviceToken(from hello: AnyCodable) -> String? {
        if let entries = hello["auth"]?["deviceTokens"]?.arrayValue {
            for entry in entries where entry["role"]?.stringValue == "operator" {
                if let token = entry["deviceToken"]?.stringValue { return token }
            }
        }
        if hello["auth"]?["role"]?.stringValue == "operator" {
            return hello["auth"]?["deviceToken"]?.stringValue
        }
        return nil
    }

    private static let instanceId: String = {
        let key = "cast.instanceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()
}
