#if os(macOS)
import Combine
import Sparkle
import SwiftUI

@MainActor
final class CastUpdates: ObservableObject {
    static let shared = CastUpdates()
    @Published private(set) var canCheck = false
    @Published var automaticChecks = false {
        didSet { self.controller?.updater.automaticallyChecksForUpdates = self.automaticChecks }
    }
    private var controller: SPUStandardUpdaterController?
    private var subscription: AnyCancellable?
    let configured: Bool

    private init() {
        let bundle = Bundle.main
        self.configured = ReleaseConfiguration.updatesConfigured(
            feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        guard self.configured,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              ProcessInfo.processInfo.environment["CAST_OFFLINE_LAYOUT_STRESS"] == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        self.automaticChecks = controller.updater.automaticallyChecksForUpdates
        self.subscription = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main).sink { [weak self] in self?.canCheck = $0 }
    }

    func check() { self.controller?.checkForUpdates(nil) }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updates = CastUpdates.shared
    var body: some View {
        Button("Check for Updates…") { self.updates.check() }
            .disabled(!self.updates.canCheck)
            .help(self.updates.configured ? "Check the signed Cast release feed" : "A signed update feed is not configured in this build")
    }
}

struct UpdatePreferencesView: View {
    @ObservedObject private var updates = CastUpdates.shared
    var body: some View {
        if self.updates.configured {
            Toggle("Check for updates automatically", isOn: self.$updates.automaticChecks)
        }
    }
}
#endif
