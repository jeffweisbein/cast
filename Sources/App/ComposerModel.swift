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

    init(model: String?, isConnected: Bool) {
        let name = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
