import AppKit
import Sparkle

/// Updates through Sparkle (scripts/release.sh): the latest GitHub release's appcast, checked once a day. Only
/// release builds take updates in practice — they carry the release signature and a newer version number.
///
/// Beta testers (Settings → General → «Бета-версии», docs/RELEASE.md «Beta builds») read the beta channel's appcast
/// instead: the newest beta and the newest release, whichever is newer wins.
@MainActor
enum Updates {
    /// nil until `start()`, and in unit tests.
    private(set) static var controller: SPUStandardUpdaterController?
    private static let channel = UpdateChannel()

    /// The beta channel's appcast, replaced by every release (`scripts/release-tools/beta-feed.py`).
    nonisolated static let betaFeedURL = "https://github.com/OlehDemishev/AIHubBar/releases/download/beta/appcast.xml"

    /// Takes betas; set from `AppSettings.betaUpdates`.
    static var beta = false {
        didSet {
            guard beta != oldValue, let updater = controller?.updater else { return }
            AppLog.info("Updates: beta channel \(beta ? "on" : "off")")
            if beta { updater.checkForUpdatesInBackground() }
        }
    }

    static func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: channel, userDriverDelegate: nil)
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

/// Points Sparkle at the beta appcast and lets it take items marked `<sparkle:channel>beta</sparkle:channel>`.
private final class UpdateChannel: NSObject, SPUUpdaterDelegate {
    private var beta: Bool { MainActor.assumeIsolated { Updates.beta } }

    func feedURLString(for updater: SPUUpdater) -> String? { beta ? Updates.betaFeedURL : nil }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> { beta ? ["beta"] : [] }
}
