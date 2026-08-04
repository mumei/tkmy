import Sparkle

@MainActor
public final class UpdateController {
    private let updaterController: SPUStandardUpdaterController?

    public var isConfigured: Bool { updaterController != nil }

    public var automaticallyChecksForUpdates: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? false }
        set { updaterController?.updater.automaticallyChecksForUpdates = newValue }
    }

    public init(bundle: Bundle = .main) {
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let configured = feed?.hasPrefix("https://") == true
            && feed?.contains("example.invalid") == false
            && publicKey?.isEmpty == false
            && publicKey?.contains("REPLACE_") == false
        updaterController = configured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    public func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}
