import SwiftUI

struct SideChatView: View {
    @Bindable var chat: SideChat
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Side chat", systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                Spacer()
                Button("Close side chat", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .disabled(chat.isBusy)
                    .help("Stop the side-chat run before closing")
            }.padding()
            Text("Separate conversation · saved on your gateway")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            DisclosureGroup("About this passage") {
                Text(chat.context).font(.callout).textSelection(.enabled)
                    .frame(maxHeight: 150).clipped()
            }.padding().background(.quaternary.opacity(0.3))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.messages.isEmpty && !chat.isBusy {
                            ContentUnavailableView("Ask without interrupting", systemImage: "text.bubble",
                                description: Text("Only this passage is shared. Your main conversation stays where it is."))
                        }
                        ForEach(chat.messages) { message in
                            if message.isUser {
                                UserBubble(text: displayQuestion(message.text))
                            } else { MarkdownBody(text: message.text) }
                        }
                        if !chat.streamingText.isEmpty { MarkdownBody(text: chat.streamingText) }
                        if chat.isBusy { ProgressView("Working in side chat…").font(.caption) }
                        Color.clear.frame(height: 1).id("side-tail")
                    }.padding()
                }
                .onChange(of: chat.messages.count) { _, _ in proxy.scrollTo("side-tail", anchor: .bottom) }
            }
            if let error = chat.error {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            Divider()
            HStack(alignment: .bottom) {
                TextField("Ask about this passage…", text: $chat.draft, axis: .vertical)
                    .lineLimit(1...6).textFieldStyle(.plain)
                    .accessibilityLabel("Side chat question")
                    .disabled(chat.isBusy)
                if chat.isBusy {
                    Button("Stop", systemImage: "stop.circle") { Task { await chat.stop() } }.labelStyle(.iconOnly)
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") { Task { await chat.send() } }
                        .labelStyle(.iconOnly).font(.title2)
                        .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding()
            Button("Refresh side chat", systemImage: "arrow.clockwise") { Task { await chat.refresh() } }
                .font(.caption).buttonStyle(.borderless).padding(.bottom, 8)
        }
        .frame(minWidth: 280, idealWidth: 360)
    }

    private func displayQuestion(_ text: String) -> String {
        let prefix = SideChat.initialMessage(context: chat.context, question: "")
        return text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }
}

struct CommitReferencesView: View {
    let references: [CommitReference]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { links }
            VStack(alignment: .leading, spacing: 8) { links }
        }
    }
    private var links: some View {
        ForEach(references) { reference in
            Link(destination: reference.url) {
                Label { Text(reference.shortHash) } icon: {
                    GitCommitGlyph().stroke(lineWidth: 1.6).frame(width: 16, height: 16)
                }
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            }
            .accessibilityLabel("Commit \(reference.shortHash) in \(reference.repository)")
            .help(reference.repository + " · " + reference.hash)
        }
    }
}

struct GitCommitGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let diameter = rect.width * 0.4
        path.addEllipse(in: CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter))
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX - diameter / 2, y: rect.midY))
        path.move(to: CGPoint(x: rect.midX + diameter / 2, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// Attach to the outer navigation container, never its detail column. On macOS 15,
/// a detail-column inspector registers a duplicate window separator and crashes.
struct SideChatInspector: ViewModifier {
    let store: ChatStore
    @Binding var isPresented: Bool
    func body(content: Content) -> some View {
        content.inspector(isPresented: $isPresented) {
            if let chat = store.sideChat {
                SideChatView(chat: chat) {
                    store.closeSideChat()
                    isPresented = false
                }
                .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
            }
        }
    }
}
