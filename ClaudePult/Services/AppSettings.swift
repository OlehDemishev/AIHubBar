import Foundation
import Observation

/// The menu bar setting before the builder (spec §2.8); kept to migrate old settings and read old exports.
enum MenuBarUsageMode: String, CaseIterable, Sendable {
    case iconOnly, session, sessionAndWeek, ring

    var title: String {
        switch self {
        case .iconOnly: String(localized: "Только значок")
        case .session: String(localized: "% сессии")
        case .sessionAndWeek: String(localized: "% сессии и недели")
        case .ring: String(localized: "Кольцо")
        }
    }
}

/// How a Claude command runs (docs/SPEC.md §2.4).
enum LaunchMode: String, CaseIterable, Sendable {
    case terminal, background

    var title: String {
        switch self {
        case .terminal: String(localized: "Терминал")
        case .background: String(localized: "Фон")
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

    /// Whose rules the developer prompts follow; set with the mode, not stored.
    var promptStyle: PromptStyle = .oleh

    /// Chosen models and the compatible server's address (SPEC-modes §11); keys live in the Keychain.
    var aiServices: AIServicesConfig {
        didSet { defaults.set(try? JSONEncoder().encode(aiServices), forKey: Keys.aiServices) }
    }

    /// Calendar reminders this many hours before a date (SPEC-modes §6); empty = none.
    var calendarReminderHours: [Int] {
        didSet { defaults.set(calendarReminderHours, forKey: Keys.calendarReminderHours) }
    }

    var calendarRemindersToTelegram: Bool {
        didSet { defaults.set(calendarRemindersToTelegram, forKey: Keys.calendarRemindersToTelegram) }
    }

    /// Percentages that raise a notification once per limit window.
    var limitThresholds: [Int] {
        didSet { defaults.set(limitThresholds, forKey: Keys.limitThresholds) }
    }

    var limitAlertsToTelegram: Bool {
        didSet { defaults.set(limitAlertsToTelegram, forKey: Keys.limitAlertsToTelegram) }
    }

    /// «Ресурсы Mac» (SPEC-profiles §4.1): notify about sustained load, memory, disk space and battery.
    var resourceAlerts: Bool {
        didSet { defaults.set(resourceAlerts, forKey: Keys.resourceAlerts) }
    }

    /// «Не спать» (SPEC-profiles §4.2).
    var keepAwakeRules: KeepAwakeRules {
        didSet { if let data = try? JSONEncoder().encode(keepAwakeRules) { defaults.set(data, forKey: Keys.keepAwakeRules) } }
    }

    /// «Быстрые команды» and «Быстрые переключатели» (SPEC-profiles §4.3–4.4).
    var quickCommands: [QuickCommand] {
        didSet { if let data = try? JSONEncoder().encode(quickCommands) { defaults.set(data, forKey: Keys.quickCommands) } }
    }

    var quickToggles: [QuickToggle] {
        didSet { defaults.set(quickToggles.map(\.rawValue), forKey: Keys.quickToggles) }
    }

    /// «История буфера» and «Заметки» (SPEC-profiles §3, second wave).
    var clipboardLimit: Int {
        didSet { defaults.set(clipboardLimit, forKey: Keys.clipboardLimit) }
    }

    var clipboardRemember: Bool {
        didSet { defaults.set(clipboardRemember, forKey: Keys.clipboardRemember) }
    }

    /// When «На ночь» runs start (an hour, 0–23).
    var nightStartHour: Int {
        didSet { defaults.set(nightStartHour, forKey: Keys.nightStartHour) }
    }

    var panelHotKey: PanelHotKey {
        didSet { defaults.set(panelHotKey.rawValue, forKey: Keys.panelHotKey) }
    }

    /// Notify when a pull request's CI fails or recovers, or the PR closes (`PullRequestAlerts`).
    var pullRequestAlerts: Bool {
        didSet { defaults.set(pullRequestAlerts, forKey: Keys.pullRequestAlerts) }
    }

    var pullRequestAlertsToTelegram: Bool {
        didSet { defaults.set(pullRequestAlertsToTelegram, forKey: Keys.pullRequestAlertsToTelegram) }
    }

    /// Also from Telegram, through ClaudePult's own bot (`TelegramApprovals`); chat id empty = the `_daily-report` one.
    var telegramApprovals: Bool {
        didSet { defaults.set(telegramApprovals, forKey: Keys.telegramApprovals) }
    }

    var telegramApprovalsChatID: String {
        didSet { defaults.set(telegramApprovalsChatID, forKey: Keys.telegramApprovalsChatID) }
    }

    /// Answer Claude Code's permission requests from notifications and the panel (`ApprovalFiles`).
    var approvalsFromClaudePult: Bool {
        didSet { defaults.set(approvalsFromClaudePult, forKey: Keys.approvalsFromClaudePult) }
    }

    var clipboardExcludedApps: [String] {
        didSet { defaults.set(clipboardExcludedApps, forKey: Keys.clipboardExcludedApps) }
    }

    var notesFolder: String {
        didSet { defaults.set(notesFolder, forKey: Keys.notesFolder) }
    }

    var resourceDiskBelowGB: Int {
        didSet { defaults.set(resourceDiskBelowGB, forKey: Keys.resourceDiskBelowGB) }
    }

    /// Renew an expired Claude Code sign-in with a one-word `claude` request (`LoginRenewal`).
    var renewClaudeLogin: Bool {
        didSet { defaults.set(renewClaudeLogin, forKey: Keys.renewClaudeLogin) }
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

    /// Other AI services (SPEC-hub): each one is on by default once found; the person can switch one off.
    var hubDisabled: Set<String> {
        didSet { defaults.set(hubDisabled.sorted(), forKey: Keys.hubDisabled) }
    }

    /// Consent to use Gemini CLI's own sign-in for the exact quota (otherwise requests are counted from its logs).
    var hubGeminiQuota: Bool {
        didSet { defaults.set(hubGeminiQuota, forKey: Keys.hubGeminiQuota) }
    }

    /// Requests a day on the person's Gemini plan: 1000 Google account, 1500 AI Pro, 2000 Ultra, 250 free API key.
    var hubGeminiDailyLimit: Int {
        didSet { defaults.set(hubGeminiDailyLimit, forKey: Keys.hubGeminiDailyLimit) }
    }

    /// Consent to read Cursor's own sign-in token from its settings database.
    var hubCursor: Bool {
        didSet { defaults.set(hubCursor, forKey: Keys.hubCursor) }
    }

    func hubEnabled(_ source: HubLimit.Source) -> Bool {
        guard !hubDisabled.contains(source.rawValue) else { return false }
        return source != .cursor || hubCursor
    }

    func setHubEnabled(_ source: HubLimit.Source, _ on: Bool) {
        if on { hubDisabled.remove(source.rawValue) } else { hubDisabled.insert(source.rawValue) }
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
        calendarReminderHours = (defaults.array(forKey: Keys.calendarReminderHours) as? [Int]) ?? [24]
        calendarRemindersToTelegram = defaults.bool(forKey: Keys.calendarRemindersToTelegram)
        let thresholds = (defaults.array(forKey: Keys.limitThresholds) as? [Int])?.filter { (1...100).contains($0) }
        limitThresholds = thresholds?.isEmpty == false ? thresholds! : Self.defaultLimitThresholds
        limitAlertsToTelegram = defaults.bool(forKey: Keys.limitAlertsToTelegram)
        renewClaudeLogin = defaults.object(forKey: Keys.renewClaudeLogin) as? Bool ?? true
        resourceAlerts = defaults.object(forKey: Keys.resourceAlerts) as? Bool ?? true
        let clipLimit = defaults.integer(forKey: Keys.clipboardLimit)
        clipboardLimit = clipLimit > 0 ? clipLimit : 50
        clipboardRemember = defaults.bool(forKey: Keys.clipboardRemember)
        approvalsFromClaudePult = defaults.object(forKey: Keys.approvalsFromClaudePult) as? Bool ?? true
        telegramApprovals = defaults.bool(forKey: Keys.telegramApprovals)
        pullRequestAlerts = defaults.object(forKey: Keys.pullRequestAlerts) as? Bool ?? true
        nightStartHour = defaults.object(forKey: Keys.nightStartHour) as? Int ?? 1
        panelHotKey = defaults.string(forKey: Keys.panelHotKey).flatMap(PanelHotKey.init(rawValue:)) ?? .controlOptionC
        pullRequestAlertsToTelegram = defaults.bool(forKey: Keys.pullRequestAlertsToTelegram)
        telegramApprovalsChatID = defaults.string(forKey: Keys.telegramApprovalsChatID) ?? ""
        clipboardExcludedApps = defaults.stringArray(forKey: Keys.clipboardExcludedApps) ?? ClipboardPolicy.defaultExcludedApps
        notesFolder = defaults.string(forKey: Keys.notesFolder) ?? "~/Documents/ClaudePult Notes"
        quickCommands = defaults.data(forKey: Keys.quickCommands).flatMap { try? JSONDecoder().decode([QuickCommand].self, from: $0) } ?? QuickCommand.examples
        quickToggles = defaults.stringArray(forKey: Keys.quickToggles)?.compactMap(QuickToggle.init(rawValue:)) ?? QuickToggle.allCases
        keepAwakeRules = defaults.data(forKey: Keys.keepAwakeRules).flatMap { try? JSONDecoder().decode(KeepAwakeRules.self, from: $0) } ?? KeepAwakeRules()
        let diskBelow = defaults.integer(forKey: Keys.resourceDiskBelowGB)
        resourceDiskBelowGB = diskBelow > 0 ? diskBelow : 20
        panelTextSize = defaults.string(forKey: Keys.panelTextSize).flatMap(PanelTextSize.init(rawValue:)) ?? .normal
        panelWidth = defaults.string(forKey: Keys.panelWidth).flatMap(PanelWidth.init(rawValue:)) ?? .normal
        panelDensity = defaults.string(forKey: Keys.panelDensity).flatMap(PanelDensity.init(rawValue:)) ?? .normal
        panelTheme = defaults.string(forKey: Keys.panelTheme).flatMap(PanelTheme.init(rawValue:)) ?? .system
        panelAnimations = defaults.object(forKey: Keys.panelAnimations) as? Bool ?? true
        hiddenBlocks = Set((defaults.stringArray(forKey: Keys.hiddenBlocks) ?? []).compactMap(PanelBlock.init(rawValue:)))
        hubDisabled = Set(defaults.stringArray(forKey: Keys.hubDisabled) ?? [])
        hubGeminiQuota = defaults.bool(forKey: Keys.hubGeminiQuota)
        let geminiLimit = defaults.integer(forKey: Keys.hubGeminiDailyLimit)
        hubGeminiDailyLimit = geminiLimit > 0 ? geminiLimit : 1000
        hubCursor = defaults.bool(forKey: Keys.hubCursor)
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
        static let calendarReminderHours = "calendarReminderHours"
        static let calendarRemindersToTelegram = "calendarRemindersToTelegram"
        static let limitThresholds = "limitThresholds"
        static let limitAlertsToTelegram = "limitAlertsToTelegram"
        static let renewClaudeLogin = "renewClaudeLogin"
        static let resourceAlerts = "resourceAlerts"
        static let clipboardLimit = "clipboardLimit"
        static let clipboardRemember = "clipboardRemember"
        static let approvalsFromClaudePult = "approvalsFromClaudePult"
        static let telegramApprovals = "telegramApprovals"
        static let pullRequestAlerts = "pullRequestAlerts"
        static let panelHotKey = "panelHotKey"
        static let nightStartHour = "nightStartHour"
        static let pullRequestAlertsToTelegram = "pullRequestAlertsToTelegram"
        static let telegramApprovalsChatID = "telegramApprovalsChatID"
        static let clipboardExcludedApps = "clipboardExcludedApps"
        static let notesFolder = "notesFolder"
        static let quickCommands = "quickCommands"
        static let quickToggles = "quickToggles"
        static let keepAwakeRules = "keepAwakeRules"
        static let resourceDiskBelowGB = "resourceDiskBelowGB"
        static let panelTextSize = "panelTextSize"
        static let panelWidth = "panelWidth"
        static let panelDensity = "panelDensity"
        static let panelTheme = "panelTheme"
        static let panelAnimations = "panelAnimations"
        static let hiddenBlocks = "hiddenBlocks"
        static let hubDisabled = "hubDisabled"
        static let hubGeminiQuota = "hubGeminiQuota"
        static let hubGeminiDailyLimit = "hubGeminiDailyLimit"
        static let hubCursor = "hubCursor"
    }
}
