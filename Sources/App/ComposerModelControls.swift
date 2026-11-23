import SwiftUI

/// The conversation's reported model, and the way into its model and reasoning settings.
/// Session metadata updates independently of the field editor and streamed transcript, so
/// this is its own view with its own observation scope.
struct ComposerModelIndicator: View {
    enum Style {
        /// A quiet line under the composer (macOS).
        case caption
        /// A compact control inside the composer's bottom row (iOS).
        case chip
        /// Fixed-width entry keeps the typing strip readable at large text sizes.
        case toolbar
    }

    let store: ChatStore
    var style: Style = .caption
    /// Lets the composer hand keyboard focus back after the sheet closes.
    var onPresentationChange: (Bool) -> Void = { _ in }
    /// The conversation the sheet was opened for. Captured on tap and never re-read, so a
    /// selection change behind the sheet cannot redirect a model request.
    @State private var settingsSession: String?

    private var isConnected: Bool {
        if case .connected = self.store.connectionState { return true }
        return false
    }

    var body: some View {
        let key = self.store.selectedSessionKey
        let session = self.store.sessions.first { $0.key == key }
        let status = ComposerModelStatus(model: session?.model, isConnected: self.isConnected)
        let pending = key.map { self.store.pendingModelChanges[$0] != nil } ?? false
        Button {
            self.settingsSession = key
        } label: {
            switch self.style {
            case .caption: self.captionLabel(status, pending: pending)
            case .chip: self.chipLabel(status, pending: pending)
            case .toolbar:
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .overlay(alignment: .topTrailing) {
                        if pending {
                            Circle().fill(.orange).frame(width: 6, height: 6).padding(6)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(key == nil)
        .accessibilityLabel(pending ? "\(status.label), change requested for the next turn" : status.label)
        .accessibilityHint("Opens model and reasoning settings")
        .accessibilityIdentifier("composer-model-settings")
        .help("Model settings. " + status.help)
        .sheet(isPresented: Binding(
            get: { self.settingsSession != nil },
            set: { if !$0 { self.settingsSession = nil } }))
        {
            if let key = self.settingsSession { SessionModelSettingsView(store: self.store, sessionKey: key) }
        }
        .onChange(of: self.settingsSession != nil) { _, presented in
            self.onPresentationChange(presented)
        }
    }

    private func captionLabel(_ status: ComposerModelStatus, pending: Bool) -> some View {
        HStack(spacing: 5) {
            Text(status.label)
            if pending {
                Text("· next turn").foregroundStyle(.orange)
            }
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipLabel(_ status: ComposerModelStatus, pending: Bool) -> some View {
        HStack(spacing: 5) {
            if pending {
                Circle().fill(.orange).frame(width: 6, height: 6)
            }
            Text(status.chipLabel)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .opacity(self.isConnected ? 1 : 0.6)
        .padding(.horizontal, 8)
        .frame(minHeight: ComposerSendGate.minimumHitTarget)
        .contentShape(Rectangle())
    }
}
