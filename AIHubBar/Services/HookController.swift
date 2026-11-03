import Foundation
import Observation

/// Settings-side state for installing and removing the Claude Code hooks.
@MainActor
@Observable
final class HookController {
    private(set) var status: HookStatus = .notInstalled
    private(set) var message: String?
    private(set) var isError = false

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        refresh()
    }

    private var installer: HookInstaller { .live(projectsDirectory: settings.projectsDirectory) }

    func refresh() {
        if (try? installer.updateScriptIfNeeded()) == true { AppLog.info("Hook script updated to this version") }
        status = installer.status()
    }

    func install() {
        perform(String(localized: "Hooks установлены")) { try installer.install() }
    }

    func uninstall() {
        perform(String(localized: "Hooks сняты")) { try installer.uninstall() }
    }

    private func perform(_ success: String, _ action: () throws -> URL?) {
        do {
            let backup = try action()
            message = success + (backup.map { String(localized: ". Резервная копия: ~/.claude/\($0.lastPathComponent)") } ?? ".")
                + String(localized: " Claude Code подхватывает изменения сам, в том числе в открытых сессиях.")
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
            AppLog.error("Hook install/uninstall failed: \(error.localizedDescription)")
        }
        refresh()
    }
}
