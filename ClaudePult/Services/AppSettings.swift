import Foundation
import Observation

/// What the menu bar shows next to the icon (spec §2.8).
enum MenuBarUsageMode: String, CaseIterable, Sendable {
    case iconOnly, session, sessionAndWeek, ring

    var title: String {
        switch self {
        case .iconOnly: "Только значок"
        case .session: "% сессии"
        case .sessionAndWeek: "% сессии и недели"
        case .ring: "Кольцо"
        }
    }
}

/// How a Claude command runs (docs/SPEC.md §2.4).
enum LaunchMode: String, CaseIterable, Sendable {
    case terminal, background

    var title: String {
        switch self {
        case .terminal: "Терминал"
        case .background: "Фон"
        }
    }
}

/// User settings stored in UserDefaults. Paths are kept with `~` expanded.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var projectsDirectory: String {
        didSet { defaults.set(projectsDirectory, forKey: Keys.projectsDirectory) }
    }

    var dailyReportDirectory: String {
        didSet { defaults.set(dailyReportDirectory, forKey: Keys.dailyReportDirectory) }
    }

    /// Path to the `claude` CLI; empty means auto-detect (see `ClaudeLocator`).
    var claudePath: String {
        didSet { defaults.set(claudePath, forKey: Keys.claudePath) }
    }

    /// nil = ask every time.
    var defaultLaunchMode: LaunchMode? {
        didSet { defaults.set(defaultLaunchMode?.rawValue, forKey: Keys.defaultLaunchMode) }
    }

    var telegramForBackground: Bool {
        didSet { defaults.set(telegramForBackground, forKey: Keys.telegramForBackground) }
    }

    var backgroundTimeLimitMinutes: Int {
        didSet { defaults.set(backgroundTimeLimitMinutes, forKey: Keys.backgroundTimeLimitMinutes) }
    }

    var menuBarUsageMode: MenuBarUsageMode {
        didSet { defaults.set(menuBarUsageMode.rawValue, forKey: Keys.menuBarUsageMode) }
    }

    /// Percentages that raise a notification once per limit window.
    var limitThresholds: [Int] {
        didSet { defaults.set(limitThresholds, forKey: Keys.limitThresholds) }
    }

    var limitAlertsToTelegram: Bool {
        didSet { defaults.set(limitAlertsToTelegram, forKey: Keys.limitAlertsToTelegram) }
    }

    static let defaultLimitThresholds = [50, 80, 95]

    static let defaultProjectsDirectory = NSHomeDirectory() + "/Projects"
    static let defaultDailyReportDirectory = NSHomeDirectory() + "/Projects/_daily-report"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        projectsDirectory = defaults.string(forKey: Keys.projectsDirectory) ?? Self.defaultProjectsDirectory
        dailyReportDirectory = defaults.string(forKey: Keys.dailyReportDirectory) ?? Self.defaultDailyReportDirectory
        claudePath = defaults.string(forKey: Keys.claudePath) ?? ""
        defaultLaunchMode = defaults.string(forKey: Keys.defaultLaunchMode).flatMap(LaunchMode.init(rawValue:))
        telegramForBackground = defaults.object(forKey: Keys.telegramForBackground) as? Bool ?? true
        let limit = defaults.integer(forKey: Keys.backgroundTimeLimitMinutes)
        backgroundTimeLimitMinutes = limit > 0 ? limit : 90
        menuBarUsageMode = defaults.string(forKey: Keys.menuBarUsageMode).flatMap(MenuBarUsageMode.init(rawValue:)) ?? .session
        let thresholds = (defaults.array(forKey: Keys.limitThresholds) as? [Int])?.filter { (1...100).contains($0) }
        limitThresholds = thresholds?.isEmpty == false ? thresholds! : Self.defaultLimitThresholds
        limitAlertsToTelegram = defaults.bool(forKey: Keys.limitAlertsToTelegram)
    }

    var reportScript: String {
        (dailyReportDirectory as NSString).appendingPathComponent("report.py")
    }

    private enum Keys {
        static let projectsDirectory = "projectsDirectory"
        static let dailyReportDirectory = "dailyReportDirectory"
        static let claudePath = "claudePath"
        static let defaultLaunchMode = "defaultLaunchMode"
        static let telegramForBackground = "telegramForBackground"
        static let backgroundTimeLimitMinutes = "backgroundTimeLimitMinutes"
        static let menuBarUsageMode = "menuBarUsageMode"
        static let limitThresholds = "limitThresholds"
        static let limitAlertsToTelegram = "limitAlertsToTelegram"
    }
}
