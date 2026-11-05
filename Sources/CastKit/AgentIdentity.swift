import Foundation

/// Public, presentation-safe identity returned by OpenClaw's `agent.identity.get`.
/// Unknown fields are intentionally ignored so gateway additions remain forwards-compatible.
public struct AgentIdentity: Codable, Sendable, Equatable {
    public let agentId: String?
    public let name: String?
    public let emoji: String?
    public let avatar: String?
    public let avatarSource: String?
    public let avatarStatus: String?
    public let avatarReason: String?

    public init(
        agentId: String? = nil,
        name: String? = nil,
        emoji: String? = nil,
        avatar: String? = nil,
        avatarSource: String? = nil,
        avatarStatus: String? = nil,
        avatarReason: String? = nil)
    {
        self.agentId = agentId
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.emoji = emoji?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.avatar = avatar?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.avatarSource = avatarSource
        self.avatarStatus = avatarStatus
        self.avatarReason = avatarReason
    }

    private enum CodingKeys: String, CodingKey {
        case agentId, name, emoji, avatar, avatarSource, avatarStatus, avatarReason
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            agentId: try? values.decodeIfPresent(String.self, forKey: .agentId),
            name: try? values.decodeIfPresent(String.self, forKey: .name),
            emoji: try? values.decodeIfPresent(String.self, forKey: .emoji),
            avatar: try? values.decodeIfPresent(String.self, forKey: .avatar),
            avatarSource: try? values.decodeIfPresent(String.self, forKey: .avatarSource),
            avatarStatus: try? values.decodeIfPresent(String.self, forKey: .avatarStatus),
            avatarReason: try? values.decodeIfPresent(String.self, forKey: .avatarReason))
    }
}

public enum AgentAvatarSource: Sendable, Equatable {
    case data(Data)
    case remote(URL)

    public static let maximumBytes = 1_048_576

    /// Accept only image data URIs, HTTPS URLs, loopback HTTP, or paths hosted by the
    /// configured gateway. Relative paths can never redirect Cast to an unrelated host.
    public static func resolve(_ rawValue: String?, gatewayURL: URL) -> AgentAvatarSource? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else { return nil }

        if rawValue.lowercased().hasPrefix("data:image/") {
            guard let comma = rawValue.firstIndex(of: ",") else { return nil }
            let metadata = rawValue[..<comma].lowercased()
            guard metadata.hasSuffix(";base64") else { return nil }
            let encoded = String(rawValue[rawValue.index(after: comma)...])
            // Base64 expands bytes by ~4/3. Reject before allocating as well as after.
            guard encoded.utf8.count <= ((Self.maximumBytes + 2) / 3) * 4,
                  let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
                  data.count <= Self.maximumBytes
            else { return nil }
            return .data(data)
        }

        if rawValue.hasPrefix("/") {
            guard var components = URLComponents(url: gatewayURL, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = components.scheme == "wss" ? "https" : "http"
            components.path = rawValue
            components.query = nil
            components.fragment = nil
            guard let url = components.url else { return nil }
            return .remote(url)
        }

        guard let url = URL(string: rawValue), let scheme = url.scheme?.lowercased() else { return nil }
        guard scheme == "https" || scheme == "http" else { return nil }
        return Self.isAllowedRemoteURL(url) ? .remote(url) : nil
    }

    public static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http", let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

public enum AgentIdentityFallback {
    public enum Choice: Equatable, Sendable {
        case initials(String)
        case emoji(String)
        case sparkle
    }

    public static func initials(from name: String?) -> String? {
        let words = (name ?? "")
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
        let initials = words.compactMap(\.first).map(String.init).joined().uppercased()
        return initials.isEmpty ? nil : initials
    }

    public static func choice(identityName: String?, emoji: String?, fallbackName: String?) -> Choice {
        if let initials = self.initials(from: identityName) { return .initials(initials) }
        if let emoji = emoji?.trimmingCharacters(in: .whitespacesAndNewlines), !emoji.isEmpty {
            return .emoji(emoji)
        }
        if let initials = self.initials(from: fallbackName) { return .initials(initials) }
        return .sparkle
    }
}

private extension String {
    var nilIfEmpty: String? { self.isEmpty ? nil : self }
}
