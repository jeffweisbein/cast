import SwiftUI

/// Uses the shipped presentation components, but never instantiates a ChatStore or GatewayClient.
struct DemoWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var demo = DemoWorkspace()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Label("Demo · sample data · no gateway connected", systemImage: "play.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(12)
                    .background(.tint.opacity(0.08))
                Picker("Sample conversation", selection: Binding(get: { demo.sample }, set: { demo.select($0) })) {
                    ForEach(DemoWorkspace.Sample.allCases) { sample in
                        Label(sample.rawValue, systemImage: sample.symbol).tag(sample)
                    }
                }
                .pickerStyle(.segmented).padding()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        UserBubble(text: demo.sample.question)
                        if demo.sample == .change {
                            ToolRunView(run: ToolRun(id: "demo-tools", steps: [
                                ToolStep(id: "demo-read", name: "read", summary: "Sample WorkspaceView.swift"),
                                ToolStep(id: "demo-edit", name: "edit", summary: "Illustrative change · no file modified")
                            ]), isExpanded: demo.toolsExpanded, onToggle: { demo.toolsExpanded.toggle() })
                        }
                        MarkdownBody(text: demo.sample.response)
                        Button("Ask in side chat", systemImage: "text.bubble") { demo.openSideChat() }
                            .buttonStyle(.borderless)
                        if demo.sample == .change {
                            HStack(spacing: 8) {
                                Label { Text("a1b2c3d").monospaced() } icon: {
                                    GitCommitGlyph().stroke(lineWidth: 1.6).frame(width: 16, height: 16)
                                }
                                .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                                .padding(8).background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                                Text("Illustrative commit").font(.caption).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine)
                            CodeBlockView(language: "diff", code: DemoWorkspace.diff)
                            VStack(alignment: .leading, spacing: 8) {
                                Label(demo.approved ? "Sample approved" : "Ready for your review", systemImage: demo.approved ? "checkmark.circle" : "hand.raised")
                                    .font(.headline)
                                Text(demo.approved ? "Nothing was executed or saved to a gateway." : "Try an approval. This only changes the demo; it cannot run a command.")
                                    .font(.callout).foregroundStyle(.secondary)
                                if !demo.approved {
                                    Button("Approve sample") { demo.approveSample() }.buttonStyle(.bordered)
                                }
                            }.padding().frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                        }
                        Text("These conversations are built-in examples, not responses from a live agent. Exit Demo to set up your own gateway.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding().frame(maxWidth: 820).frame(maxWidth: .infinity)
                }
                .id(demo.sample)
            }
            .navigationTitle("Explore Cast")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Exit Demo") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Side chat", systemImage: "sidebar.right") { demo.openSideChat() }
                }
            }
        }
        .inspector(isPresented: Binding(get: { demo.showingSideChat }, set: { if !$0 { demo.closeSideChat() } })) {
            DemoSideChatView(demo: demo)
                .inspectorColumnWidth(min: 300, ideal: 380, max: 500)
        }
        #if os(macOS)
        .frame(minWidth: 680, idealWidth: 1000, minHeight: 640, idealHeight: 800)
        #endif
    }
}

struct DemoSideChatView: View {
    @Bindable var demo: DemoWorkspace
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Side chat", systemImage: "text.bubble").font(.headline)
                Spacer()
                Button("Close side chat", systemImage: "xmark") { demo.closeSideChat() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }.padding()
            Text("Demo · built-in answers · not saved")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            Text(demo.sample.context).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
                .background(.quaternary.opacity(0.3))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if demo.exchanges.isEmpty {
                            Text("Explore a detail without changing the main conversation. Choose a sample question below.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(demo.exchanges) { exchange in
                            UserBubble(text: exchange.question)
                            MarkdownBody(text: exchange.answer)
                        }
                        Color.clear.frame(height: 1).id("demo-side-tail")
                    }.padding()
                }
                .onChange(of: demo.exchanges.count) { _, _ in proxy.scrollTo("demo-side-tail", anchor: .bottom) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Try a sample question").font(.caption).foregroundStyle(.secondary)
                ForEach(DemoWorkspace.Question.allCases) { question in
                    Button(question.rawValue) { demo.ask(question) }.buttonStyle(.bordered)
                }
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 280)
    }
}
