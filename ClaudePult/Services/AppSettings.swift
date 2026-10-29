import Foundation
import Observation

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

    static let defaultProjectsDirectory = NSHomeDirectory() + "/Projects"
    static let defaultDailyReportDirectory = NSHomeDirectory() + "/Projects/_daily-report"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        projectsDirectory = defaults.string(forKey: Keys.projectsDirectory) ?? Self.defaultProjectsDirectory
        dailyReportDirectory = defaults.string(forKey: Keys.dailyReportDirectory) ?? Self.defaultDailyReportDirectory
    }

    var reportScript: String {
        (dailyReportDirectory as NSString).appendingPathComponent("report.py")
    }

    private enum Keys {
        static let projectsDirectory = "projectsDirectory"
        static let dailyReportDirectory = "dailyReportDirectory"
    }
}
