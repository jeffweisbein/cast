import Foundation
import Observation

/// The composer's deliberately narrow observation boundary. ChatStore publishes transcript
/// tokens, session rows, presence, unread ledgers, and dozens of other values; none of those
/// should invalidate the AppKit-backed field editor. Only state rendered by Composer is
/// projected here, while actions continue through ChatStore's existing API.
///
/// Under Observation the projection is by reference rather than by mirror: each property
/// forwards to the store, so reading it inside `Composer.body` registers exactly that one
/// store property with the tracking scope and nothing else. That drops the Combine
/// subscriptions and the duplicated state they kept in sync, and — unlike a mirror driven
/// by `withObservationTracking`, which can only re-read one main-actor hop after the change —
/// the composer never renders a value the store has already moved past.
@MainActor
@Observable
final class ComposerModel {
    @ObservationIgnored private let store: ChatStore

    var pendingAttachments: [PreparedAttachment] { self.store.pendingAttachments }
    var selectedSessionKey: String? { self.store.selectedSessionKey }
    var deliverExternally: Bool { self.store.deliverExternally }
    var lastError: String? { self.store.lastError }
    var contextCompactionOfferKey: String? { self.store.contextCompactionOfferKey }

    init(store: ChatStore) {
        self.store = store
    }
}

/// Display only the gateway's session-reported model, never a guessed global default.
struct ComposerModelStatus: Equatable {
    let label: String
    let help: String
    /// Short name for the in-composer chip: the reported model without its provider prefix.
    /// The full `label` remains the accessibility text.
    let chipLabel: String

    init(model: String?, isConnected: Bool) {
        let name = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.chipLabel = SessionModelSheetState.shortName(name) ?? "Model"
        if name.isEmpty {
            self.label = isConnected ? "Model: unavailable" : "Model: unavailable · Offline"
            self.help = "The gateway has not reported a model for this conversation yet."
        } else if isConnected {
            self.label = "Model: \(name)"
            self.help = "The model currently reported by the gateway for this conversation. Runtime fallbacks appear when the gateway updates the session."
        } else {
            self.label = "Model: \(name) · Offline"
            self.help = "Last reported session model. Reconnect to refresh it."
        }
    }
}

/// Everything the model sheet says, derived only from gateway-reported values and the
/// operator's selection in the sheet. Three things stay distinct: what the conversation is
/// set to now, what actually produced the last reply, and what has been requested for the
/// next turn.
struct SessionModelSheetState: Equatable {
    var sessionModel: String?
    var sessionProvider: String?
    var thinkingOverride: String?
    var thinkingDefault: String?
    var lastResponseModel: String?
    var lastResponseProvider: String?
    var pendingReference: String?
    var choices: [GatewayModelChoice] = []
    var selectedReference = ""
    /// Empty means "model default".
    var selectedEffort = ""
    var supportsControls = true
    var isConnected = true
    var isSaving = false

    static func shortName(_ model: String?) -> String? {
        guard let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        let last = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return last.isEmpty ? trimmed : last
    }

    /// The catalog entry for a session-reported model, which may be a bare id or a
    /// `provider/id` reference.
    static func choice(matching model: String?, provider: String?, in choices: [GatewayModelChoice])
        -> GatewayModelChoice?
    {
        guard let model, !model.isEmpty else { return nil }
        return choices.first {
            ($0.id == model || $0.reference == model) && (provider == nil || $0.provider == provider)
        }
    }

    /// Keeps a reasoning level across a model change only when the destination supports it,
    /// so choosing a model never silently clears or invents an override.
    static func carriedEffort(_ effort: String?, to choice: GatewayModelChoice?) -> String {
        guard let effort, !effort.isEmpty,
              (choice?.thinkingLevels ?? []).contains(where: { $0.id == effort })
        else { return "" }
        return effort
    }

    var currentChoice: GatewayModelChoice? {
        Self.choice(matching: self.sessionModel, provider: self.sessionProvider, in: self.choices)
    }

    var selectedChoice: GatewayModelChoice? {
        self.choices.first { $0.reference == self.selectedReference }
    }

    var currentModelLabel: String {
        if let choice = self.currentChoice { return choice.name }
        let name = self.sessionModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Not reported" : name
    }

    var currentReasoningLabel: String {
        if let level = self.thinkingOverride, !level.isEmpty { return self.effortLabel(level) }
        if let level = self.thinkingDefault ?? self.currentChoice?.thinkingDefault, !level.isEmpty {
            return "Model default · \(self.effortLabel(level))"
        }
        return "Not reported"
    }

    var lastReplyLabel: String? {
        guard let model = self.lastResponseModel, !model.isEmpty else { return nil }
        return [self.lastResponseProvider, model].compactMap { $0 }.joined(separator: "/")
    }

    /// True only when both values are reported and name different models.
    var lastReplyDiffers: Bool {
        guard let reply = Self.shortName(self.lastResponseModel),
              let current = Self.shortName(self.currentChoice?.id ?? self.sessionModel)
        else { return false }
        return reply.caseInsensitiveCompare(current) != .orderedSame
    }

    var requestedLabel: String? {
        guard let reference = self.pendingReference, !reference.isEmpty else { return nil }
        return self.choices.first { $0.reference == reference }?.name ?? reference
    }

    var summaryFootnote: String {
        var parts: [String] = []
        if !self.isConnected { parts.append("Offline — these are the last reported values.") }
        if self.lastReplyDiffers {
            parts.append("The last reply came from a different model: either a change that starts with the next turn, or a gateway fallback.")
        }
        parts.append("Cast shows only what the gateway reports.")
        return parts.joined(separator: " ")
    }

    var effortOptions: [ThinkingOption] { self.selectedChoice?.thinkingLevels ?? [] }

    var defaultEffortLabel: String {
        guard let level = self.selectedChoice?.thinkingDefault, !level.isEmpty else { return "Default" }
        let label = self.effortOptions.first { $0.id == level }?.label ?? level
        return "Default (\(label))"
    }

    /// Why there is no reasoning control, when the selected model does not offer one.
    var reasoningUnavailableNote: String? {
        guard let choice = self.selectedChoice, self.effortOptions.isEmpty else { return nil }
        return "\(choice.name) does not report adjustable reasoning levels."
    }

    var hasChanges: Bool {
        guard let selected = self.selectedChoice else { return false }
        return selected.reference != self.currentChoice?.reference
            || self.selectedEffort != (self.thinkingOverride ?? "")
    }

    /// The single reason the request cannot be made, or nil when it can.
    var applyBlocker: String? {
        if !self.supportsControls { return "This gateway does not advertise model controls. Update the gateway to change models here." }
        if !self.isConnected { return "Reconnect to change this conversation’s model." }
        guard let selected = self.selectedChoice else { return "Choose a model." }
        if selected.available == false { return "\(selected.name) is unavailable right now." }
        if !self.selectedEffort.isEmpty, !self.effortOptions.contains(where: { $0.id == self.selectedEffort }) {
            return "Choose a reasoning level this model supports."
        }
        if !self.hasChanges { return "Already set for this conversation." }
        return nil
    }

    var canApply: Bool { !self.isSaving && self.applyBlocker == nil }
    var applyTitle: String { self.isSaving ? "Saving…" : "Use for next turn" }

    private func effortLabel(_ level: String) -> String {
        let levels = (self.currentChoice?.thinkingLevels ?? []) + self.effortOptions
        return levels.first { $0.id == level }?.label ?? level
    }
}
