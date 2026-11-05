#if os(iOS)
import SwiftUI

struct ShareExtensionView: View {
    @StateObject var model: ShareExtensionModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(self.model.itemSummary, systemImage: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Shared content: \(self.model.itemSummary)")
                }

                Section("Destination") {
                    if self.model.destinations.workspaces.isEmpty {
                        ContentUnavailableView(
                            "No Cast destinations",
                            systemImage: "rectangle.stack.badge.plus",
                            description: Text("Open Cast, connect a workspace, and refresh its conversations before sharing."))
                            .accessibilityLabel("No Cast destinations. Open Cast, connect a workspace, and refresh its conversations before sharing.")
                    } else {
                        Picker("Workspace", selection: Binding(
                            get: { self.model.selectedWorkspaceID },
                            set: { self.model.selectWorkspace($0) })) {
                            ForEach(self.model.destinations.workspaces) { workspace in
                                Text(workspace.name).tag(workspace.id)
                            }
                        }
                        .accessibilityLabel("Cast workspace")
                        .accessibilityHint("Choose the saved Cast workspace for this share")
                        Picker("Conversation", selection: self.$model.selectedSessionKey) {
                            ForEach(self.model.availableSessions) { session in
                                Text(session.name).tag(session.key)
                            }
                        }
                        .accessibilityLabel("Cast conversation")
                        .accessibilityHint("Choose the conversation that will receive this share")
                        if self.model.availableSessions.isEmpty {
                            Text("Open Cast and refresh this workspace’s conversations, then try again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Optional message") {
                    TextField("Add context…", text: self.$model.message, axis: .vertical)
                        .lineLimit(2 ... 5)
                        .accessibilityLabel("Optional message")
                        .accessibilityHint("Add context to send with the shared content")
                }

                if let status = self.model.status {
                    Section {
                        Label(status, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel(status)
                    }
                }
                if let error = self.model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Error: \(error)")
                    }
                }
            }
            .navigationTitle("Share to Cast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { self.model.cancel() }
                        .accessibilityLabel("Cancel sharing to Cast")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { self.model.submit() }
                        .disabled(!self.model.canSend)
                        .accessibilityLabel("Queue share for Cast")
                        .accessibilityHint("Saves this share for the selected Cast conversation")
                }
            }
            .disabled(self.model.isSending)
        }
    }
}
#endif
