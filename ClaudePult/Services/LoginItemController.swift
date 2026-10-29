import Foundation
import Observation
import OSLog
import ServiceManagement

/// Login item state as shown in the UI, decoupled from `SMAppService.Status` so it can be tested.
enum LoginItemState: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        // `mainApp` reports `.notFound` until the app has been registered once.
        case .notRegistered, .notFound: self = .disabled
        @unknown default: self = .disabled
        }
    }

    /// Whether the toggle should appear switched on.
    var isOn: Bool {
        self != .disabled
    }

    var message: String? {
        switch self {
        case .enabled, .disabled:
            nil
        case .requiresApproval:
            "Нужно разрешить ClaudePult в Системных настройках → Основные → Объекты входа."
        }
    }
}

/// Registers ClaudePult as a login item via `SMAppService.mainApp`.
@MainActor
@Observable
final class LoginItemController {
    private(set) var state: LoginItemState
    private(set) var lastError: String?

    private let service = SMAppService.mainApp
    private let log = Logger(subsystem: "com.demishev.claudepult", category: "login-item")

    init() {
        state = LoginItemState(SMAppService.mainApp.status)
    }

    func refresh() {
        state = LoginItemState(service.status)
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            log.error("Login item \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
