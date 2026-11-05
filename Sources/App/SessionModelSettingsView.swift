import SwiftUI

struct SessionModelSettingsView: View {
    let store: ChatStore
    let sessionKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var reference = ""
    @State private var effort = ""
    @State private var loading = true
    @State private var error: String?
    @State private var saved = false

    private var session: SessionRow? { self.store.sessions.first { $0.key == self.sessionKey } }
    private var choices: [GatewayModelChoice] {
        guard self.store.modelCatalogAgentID == (SessionKeyMatcher.agentID(from: self.sessionKey) ?? "main") else { return [] }
        return self.store.modelCatalog
    }
    private var selected: GatewayModelChoice? { self.choices.first { $0.reference == self.reference } }

    var body: some View {
        NavigationStack {
            Form {
                Section("This conversation") {
                    LabeledContent("Selected model", value: self.session?.model ?? "Not reported")
                    LabeledContent("Reasoning", value: self.session?.modelInfo?.thinkingLevel
                        ?? self.session?.modelInfo?.thinkingDefault ?? "Not reported")
                    if self.store.selectedSessionKey == self.sessionKey,
                       let reply = self.store.messages.last(where: { $0.role == "assistant" && $0.responseModel != nil }) {
                        LabeledContent("Last reported response", value: [reply.responseProvider, reply.responseModel]
                            .compactMap { $0 }.joined(separator: "/"))
                    }
                    Text("The last response can differ from your selection after a fallback. Cast only shows model information the gateway reports.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !self.store.supportsModelControls {
                    Text("This gateway does not advertise model controls. Update the gateway to enable them.")
                } else if self.loading {
                    ProgressView("Loading available models…")
                } else {
                    Section("Change model") {
                        Picker("Model", selection: self.$reference) {
                            Text("Choose a model").tag("")
                            ForEach(self.choices, id: \.reference) { model in
                                Text("\(model.name) · \(model.provider)\(model.available == false ? " (unavailable)" : "")")
                                    .tag(model.reference)
                            }
                        }
                        Picker("Reasoning effort", selection: self.$effort) {
                            Text("Model default").tag("")
                            ForEach(self.selected?.thinkingLevels ?? []) { level in
                                Text(level.label).tag(level.id)
                            }
                        }
                        Text("Applies only to this conversation, starting with the next turn. It does not interrupt a response already running or change the workspace default. Reasoning effort is set with the gateway’s /think command, which posts a short acknowledgement in the conversation. Model billing follows your gateway configuration.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(self.store.savingModelKeys.contains(self.sessionKey) ? "Saving…" : "Use for next turn") {
                            Task {
                                do {
                                    try await self.store.changeSessionModel(key: self.sessionKey,
                                        reference: self.reference, effort: self.effort.isEmpty ? nil : self.effort)
                                    self.error = nil
                                    self.saved = true
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                        .disabled(self.selected == nil || self.selected?.available == false
                                  || self.store.savingModelKeys.contains(self.sessionKey))
                    }
                }
                if self.saved { Label("Saved. Your next turn will request this model.", systemImage: "checkmark.circle") }
                if let error = self.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("Reload models") { Task { await self.load() } }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Model settings")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { self.dismiss() } } }
            .task { await self.load() }
            .onChange(of: self.reference) { _, _ in self.effort = ""; self.saved = false }
        }
        #if os(macOS)
        .frame(width: 560, height: 510)
        #endif
    }

    private func load() async {
        self.loading = true
        defer { self.loading = false }
        do {
            try await self.store.loadModelChoices(for: self.sessionKey)
            self.reference = self.choices.first {
                ($0.id == self.session?.model || $0.reference == self.session?.model)
                    && (self.session?.modelInfo?.modelProvider == nil || $0.provider == self.session?.modelInfo?.modelProvider)
            }?.reference ?? ""
            self.error = nil
        } catch { self.error = error.localizedDescription }
    }
}
