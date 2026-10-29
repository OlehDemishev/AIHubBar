import Foundation
import Observation

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
    }
}
