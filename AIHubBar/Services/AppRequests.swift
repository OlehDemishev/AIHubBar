import Foundation
import Observation

/// Requests to the running app from outside the panel: windows to open (served by the menu bar label, the only
/// view alive while the panel is closed) and commands sent by `AIHubBar --app-command` as distributed notifications.
@MainActor
@Observable
final class AppRequests {
    struct WindowRequest: Equatable {
        var id: WindowID
        var serial: Int
    }

    nonisolated static let notificationName = Notification.Name("com.demishev.claudepult.app-command")
    /// `--app-command` names that open a window instead of running a command.
    static let windows: [String: WindowID] = Dictionary(uniqueKeysWithValues: [WindowID.help, .cleanupOutput, .settings, .assistant, .notchSetup, .usageHistory].map { ($0.rawValue, $0) })
    /// Other `--app-command` names handled by the app itself.
    static let actions = ["test-notification", "test-island", "quick-prompt", "open-panel"]

    private(set) var window: WindowRequest?
    /// The last request a view opened: one made before the menu bar label was there is opened when it appears.
    @ObservationIgnored private var openedSerial = 0
    private var observer: NSObjectProtocol?

    func openWindow(_ id: WindowID) {
        window = WindowRequest(id: id, serial: (window?.serial ?? 0) + 1)
    }

    /// The window to open now, once: nil when there is none or it was opened already.
    func takeWindow() -> WindowID? {
        guard let window, window.serial > openedSerial else { return nil }
        openedSerial = window.serial
        return window.id
    }

    /// Listens for `--app-command <name>` from other processes.
    func listen(commands: CommandStore) {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName, object: nil, queue: .main
        ) { [weak self, weak commands] note in
            let name = note.object as? String ?? ""
            MainActor.assumeIsolated {
                AppLog.info("App command «\(name)» received")
                if name == "test-notification" {
                    Notifier.postTest()
                } else if name == "test-island" {
                    Notifier.postIslandTest()
                } else if name == "open-panel" {
                    PanelOpener.toggle()
                } else if name == "quick-prompt" {
                    // The same as its hot key: what is in front is read before the window comes up.
                    GlobalHotKey.quickPromptAction?()
                } else if let window = Self.windows[name] {
                    self?.openWindow(window)
                } else if let command = CommonCommand.allCases.first(where: { $0.cliName == name }) {
                    commands?.run(command)
                }
            }
        }
    }

    nonisolated static func post(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(notificationName, object: name, userInfo: nil, deliverImmediately: true)
    }
}
