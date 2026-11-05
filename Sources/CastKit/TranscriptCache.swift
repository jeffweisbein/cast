import CryptoKit
import Foundation

public struct CachedSearchHit: Identifiable, Sendable, Equatable {
    public let id: String
    public let sessionKey: String
    public let role: String
    public let snippet: String
    public let timestamp: Double?
    public let matchedText: String?

    fileprivate let relevance: Int
}

public struct TranscriptCacheSnapshot: Sendable {
    public let messages: [ChatMessage]
    public let isComplete: Bool
    public let totalMessageCount: Int?
    public let skippedOversizedLegacyFile: Bool

    public init(
        messages: [ChatMessage],
        isComplete: Bool,
        totalMessageCount: Int?,
        skippedOversizedLegacyFile: Bool = false)
    {
        self.messages = messages
        self.isComplete = isComplete
        self.totalMessageCount = totalMessageCount
        self.skippedOversizedLegacyFile = skippedOversizedLegacyFile
    }
}

public enum TranscriptSearchMatcher {
    public static func tokens(in query: String) -> [String] {
        query
            .components(separatedBy: .whitespacesAndNewlines)
            .map(self.folded)
            .filter { !$0.isEmpty }
    }

    public static func relevance(of text: String, query: String) -> Int? {
        let phrase = self.folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let tokens = self.tokens(in: query)
        guard phrase.count >= 2, !tokens.isEmpty else { return nil }
        let haystack = self.folded(text)
        guard tokens.allSatisfy(haystack.contains) else { return nil }

        var score = tokens.count * 100
        if haystack == phrase { score += 2_000 }
        else if haystack.hasPrefix(phrase) { score += 1_200 }
        else if haystack.contains(phrase) { score += 800 }
        // Prefer compact matches over messages where the terms are scattered through a
        // very long transcript row, while keeping recency as the final tie-breaker.
        score += max(0, 300 - min(haystack.count, 300))
        return score
    }

    public static func snippet(in text: String, query: String) -> (text: String, match: String?) {
        let terms = [query.trimmingCharacters(in: .whitespacesAndNewlines)]
            + query.components(separatedBy: .whitespacesAndNewlines)
        let matchRange = terms
            .filter { !$0.isEmpty }
            .compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) }
            .min { text.distance(from: text.startIndex, to: $0.lowerBound)
                < text.distance(from: text.startIndex, to: $1.lowerBound) }

        guard let matchRange else {
            let value = String(text.prefix(180)).replacingOccurrences(of: "\n", with: " ")
            return (value, nil)
        }
        let lower = text.index(matchRange.lowerBound, offsetBy: -55, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(matchRange.upperBound, offsetBy: 115, limitedBy: text.endIndex) ?? text.endIndex
        var value = String(text[lower ..< upper]).replacingOccurrences(of: "\n", with: " ")
        if lower != text.startIndex { value = "…" + value }
        if upper != text.endIndex { value += "…" }
        return (value, String(text[matchRange]))
    }

    private static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

public actor TranscriptCache {
    /// The transcript UI materializes at most 200 items initially and expands in 200-item
    /// chunks. Keeping ten windows on disk makes ordinary offline browsing useful without
    /// decoding and rewriting an unbounded multi-megabyte JSON document on every open/send.
    public nonisolated static let maximumPersistedMessages = 2_000

    /// Old cache files have no sidecar that tells us whether their JSON is bounded. Avoid a
    /// one-time 20+ MB decode on the session-open critical path; the live 200-row tail replaces
    /// it immediately and the utility-priority history backfill rebuilds the bounded cache.
    public nonisolated static let maximumLegacyOpenBytes = 12 * 1_024 * 1_024

    private struct CachedTranscript: Codable {
        let sessionKey: String
        var savedAtMs: Double
        let messages: [ChatMessage]
        let localMediaByMessageID: [String: [String]]?
        let isComplete: Bool?
        let totalMessageCount: Int?
    }

    private struct CacheMetadata: Codable {
        let version: Int
        let contentDigest: String?
    }

    private let root: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(workspaceID: String, root: URL? = nil) {
        self.encoder.outputFormatting = [.sortedKeys]
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.root = base.appendingPathComponent("Cast/Transcripts/\(workspaceID)", isDirectory: true)
            let legacyBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            let legacyRoot = legacyBase?.appendingPathComponent("Cast/Transcripts/\(workspaceID)", isDirectory: true)
            if let legacyRoot {
                Self.migrateLegacyTranscripts(from: legacyRoot, to: self.root)
            }
        }
    }

    public func load(sessionKey: String) -> [ChatMessage] {
        self.loadSnapshot(sessionKey: sessionKey).messages
    }

    public func loadSnapshot(
        sessionKey: String,
        allowOversizedLegacyFile: Bool = false) -> TranscriptCacheSnapshot
    {
        let fileURL = self.url(for: sessionKey)
        let metadata = self.loadMetadata(sessionKey: sessionKey)
        if !allowOversizedLegacyFile,
           metadata == nil,
           let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
           let byteCount = values.fileSize,
           byteCount > Self.maximumLegacyOpenBytes
        {
            return TranscriptCacheSnapshot(
                messages: [],
                isComplete: false,
                totalMessageCount: nil,
                skippedOversizedLegacyFile: true)
        }

        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? self.decoder.decode(CachedTranscript.self, from: data)
        else {
            return TranscriptCacheSnapshot(messages: [], isComplete: false, totalMessageCount: nil)
        }
        let messages = self.rehydratingLocalMedia(
            in: cached.messages,
            references: cached.localMediaByMessageID ?? [:],
            sessionKey: sessionKey)
        return TranscriptCacheSnapshot(
            messages: messages.map { message in
                var recovered = message
                if recovered.localDeliveryState == .pending { recovered.localDeliveryState = .uncertain }
                return recovered
            },
            // Pre-Phase-3 files have no completeness marker. Treat them as partial: an
            // unnecessary utility backfill is safe, while trusting an incomplete legacy
            // file would permanently hide older history behind a false "complete" latch.
            isComplete: cached.isComplete ?? false,
            totalMessageCount: cached.totalMessageCount ?? messages.count)
    }

    public func save(
        _ messages: [ChatMessage],
        sessionKey: String,
        historyIsComplete: Bool = true)
    {
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let persistedMessages = Array(messages.suffix(Self.maximumPersistedMessages))
            let persistedHistoryIsComplete = historyIsComplete
                && persistedMessages.count == messages.count
            let localMediaByMessageID = try self.persistLocalMedia(
                in: messages,
                sessionKey: sessionKey,
                pruneUnused: persistedHistoryIsComplete)
            var payload = CachedTranscript(
                sessionKey: sessionKey,
                savedAtMs: 0,
                messages: persistedMessages,
                localMediaByMessageID: localMediaByMessageID.isEmpty ? nil : localMediaByMessageID,
                isComplete: persistedHistoryIsComplete,
                totalMessageCount: messages.count)
            // History refreshes and duplicate events often produce the same snapshot.
            // Exclude the save clock from its identity; retain only a digest, not another
            // in-memory copy of every session. The sidecar survives app restarts, too.
            let contentDigest = SHA256.hash(data: try self.encoder.encode(payload))
                .map { String(format: "%02x", $0) }.joined()
            if self.loadMetadata(sessionKey: sessionKey)?.contentDigest == contentDigest,
               FileManager.default.fileExists(atPath: self.url(for: sessionKey).path)
            {
                return
            }
            payload.savedAtMs = Date().timeIntervalSince1970 * 1000
            let data = try self.encoder.encode(payload)
            try data.write(to: self.url(for: sessionKey), options: .atomic)
            let metadata = CacheMetadata(version: 1, contentDigest: contentDigest)
            try self.encoder.encode(metadata).write(
                to: self.metadataURL(for: sessionKey),
                options: .atomic)
        } catch {
            // Cache failure never blocks live chat; the gateway remains authoritative.
        }
    }

    public func search(
        _ query: String,
        limit: Int = 40,
        includingSessionKey: String? = nil,
        currentMessages: [ChatMessage] = []) -> [CachedSearchHit]
    {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: self.root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        var hitsByID: [String: CachedSearchHit] = [:]

        func collect(_ messages: [ChatMessage], sessionKey: String) {
            for message in messages.reversed() {
                guard message.role == "user" || message.role == "assistant",
                      let relevance = TranscriptSearchMatcher.relevance(of: message.text, query: needle)
                else { continue }
                let snippet = TranscriptSearchMatcher.snippet(in: message.text, query: needle)
                let id = "\(sessionKey)-\(message.id)"
                let hit = CachedSearchHit(
                    id: id,
                    sessionKey: sessionKey,
                    role: message.role,
                    snippet: snippet.text,
                    timestamp: message.timestamp,
                    matchedText: snippet.match,
                    relevance: relevance)
                if let existing = hitsByID[id] {
                    if hit.relevance > existing.relevance { hitsByID[id] = hit }
                } else {
                    hitsByID[id] = hit
                }
            }
        }

        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file),
                  let cached = try? self.decoder.decode(CachedTranscript.self, from: data)
            else { continue }
            collect(cached.messages, sessionKey: cached.sessionKey)
        }
        if let includingSessionKey, !currentMessages.isEmpty {
            collect(currentMessages, sessionKey: includingSessionKey)
        }

        return hitsByID.values.sorted {
            if $0.relevance != $1.relevance { return $0.relevance > $1.relevance }
            if $0.timestamp != $1.timestamp { return ($0.timestamp ?? 0) > ($1.timestamp ?? 0) }
            return $0.id < $1.id
        }.prefix(max(0, limit)).map { $0 }
    }

    private func url(for sessionKey: String) -> URL {
        self.root.appendingPathComponent("\(Self.digest(sessionKey)).json", isDirectory: false)
    }

    private func metadataURL(for sessionKey: String) -> URL {
        self.root.appendingPathComponent("\(Self.digest(sessionKey)).meta", isDirectory: false)
    }

    private func loadMetadata(sessionKey: String) -> CacheMetadata? {
        guard let data = try? Data(contentsOf: self.metadataURL(for: sessionKey)) else { return nil }
        return try? self.decoder.decode(CacheMetadata.self, from: data)
    }

    private func mediaDirectory(for sessionKey: String) -> URL {
        self.root
            .appendingPathComponent("Media", isDirectory: true)
            .appendingPathComponent(Self.digest(sessionKey), isDirectory: true)
    }

    private func persistLocalMedia(
        in messages: [ChatMessage],
        sessionKey: String,
        pruneUnused: Bool) throws -> [String: [String]]
    {
        let directory = self.mediaDirectory(for: sessionKey)
        var references: [String: [String]] = [:]
        var retainedNames = Set<String>()

        for message in messages where !message.localImageData.isEmpty {
            var names: [String] = []
            for (index, data) in message.localImageData.enumerated() {
                let name = "\(Self.digest(message.id))-\(index).bin"
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(name)
                // Keep legacy deterministic names so backfilled rows still rehydrate.
                // Atomic replacement of every unchanged image on every history poll
                // amplified a day's normal refreshes into tens of GB of disk writes.
                // Map for comparison rather than retain duplicate image buffers.
                if (try? Data(contentsOf: destination, options: .mappedIfSafe)) != data {
                    try data.write(to: destination, options: .atomic)
                }
                names.append(name)
                retainedNames.insert(name)
            }
            references[message.id] = names
        }

        if pruneUnused,
           let existing = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        {
            for file in existing where !retainedNames.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return references
    }

    /// Rehydrates gateway backfill rows from Cast's deterministic media side files. Partial
    /// cache saves deliberately do not delete files for rows outside the retained 2,000-message
    /// JSON tail, so older local images remain readable when the online backfill restores them.
    public func rehydrateLocalMedia(
        in messages: [ChatMessage],
        sessionKey: String) -> [ChatMessage]
    {
        let directory = self.mediaDirectory(for: sessionKey)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        var namesByDigest: [String: [String]] = [:]
        for file in files {
            let name = file.lastPathComponent
            guard name.count > 65 else { continue }
            namesByDigest[String(name.prefix(64)), default: []].append(name)
        }
        guard !namesByDigest.isEmpty else { return messages }
        return messages.map { cached in
            let digest = Self.digest(cached.id)
            guard let names = namesByDigest[digest] else { return cached }
            var message = cached
            message.localImageData = names.sorted().compactMap { name in
                try? Data(contentsOf: directory.appendingPathComponent(name))
            }
            return message
        }
    }

    private func rehydratingLocalMedia(
        in cachedMessages: [ChatMessage],
        references: [String: [String]],
        sessionKey: String) -> [ChatMessage]
    {
        let directory = self.mediaDirectory(for: sessionKey)
        return cachedMessages.map { cached in
            guard let names = references[cached.id] else { return cached }
            var message = cached
            message.localImageData = names.compactMap { name in
                guard name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
                return try? Data(contentsOf: directory.appendingPathComponent(name))
            }
            return message
        }
    }

    private nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func migrateLegacyTranscripts(from legacyRoot: URL, to durableRoot: URL) {
        guard legacyRoot.standardizedFileURL != durableRoot.standardizedFileURL,
              FileManager.default.fileExists(atPath: legacyRoot.path)
        else { return }
        do {
            try FileManager.default.createDirectory(at: durableRoot, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(
                at: legacyRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
            for source in files where source.pathExtension == "json" {
                let destination = durableRoot.appendingPathComponent(source.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
                try FileManager.default.copyItem(at: source, to: destination)
            }
        } catch {
            // Best-effort migration: the gateway can still repopulate durable history.
        }
    }
}
