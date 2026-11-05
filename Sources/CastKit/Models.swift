// Cast — typed gateway payload models (lenient decode; shapes verified live 2026-07-21).
import CryptoKit
import Foundation

// MARK: - Sessions

public struct SessionRow: Codable, Identifiable, Sendable, Equatable {
    public var id: String { self.key }
    public let key: String
    public let kind: String?
    public let displayName: String?
    public let derivedTitle: String?
    public let lastMessagePreview: String?
    public let channel: String?
    public let updatedAt: Double?
    public let unread: Bool?
    public let pinned: Bool?
    public let hasActiveRun: Bool?
    public let model: String?
    public let modelInfo: SessionModelInfo?
    public let status: String?
    public let abortedLastRun: Bool?
    public let spawnedBy: String?
    public let label: String?
    public let subagentRole: String?
    /// Cumulative usage the gateway already tracks per session (`sessions.list`, verified
    /// against the installed dist's `listSessionsFromStoreAsync`). `totalTokens` is the last
    /// run's prompt size; `contextTokens` is the model's window.
    public let inputTokens: Double?
    public let outputTokens: Double?
    public let totalTokens: Double?
    public let contextTokens: Double?
    public let totalTokensFresh: Bool?
    public let estimatedCostUsd: Double?

    public init(
        key: String,
        kind: String?,
        displayName: String?,
        derivedTitle: String?,
        lastMessagePreview: String?,
        channel: String?,
        updatedAt: Double?,
        unread: Bool?,
        pinned: Bool?,
        hasActiveRun: Bool?,
        model: String?,
        status: String? = nil,
        abortedLastRun: Bool? = nil,
        spawnedBy: String? = nil,
        label: String? = nil,
        subagentRole: String? = nil,
        inputTokens: Double? = nil,
        outputTokens: Double? = nil,
        totalTokens: Double? = nil,
        contextTokens: Double? = nil,
        modelInfo: SessionModelInfo? = nil,
        totalTokensFresh: Bool? = nil,
        estimatedCostUsd: Double? = nil)
    {
        self.key = key
        self.kind = kind
        self.displayName = displayName
        self.derivedTitle = derivedTitle
        self.lastMessagePreview = lastMessagePreview
        self.channel = channel
        self.updatedAt = updatedAt
        self.unread = unread
        self.pinned = pinned
        self.hasActiveRun = hasActiveRun
        self.model = model
        self.modelInfo = modelInfo
        self.status = status
        self.abortedLastRun = abortedLastRun
        self.spawnedBy = spawnedBy
        self.label = label
        self.subagentRole = subagentRole
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.contextTokens = contextTokens
        self.totalTokensFresh = totalTokensFresh
        self.estimatedCostUsd = estimatedCostUsd.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    public var title: String {
        if let name = self.displayName, !name.isEmpty { return name }
        if let derived = self.derivedTitle, !derived.isEmpty { return derived }
        return self.key
    }

    public var updatedDate: Date? {
        guard let ms = self.updatedAt else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    public var isUnread: Bool { self.unread == true }

    /// How full this session's context window is, 0...1, or nil when the gateway did not
    /// report both counts. `totalTokens` can briefly exceed `contextTokens` right before a
    /// compaction, so the fraction is clamped rather than trusted as a ratio.
    public var contextFillFraction: Double? {
        guard self.totalTokensFresh != false,
              let total = self.totalTokens, let window = self.contextTokens,
              total.isFinite, window.isFinite, window > 0, total >= 0
        else { return nil }
        return min(total / window, 1)
    }

    public func settingUnread(_ unread: Bool) -> SessionRow {
        SessionRow(
            key: self.key,
            kind: self.kind,
            displayName: self.displayName,
            derivedTitle: self.derivedTitle,
            lastMessagePreview: self.lastMessagePreview,
            channel: self.channel,
            updatedAt: self.updatedAt,
            unread: unread,
            pinned: self.pinned,
            hasActiveRun: self.hasActiveRun,
            model: self.model,
            status: self.status,
            abortedLastRun: self.abortedLastRun,
            spawnedBy: self.spawnedBy,
            label: self.label,
            subagentRole: self.subagentRole,
            inputTokens: self.inputTokens,
            outputTokens: self.outputTokens,
            totalTokens: self.totalTokens,
            contextTokens: self.contextTokens,
            modelInfo: self.modelInfo,
            totalTokensFresh: self.totalTokensFresh,
            estimatedCostUsd: self.estimatedCostUsd)
    }

    enum CodingKeys: String, CodingKey {
        case key, kind, displayName, derivedTitle, lastMessagePreview, channel, updatedAt
        case unread, pinned, hasActiveRun, model, modelInfo, status, abortedLastRun, spawnedBy, label, subagentRole
        case inputTokens, outputTokens, totalTokens, contextTokens, totalTokensFresh, estimatedCostUsd
    }

    /// Session rows evolve independently of Cast releases. One malformed optional field
    /// must not discard an otherwise usable row from the sidebar.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            kind: (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? nil,
            displayName: (try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? nil,
            derivedTitle: (try? container.decodeIfPresent(String.self, forKey: .derivedTitle)) ?? nil,
            lastMessagePreview: (try? container.decodeIfPresent(String.self, forKey: .lastMessagePreview)) ?? nil,
            channel: (try? container.decodeIfPresent(String.self, forKey: .channel)) ?? nil,
            updatedAt: (try? container.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? nil,
            unread: (try? container.decodeIfPresent(Bool.self, forKey: .unread)) ?? nil,
            pinned: (try? container.decodeIfPresent(Bool.self, forKey: .pinned)) ?? nil,
            hasActiveRun: (try? container.decodeIfPresent(Bool.self, forKey: .hasActiveRun)) ?? nil,
            model: (try? container.decodeIfPresent(String.self, forKey: .model)) ?? nil,
            status: (try? container.decodeIfPresent(String.self, forKey: .status)) ?? nil,
            abortedLastRun: (try? container.decodeIfPresent(Bool.self, forKey: .abortedLastRun)) ?? nil,
            spawnedBy: (try? container.decodeIfPresent(String.self, forKey: .spawnedBy)) ?? nil,
            label: (try? container.decodeIfPresent(String.self, forKey: .label)) ?? nil,
            subagentRole: (try? container.decodeIfPresent(String.self, forKey: .subagentRole)) ?? nil,
            inputTokens: (try? container.decodeIfPresent(Double.self, forKey: .inputTokens)) ?? nil,
            outputTokens: (try? container.decodeIfPresent(Double.self, forKey: .outputTokens)) ?? nil,
            totalTokens: (try? container.decodeIfPresent(Double.self, forKey: .totalTokens)) ?? nil,
            contextTokens: (try? container.decodeIfPresent(Double.self, forKey: .contextTokens)) ?? nil,
            modelInfo: (try? container.decodeIfPresent(SessionModelInfo.self, forKey: .modelInfo)) ?? (try? SessionModelInfo(from: decoder)),
            totalTokensFresh: (try? container.decodeIfPresent(Bool.self, forKey: .totalTokensFresh)) ?? nil,
            estimatedCostUsd: (try? container.decodeIfPresent(Double.self, forKey: .estimatedCostUsd)) ?? nil)
    }
}

public struct SessionsListResponse: Decodable, Sendable {
    public struct Defaults: Decodable, Sendable {
        public let mainSessionKey: String?
    }

    public let sessions: [SessionRow]
    public let defaults: Defaults?
}

// MARK: - Transcript messages

public struct ChatContentBlock: Codable, Sendable, Equatable {
    public let type: String?
    public let text: String?
    public let thinking: String?
    public let name: String?
    public let mimeType: String?
    public let fileName: String?
    public let id: String?
    public let arguments: AnyCodable?
    public let attachment: ManagedChatAttachment?

    public init(
        type: String?,
        text: String?,
        thinking: String?,
        name: String?,
        mimeType: String?,
        fileName: String?,
        id: String? = nil,
        arguments: AnyCodable? = nil,
        attachment: ManagedChatAttachment? = nil
    ) {
        self.type = type
        self.text = text
        self.thinking = thinking
        self.name = name
        self.mimeType = mimeType
        self.fileName = fileName
        self.id = id
        self.arguments = arguments
        self.attachment = attachment
    }

    /// Live gateway emits lowercase types: text, thinking, toolcall, tool_result, image.
    public var normalizedType: String {
        (self.type ?? "").lowercased().replacingOccurrences(of: "_", with: "")
    }

    public var isToolCall: Bool {
        self.normalizedType == "toolcall" || self.normalizedType == "tooluse"
    }

    enum CodingKeys: String, CodingKey {
        case type, text, thinking, name, mimeType, fileName, id, arguments, input, attachment
    }

    /// Field-level leniency: one odd field (arguments as string, content arrays, bare-string
    /// blocks) must never drop the whole block, let alone the message row.
    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            let text = try? decoder.singleValueContainer().decode(String.self)
            self.init(type: "text", text: text, thinking: nil, name: nil, mimeType: nil, fileName: nil)
            return
        }
        self.init(
            type: (try? container.decodeIfPresent(String.self, forKey: .type)) ?? nil,
            text: (try? container.decodeIfPresent(String.self, forKey: .text)) ?? nil,
            thinking: (try? container.decodeIfPresent(String.self, forKey: .thinking)) ?? nil,
            name: (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil,
            mimeType: (try? container.decodeIfPresent(String.self, forKey: .mimeType)) ?? nil,
            fileName: (try? container.decodeIfPresent(String.self, forKey: .fileName)) ?? nil,
            id: (try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil,
            arguments: (try? container.decodeIfPresent(AnyCodable.self, forKey: .arguments))
                ?? ((try? container.decodeIfPresent(AnyCodable.self, forKey: .input)) ?? nil),
            attachment: ManagedChatAttachment.decodeBlock(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.type, forKey: .type)
        try container.encodeIfPresent(self.text, forKey: .text)
        try container.encodeIfPresent(self.thinking, forKey: .thinking)
        try container.encodeIfPresent(self.name, forKey: .name)
        try container.encodeIfPresent(self.mimeType, forKey: .mimeType)
        try container.encodeIfPresent(self.fileName, forKey: .fileName)
        try container.encodeIfPresent(self.id, forKey: .id)
        try container.encodeIfPresent(self.arguments, forKey: .arguments)
        try container.encodeIfPresent(self.attachment, forKey: .attachment)
    }
}

/// Local send lifecycle for an optimistic user echo. Every gateway-authored row is
/// `.delivered`; only rows Cast appended itself can still be `.pending` or `.failed`.
public enum LocalDeliveryState: String, Codable, Sendable {
    case pending
    case delivered
    case failed
    case uncertain
}

public struct ChatMessage: Identifiable, Sendable, Encodable, Equatable {
    public let id: String
    public let gatewayRequestID: String?
    public let responseModel: String?
    public let responseProvider: String?
    public let role: String
    public let blocks: [ChatContentBlock]
    public let timestamp: Double?
    public var managedAttachments: [ManagedChatAttachment] { blocks.compactMap(\.attachment) }
    /// Gateway-host file paths for inbound attachments (message-level MediaPath/MediaPaths,
    /// verified live 2026-07-21). Paths resolve locally only for loopback workspaces.
    public let mediaPaths: [String]
    public let mediaTypes: [String]
    /// Transient optimistic-echo image bytes; never cached or sent back over the wire.
    public var localImageData: [Data]
    /// Whether this row's send has been accepted by the gateway. Deliberately excluded from
    /// the content-addressed identity: a bubble must keep its id while it fails and retries,
    /// or SwiftUI reads each state change as a delete plus insert.
    public var localDeliveryState: LocalDeliveryState
    /// The idempotency key the failed send used, kept on the row so a retry — including one
    /// after relaunch, off the cached transcript — resends under the same key and a first
    /// attempt that actually reached the gateway cannot post twice.
    public let localIdempotencyKey: String?
    /// Which gateway surface wrote the row (`api` on the wire). `cli` marks the reply the
    /// gateway delivered itself for a claude-cli turn; `anthropic-messages` marks a model step.
    public let transport: String?
    /// Set when the gateway imported the row from an external transcript
    /// (`__openclaw.importedFrom`, e.g. `claude-cli` for the CLI session file the backend
    /// replays next to its own delivery records).
    public let importedFrom: String?

    public var date: Date? {
        guard let ms = self.timestamp else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    public var text: String {
        self.blocks.compactMap { block -> String? in
            guard block.normalizedType == "text" || (block.type == nil && block.text != nil) else { return nil }
            return block.text
        }.joined(separator: "\n\n")
    }

    public var toolNames: [String] {
        self.blocks.filter(\.isToolCall).compactMap(\.name)
    }

    public var isUser: Bool { self.role == "user" }

    public init(
        id: String = UUID().uuidString,
        role: String,
        blocks: [ChatContentBlock],
        timestamp: Double?,
        mediaPaths: [String] = [],
        mediaTypes: [String] = [],
        localImageData: [Data] = [],
        localDeliveryState: LocalDeliveryState = .delivered,
        localIdempotencyKey: String? = nil,
        responseModel: String? = nil,
        responseProvider: String? = nil,
        gatewayRequestID: String? = nil,
        transport: String? = nil,
        importedFrom: String? = nil
    ) {
        self.gatewayRequestID = gatewayRequestID
        self.responseModel = responseModel
        self.responseProvider = responseProvider
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
        self.mediaPaths = mediaPaths
        self.mediaTypes = mediaTypes
        self.localImageData = localImageData
        self.localDeliveryState = localDeliveryState
        self.localIdempotencyKey = localIdempotencyKey
        self.transport = transport
        self.importedFrom = importedFrom
    }
}

extension ChatMessage: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, model, provider, idempotencyKey, gatewayRequestID
        case mediaPath = "MediaPath"
        case mediaPaths = "MediaPaths"
        case mediaType = "MediaType"
        case mediaTypes = "MediaTypes"
        case localDeliveryState, localIdempotencyKey
        case api
        case openclawMeta = "__openclaw"
    }

    enum OpenClawMetaKeys: String, CodingKey {
        case importedFrom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.transport = (try? container.decodeIfPresent(String.self, forKey: .api)) ?? nil
        if let meta = try? container.nestedContainer(keyedBy: OpenClawMetaKeys.self, forKey: .openclawMeta) {
            self.importedFrom = (try? meta.decodeIfPresent(String.self, forKey: .importedFrom)) ?? nil
        } else {
            self.importedFrom = nil
        }
        let wireKey = try? container.decodeIfPresent(String.self, forKey: .idempotencyKey)
        self.gatewayRequestID = (try? container.decodeIfPresent(String.self, forKey: .gatewayRequestID))
            ?? wireKey.map { $0.hasSuffix(":user") ? String($0.dropLast(5)) : $0 }
        self.responseModel = try? container.decodeIfPresent(String.self, forKey: .model)
        self.responseProvider = try? container.decodeIfPresent(String.self, forKey: .provider)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.role = try container.decodeIfPresent(String.self, forKey: .role) ?? "unknown"
        self.timestamp = try? container.decodeIfPresent(Double.self, forKey: .timestamp)
        if let blocks = try? container.decode([ChatContentBlock].self, forKey: .content) {
            self.blocks = blocks
        } else if let text = try? container.decode(String.self, forKey: .content) {
            self.blocks = [ChatContentBlock(type: "text", text: text, thinking: nil, name: nil, mimeType: nil, fileName: nil)]
        } else {
            self.blocks = []
        }
        if let paths = (try? container.decodeIfPresent([String].self, forKey: .mediaPaths)) ?? nil, !paths.isEmpty {
            self.mediaPaths = paths
        } else if let path = (try? container.decodeIfPresent(String.self, forKey: .mediaPath)) ?? nil {
            self.mediaPaths = [path]
        } else {
            self.mediaPaths = []
        }
        if let types = (try? container.decodeIfPresent([String].self, forKey: .mediaTypes)) ?? nil, !types.isEmpty {
            self.mediaTypes = types
        } else if let type = (try? container.decodeIfPresent(String.self, forKey: .mediaType)) ?? nil {
            self.mediaTypes = [type]
        } else {
            self.mediaTypes = []
        }
        self.localImageData = []
        // Gateway rows never carry these keys; only Cast's own transcript cache does.
        self.localDeliveryState = (try? container.decodeIfPresent(
            LocalDeliveryState.self, forKey: .localDeliveryState)) ?? .delivered
        self.localIdempotencyKey = (try? container.decodeIfPresent(
            String.self, forKey: .localIdempotencyKey)) ?? nil
    }
}

extension ChatMessage {
    /// Deterministic identity for rows the gateway did not label with an `id`.
    ///
    /// Decoding those rows to a fresh `UUID` gave the same logical message a different
    /// identity every time it was decoded again, so a history reconcile flipped ids in
    /// place. `TranscriptGroup.id` and `ToolRun.id` derive from a message id, which made
    /// `ForEach` read the whole transcript as a delete plus re-insert — the LazyVStack was
    /// rebuilt and the reader's scroll offset reset to the top.
    ///
    /// `positionSalt` is the row's index inside the batch it arrived in. Two byte-identical
    /// rows in one page would otherwise hash to a single id and `ChatStore.dedupedByID`
    /// would silently drop the second.
    public static func contentAddressedID(for message: ChatMessage, positionSalt: Int) -> String {
        var canonical = "\(positionSalt)\u{1}\(message.role)\u{1}"
        canonical += message.timestamp.map { "\($0)" } ?? ""
        for block in message.blocks {
            canonical += "\u{1}\(block.type ?? "")\u{2}\(block.id ?? "")\u{2}\(block.name ?? "")"
            canonical += "\u{2}\(block.text ?? "")\u{2}\(block.thinking ?? "")"
            canonical += "\u{2}\(block.mimeType ?? "")\u{2}\(block.fileName ?? "")"
            if let attachment = block.attachment { canonical += "\u{2}\(attachment.artifactId)" }
        }
        canonical += "\u{1}\(message.mediaPaths.joined(separator: "\u{2}"))"
        canonical += "\u{1}\(message.mediaTypes.joined(separator: "\u{2}"))"
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return "msg-\(digest)"
    }

    /// The same row, keyed by what it contains instead of by a random `UUID`.
    public func identifiedByContent(positionSalt: Int = 0) -> ChatMessage {
        self.withID(Self.contentAddressedID(for: self, positionSalt: positionSalt))
    }

    /// The same row under a different identifier. `id` is `let`, and identity is the only
    /// field reconciliation ever needs to override.
    public func withID(_ id: String) -> ChatMessage {
        ChatMessage(
            id: id,
            role: self.role,
            blocks: self.blocks,
            timestamp: self.timestamp,
            mediaPaths: self.mediaPaths,
            mediaTypes: self.mediaTypes,
            localImageData: self.localImageData,
            localDeliveryState: self.localDeliveryState,
            localIdempotencyKey: self.localIdempotencyKey,
            responseModel: self.responseModel,
            responseProvider: self.responseProvider,
            gatewayRequestID: self.gatewayRequestID,
            transport: self.transport,
            importedFrom: self.importedFrom)
    }

    /// The same row with different content blocks; identity and every other field are kept.
    public func withBlocks(_ blocks: [ChatContentBlock]) -> ChatMessage {
        ChatMessage(
            id: self.id,
            role: self.role,
            blocks: blocks,
            timestamp: self.timestamp,
            mediaPaths: self.mediaPaths,
            mediaTypes: self.mediaTypes,
            localImageData: self.localImageData,
            localDeliveryState: self.localDeliveryState,
            localIdempotencyKey: self.localIdempotencyKey,
            responseModel: self.responseModel,
            responseProvider: self.responseProvider,
            gatewayRequestID: self.gatewayRequestID,
            transport: self.transport,
            importedFrom: self.importedFrom)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.transport, forKey: .api)
        if let importedFrom = self.importedFrom {
            var meta = container.nestedContainer(keyedBy: OpenClawMetaKeys.self, forKey: .openclawMeta)
            try meta.encode(importedFrom, forKey: .importedFrom)
        }
        try container.encodeIfPresent(self.gatewayRequestID, forKey: .gatewayRequestID)
        try container.encodeIfPresent(self.responseModel, forKey: .model)
        try container.encodeIfPresent(self.responseProvider, forKey: .provider)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.role, forKey: .role)
        try container.encode(self.blocks, forKey: .content)
        try container.encodeIfPresent(self.timestamp, forKey: .timestamp)
        if !self.mediaPaths.isEmpty { try container.encode(self.mediaPaths, forKey: .mediaPaths) }
        if !self.mediaTypes.isEmpty { try container.encode(self.mediaTypes, forKey: .mediaTypes) }
        // Only unsettled local sends serialize their state; every other row is implicitly
        // `.delivered`, so cached transcripts do not grow a field per historical message.
        if self.localDeliveryState != .delivered {
            try container.encode(self.localDeliveryState, forKey: .localDeliveryState)
            try container.encodeIfPresent(self.localIdempotencyKey, forKey: .localIdempotencyKey)
        }
    }
}

public struct ChatHistoryPayload: Decodable, Sendable {
    public struct SessionInfo: Decodable, Sendable {
        public let hasActiveRun: Bool?
        public let activeRunIds: [String]?
    }

    public struct InFlightRun: Decodable, Sendable {
        public let runId: String
        public let text: String?
    }

    public let sessionKey: String?
    public let messages: [AnyCodable]?
    public let offset: Int?
    public let nextOffset: Int?
    public let hasMore: Bool?
    public let totalMessages: Int?
    public let sessionInfo: SessionInfo?
    public let inFlightRun: InFlightRun?

    /// Per-row defensive decode: one malformed row must not drop the transcript.
    public func decodedMessages() -> [ChatMessage] {
        guard let rows = self.messages else { return [] }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return rows.enumerated().compactMap { index, row in
            guard let data = try? encoder.encode(row) else { return nil }
            guard let message = try? decoder.decode(ChatMessage.self, from: data) else { return nil }
            guard row["id"]?.stringValue?.isEmpty != false else { return message }
            return message.withID(
                ChatMessage.contentAddressedID(for: message, positionSalt: index))
        }
    }
}

// MARK: - Events

public struct ChatEventPayload: Decodable, Sendable {
    public let runId: String?
    public let sessionKey: String?
    public let state: String?
    public let deltaText: String?
    public let replace: Bool?
    public let errorMessage: String?
    /// `refusal | timeout | rate_limit | context_length | unknown` on `state:"error"`
    /// (ChatErrorEventSchema, verified against the installed dist). Kept as a raw string so
    /// a future kind degrades to the generic alert instead of dropping the event.
    public let errorKind: String?
    public let errorDetail: GatewayChatErrorDetail?
    public let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case runId, sessionKey, state, deltaText, replace, errorMessage, errorKind, errorDetail, stopReason
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.runId = try? c.decode(String.self, forKey: .runId)
        self.sessionKey = try? c.decode(String.self, forKey: .sessionKey)
        self.state = try? c.decode(String.self, forKey: .state)
        self.deltaText = try? c.decode(String.self, forKey: .deltaText)
        self.replace = try? c.decode(Bool.self, forKey: .replace)
        self.errorMessage = try? c.decode(String.self, forKey: .errorMessage)
        self.errorKind = try? c.decode(String.self, forKey: .errorKind)
        self.errorDetail = try? c.decode(GatewayChatErrorDetail.self, forKey: .errorDetail)
        self.stopReason = try? c.decode(String.self, forKey: .stopReason)
    }
}

public struct AgentEventPayload: Decodable, Sendable {
    public let runId: String?
    public let sessionKey: String?
    public let stream: String?
    public let data: AnyCodable?
}

public struct ChatSendResponse: Decodable, Sendable {
    public let runId: String?
    public let status: String?
}

// MARK: - Approvals and presence

/// Which approval family a prompt belongs to. Not on the wire — both families broadcast
/// `{id, request, createdAtMs, expiresAtMs}` — so the receiver tags it from the event or
/// replay-list name, and resolve routes to the matching `*.approval.resolve` method.
public enum ApprovalKind: String, Sendable {
    case exec
    case plugin
}

public struct ExecApproval: Decodable, Identifiable, Sendable, Equatable {
    public struct Request: Decodable, Sendable, Equatable {
        public struct SystemRunPlan: Decodable, Sendable, Equatable {
            public let commandText: String?
            public let commandPreview: String?
            public let cwd: String?
        }

        public let command: String?
        public let rawCommand: String?
        public let cwd: String?
        public let host: String?
        public let agentId: String?
        public let sessionKey: String?
        public let systemRunPlan: SystemRunPlan?
        // Plugin-approval request fields (PluginApprovalRequestParams in the installed
        // dist); nil on exec approvals. Same struct so both families share the card path.
        public let title: String?
        public let description: String?
        public let pluginId: String?
        public let toolName: String?
        public let allowedDecisions: [String]?
    }

    public let id: String
    public let request: Request
    public let createdAtMs: Double?
    public let expiresAtMs: Double?
    public var kind: ApprovalKind = .exec

    enum CodingKeys: String, CodingKey { case id, request, createdAtMs, expiresAtMs }

    public var commandText: String {
        self.request.systemRunPlan?.commandPreview
            ?? self.request.systemRunPlan?.commandText
            ?? self.request.rawCommand
            ?? self.request.command
            ?? self.request.title
            ?? "Command details unavailable"
    }

    public var cwd: String? { self.request.cwd ?? self.request.systemRunPlan?.cwd }
    public var isExpired: Bool { (self.expiresAtMs ?? .greatestFiniteMagnitude) <= Date().timeIntervalSince1970 * 1000 }

    /// Plugin approvals may narrow the decision set (`allowedDecisions`); the gateway
    /// rejects anything outside it, so the card must not offer those buttons. Exec
    /// approvals never carry the field and allow all three.
    public func allows(decision: String) -> Bool {
        guard let allowed = self.request.allowedDecisions else { return true }
        return allowed.contains(decision)
    }
}

public struct PresenceEntry: Decodable, Identifiable, Sendable, Equatable {
    public var id: String { self.deviceId ?? self.instanceId ?? "\(self.host ?? "device")-\(self.ts ?? 0)" }
    public let deviceId: String?
    public let instanceId: String?
    public let host: String?
    public let platform: String?
    public let deviceFamily: String?
    public let mode: String?
    public let text: String?
    public let ts: Double?
}

// MARK: - Progress card

public enum ProgressStepStatus: String, Codable, Sendable, Equatable {
    case pending
    case inProgress = "in_progress"
    case completed
    /// Gateway may add new statuses; unknown falls back to pending rendering.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProgressStepStatus(rawValue: raw) ?? .unknown
    }
}

public struct ProgressStep: Codable, Sendable, Equatable {
    public let step: String
    public let status: ProgressStepStatus
}

/// Durable per-session status card published by the gateway's `progressCard` tool.
/// `updatedAt` is epoch milliseconds (JavaScript `Date.now()`).
public struct ProgressCard: Codable, Sendable, Equatable {
    public let sessionKey: String
    public let revision: Int
    public let updatedAt: Double
    public let markdown: String?
    public let steps: [ProgressStep]?

    public var updatedDate: Date { Date(timeIntervalSince1970: self.updatedAt / 1000) }

    public var completedStepCount: Int { self.steps?.filter { $0.status == .completed }.count ?? 0 }
    public var totalStepCount: Int { self.steps?.count ?? 0 }

    /// Lenient decode: one bad field must not discard the whole card.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionKey = (try? c.decode(String.self, forKey: .sessionKey)) ?? ""
        self.revision = (try? c.decode(Int.self, forKey: .revision)) ?? 0
        self.updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
        self.markdown = (try? c.decodeIfPresent(String.self, forKey: .markdown)) ?? nil
        self.steps = (try? c.decodeIfPresent([ProgressStep].self, forKey: .steps)) ?? nil
    }
}
