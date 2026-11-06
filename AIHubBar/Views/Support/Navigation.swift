import AppKit
import SwiftUI

// Where things open (docs/specs/SPEC-refactor.md §5): window ids, the Settings page route, and the keys of small UI states.

/// The app's windows. The raw values are the scene ids, also used by `--app-command`, notification targets and
/// widget links — they stay as they are.
enum WindowID: String, CaseIterable, Sendable {
    case search, limits, assistant, calendar, compare, help
    case claudeConfig = "claude-config"
    case runLog = "run-log"
    case cleanupOutput = "cleanup-output"
    case notchSetup = "notch-setup"
    case quickPrompt = "quick-prompt"
    case usageHistory = "usage-history"
    /// Not a scene: the Settings window, opened with `openSettings`.
    case settings
}

extension OpenWindowAction {
    @MainActor func callAsFunction(_ id: WindowID) { callAsFunction(id: id.rawValue) }
}

extension DismissWindowAction {
    @MainActor func callAsFunction(_ id: WindowID) { callAsFunction(id: id.rawValue) }
}

/// Keys of small UI states kept in UserDefaults — open pages, folded blocks. Settings proper live in `AppSettings`.
enum StorageKey {
    /// The Settings page that opens next (`SettingsPane.rawValue`).
    static let settingsPage = "settingsPage"
    /// Panel blocks folded by a click on their title (`PanelBlock` raw values).
    static let collapsedBlocks = "collapsedBlocks"
    /// The profile «Панель» edits; cleared on every start, so it is the current one unless chosen.
    static let panelProfile = "settingsPanelProfile"
    static let servicesExpanded = "settingsServicesExpanded"
    static let helpTopic = "helpTopic"
    static let claudeConfigTab = "claudeConfigTab"
    static let calendarScope = "calendarScope"
    static let calendarCurrentModeOnly = "calendarCurrentModeOnly"
    static let limitsBreakdownExpanded = "limitsBreakdownExpanded"
}

/// Which Settings page opens next. One key holds the whole page; the three keys it replaced are read once
/// (`migrate`) so links saved before keep working.
enum SettingsRoute {
    static func open(_ pane: SettingsPane, defaults: UserDefaults = .standard) {
        defaults.set(pane.rawValue, forKey: StorageKey.settingsPage)
    }

    static func open(module: ModuleKind, defaults: UserDefaults = .standard) { open(.module(module), defaults: defaults) }
    static func open(service: ServiceTab, defaults: UserDefaults = .standard) { open(.service(service), defaults: defaults) }

    /// Pages stored before 2026-11-03 as `settingsTab` + `servicesTab` / `settingsModule` (and the older «claude» tab).
    static func migrate(_ defaults: UserDefaults = .standard) {
        let keys = ["settingsTab", "servicesTab", "settingsModule"]
        defer { keys.forEach(defaults.removeObject(forKey:)) }
        guard defaults.string(forKey: StorageKey.settingsPage) == nil, let tab = defaults.string(forKey: "settingsTab") else { return }
        let service = defaults.string(forKey: "servicesTab").flatMap(ServiceTab.init(rawValue:)) ?? .claude
        let module = defaults.string(forKey: "settingsModule").flatMap(ModuleKind.init(rawValue:)) ?? .limits
        let pane: SettingsPane? = switch tab {
        case "services": .service(service)
        case "claude": .service(.claude)
        case "module": .module(module)
        default: SettingsPane(rawValue: tab)
        }
        if let pane { open(pane, defaults: defaults) }
    }
}

extension EnvironmentValues {
    /// Opens Settings, on a page if given — the one way views do it.
    var openSettingsPage: OpenSettingsPage { OpenSettingsPage(openSettings: openSettings) }
}

struct OpenSettingsPage {
    let openSettings: OpenSettingsAction

    @MainActor func callAsFunction(_ pane: SettingsPane? = nil) {
        if let pane { SettingsRoute.open(pane) }
        NSApp.activate()
        openSettings()
    }
}
