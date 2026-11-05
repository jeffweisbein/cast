import Foundation

/// Deliberately excludes providerErrorMessagePreview, raw errors, provider/model names,
/// and arbitrary metadata. Only recognized categories ever reach the UI or share sheet.
public struct GatewayChatErrorDetail: Decodable, Sendable {
    public let failoverReason: String?
    public let providerRuntimeFailureKind: String?
    public let httpStatus: Int?

    enum CodingKeys: String, CodingKey { case failoverReason, providerRuntimeFailureKind, httpStatus }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.failoverReason = try? c.decode(String.self, forKey: .failoverReason)
        self.providerRuntimeFailureKind = try? c.decode(String.self, forKey: .providerRuntimeFailureKind)
        let status = try? c.decode(Int.self, forKey: .httpStatus)
        self.httpStatus = status.flatMap { (100...599).contains($0) ? $0 : nil }
    }
}

public enum RunFailureCategory: String, Sendable, Equatable {
    case refusal, timeout, rateLimit, contextLength, modelUnavailable, authentication
    case billing, overloaded, sessionExpired, invalidRequest, unknown

    public static func resolve(kind: String?, detail: GatewayChatErrorDetail?) -> Self {
        // A recognized top-level category is authoritative. Unknown/missing categories
        // can use structured provider facts; arbitrary error text is never inspected.
        switch kind {
        case "refusal": return .refusal
        case "timeout": return .timeout
        case "rate_limit": return .rateLimit
        case "context_length": return .contextLength
        default: break
        }
        for reason in [detail?.providerRuntimeFailureKind, detail?.failoverReason].compactMap({ $0 }) {
            switch reason {
            case "model_not_found": return .modelUnavailable
            case "auth", "auth_permanent": return .authentication
            case "billing": return .billing
            case "rate_limit": return .rateLimit
            case "overloaded", "server_error": return .overloaded
            case "timeout": return .timeout
            case "context_overflow": return .contextLength
            case "session_expired": return .sessionExpired
            case "format": return .invalidRequest
            default: continue
            }
        }
        switch detail?.httpStatus {
        case 401, 403: return .authentication
        case 402: return .billing
        case 429: return .rateLimit
        case 500, 502, 503, 504: return .overloaded
        default: return .unknown
        }
    }

    public var title: String {
        switch self {
        case .refusal: return "Model declined the request"
        case .timeout: return "Run timed out"
        case .rateLimit: return "Provider rate limit"
        case .contextLength: return "Conversation context full"
        case .modelUnavailable: return "Model unavailable"
        case .authentication: return "Provider access failed"
        case .billing: return "Provider billing limit"
        case .overloaded: return "Provider temporarily unavailable"
        case .sessionExpired: return "Provider session expired"
        case .invalidRequest: return "Provider rejected the request format"
        case .unknown: return "Run failed — cause not reported"
        }
    }

    public var message: String {
        switch self {
        case .refusal: return "The model declined to complete this request. Rephrase it and try again."
        case .timeout: return "The run timed out before it could finish. Check the conversation and completed actions before retrying."
        case .rateLimit: return "The provider is rate limiting this workspace. Wait for the limit to reset, then review the conversation before retrying."
        case .contextLength: return GatewayFailurePolicy.contextLengthAlert
        case .modelUnavailable: return "The gateway could not use the selected model. Choose an available conversation model, or have your gateway administrator check model access and the installed model client version."
        case .authentication: return "The provider rejected the gateway’s access. Reconnect the provider account in OpenClaw; re-pairing Cast will not fix provider access."
        case .billing: return "The provider reported a billing or spending limit. Check the provider account in OpenClaw. Cast has not changed your plan or spending limits."
        case .overloaded: return "The provider is temporarily unavailable. Wait, then check the conversation before retrying."
        case .sessionExpired: return "The provider’s session expired. Refresh the conversation and check provider-session recovery in OpenClaw. Do not delete this chat to recover it."
        case .invalidRequest: return "The provider rejected the request format. Check gateway/model-client compatibility before retrying the same request."
        case .unknown: return GatewayFailurePolicy.agentRunAlert
        }
    }
}

public struct SessionRunFailure: Equatable, Sendable {
    public let category: RunFailureCategory
    public let observedAt: Date
}

/// In-memory observation, not a claim about unobserved gateway history.
public struct SessionCompactionStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case running, completed, notCompleted, interrupted }
    public let operationID: String
    public let phase: Phase
    public let observedAt: Date
    public let gatewayTimestamp: Double?

    public init(operationID: String, phase: Phase, observedAt: Date, gatewayTimestamp: Double? = nil) {
        self.operationID = operationID
        self.phase = phase
        self.observedAt = observedAt
        self.gatewayTimestamp = gatewayTimestamp
    }

    public var label: String {
        switch self.phase {
        case .running: return "Compacting conversation…"
        case .completed: return "Compaction completed"
        case .notCompleted: return "Compaction did not complete"
        case .interrupted: return "Compaction outcome unconfirmed — refresh to check"
        }
    }
}

extension SessionRow {
    public var contextUsageSummary: String {
        guard self.totalTokensFresh != false else { return "Stale — awaiting updated gateway counts" }
        guard let fraction = self.contextFillFraction, let used = self.totalTokens, let capacity = self.contextTokens
        else { return "Not reported by this gateway" }
        return "\(used.formatted(.number.precision(.fractionLength(0)))) / \(capacity.formatted(.number.precision(.fractionLength(0)))) tokens (\((fraction * 100).formatted(.number.precision(.fractionLength(0))))%)"
    }
}


extension SessionRow {
    public var estimatedCostSummary: String {
        guard let cost = self.estimatedCostUsd else { return "Not reported" }
        return cost.formatted(.currency(code: "USD")) + " estimated"
    }
}

/// A bounded diagnosis request, not an automatic action or a dump of private runtime state.
public enum DiagnosisRequest {
    public static func draft(safeSummary: String) -> String {
        "Investigate this Cast connection/conversation issue read-only. Preserve the current task and model. "
            + "Check these observations against current runtime evidence; do not infer success from a heartbeat. "
            + "Do not restart services, change configuration, replay messages or send anything externally. "
            + "Report the cause, evidence and smallest repair.\n\n"
            + safeSummary
    }
}
