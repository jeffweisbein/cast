import SwiftUI

#if os(macOS)
struct DictationSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var service = HexService()
    @State private var model: HexModel?
    @State private var status = "Checking local engine…"
    @State private var busy = false
    @State private var confirmDelete = false
    @AppStorage("dictationCorrections") private var corrections = DictationDraft.defaultCorrections
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Local dictation").font(.title2.bold())
            Text("Hex transcribes on your Mac. Your recording is deleted after transcription or cancellation. Text stays in the draft until you send it.")
            if HexService.executable == nil {
                Link("Install Hex", destination: URL(string: "https://anoma.ly/hex/")!)
                Text("Place Hex in Applications. You don't need to run it alongside Cast.").foregroundStyle(.secondary)
            }
            if let model {
                Text(model.name).font(.headline)
                Text(model.installed && model.verified ? "Downloaded and verified" : "Model download required")
                if let bytes = model.downloadBytes {
                    Text("Download size: \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))").font(.caption)
                }
                Text("Cast reuses Hex’s model storage. Removing this shared model also affects Hex.").font(.caption).foregroundStyle(.secondary)
                Button(model.installed ? "Prepare model" : "Download model") {
                    busy = true
                    work = Task {
                        do {
                            try await service.prepare { status = $0 }
                            self.model = try await service.models().first { $0.id == HexService.model }
                        } catch { status = error.localizedDescription }
                        busy = false
                    }
                }.disabled(busy)
                if model.installed {
                    Button("Remove downloaded model…", role: .destructive) { confirmDelete = true }.disabled(busy)
                }
                Link("Model license", destination: URL(string: "https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf/blob/main/LICENSE")!)
            }
            DisclosureGroup("Preferred spellings") {
                Text("One correction per line: heard phrase=preferred spelling").font(.caption)
                TextEditor(text: $corrections).frame(height: 90).font(.system(.body, design: .monospaced))
            }
            Text(status).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Check again") { check() }.disabled(busy)
                Spacer()
                Button(busy ? "Cancel" : "Done") { work?.cancel(); service.close(); dismiss() }
            }
        }
        .padding(24).frame(width: 480)
        .confirmationDialog("Remove the shared English model?", isPresented: $confirmDelete) {
            Button("Remove model", role: .destructive) {
                service.close()
                let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/hex/models")
                do {
                    for name in ["parakeet-unified-en-0.6b-Q8_0.gguf", "parakeet-unified-en-0.6b-Q8_0.gguf.verified.json"] {
                        let url = root.appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    }
                    check()
                } catch { status = error.localizedDescription }
            }
        } message: { Text("Hex also uses this model. You can download it again later. No recordings, drafts or other models are removed.") }
        .task { check() }
        .onDisappear { work?.cancel(); service.close() }
    }

    private func check() {
        busy = true
        work = Task {
            do {
                try await service.start()
                self.model = try await service.models().first { $0.id == HexService.model }
                status = model == nil ? "This Hex version does not offer the required English model. Update Hex." : "English dictation · no cloud transcription"
            } catch { status = error.localizedDescription }
            busy = false
        }
    }
}

struct DesktopWindowPicker: View {
    @ObservedObject var access: DesktopAccess
    let choose: (DesktopWindow, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: DesktopWindow?
    @State private var interact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share a window with your agent").font(.title2.bold())
            Text("Adds the selected window's accessible text and controls to this draft. No screen recording or other windows are included.").foregroundStyle(.secondary)
            if access.loading { ProgressView("Finding windows…") }
            List(access.windows, selection: $selected) { window in
                VStack(alignment: .leading) {
                    Text(window.app_name).font(.headline)
                    Text(window.title).font(.caption).lineLimit(1)
                }.tag(window)
            }.frame(height: 220)
            Toggle("Allow interaction with this window", isOn: $interact)
            Text(interact ? "The agent can use supported controls without moving your mouse. Access lasts 15 minutes. Stop access in the composer at any time." : "Inspect only. The agent can read this window but cannot operate controls through this access session.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = access.failure { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Refresh") { Task { await access.refresh() } }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Attach window") {
                    guard let selected else { return }
                    choose(selected, interact); dismiss()
                }.disabled(selected == nil || access.loading)
            }
        }.padding(24).frame(width: 540)
        .task { await access.refresh() }
    }
}
#endif
