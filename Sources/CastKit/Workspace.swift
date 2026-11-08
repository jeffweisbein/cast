import Foundation
import Observation
import SwiftUI

public struct WorkspaceProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var gatewayURL: URL
    public var accent: String

    public init(id: String, name: String, gatewayURL: URL, accent: String) {
        self.id = id
        self.name = name
        self.gatewayURL = gatewayURL
        self.accent = accent
    }

    public static let developmentLocal = WorkspaceProfile(
        id: "local",
        name: "Local OpenClaw",
        gatewayURL: URL(string: "ws://127.0.0.1:18789")!,
        accent: "orange")

    public static let unconfigured = WorkspaceProfile(
        id: "unconfigured",
        name: "Cast",
        gatewayURL: URL(string: "ws://127.0.0.1:1")!,
        accent: "orange")
}

public struct GatewaySetupPayload: Decodable, Sendable {
    public let url: URL
    public let urls: [URL]?
    public let bootstrapToken: String
    public let expiresAtMs: Double?

    public static func decode(setupCode: String) throws -> GatewaySetupPayload {
        let trimmed = setupCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: Data?
        if trimmed.hasPrefix("{") {
            raw = trimmed.data(using: .utf8)
        } else {
            let normalized = trimmed
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
            raw = Data(base64Encoded: padded)
        }
        guard let raw else { throw PairingError.invalidCode }
        guard let payload = try? JSONDecoder().decode(GatewaySetupPayload.self, from: raw) else {
            throw PairingError.invalidCode
        }
        if let expiry = payload.expiresAtMs, expiry < Date().timeIntervalSince1970 * 1000 {
            throw PairingError.expiredCode
        }
        guard Self.isSafeBootstrapURL(payload.url) else { throw PairingError.insecureRemoteURL }
        return payload
    }

    public static func isSafeBootstrapURL(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "wss" { return true }
        guard url.scheme?.lowercased() == "ws", let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16 ... 31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    public static func validateManualURL(_ text: String) throws -> URL {
        guard let url = URL(string: text),
              ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil
        else { throw PairingError.invalidURL }
        guard self.isSafeBootstrapURL(url) else { throw PairingError.insecureRemoteURL }
        return url
    }
}

public enum PairingError: Error, LocalizedError, Sendable {
    case invalidCode
    case expiredCode
    case insecureRemoteURL
    case invalidURL
    case missingName

    public var errorDescription: String? {
        switch self {
        case .invalidCode: return "That setup code is not valid."
        case .expiredCode: return "That setup code expired. Generate a fresh code and try again."
        case .insecureRemoteURL: return "Remote gateways require wss://. Plain ws:// is allowed only on loopback or a private LAN."
        case .invalidURL: return "Enter a valid ws:// or wss:// gateway URL."
        case .missingName: return "Give this workspace a name so you can recognize it later."
        }
    }

    public static func userFacingMessage(for error: Error) -> String {
        if let pairingError = error as? PairingError {
            return pairingError.localizedDescription
        }
        return "Cast couldn’t save this workspace securely. Make sure Keychain is available, then try again."
    }
}

public enum CastOnboarding {
    public static let currentVersion = 1
    public static let completionKey = "cast.onboarding.completedVersion"
    public static let seenKey = "cast.onboarding.seenVersion"

    public enum LaunchDecision: Equatable, Sendable {
        case present
        case skip
        case skipAndMigrate
    }

    /// Existing credential-bearing installs predate onboarding and must not be interrupted.
    /// Once a version has been recorded, a future version bump may present its new guidance.
    public static func launchDecision(
        completedVersion: Int?,
        seenVersion: Int?,
        hasConfiguredCredential: Bool) -> LaunchDecision
    {
        if let completedVersion, completedVersion >= self.currentVersion { return .skip }
        if completedVersion == nil, seenVersion == nil, hasConfiguredCredential {
            return .skipAndMigrate
        }
        return .present
    }
}

public enum PairingConnectionPhase: Equatable, Sendable {
    case connecting
    case approvalRequired
    case connected
    case authenticationFailed
    case unreachable

    public static func phase(for state: GatewayConnectionState) -> PairingConnectionPhase {
        switch state {
        case .connecting:
            return .connecting
        case .waitingForApproval:
            return .approvalRequired
        case .connected:
            return .connected
        case .needsCredentials:
            return .authenticationFailed
        case let .disconnected(reason):
            let normalized = reason?.lowercased() ?? ""
            if normalized.isEmpty || normalized == "reconnecting" { return .connecting }
            if normalized.contains("auth")
                || normalized.contains("token")
                || normalized.contains("unauthorized")
            {
                return .authenticationFailed
            }
            return .unreachable
        }
    }
}

public enum WorkspaceBootstrapPolicy {
    public static func profiles(
        saved: [WorkspaceProfile],
        includeDevelopmentWorkspaces: Bool,
        hasCredential: (String) -> Bool) -> [WorkspaceProfile]
    {
        var profiles = saved
        let builtIns: [WorkspaceProfile] = [.developmentLocal]
        for profile in builtIns where includeDevelopmentWorkspaces || hasCredential(profile.id) {
            if !profiles.contains(where: { $0.id == profile.id }) {
                profiles.append(profile)
            }
        }
        return profiles
    }
}

@MainActor
public final class WorkspaceManager: ObservableObject {
    @Published public private(set) var profiles: [WorkspaceProfile]
    @Published public var selectedWorkspaceID: String
    @Published public private(set) var isOnboardingPresented: Bool
    @Published public var pairingError: String?
    @Published public var pendingShareError: String?
    @Published public private(set) var unreadSessionCount = 0

    private var stores: [String: ChatStore] = [:]
    private var isApplicationActive = true
    private var unreadCountsByWorkspace: [String: Int] = [:]
    /// Workspaces whose store is already being tracked, so re-entry through `store(for:)`
    /// cannot install a second observation loop for the same store.
    private var observedWorkspaceIDs: Set<String> = []
    #if os(iOS)
    private var shareRequestsInFlight: Set<UUID> = []
    #endif
    private let defaultsKey = "cast.workspaceProfiles.v2"
    private let defaults: UserDefaults

    public init(
        defaults: UserDefaults = .standard,
        credentialProvider: @escaping (String) -> GatewayCredential? = {
            GatewayCredentialStore.preferred(workspaceID: $0)
        },
        includeDevelopmentWorkspaces: Bool? = nil,
        legacyLocalCredentialAvailable: Bool? = nil)
    {
        self.defaults = defaults
        let saved: [WorkspaceProfile]
        if let data = defaults.data(forKey: self.defaultsKey),
           let decoded = try? JSONDecoder().decode([WorkspaceProfile].self, from: data) {
            saved = decoded
        } else {
            saved = []
        }
        let hasLegacyLocalCredential = legacyLocalCredentialAvailable
            ?? (GatewayConfigLoader.discoverLocalToken() != nil)
        #if DEBUG
        let legacyEnvironmentWorkspaceIDs = Set([
            ("local", ProcessInfo.processInfo.environment["CAST_GATEWAY_TOKEN"]),
        ].compactMap { id, token in
            token?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? id : nil
        })
        #else
        let legacyEnvironmentWorkspaceIDs = Set<String>()
        #endif
        let hasCredential: (String) -> Bool = { workspaceID in
            credentialProvider(workspaceID) != nil
                || (workspaceID == WorkspaceProfile.developmentLocal.id && hasLegacyLocalCredential)
                || legacyEnvironmentWorkspaceIDs.contains(workspaceID)
        }
        let includeDevelopmentWorkspaces = includeDevelopmentWorkspaces ?? Self.defaultDevelopmentWorkspacePolicy
        let merged = WorkspaceBootstrapPolicy.profiles(
            saved: saved,
            includeDevelopmentWorkspaces: includeDevelopmentWorkspaces,
            hasCredential: hasCredential)
        self.profiles = merged
        let remembered = defaults.string(forKey: "cast.selectedWorkspace")
        if let remembered, merged.contains(where: { $0.id == remembered }) {
            self.selectedWorkspaceID = remembered
        } else {
            self.selectedWorkspaceID = merged.first?.id ?? ""
        }
        let completedVersion = defaults.object(forKey: CastOnboarding.completionKey) as? Int
        let seenVersion = defaults.object(forKey: CastOnboarding.seenKey) as? Int
        switch CastOnboarding.launchDecision(
            completedVersion: completedVersion,
            seenVersion: seenVersion,
            hasConfiguredCredential: merged.contains(where: { hasCredential($0.id) }))
        {
        case .present:
            self.isOnboardingPresented = true
            defaults.set(CastOnboarding.currentVersion, forKey: CastOnboarding.seenKey)
        case .skip:
            self.isOnboardingPresented = false
        case .skipAndMigrate:
            self.isOnboardingPresented = false
            defaults.set(CastOnboarding.currentVersion, forKey: CastOnboarding.completionKey)
            defaults.set(CastOnboarding.currentVersion, forKey: CastOnboarding.seenKey)
        }
        for profile in merged {
            let store = ChatStore(profile: profile)
            self.stores[profile.id] = store
            self.observeUnreadCount(store, workspaceID: profile.id)
        }
        self.publishShareDestinations()
    }

    private static var defaultDevelopmentWorkspacePolicy: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CAST_INCLUDE_DEVELOPMENT_WORKSPACES"] == "1"
        #else
        return false
        #endif
    }

    public var selectedStore: ChatStore {
        self.store(for: self.selectedWorkspaceID)
    }

    public var selectedStoreIfConfigured: ChatStore? {
        guard self.profiles.contains(where: { $0.id == self.selectedWorkspaceID }) else { return nil }
        return self.store(for: self.selectedWorkspaceID)
    }

    public var hasCompletedOnboarding: Bool {
        self.defaults.integer(forKey: CastOnboarding.completionKey) >= CastOnboarding.currentVersion
    }

    public func store(for workspaceID: String) -> ChatStore {
        if let existing = self.stores[workspaceID] { return existing }
        let profile = self.profiles.first(where: { $0.id == workspaceID }) ?? .unconfigured
        let store = ChatStore(profile: profile)
        store.isNotificationContextVisible = self.isApplicationActive && workspaceID == self.selectedWorkspaceID
        self.stores[workspaceID] = store
        self.observeUnreadCount(store, workspaceID: workspaceID)
        return store
    }

    /// Keeps the aggregate badge summed across every workspace's store.
    ///
    /// This was a `$numericUnreadCount` subscription; `ChatStore` is `@Observable` now, so
    /// there is no publisher to sink. `withObservationTracking` fires once per change and
    /// drops the registration, hence the re-arm at the end of each pass. Both halves of the
    /// old behaviour are kept deliberately: the current count is applied immediately at
    /// registration, the way a `@Published` sink delivered its initial value, and the
    /// aggregate is only recomputed when a workspace's count actually moves, the way
    /// `removeDuplicates()` did.
    private func observeUnreadCount(_ store: ChatStore, workspaceID: String) {
        guard self.observedWorkspaceIDs.insert(workspaceID).inserted else { return }
        self.applyUnreadCount(store.numericUnreadCount, workspaceID: workspaceID)
        self.trackUnreadCount(of: store, workspaceID: workspaceID)
    }

    private func trackUnreadCount(of store: ChatStore, workspaceID: String) {
        withObservationTracking {
            _ = store.numericUnreadCount
        } onChange: { [weak self, weak store] in
            // `onChange` runs before the store's new value is stored, so the read has to
            // happen on the next main-actor turn rather than inside the callback.
            Task { @MainActor in
                guard let self, let store, self.stores[workspaceID] === store else { return }
                self.applyUnreadCount(store.numericUnreadCount, workspaceID: workspaceID)
                self.trackUnreadCount(of: store, workspaceID: workspaceID)
            }
        }
    }

    private func applyUnreadCount(_ count: Int, workspaceID: String) {
        guard self.unreadCountsByWorkspace[workspaceID] != count else { return }
        self.unreadCountsByWorkspace[workspaceID] = count
        self.unreadSessionCount = self.unreadCountsByWorkspace.values.reduce(0, +)
        Task {
            await NativeNotificationDelivery.shared.setBadgeCount(self.unreadSessionCount)
        }
    }

    public func start() {
        self.migrateDevelopmentCredentialsIfNeeded()
        for profile in self.profiles { self.store(for: profile.id).start() }
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let workspace = environment["CAST_OPEN_WORKSPACE"],
           self.profiles.contains(where: { $0.id == workspace }) {
            self.select(workspace)
        }
        if let sessionKey = environment["CAST_OPEN_SESSION_KEY"], !sessionKey.isEmpty {
            self.selectedStoreIfConfigured?.selectedSessionKey = sessionKey
        }
        #endif
    }

    public func observeRemoteNotification(_ destination: NativeNotificationDestination, presenting: Bool) -> Bool {
        guard self.profiles.contains(where: { $0.id == destination.workspaceID }) else { return false }
        return self.store(for: destination.workspaceID).observeRemoteCompletion(destination, presenting: presenting)
    }

    public func reconcileDeliveredNotifications() async {
        for destination in await NativeNotificationDelivery.shared.deliveredRemoteDestinations() {
            _ = self.observeRemoteNotification(destination, presenting: false)
        }
    }

    public func syncRemoteNotificationPreferences() {
        for profile in self.profiles { self.store(for: profile.id).scheduleRemotePushSync() }
    }

    public func setApplicationActive(_ active: Bool) {
        self.isApplicationActive = active
        for (workspaceID, store) in self.stores {
            store.isNotificationContextVisible = active && workspaceID == self.selectedWorkspaceID
        }
    }

    /// A notification may select only an already-configured workspace. Session visibility
    /// and access remain authoritative at the gateway when history is loaded.
    @discardableResult
    public func openNotification(_ destination: NativeNotificationDestination) -> Bool {
        guard self.profiles.contains(where: { $0.id == destination.workspaceID }) else { return false }
        let store = self.store(for: destination.workspaceID)
        if destination.gatewayDeviceID != nil, !store.acceptsRemoteNotification(destination) { return false }
        if destination.gatewayDeviceID != nil {
            store.observeRemoteCompletion(destination, presenting: false)
        }
        self.select(destination.workspaceID)
        self.selectedStore.selectedSessionKey = destination.sessionKey
        return true
    }

    public func suspendAllForBackground() {
        for profile in self.profiles {
            self.store(for: profile.id).suspendForBackground()
        }
    }

    public func refreshAllAfterActivation() async {
        for profile in self.profiles {
            await self.store(for: profile.id).refreshAfterActivation()
        }
    }

    public func select(_ workspaceID: String) {
        guard self.profiles.contains(where: { $0.id == workspaceID }) else { return }
        self.selectedWorkspaceID = workspaceID
        self.setApplicationActive(self.isApplicationActive)
        self.defaults.set(workspaceID, forKey: "cast.selectedWorkspace")
        self.publishShareDestinations()
        let selectedStore = self.store(for: workspaceID)
        selectedStore.start()
        Task { await selectedStore.refreshAfterActivation() }
    }

    /// The notification panel's contents: one row per chat carrying unread state, across every
    /// workspace, most-recently-active first — the same honest per-session counts the sidebar
    /// badges show, just flattened into a single list.
    public var unreadInbox: [UnreadInboxItem] {
        self.profiles
            .flatMap { profile in
                self.store(for: profile.id).unreadSummaries.map { summary in
                    UnreadInboxItem(workspaceID: profile.id, workspaceName: profile.name, summary: summary)
                }
            }
            .sorted { ($0.summary.updatedAt ?? 0) > ($1.summary.updatedAt ?? 0) }
    }

    /// Selects the chat behind an inbox row, switching workspace first if it lives elsewhere.
    public func openUnreadInboxItem(_ item: UnreadInboxItem) {
        if item.workspaceID != self.selectedWorkspaceID {
            self.select(item.workspaceID)
        }
        self.store(for: item.workspaceID).selectFromSidebar(item.summary.sessionKey)
    }

    /// Zeros unread state for every chat in every workspace, local ledger and authoritative
    /// gateway flag alike.
    public func markAllRead() {
        for profile in self.profiles {
            self.store(for: profile.id).markAllRead()
        }
    }

    /// Legacy one-step unread navigation retained for command callers. The visible bell now
    /// presents `unreadInbox`, where the reader can choose a destination or clear everything.
    @discardableResult
    public func openFirstUnreadSession() -> Bool {
        guard let destination = UnreadNavigation.nextDestination(
            selectedWorkspaceID: self.selectedWorkspaceID,
            workspaceIDs: self.profiles.map(\.id),
            firstUnreadSessionKey: { self.store(for: $0).firstUnreadSessionKey })
        else { return false }

        if destination.workspaceID != self.selectedWorkspaceID {
            self.select(destination.workspaceID)
        }
        self.store(for: destination.workspaceID).selectFromSidebar(destination.sessionKey)
        return true
    }

    @discardableResult
    public func pair(name: String, setupCode: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PairingError.missingName }
        let payload = try GatewaySetupPayload.decode(setupCode: setupCode)
        let existing = self.profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        let id = existing?.id ?? self.uniqueID(from: name)
        let profile = WorkspaceProfile(id: id, name: name, gatewayURL: payload.url, accent: existing?.accent ?? "purple")
        try GatewayCredentialStore.replaceWithBootstrapToken(payload.bootstrapToken, workspaceID: id)
        self.upsert(profile)
        if existing == profile { self.reconnect(workspaceID: id) }
        return id
    }

    @discardableResult
    public func configure(name: String, urlText: String, sharedToken: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PairingError.missingName }
        let url = try GatewaySetupPayload.validateManualURL(urlText)
        let existing = self.profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        let id = existing?.id
            ?? self.uniqueID(from: name)
        let profile = WorkspaceProfile(
            id: id,
            name: name,
            gatewayURL: url,
            accent: existing?.accent ?? "purple")
        try GatewayCredentialStore.setSharedToken(sharedToken.trimmingCharacters(in: .whitespacesAndNewlines), workspaceID: id)
        self.upsert(profile)
        if existing == profile { self.reconnect(workspaceID: id) }
        return id
    }

    public func presentOnboarding() {
        self.isOnboardingPresented = true
    }

    public func dismissOnboarding() {
        self.isOnboardingPresented = false
    }

    public func completeOnboarding() {
        self.defaults.set(CastOnboarding.currentVersion, forKey: CastOnboarding.completionKey)
        self.isOnboardingPresented = false
    }

    public func reconnect(workspaceID: String) {
        self.store(for: workspaceID).restartWithStoredCredential()
    }

    private func upsert(_ profile: WorkspaceProfile) {
        if let index = self.profiles.firstIndex(where: { $0.id == profile.id }) {
            self.profiles[index] = profile
            self.stores[profile.id]?.update(profile: profile)
        } else {
            self.profiles.append(profile)
            _ = self.store(for: profile.id)
        }
        self.persistProfiles()
        self.select(profile.id)
        self.store(for: profile.id).start()
    }

    private func uniqueID(from name: String) -> String {
        let base = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
        let seed = base.isEmpty ? "workspace" : base
        if !self.profiles.contains(where: { $0.id == seed }) { return seed }
        var suffix = 2
        while self.profiles.contains(where: { $0.id == "\(seed)-\(suffix)" }) { suffix += 1 }
        return "\(seed)-\(suffix)"
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(self.profiles) {
            self.defaults.set(data, forKey: self.defaultsKey)
        }
    }

    private func publishShareDestinations() {
        guard let store = ShareDestinationStore.appGroup else { return }
        let existing = store.load()
        let workspaces = self.profiles.map { profile in
            let priorSessions = existing.workspaces.first(where: { $0.id == profile.id })?.sessions ?? []
            let priorPreferred = existing.workspaces.first(where: { $0.id == profile.id })?.preferredSessionKey
            let liveSessions = self.stores[profile.id]?.sessions.map {
                ShareSessionDestination(
                    key: $0.key,
                    name: SidebarGrouper.displayTitle(
                        for: $0,
                        mainSessionKey: self.stores[profile.id]?.mainSessionKey),
                    channel: $0.channel)
            } ?? []
            return ShareWorkspaceDestination(
                id: profile.id,
                name: profile.name,
                sessions: liveSessions.isEmpty ? priorSessions : liveSessions,
                preferredSessionKey: self.stores[profile.id]?.selectedSessionKey
                    ?? self.stores[profile.id]?.mainSessionKey
                    ?? priorPreferred)
        }
        store.save(ShareDestinationSnapshot(
            workspaces: workspaces,
            selectedWorkspaceID: self.selectedWorkspaceID))
    }

    private func migrateDevelopmentCredentialsIfNeeded() {
        if GatewayCredentialStore.preferred(workspaceID: "local") == nil,
           let local = GatewayConfigLoader.discoverLocalToken() {
            try? GatewayCredentialStore.setSharedToken(local, workspaceID: "local")
        }
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let token = environment["CAST_GATEWAY_TOKEN"], !token.isEmpty {
            try? GatewayCredentialStore.setSharedToken(token, workspaceID: "local")
        }
        #endif
    }

    #if os(iOS)
    /// Drains durable extension handoffs only after the selected destination is
    /// connected. Failed preparation or an unavailable gateway leaves the
    /// request in the inbox for the next foreground/open attempt.
    public func consumePendingShares(requestID: UUID? = nil) async {
        guard let inbox = ShareInbox.appGroup else { return }
        let pending = inbox.pending().filter { requestID == nil || $0.id == requestID }
        for request in pending {
            guard let route = ShareDestinationResolver.exactRoute(
                for: request,
                availableWorkspaceIDs: Set(self.profiles.map(\.id)))
            else {
                self.pendingShareError = "A shared item is still queued, but its Cast workspace is no longer configured. Reconnect that workspace to send it."
                continue
            }
            guard self.shareRequestsInFlight.insert(request.id).inserted else { continue }
            var awaitingSendCompletion = false
            defer {
                if !awaitingSendCompletion { self.shareRequestsInFlight.remove(request.id) }
            }
            self.select(route.workspaceID)
            let destinationStore = self.store(for: route.workspaceID)
            destinationStore.selectedSessionKey = route.sessionKey
            destinationStore.start()

            var connected = false
            for _ in 0 ..< 20 {
                if case .connected = destinationStore.connectionState {
                    connected = true
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard connected else {
                destinationStore.showError("This shared item is still queued because Cast couldn’t connect. It will retry the next time Cast opens.")
                continue
            }

            do {
                let fileItems = request.items.filter { $0.kind == .image || $0.kind == .file }
                let attachments = try await Task.detached(priority: .userInitiated) {
                    var prepared: [PreparedAttachment] = []
                    for item in fileItems {
                        guard let url = inbox.fileURL(for: item, requestID: request.id) else {
                            throw ShareInboxError.invalidFile
                        }
                        prepared.append(try await AttachmentProcessor.prepareForSending(
                            url: url,
                            originalFileName: item.fileName,
                            typeIdentifier: item.typeIdentifier))
                    }
                    return prepared
                }.value
                let sharedText = request.items.compactMap { item -> String? in
                    guard item.kind == .text || item.kind == .url else { return nil }
                    return item.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }.joined(separator: "\n")
                let message = [request.message, sharedText]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                let accepted = destinationStore.send(
                    message,
                    attachments: attachments,
                    deliver: false,
                    idempotencyKey: request.id.uuidString)
                { [weak self] succeeded in
                    guard let self else { return }
                    self.shareRequestsInFlight.remove(request.id)
                    if succeeded { try? inbox.remove(request) }
                }
                if !accepted {
                    destinationStore.showError("This shared item is still queued because Cast couldn’t prepare it for sending.")
                }
                awaitingSendCompletion = accepted
            } catch {
                destinationStore.showError("Shared item: \(error.localizedDescription)")
            }
        }
    }
    #endif
}

struct UnreadDestination: Equatable, Sendable {
    let workspaceID: String
    let sessionKey: String
}

/// A notification-panel row: one workspace's chat carrying unread state.
public struct UnreadInboxItem: Identifiable, Equatable, Sendable {
    public let workspaceID: String
    public let workspaceName: String
    public let summary: ChatUnreadSummary

    public var id: String { "\(self.workspaceID):\(self.summary.sessionKey)" }
}

/// Shared routing policy for the aggregate badge on macOS and iOS. It deliberately returns a
/// destination instead of mutating unread state; selecting the resulting sidebar row owns the
/// existing per-conversation mark-read transaction and authoritative gateway patch.
enum UnreadNavigation {
    static func firstSessionKey(
        in sections: [SidebarSection],
        unreadCount: (String) -> Int) -> String?
    {
        sections.lazy
            .flatMap(\.sessions)
            .first { unreadCount($0.key) > 0 }?
            .key
    }

    static func nextDestination(
        selectedWorkspaceID: String,
        workspaceIDs: [String],
        firstUnreadSessionKey: (String) -> String?) -> UnreadDestination?
    {
        let orderedWorkspaceIDs = [selectedWorkspaceID]
            + workspaceIDs.filter { $0 != selectedWorkspaceID }
        for workspaceID in orderedWorkspaceIDs {
            guard let sessionKey = firstUnreadSessionKey(workspaceID) else { continue }
            return UnreadDestination(workspaceID: workspaceID, sessionKey: sessionKey)
        }
        return nil
    }
}
