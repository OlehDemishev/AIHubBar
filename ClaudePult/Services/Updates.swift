import AppKit
import Sparkle

/// Updates through Sparkle (scripts/release.sh): the latest GitHub release's appcast, checked once a day. Only
/// release builds take updates in practice — they carry the release signature and a newer version number.
@MainActor
enum Updates {
    /// nil until `start()`, and in unit tests.
    private(set) static var controller: SPUStandardUpdaterController?

    static func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    static func checkNow() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    static var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
