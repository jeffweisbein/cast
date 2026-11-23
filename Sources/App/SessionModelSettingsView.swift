import SwiftUI

/// Model and reasoning for one conversation, together. Opens as a bottom sheet on iOS so
/// the conversation stays in view behind it.
struct SessionModelSettingsView: View {
    let store: ChatStore
    /// Fixed for the life of the sheet; every read and the request itself use this key.
    let sessionKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var reference = ""
    @State private var effort = ""
    @State private var loading = true
    @State private var error: String?
    @State private var savedCount = 0

    private var session: SessionRow? { self.store.sessions.first { $0.key == self.sessionKey } }

    private var choices: [GatewayModelChoice] {
        guard self.store.modelCatalogAgentID == (SessionKeyMatcher.agentID(from: self.sessionKey) ?? "main")
        else { return [] }
        return self.store.modelCatalog
    }

    private var isConnected: Bool {
        if case .connected = self.store.connectionState { return true }
        return false
    }

    private var state: SessionModelSheetState {
        let reply = self.store.selectedSessionKey == self.sessionKey
            ? self.store.messages.last(where: { $0.role == "assistant" && $0.responseModel != nil })
            : nil
        return SessionModelSheetState(
            sessionModel: self.session?.model,
            sessionProvider: self.session?.modelInfo?.modelProvider,
            thinkingOverride: self.session?.modelInfo?.thinkingLevel,
            thinkingDefault: self.session?.modelInfo?.thinkingDefault,
            lastResponseModel: reply?.responseModel,
            lastResponseProvider: reply?.responseProvider,
            pendingReference: self.store.pendingModelChanges[self.sessionKey],
            choices: self.choices,
            selectedReference: self.reference,
            selectedEffort: self.effort,
            supportsControls: self.store.supportsModelControls,
            isConnected: self.isConnected,
            isSaving: self.store.savingModelKeys.contains(self.sessionKey))
    }

    var body: some View {
        let state = self.state
        NavigationStack {
            Form {
                self.summarySection(state)
                if !state.supportsControls {
                    Section {
                        Label(
                            "This gateway does not advertise model controls. Update the gateway to change models here.",
                            systemImage: "lock")
                            .foregroundStyle(.secondary)
                    }
                } else if self.loading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading available models…").foregroundStyle(.secondary)
                        }
                    }
                } else if state.choices.isEmpty {
                    if self.error == nil {
                        Section {
                            Text("The gateway did not return models for this conversation.")
                                .foregroundStyle(.secondary)
                            Button("Reload models") { Task { await self.load() } }
                        }
                    }
                } else {
                    self.modelSection(state)
                    self.reasoningSection(state)
                }
                if let error = self.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button("Reload models") { Task { await self.load() } }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Model & reasoning")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { self.dismiss() } } }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if state.supportsControls, !self.loading, !state.choices.isEmpty {
                    self.applyBar(state)
                }
            }
            .task { await self.load() }
        }
        .sensoryFeedback(.success, trigger: self.savedCount)
        #if os(macOS)
        .frame(width: 560, height: 600)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private func summarySection(_ state: SessionModelSheetState) -> some View {
        Section {
            LabeledContent("Model", value: state.currentModelLabel)
            LabeledContent("Reasoning", value: state.currentReasoningLabel)
            if let reply = state.lastReplyLabel {
                LabeledContent("Last reply", value: reply)
            }
            if let requested = state.requestedLabel {
                LabeledContent("Next turn") {
                    Text(requested).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("In use now")
        } footer: {
            Text(state.summaryFootnote)
        }
    }

    private func modelSection(_ state: SessionModelSheetState) -> some View {
        Section {
            ForEach(state.choices, id: \.reference) { model in
                SessionModelChoiceRow(
                    model: model,
                    isSelected: model.reference == state.selectedReference,
                    isCurrent: model.reference == state.currentChoice?.reference)
                {
                    self.reference = model.reference
                    self.effort = SessionModelSheetState.effortAfterSelecting(
                        model, currentEffort: self.effort, override: self.session?.modelInfo?.thinkingLevel,
                        currentModelReference: state.currentChoice?.reference)
                    self.error = nil
                }
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Model billing follows your gateway configuration.")
        }
    }

    private func reasoningSection(_ state: SessionModelSheetState) -> some View {
        Section {
            if state.selectedChoice == nil {
                Text("Choose a model to see its reasoning levels.")
                    .foregroundStyle(.secondary)
            } else if let note = state.reasoningUnavailableNote {
                Label(note, systemImage: "slash.circle")
                    .foregroundStyle(.secondary)
            } else {
                SessionEffortSelector(
                    options: [ThinkingOption(id: "", label: state.defaultEffortLabel)] + state.effortOptions,
                    selection: self.$effort)
            }
            if let note = state.overrideResetNote {
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Reasoning")
        }
    }

    private func applyBar(_ state: SessionModelSheetState) -> some View {
        VStack(spacing: 8) {
            Text(state.applyBlocker
                ?? "Applies to this conversation from the next turn; a response already running is not interrupted. Reasoning is set with /think, which posts a short acknowledgement here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                self.apply()
            } label: {
                Text(state.applyTitle)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!state.canApply)
            .accessibilityIdentifier("model-settings-apply")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func apply() {
        let reference = self.reference
        let effort = self.effort.isEmpty ? nil : self.effort
        Task {
            do {
                try await self.store.changeSessionModel(key: self.sessionKey, reference: reference, effort: effort)
                self.error = nil
                self.savedCount += 1
                self.dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func load() async {
        self.loading = true
        defer { self.loading = false }
        do {
            try await self.store.loadModelChoices(for: self.sessionKey)
            let current = SessionModelSheetState.choice(
                matching: self.session?.model,
                provider: self.session?.modelInfo?.modelProvider,
                in: self.choices)
            self.reference = current?.reference ?? ""
            // Start from exactly what is in force, even when the catalog does not list it:
            // opening the sheet must never propose a change, and Apply stays "Already set"
            // until the operator picks something.
            self.effort = SessionModelSheetState.initialEffort(override: self.session?.modelInfo?.thinkingLevel)
            self.error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SessionModelChoiceRow: View {
    let model: GatewayModelChoice
    let isSelected: Bool
    let isCurrent: Bool
    let onSelect: () -> Void

    private var isUnavailable: Bool { self.model.available == false }

    var body: some View {
        Button(action: self.onSelect) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.model.name)
                        .foregroundStyle(self.isUnavailable ? .secondary : .primary)
                    Text(self.isUnavailable ? "\(self.model.provider) · Unavailable" : self.model.provider)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if self.isCurrent {
                    Text("Current")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.quaternary))
                }
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .opacity(self.isSelected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(self.isUnavailable)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }
}

/// Every level the selected model reports, side by side, with the model default first.
private struct SessionEffortSelector: View {
    let options: [ThinkingOption]
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(self.options) { option in
                    let isSelected = option.id == self.selection
                    Button {
                        self.selection = option.id
                    } label: {
                        Text(option.label)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(Capsule().fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))
                            .frame(minHeight: ComposerSendGate.minimumHitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reasoning effort")
    }
}
