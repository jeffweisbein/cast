import SwiftUI
#if os(iOS)
import VisionKit
#endif

struct ApprovalCardView: View {
    let approval: ExecApproval
    let store: ChatStore

    private var activity: ApprovalActivity? { store.approvalActivity[approval.id] }
    private var isConnected: Bool { if case .connected = store.connectionState { return true }; return false }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
        let expired = (approval.expiresAtMs ?? .greatestFiniteMagnitude) <= context.date.timeIntervalSince1970 * 1000
        let state = activity?.state == .confirmed ? ActionPresentation.confirmed : expired ? .expired : activity?.state ?? .waiting
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(state.rawValue, systemImage: state == .confirmed ? "checkmark.circle.fill" : "checkmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                if let expiry = self.approval.expiresAtMs {
                    Text(Date(timeIntervalSince1970: expiry / 1000), style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(self.approval.commandText)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            // Plugin approvals describe an action, not a command; the description is the
            // only place the plugin says what it is about to do.
            if self.approval.kind == .plugin, let description = self.approval.request.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if self.approval.kind == .plugin, let plugin = self.approval.request.pluginId {
                    Label(plugin, systemImage: "puzzlepiece.extension")
                }
                if let tool = self.approval.request.toolName { Label(tool, systemImage: "wrench.and.screwdriver") }
                if let host = self.approval.request.host { Label(host, systemImage: "desktopcomputer") }
                if let cwd = self.approval.cwd { Label(cwd, systemImage: "folder") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if let activity { Text(activity.detail).font(.caption).foregroundStyle(.secondary) }
            if !isConnected { Text("Reconnect to submit a decision.").font(.caption).foregroundStyle(.secondary) }
            if state == .submitting { ProgressView("Waiting for confirmation…") }
            if state == .uncertain {
                Button("Refresh status") { Task { await store.refreshApprovals() } }.disabled(!isConnected)
            }
            HStack {
                // Plugin approvals can restrict the decision set; offering a decision the
                // gateway will reject just turns the tap into an error alert.
                if self.approval.allows(decision: "deny") {
                    Button("Deny", role: .destructive) { self.store.resolveApproval(id: self.approval.id, decision: "deny") }
                }
                Spacer()
                if self.approval.allows(decision: "allow-always") {
                    Button("Always allow") { self.store.resolveApproval(id: self.approval.id, decision: "allow-always") }
                }
                if self.approval.allows(decision: "allow-once") {
                    Button("Allow once") { self.store.resolveApproval(id: self.approval.id, decision: "allow-once") }
                        .buttonStyle(.borderedProminent)
                }
            }.disabled(expired || state != .waiting || !isConnected)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.orange.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(state.rawValue) for \(self.approval.commandText)")
        }
    }
}

struct PairWorkspaceView: View {
    @ObservedObject var manager: WorkspaceManager
    var onFinished: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var name = "Workspace"
    @State private var setupCode = ""
    @State private var gatewayURL = "wss://"
    @State private var token = ""
    @State private var showingScanner = false
    @State private var errorText: String?
    @State private var connectingWorkspaceID: String?
    @State private var connectionSucceeded = false

    init(
        manager: WorkspaceManager,
        initialConnectingWorkspaceID: String? = nil,
        onFinished: (() -> Void)? = nil)
    {
        self.manager = manager
        self.onFinished = onFinished
        self._connectingWorkspaceID = State(initialValue: initialConnectingWorkspaceID)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let workspaceID = self.connectingWorkspaceID {
                    PairingValidationView(
                        store: self.manager.store(for: workspaceID),
                        connectionSucceeded: self.$connectionSucceeded,
                        retry: { self.manager.reconnect(workspaceID: workspaceID) },
                        useDifferentCode: {
                            self.errorText = nil
                            self.connectionSucceeded = false
                            self.connectingWorkspaceID = nil
                        },
                        done: { self.finishOrDismiss() })
                } else {
                    self.pairingForm
                }
            }
            .navigationTitle("Pair workspace")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if self.connectingWorkspaceID == nil {
                        Button("Cancel") { self.dismiss() }
                    } else {
                        Button(self.connectionSucceeded ? "Done" : "Set Up Later") {
                            self.finishOrDismiss()
                        }
                    }
                }
                if self.connectingWorkspaceID == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Connect") { self.connect() }
                            .fontWeight(.semibold)
                            .disabled(!self.canConnect)
                    }
                }
            }
            #if os(iOS)
            .sheet(isPresented: self.$showingScanner) {
                QRScannerView { code in
                    self.setupCode = code
                    self.showingScanner = false
                }
            }
            #endif
        }
        #if os(macOS)
        .frame(width: 520, height: 520)
        #endif
        .interactiveDismissDisabled(self.connectingWorkspaceID != nil)
    }

    private var pairingForm: some View {
        Form {
            Section {
                Picker("Pairing method", selection: self.$mode) {
                    Text("Setup code").tag(0)
                    Text("Gateway token").tag(1)
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Setup code is recommended for most testers.")
            } footer: {
                Text(self.mode == 0
                    ? "Recommended: generate a short-lived setup code from an authorized OpenClaw Control UI."
                    : "Advanced: use a gateway URL and operator token supplied by its owner.")
            }

            Section("Workspace") {
                TextField("Name", text: self.$name)
                    .textContentType(.organizationName)
                    .accessibilityHint("A private label used only to identify this gateway in Cast.")
            }

            if self.mode == 0 {
                Section("QR / setup code") {
                    TextEditor(text: self.$setupCode)
                        .font(.caption.monospaced())
                        .frame(minHeight: 110)
                        .accessibilityLabel("Setup code")
                        .accessibilityHint("Paste the setup code generated by OpenClaw.")
                    #if os(iOS)
                    if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                        Button("Scan QR code", systemImage: "qrcode.viewfinder") {
                            self.showingScanner = true
                        }
                    } else {
                        Text("QR scanning isn’t available on this device. Paste the setup code above instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    #endif
                    Label("Credentials stay in this device’s Keychain.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Manual gateway") {
                    TextField("ws:// or wss:// URL", text: self.$gatewayURL)
                        .textContentType(.URL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    SecureField("Gateway token", text: self.$token)
                        .textContentType(.password)
                    Text("Cast stores the token in Keychain, not in the workspace profile. Remote gateways should use wss://.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorText {
                Section("Couldn’t start pairing") {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Pairing error: \(errorText)")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var canConnect: Bool {
        guard !self.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if self.mode == 0 {
            return !self.setupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !self.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !self.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func connect() {
        do {
            if self.mode == 0 {
                self.connectingWorkspaceID = try self.manager.pair(
                    name: self.name,
                    setupCode: self.setupCode)
            } else {
                guard !self.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PairingError.invalidCode
                }
                self.connectingWorkspaceID = try self.manager.configure(
                    name: self.name,
                    urlText: self.gatewayURL,
                    sharedToken: self.token)
            }
            self.errorText = nil
            self.connectionSucceeded = false
        } catch {
            self.errorText = PairingError.userFacingMessage(for: error)
        }
    }

    private func finishOrDismiss() {
        if self.connectionSucceeded { self.onFinished?() }
        self.dismiss()
    }
}

private struct PairingValidationView: View {
    let store: ChatStore
    @Binding var connectionSucceeded: Bool
    let retry: () -> Void
    let useDifferentCode: () -> Void
    let done: () -> Void

    private var phase: PairingConnectionPhase {
        PairingConnectionPhase.phase(for: self.store.connectionState)
    }

    private var presentation: (title: String, message: String, symbol: String, color: Color) {
        switch self.phase {
        case .connecting:
            return (
                "Connecting…",
                "Cast is contacting \(self.store.profile.name) and validating this device.",
                "network",
                .orange)
        case .approvalRequired:
            return (
                "Approve this device",
                "Open your authorized OpenClaw Control UI and approve Cast. This screen will update automatically.",
                "checkmark.shield",
                .orange)
        case .connected:
            return (
                "Workspace connected",
                "Cast can now load conversations and send messages through \(self.store.profile.name).",
                "checkmark.circle.fill",
                .green)
        case .authenticationFailed:
            return (
                "Credential wasn’t accepted",
                "Check the setup code or gateway token with the gateway owner, then edit the connection details and try again.",
                "key.slash",
                .red)
        case .unreachable:
            return (
                "Can’t reach the gateway",
                "Make sure OpenClaw is running and this device can reach the gateway’s network, then try again.",
                "wifi.exclamationmark",
                .red)
        }
    }

    private var statusSummary: some View {
        VStack(spacing: 8) {
            Text(self.presentation.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(self.presentation.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .contain)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if self.phase == .connecting {
                    ProgressView()
                        .controlSize(.large)
                        .accessibilityLabel("Connecting to workspace")
                } else {
                    Image(systemName: self.presentation.symbol)
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(self.presentation.color)
                        .accessibilityHidden(true)
                }

                self.statusSummary

                Group {
                    switch self.phase {
                    case .connected:
                        Button("Done", action: self.done)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    case .authenticationFailed, .unreachable:
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                Button("Edit Connection Details", action: self.useDifferentCode)
                                Button("Try Again", action: self.retry)
                                    .buttonStyle(.borderedProminent)
                            }
                            VStack {
                                Button("Try Again", action: self.retry)
                                    .buttonStyle(.borderedProminent)
                                Button("Edit Connection Details", action: self.useDifferentCode)
                            }
                        }
                    case .approvalRequired:
                        Button("Check Again", action: self.retry)
                            .buttonStyle(.borderedProminent)
                    case .connecting:
                        EmptyView()
                    }
                }
                .controlSize(.large)

                Label(
                    "Cast connects directly to the configured gateway. Credentials remain in Keychain on this device.",
                    systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(32)
        }
        .onAppear { self.connectionSucceeded = self.phase == .connected }
        .onChange(of: self.phase) { _, phase in
            self.connectionSucceeded = phase == .connected
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var manager: WorkspaceManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var step = 0
    @State private var showingPairing = false

    private let finalStep = 3

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(self.step + 1), total: Double(self.finalStep + 1))
                    .accessibilityLabel("Setup step \(self.step + 1) of \(self.finalStep + 1)")
                    .padding(.horizontal)
                    .padding(.top, 8)

                ScrollView {
                    self.stepContent
                        .frame(maxWidth: 680)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, self.horizontalSizeClass == .compact ? 22 : 42)
                        .padding(.vertical, 28)
                }

                Divider()
                self.navigationButtons
                    .padding()
            }
            .navigationTitle("Welcome to Cast")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if self.step == self.finalStep {
                        Button("Done") { self.manager.completeOnboarding() }
                    } else {
                        Button("Set Up Later") { self.manager.dismissOnboarding() }
                    }
                }
            }
            .sheet(isPresented: self.$showingPairing) {
                PairWorkspaceView(manager: self.manager) {
                    self.step = self.finalStep
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 680, minHeight: 660)
        #endif
        .interactiveDismissDisabled(self.step == self.finalStep)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch self.step {
        case 0:
            OnboardingPage(
                symbol: "bubble.left.and.bubble.right.fill",
                title: "Your OpenClaw conversations, on the go",
                message: "Cast is a native client for an OpenClaw gateway you or your organization controls.")
            {
                OnboardingFeature(
                    symbol: "message.fill",
                    title: "Talk to your agents",
                    message: "Browse gateway conversations, send messages, and follow structured work updates.")
                OnboardingFeature(
                    symbol: "rectangle.3.group.fill",
                    title: "One app, multiple workspaces",
                    message: "Each workspace points to a separate gateway. Cast does not create or host an OpenClaw account.")
            }
        case 1:
            OnboardingPage(
                symbol: "checklist",
                title: "What you’ll need",
                message: "Have these ready before connecting Cast.")
            {
                OnboardingFeature(
                    symbol: "server.rack",
                    title: "A running OpenClaw gateway",
                    message: "It must be reachable from this device over its local network or a secure wss:// address.")
                OnboardingFeature(
                    symbol: "qrcode",
                    title: "A setup code",
                    message: "Generate a fresh mobile setup code from an authorized OpenClaw Control UI. You may also need to approve this device there.")
            }
        case 2:
            OnboardingPage(
                symbol: "lock.shield.fill",
                title: "Direct and private by design",
                message: "Credentials and device identity stay in Keychain. Cast connects directly to the gateway URL you configure; conversations come from that gateway and may be cached locally for continuity.")
            {
                Text("Setup codes are short-lived. If one expires, generate a fresh code and try again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        default:
            OnboardingPage(
                symbol: "checkmark.circle.fill",
                symbolColor: .green,
                title: "You’re connected",
                message: "A workspace is one OpenClaw gateway. Its conversations appear in the sidebar, and messages travel through that gateway.")
            {
                OnboardingFeature(
                    symbol: "square.stack.3d.up",
                    title: "Switch or add workspaces",
                    message: "Use the workspace menu at any time to connect another gateway or reopen setup and privacy help.")
                OnboardingFeature(
                    symbol: "square.and.pencil",
                    title: "Start a conversation",
                    message: "Choose an existing session or use New Chat. Connection status remains visible in the toolbar.")
            }
        }
    }

    @ViewBuilder
    private var navigationButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                if self.step > 0, self.step < self.finalStep {
                    Button("Back") { self.step -= 1 }
                }
                Spacer()
                self.primaryNavigationButton
            }
            VStack(spacing: 10) {
                self.primaryNavigationButton
                    .frame(maxWidth: .infinity)
                if self.step > 0, self.step < self.finalStep {
                    Button("Back") { self.step -= 1 }
                }
            }
        }
    }

    @ViewBuilder
    private var primaryNavigationButton: some View {
        if self.step < 2 {
            Button("Continue") { self.step += 1 }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        } else if self.step == 2 {
            Button(self.manager.hasCompletedOnboarding ? "Add Another Workspace" : "Connect Workspace") {
                self.showingPairing = true
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Opens setup-code and gateway-token pairing options.")
        } else {
            Button("Start Chatting") { self.manager.completeOnboarding() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

private struct OnboardingPage<Content: View>: View {
    let symbol: String
    let symbolColor: Color
    let title: String
    let message: String
    let content: Content

    init(
        symbol: String,
        symbolColor: Color = .accentColor,
        title: String,
        message: String,
        @ViewBuilder content: () -> Content)
    {
        self.symbol = symbol
        self.symbolColor = symbolColor
        self.title = title
        self.message = message
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: self.symbol)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(self.symbolColor)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(self.title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(self.message)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 16) { self.content }
                .frame(maxWidth: .infinity)
        }
    }
}

private struct OnboardingFeature: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: self.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(self.title).font(.headline)
                Text(self.message).font(.body).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#if os(iOS)
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: self.onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem])
        {
            for item in addedItems {
                if case let .barcode(barcode) = item, let value = barcode.payloadStringValue {
                    self.onCode(value)
                    return
                }
            }
        }
    }
}
#endif
