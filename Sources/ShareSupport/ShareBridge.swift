import Foundation

public enum CastAppGroup {
    public static let identifier = "group.com.besttechie.cast"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: self.identifier)
    }
}

public struct ShareSessionDestination: Codable, Equatable, Identifiable, Sendable {
    public var id: String { self.key }
    public let key: String
    public let name: String
    public let channel: String?

    public init(key: String, name: String, channel: String? = nil) {
        self.key = key
        self.name = name
        self.channel = channel
    }
}

public struct ShareWorkspaceDestination: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public var sessions: [ShareSessionDestination]
    public var preferredSessionKey: String?

    public init(
        id: String,
        name: String,
        sessions: [ShareSessionDestination],
        preferredSessionKey: String? = nil)
    {
        self.id = id
        self.name = name
        self.sessions = sessions
        self.preferredSessionKey = preferredSessionKey
    }
}

/// Non-secret destination metadata shared with the extension. Gateway URLs and
/// credentials deliberately never cross the app-group boundary.
public struct ShareDestinationSnapshot: Codable, Equatable, Sendable {
    public var workspaces: [ShareWorkspaceDestination]
    public var selectedWorkspaceID: String?

    public init(workspaces: [ShareWorkspaceDestination], selectedWorkspaceID: String?) {
        self.workspaces = workspaces
        self.selectedWorkspaceID = selectedWorkspaceID
    }
}

public struct ShareDestinationSelection: Codable, Equatable, Sendable {
    public let workspaceID: String
    public let sessionKey: String

    public init(workspaceID: String, sessionKey: String) {
        self.workspaceID = workspaceID
        self.sessionKey = sessionKey
    }
}

/// Resolves extension defaults from non-secret metadata. The recent selection
/// is only a preference; the containing app remains the source of truth for
/// workspaces, sessions, and credentials.
public enum ShareDestinationResolver {
    public static func resolve(
        snapshot: ShareDestinationSnapshot,
        recent: ShareDestinationSelection?) -> ShareDestinationSelection?
    {
        if let recent, self.contains(recent, in: snapshot) { return recent }
        if let selectedWorkspaceID = snapshot.selectedWorkspaceID,
           let workspace = snapshot.workspaces.first(where: { $0.id == selectedWorkspaceID }),
           let session = self.preferredSession(in: workspace) {
            return ShareDestinationSelection(workspaceID: workspace.id, sessionKey: session.key)
        }
        guard let workspace = snapshot.workspaces.first(where: { !$0.sessions.isEmpty }),
              let session = self.preferredSession(in: workspace)
        else { return nil }
        return ShareDestinationSelection(workspaceID: workspace.id, sessionKey: session.key)
    }

    public static func contains(
        _ selection: ShareDestinationSelection,
        in snapshot: ShareDestinationSnapshot) -> Bool
    {
        snapshot.workspaces.contains { workspace in
            workspace.id == selection.workspaceID
                && workspace.sessions.contains(where: { $0.key == selection.sessionKey })
        }
    }

    /// A queued request is routed exactly as selected. Never silently move a
    /// share to another configured workspace when metadata has changed.
    public static func exactRoute(
        for request: QueuedShareRequest,
        availableWorkspaceIDs: Set<String>) -> ShareDestinationSelection?
    {
        guard availableWorkspaceIDs.contains(request.workspaceID),
              !request.sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return ShareDestinationSelection(
            workspaceID: request.workspaceID,
            sessionKey: request.sessionKey)
    }

    private static func preferredSession(
        in workspace: ShareWorkspaceDestination) -> ShareSessionDestination?
    {
        if let preferredSessionKey = workspace.preferredSessionKey,
           let preferred = workspace.sessions.first(where: { $0.key == preferredSessionKey }) {
            return preferred
        }
        return workspace.sessions.first
    }
}

public struct ShareDestinationStore {
    private static let key = "cast.share.destinations.v1"
    private static let recentKey = "cast.share.recent-destination.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public static var appGroup: ShareDestinationStore? {
        UserDefaults(suiteName: CastAppGroup.identifier).map(Self.init(defaults:))
    }

    public func load() -> ShareDestinationSnapshot {
        guard let data = self.defaults.data(forKey: Self.key),
              let snapshot = try? JSONDecoder().decode(ShareDestinationSnapshot.self, from: data)
        else { return ShareDestinationSnapshot(workspaces: [], selectedWorkspaceID: nil) }
        return snapshot
    }

    public func save(_ snapshot: ShareDestinationSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        self.defaults.set(data, forKey: Self.key)
    }

    public func loadRecentSelection() -> ShareDestinationSelection? {
        guard let data = self.defaults.data(forKey: Self.recentKey) else { return nil }
        return try? JSONDecoder().decode(ShareDestinationSelection.self, from: data)
    }

    public func remember(_ selection: ShareDestinationSelection) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        self.defaults.set(data, forKey: Self.recentKey)
    }
}

public enum SharedItemKind: String, Codable, Sendable {
    case text
    case url
    case image
    case file
}

public struct SharedItemInput: Sendable {
    public let kind: SharedItemKind
    public let text: String?
    public let data: Data?
    public let sourceFileURL: URL?
    public let fileName: String?
    public let typeIdentifier: String?

    public init(
        kind: SharedItemKind,
        text: String? = nil,
        data: Data? = nil,
        sourceFileURL: URL? = nil,
        fileName: String? = nil,
        typeIdentifier: String? = nil)
    {
        self.kind = kind
        self.text = text
        self.data = data
        self.sourceFileURL = sourceFileURL
        self.fileName = fileName
        self.typeIdentifier = typeIdentifier
    }
}

public struct QueuedSharedItem: Codable, Equatable, Sendable {
    public let kind: SharedItemKind
    public let text: String?
    public let relativePath: String?
    public let fileName: String?
    public let typeIdentifier: String?
}

public struct QueuedShareRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let workspaceID: String
    public let sessionKey: String
    public let message: String
    public let items: [QueuedSharedItem]
}

public enum ShareInboxError: Error, LocalizedError, Sendable {
    case appGroupUnavailable
    case emptyShare
    case invalidDestination
    case invalidFile

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable: return "Cast shared storage is unavailable."
        case .emptyShare: return "There is nothing to share."
        case .invalidDestination: return "Choose a Cast destination before sending."
        case .invalidFile: return "A shared file could not be saved."
        }
    }
}

/// A tiny file-backed queue shared by the extension and containing app. Each
/// request owns a directory so its metadata and copied attachments can be
/// removed together only after Cast has accepted the handoff.
public struct ShareInbox: Sendable {
    public let root: URL

    public init(root: URL) throws {
        self.root = root.appendingPathComponent("ShareInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public static var appGroup: ShareInbox? {
        guard let container = CastAppGroup.containerURL else { return nil }
        return try? ShareInbox(root: container)
    }

    @discardableResult
    public func enqueue(
        workspaceID: String,
        sessionKey: String,
        message: String,
        items: [SharedItemInput],
        id: UUID = UUID(),
        createdAt: Date = Date()) throws -> QueuedShareRequest
    {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ShareInboxError.invalidDestination }
        guard !trimmed.isEmpty || !items.isEmpty else { throw ShareInboxError.emptyShare }

        let requestDirectory = self.directory(for: id)
        try FileManager.default.createDirectory(at: requestDirectory, withIntermediateDirectories: true)
        do {
            var queued: [QueuedSharedItem] = []
            for input in items {
                var relativePath: String?
                if let data = input.data {
                    let extensionName = Self.safeExtension(from: input.fileName)
                    let storedName = UUID().uuidString + extensionName
                    let destination = requestDirectory.appendingPathComponent(storedName)
                    try data.write(to: destination, options: .atomic)
                    relativePath = storedName
                } else if let source = input.sourceFileURL {
                    let extensionName = Self.safeExtension(from: input.fileName ?? source.lastPathComponent)
                    let storedName = UUID().uuidString + extensionName
                    let destination = requestDirectory.appendingPathComponent(storedName)
                    let values = try source.resourceValues(forKeys: [.isRegularFileKey])
                    guard values.isRegularFile == true else { throw ShareInboxError.invalidFile }
                    try FileManager.default.copyItem(at: source, to: destination)
                    relativePath = storedName
                }
                queued.append(QueuedSharedItem(
                    kind: input.kind,
                    text: input.text,
                    relativePath: relativePath,
                    fileName: input.fileName,
                    typeIdentifier: input.typeIdentifier))
            }
            let request = QueuedShareRequest(
                id: id,
                createdAt: createdAt,
                workspaceID: workspaceID,
                sessionKey: sessionKey,
                message: trimmed,
                items: queued)
            let data = try JSONEncoder().encode(request)
            try data.write(to: requestDirectory.appendingPathComponent("request.json"), options: .atomic)
            return request
        } catch {
            try? FileManager.default.removeItem(at: requestDirectory)
            throw error
        }
    }

    public func pending() -> [QueuedShareRequest] {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: self.root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return directories.compactMap { directory in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("request.json")) else { return nil }
            return try? JSONDecoder().decode(QueuedShareRequest.self, from: data)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func fileURL(for item: QueuedSharedItem, requestID: UUID) -> URL? {
        guard let relativePath = item.relativePath,
              relativePath == URL(fileURLWithPath: relativePath).lastPathComponent
        else { return nil }
        return self.directory(for: requestID).appendingPathComponent(relativePath)
    }

    public func remove(_ request: QueuedShareRequest) throws {
        let directory = self.directory(for: request.id)
        guard directory.deletingLastPathComponent().standardizedFileURL == self.root.standardizedFileURL else {
            throw ShareInboxError.invalidFile
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func directory(for id: UUID) -> URL {
        self.root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static func safeExtension(from fileName: String?) -> String {
        guard let ext = fileName.map({ URL(fileURLWithPath: $0).pathExtension }),
              !ext.isEmpty,
              ext.count <= 12,
              ext.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return "" }
        return "." + ext.lowercased()
    }
}
