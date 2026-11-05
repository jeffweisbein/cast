import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct CastApp: App {
    @StateObject private var manager: WorkspaceManager
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS) && DEBUG
    private let offlineStressConfiguration: OfflineLayoutStressConfiguration
    /// Optional because `@State` initializes eagerly where `@StateObject`'s autoclosure did
    /// not: a normal launch must not pay for the fixture's store (ledger loads and all) just
    /// to never render it.
    @State private var offlineStressStore: ChatStore?
    #endif

    init() {
        CastLifecycleDiagnostics.appStarted()
        #if os(macOS) && DEBUG
        let environment = ProcessInfo.processInfo.environment
        let configuration = OfflineLayoutStressConfiguration.resolve(
            environment: environment)
        self.offlineStressConfiguration = configuration
        self._offlineStressStore = State(wrappedValue: configuration.isEnabled
            ? ChatStore(profile: WorkspaceProfile(
                id: "offline-layout-stress",
                name: "Offline Layout Stress",
                gatewayURL: URL(string: "ws://127.0.0.1:1")!,
                accent: "orange"),
                // Supplying an inert root also bypasses TranscriptCache's normal legacy-cache
                // migration during initialization. The fixture never loads or saves this root.
                transcriptCacheRoot: URL(fileURLWithPath: "/__cast_offline_layout_stress_no_io__"))
            : nil)
        // App-hosted XCTest loads `CastApp` before executing the bundle. Both XCTest and
        // the offline fixture must choose an inert manager here, before SwiftUI evaluates
        // any StateObject autoclosure; guarding the later `.task` is too late to prevent a
        // Keychain lookup from blocking host startup.
        let isTestHost = environment["XCTestConfigurationFilePath"] != nil
        if configuration.isEnabled || isTestHost {
            let defaults = UserDefaults(suiteName: "com.besttechie.cast.isolated-launch.\(UUID().uuidString)")!
            self._manager = StateObject(wrappedValue: WorkspaceManager(
                defaults: defaults,
                credentialProvider: { _ in nil },
                includeDevelopmentWorkspaces: false,
                legacyLocalCredentialAvailable: false))
        } else {
            self._manager = StateObject(wrappedValue: WorkspaceManager())
        }
        #else
        self._manager = StateObject(wrappedValue: WorkspaceManager())
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if os(macOS) && DEBUG
            if self.offlineStressConfiguration.isEnabled, let store = self.offlineStressStore {
                OfflineLayoutStressView(
                    store: store,
                    configuration: self.offlineStressConfiguration)
                    .task { await Self.snapshotLoopIfRequested() }
            } else {
                self.normalContent
            }
            #else
            self.normalContent
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1120, height: 780)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
            CommandMenu("Diagnostics") {
                Button("Reveal Hang Diagnostics in Finder") {
                    let fileURL = MainThreadWatchdog.fileURL
                    try? FileManager.default.createDirectory(
                        at: fileURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: fileURL.path) {
                        try? Data("{\"activeRunID\":null,\"records\":[]}".utf8)
                            .write(to: fileURL, options: .atomic)
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            }
        }
        #endif
    }

    private var normalContent: some View {
        ContentView()
            .environmentObject(self.manager)
            .task {
                guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                self.manager.start()
                #if os(iOS)
                await self.manager.consumePendingShares()
                #endif
            }
            .onChange(of: self.scenePhase) { _, phase in
                switch phase {
                case .active:
                    CastLifecycleDiagnostics.transition("active")
                    Task { await self.manager.refreshAllAfterActivation() }
                    #if os(iOS)
                    Task { await self.manager.consumePendingShares() }
                    #endif
                case .background:
                    CastLifecycleDiagnostics.transition("background")
                    self.manager.suspendAllForBackground()
                case .inactive:
                    CastLifecycleDiagnostics.transition("inactive")
                @unknown default:
                    CastLifecycleDiagnostics.transition("unknown")
                }
            }
                #if os(macOS) && DEBUG
                .task { await Self.snapshotLoopIfRequested() }
                #endif
    }

    #if os(macOS) && DEBUG
    /// Headless evidence path: the build host lacks Screen Recording permission for the
    /// agent shell, but an app may always render its own window. Set CAST_SNAPSHOT_PATH
    /// to get a PNG of the window every 4s.
    @MainActor
    private static func snapshotLoopIfRequested() async {
        guard let path = ProcessInfo.processInfo.environment["CAST_SNAPSHOT_PATH"] else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
    #endif
}
