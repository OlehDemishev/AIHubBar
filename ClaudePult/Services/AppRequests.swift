import Foundation
import Observation

/// Requests to the running app from outside the panel: windows to open (served by the menu bar label, the only
/// view alive while the panel is closed) and commands sent by `ClaudePult --app-command` as distributed notifications.
@MainActor
@Observable
final class AppRequests {
    struct WindowRequest: Equatable {
        var id: String
        var serial: Int
    }

    nonisolated static let notificationName = Notification.Name("com.demishev.claudepult.app-command")
    /// `--app-command` names that open a window instead of running a command.
    static let windows = ["help": "help", "cleanup-output": "cleanup-output"]

    private(set) var window: WindowRequest?
    private var observer: NSObjectProtocol?

    func openWindow(_ id: String) {
        window = WindowRequest(id: id, serial: (window?.serial ?? 0) + 1)
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
                if let window = Self.windows[name] {
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
