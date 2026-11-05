// Cast — gateway protocol v4 frames (see products/cast/protocol-notes.md).
import Foundation

public struct RequestFrame: Encodable, Sendable {
    public let type = "req"
    public let id: String
    public let method: String
    public let params: AnyCodable?

    enum CodingKeys: String, CodingKey { case type, id, method, params }

    public init(id: String, method: String, params: AnyCodable?) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct ResponseFrame: Decodable, Sendable {
    public let id: String
    public let ok: Bool?
    public let payload: AnyCodable?
    public let error: [String: AnyCodable]?
}

public struct EventFrame: Decodable, Sendable {
    public let event: String
    public let payload: AnyCodable?
    public let seq: Int?
}

public enum GatewayFrame: Decodable, Sendable {
    case res(ResponseFrame)
    case event(EventFrame)
    case unknown

    enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)
        switch type {
        case "res":
            self = try .res(ResponseFrame(from: decoder))
        case "event":
            self = try .event(EventFrame(from: decoder))
        default:
            self = .unknown
        }
    }
}

public struct GatewayRequestError: Error, LocalizedError, Sendable {
    public let method: String
    public let code: String?
    public let message: String?
    public let reason: String?
    public let recommendedNextStep: String?
    public let retryAfterMs: Int?

    public init(
        method: String,
        code: String?,
        message: String?,
        recommendedNextStep: String? = nil,
        retryAfterMs: Int? = nil,
        reason: String? = nil)
    {
        self.method = method
        self.reason = reason
        self.code = code
        self.message = message
        self.recommendedNextStep = recommendedNextStep
        self.retryAfterMs = retryAfterMs
    }

    public var errorDescription: String? {
        "\(self.method) failed: \(self.code ?? "?") \(self.message ?? "")"
    }
}
