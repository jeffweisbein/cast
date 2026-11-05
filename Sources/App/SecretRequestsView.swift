import SwiftUI

struct SecretRequestsView: View {
    let store: ChatStore
    @State private var selected: SecretRequest?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Toggle("Enable secure requests", isOn: Binding(get: { store.secretEntryEnabled }, set: { store.setSecretEntryEnabled($0) }))
                Text("Uses the Gateway Secret Store, never chat. Enabling may require device permission approval in OpenClaw.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = store.secretRequestError { Text(error).foregroundStyle(.secondary) }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let pending = store.secretRequests.filter { $0.isPendingSecret && $0.belongs(to: store.selectedSessionKey) }
                    if pending.isEmpty { Text("No pending secret requests in this conversation.").foregroundStyle(.secondary) }
                    ForEach(pending) { request in
                        Button(request.questions[0].secretStore?.name ?? "Secret request") { selected = request }
                    }
                }
                Button("Refresh") { Task { await store.refreshSecretRequests() } }
            }
            .navigationTitle("Secure entry")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $selected) { request in SecretEntryView(store: store, request: request) }
            .task { await store.refreshSecretRequests() }
        }
        .frame(minWidth: 320, minHeight: 320)
    }
}

struct SecretEntryView: View {
    let store: ChatStore
    let request: SecretRequest
    @State private var value = ""
    @State private var submitting = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            Form {
                Text(request.questions[0].question)
                Text(request.questions[0].secretStore?.name ?? "Secret") .font(.headline)
                if request.questions[0].secretStoreExisting != nil {
                    Text("Saving will replace the existing stored value.").foregroundStyle(.orange)
                }
                let hosts = request.questions[0].secretStore?.allowedHosts ?? []
                Text(hosts.isEmpty ? "No outbound hosts allowed." : "Allowed destinations: " + hosts.joined(separator: ", "))
                    .font(.caption)
                SecureField("Secret value", text: $value)
                    .textContentType(.password)
                    .privacySensitive()
                    .disabled(submitting)
                Text("Sent directly to your Gateway over its authenticated connection. Not added to the conversation or saved on this device.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                Button(submitting ? "Saving…" : "Save to Secret Store") {
                    let submitted = value
                    value = ""
                    submitting = true
                    Task {
                        error = await store.resolveSecretRequest(request, value: submitted)
                        submitting = false
                        if error == nil { dismiss() }
                    }
                }.disabled(value.isEmpty || submitting || !request.isPendingSecret)
                Button("Decline request", role: .destructive) {
                    value = ""; submitting = true
                    Task {
                        error = await store.resolveSecretRequest(request, value: nil)
                        submitting = false
                        if error == nil { dismiss() }
                    }
                }.disabled(submitting)
            }
            .navigationTitle("Secure entry")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { value = ""; dismiss() } } }
        }
        .frame(minWidth: 320, minHeight: 360)
        .onDisappear { value = "" }
        .onChange(of: scenePhase) { _, phase in if phase != .active { value = "" } }
        .onChange(of: store.selectedSessionKey) { _, _ in value = ""; dismiss() }
        .onChange(of: store.connectionState) { _, _ in value = ""; dismiss() }
        .task {
            while !Task.isCancelled {
                if !request.isPendingSecret || !store.secretRequests.contains(where: { $0.id == request.id }) {
                    value = ""; dismiss(); return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
