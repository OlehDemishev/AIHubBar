import Foundation
import Observation

/// The menu bar setting before the builder (spec §2.8); kept to migrate old settings and read old exports.
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

    /// What the menu bar item shows (SPEC-modes §7).
    var menuBarConfig: MenuBarConfig {
        didSet { defaults.set(try? JSONEncoder().encode(menuBarConfig), forKey: Keys.menuBarConfig) }
    }

    /// Where the current mode's projects come from; set by `ModeStore` when a mode is applied, not stored.
    var activeSource: ProjectSource = .none

    /// Chosen models and the compatible server's address (SPEC-modes §11); keys live in the Keychain.
    var aiServices: AIServicesConfig {
        didSet { defaults.set(try? JSONEncoder().encode(aiServices), forKey: Keys.aiServices) }
    }

    /// Percentages that raise a notification once per limit window.
    var limitThresholds: [Int] {
        didSet { defaults.set(limitThresholds, forKey: Keys.limitThresholds) }
    }

    var limitAlertsToTelegram: Bool {
        didSet { defaults.set(limitAlertsToTelegram, forKey: Keys.limitAlertsToTelegram) }
    }

    static let defaultLimitThresholds = [50, 80, 95]

    // MARK: Appearance

    var panelTextSize: PanelTextSize {
        didSet { defaults.set(panelTextSize.rawValue, forKey: Keys.panelTextSize) }
    }

    var panelWidth: PanelWidth {
        didSet { defaults.set(panelWidth.rawValue, forKey: Keys.panelWidth) }
    }

    var panelDensity: PanelDensity {
        didSet { defaults.set(panelDensity.rawValue, forKey: Keys.panelDensity) }
    }

    var panelTheme: PanelTheme {
        didSet { defaults.set(panelTheme.rawValue, forKey: Keys.panelTheme) }
    }

    var panelAnimations: Bool {
        didSet { defaults.set(panelAnimations, forKey: Keys.panelAnimations) }
    }

    var hiddenBlocks: Set<PanelBlock> {
        didSet { defaults.set(hiddenBlocks.map(\.rawValue).sorted(), forKey: Keys.hiddenBlocks) }
    }

    func shows(_ block: PanelBlock) -> Bool { !hiddenBlocks.contains(block) }

    func setShows(_ block: PanelBlock, _ visible: Bool) {
        if visible { hiddenBlocks.remove(block) } else { hiddenBlocks.insert(block) }
    }

    /// Back to the default look (Settings → «Внешний вид» → «Сбросить»).
    func resetAppearance() {
        panelTextSize = .normal
        panelWidth = .normal
        panelDensity = .normal
        panelTheme = .system
        panelAnimations = true
        hiddenBlocks = []
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
        menuBarConfig = defaults.data(forKey: Keys.menuBarConfig).flatMap { try? JSONDecoder().decode(MenuBarConfig.self, from: $0) }
            ?? MenuBarConfig.migrated(from: defaults.string(forKey: Keys.menuBarUsageMode).flatMap(MenuBarUsageMode.init(rawValue:)) ?? .session)
        aiServices = defaults.data(forKey: Keys.aiServices).flatMap { try? JSONDecoder().decode(AIServicesConfig.self, from: $0) }
            ?? AIServicesConfig()
        let thresholds = (defaults.array(forKey: Keys.limitThresholds) as? [Int])?.filter { (1...100).contains($0) }
        limitThresholds = thresholds?.isEmpty == false ? thresholds! : Self.defaultLimitThresholds
        limitAlertsToTelegram = defaults.bool(forKey: Keys.limitAlertsToTelegram)
        panelTextSize = defaults.string(forKey: Keys.panelTextSize).flatMap(PanelTextSize.init(rawValue:)) ?? .normal
        panelWidth = defaults.string(forKey: Keys.panelWidth).flatMap(PanelWidth.init(rawValue:)) ?? .normal
        panelDensity = defaults.string(forKey: Keys.panelDensity).flatMap(PanelDensity.init(rawValue:)) ?? .normal
        panelTheme = defaults.string(forKey: Keys.panelTheme).flatMap(PanelTheme.init(rawValue:)) ?? .system
        panelAnimations = defaults.object(forKey: Keys.panelAnimations) as? Bool ?? true
        hiddenBlocks = Set((defaults.stringArray(forKey: Keys.hiddenBlocks) ?? []).compactMap(PanelBlock.init(rawValue:)))
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
        static let menuBarConfig = "menuBarConfig"
        static let aiServices = "aiServices"
        static let limitThresholds = "limitThresholds"
        static let limitAlertsToTelegram = "limitAlertsToTelegram"
        static let panelTextSize = "panelTextSize"
        static let panelWidth = "panelWidth"
        static let panelDensity = "panelDensity"
        static let panelTheme = "panelTheme"
        static let panelAnimations = "panelAnimations"
        static let hiddenBlocks = "hiddenBlocks"
    }
}
