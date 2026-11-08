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

/// How a Claude command runs (docs/specs/SPEC.md §2.4).
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

    /// macOS's Accessibility prompt was shown for «Раскладка»: it comes up by itself once, not at every launch.
    var layoutAccessAsked: Bool {
        didSet { defaults.set(layoutAccessAsked, forKey: Keys.layoutAccessAsked) }
    }

    var telegramForBackground: Bool {
        didSet { defaults.set(telegramForBackground, forKey: Keys.telegramForBackground) }
    }

    var backgroundTimeLimitMinutes: Int {
        didSet { defaults.set(backgroundTimeLimitMinutes, forKey: Keys.backgroundTimeLimitMinutes) }
    }

    /// What the menu bar item shows (SPEC-modes §7).
    var menuBarConfig: MenuBarConfig {
        didSet { defaults.setEncoded(menuBarConfig, forKey: Keys.menuBarConfig) }
    }

    /// Where the current mode's projects come from; set by `ProfileStore` when a mode is applied, not stored.
    var activeSource: ProjectSource = .none

    /// `Profile.resultPatterns` of the current mode; set with the source, not stored.
    var activeResultPatterns: [String] = []

    /// Whose rules the developer prompts follow; set with the mode, not stored.
    var promptStyle: PromptStyle = .workspace

    /// Chosen models and the compatible server's address (SPEC-modes §11); keys live in the Keychain.
    var aiServices: AIServicesConfig {
        didSet { defaults.setEncoded(aiServices, forKey: Keys.aiServices) }
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

    /// Per-service thresholds (SPEC-ai-services stage 4), by `ServiceTab` raw value: missing — the common
    /// `limitThresholds`, empty — no limit notifications for that service.
    var serviceThresholds: [String: [Int]] {
        didSet { defaults.set(serviceThresholds, forKey: Keys.serviceThresholds) }
    }

    /// The thresholds a service's limits notify at.
    func thresholds(for service: ServiceTab) -> [Int] {
        serviceThresholds[service.rawValue] ?? limitThresholds
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
        didSet { defaults.setEncoded(keepAwakeRules, forKey: Keys.keepAwakeRules) }
    }

    /// «Остров у чёлки» (SPEC-notch §6).
    var notch: NotchSettings {
        didSet { defaults.setEncoded(notch, forKey: Keys.notch) }
    }

    /// Beta builds through Sparkle and the modules still in beta testing (docs/RELEASE.md «Beta builds»).
    var betaUpdates: Bool {
        didSet { defaults.set(betaUpdates, forKey: Keys.betaUpdates) }
    }

    /// «Раскладка» (SPEC-layout §4).
    var layout: LayoutSettings {
        didSet { defaults.setEncoded(layout, forKey: Keys.layout) }
    }

    /// «Telegram» (SPEC-telegram §6).
    var telegramBot: TelegramBotSettings {
        didSet { defaults.setEncoded(telegramBot, forKey: Keys.telegramBot) }
    }

    /// «Быстрый запрос» (SPEC-quick-prompt §4): its hot key, and the project and mode of the last request.
    var quickPrompt: QuickPromptSettings {
        didSet { defaults.setEncoded(quickPrompt, forKey: Keys.quickPrompt) }
    }

    /// «Быстрые команды» and «Быстрые переключатели» (SPEC-profiles §4.3–4.4).
    /// Extra Claude accounts whose limits the panel shows.
    var claudeAccounts: [ClaudeAccount] {
        didSet { defaults.setEncoded(claudeAccounts, forKey: Keys.claudeAccounts) }
    }

    var quickCommands: [QuickCommand] {
        didSet { defaults.setEncoded(quickCommands, forKey: Keys.quickCommands) }
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

    var openPanelHotKey: OpenPanelHotKey {
        didSet { defaults.set(openPanelHotKey.rawValue, forKey: Keys.openPanelHotKey) }
    }

    /// Notify when a pull request's CI fails or recovers, or the PR closes (`PullRequestAlerts`).
    var pullRequestAlerts: Bool {
        didSet { defaults.set(pullRequestAlerts, forKey: Keys.pullRequestAlerts) }
    }

    var pullRequestAlertsToTelegram: Bool {
        didSet { defaults.set(pullRequestAlertsToTelegram, forKey: Keys.pullRequestAlertsToTelegram) }
    }

    /// Also from Telegram, through AI Hub Bar's own bot (`TelegramApprovals`); chat id empty = the `_daily-report` one.
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

    var panelBackground: PanelBackground {
        didSet { defaults.set(panelBackground.rawValue, forKey: Keys.panelBackground) }
    }

    var panelAnimations: Bool {
        didSet { defaults.set(panelAnimations, forKey: Keys.panelAnimations) }
    }

    var hiddenBlocks: Set<PanelBlock> {
        didSet { defaults.set(hiddenBlocks.map(\.rawValue).sorted(), forKey: Keys.hiddenBlocks) }
    }

    /// How often each kind of notification may repeat (kind → `NotificationFrequency`); missing kinds use their default.
    var notificationFrequencies: [String: String] {
        didSet { defaults.set(notificationFrequencies, forKey: Keys.notificationFrequencies) }
    }

    func frequency(_ kind: NotificationKind) -> NotificationFrequency {
        notificationFrequencies[kind.rawValue].flatMap(NotificationFrequency.init(rawValue:)) ?? kind.defaultFrequency
    }

    /// The chat of the bot set in the «Telegram» module (the token is in the Keychain).
    var telegramChatID: String {
        didSet { defaults.set(telegramChatID, forKey: Keys.telegramChatID) }
    }

    /// «Свои промпты» for the search (⌃⌥C).
    var savedPrompts: [SavedPrompt] {
        didSet { defaults.setEncoded(savedPrompts, forKey: Keys.savedPrompts) }
    }

    /// «Неделя Claude» in Telegram: on/off, weekday (1 = Sunday … 7 = Saturday) and hour.
    var weeklySummary: Bool {
        didSet { defaults.set(weeklySummary, forKey: Keys.weeklySummary) }
    }

    var weeklySummaryWeekday: Int {
        didSet { defaults.set(weeklySummaryWeekday, forKey: Keys.weeklySummaryWeekday) }
    }

    var weeklySummaryHour: Int {
        didSet { defaults.set(weeklySummaryHour, forKey: Keys.weeklySummaryHour) }
    }

    /// «Стоп-кран»: at this session or week usage background runs pause until the reset; 0 is off.
    var runGuardPercent: Int {
        didSet { defaults.set(runGuardPercent, forKey: Keys.runGuardPercent) }
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
        panelBackground = .standard
        panelAnimations = true
    }

    static let defaultProjectsDirectory = NSHomeDirectory() + "/Projects"
    static let defaultDailyReportDirectory = NSHomeDirectory() + "/Projects/_daily-report"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        projectsDirectory = defaults.string(forKey: Keys.projectsDirectory) ?? Self.defaultProjectsDirectory
        dailyReportDirectory = defaults.string(forKey: Keys.dailyReportDirectory) ?? Self.defaultDailyReportDirectory
        claudePath = defaults.string(forKey: Keys.claudePath) ?? ""
        defaultLaunchMode = defaults.value(LaunchMode.self, forKey: Keys.defaultLaunchMode)
        layoutAccessAsked = defaults.bool(Keys.layoutAccessAsked, default: false)
        telegramForBackground = defaults.bool(Keys.telegramForBackground, default: true)
        backgroundTimeLimitMinutes = defaults.positiveInt(Keys.backgroundTimeLimitMinutes, default: 90)
        menuBarConfig = defaults.decoded(MenuBarConfig.self, forKey: Keys.menuBarConfig)
            ?? MenuBarConfig.migrated(from: defaults.value(MenuBarUsageMode.self, forKey: Keys.menuBarUsageMode) ?? .session)
        aiServices = defaults.decoded(AIServicesConfig.self, forKey: Keys.aiServices)
            ?? AIServicesConfig()
        calendarReminderHours = (defaults.array(forKey: Keys.calendarReminderHours) as? [Int]) ?? [24]
        calendarRemindersToTelegram = defaults.bool(forKey: Keys.calendarRemindersToTelegram)
        let thresholds = (defaults.array(forKey: Keys.limitThresholds) as? [Int])?.filter { (1...100).contains($0) }
        limitThresholds = thresholds?.isEmpty == false ? thresholds! : Self.defaultLimitThresholds
        serviceThresholds = ((defaults.dictionary(forKey: Keys.serviceThresholds) as? [String: [Int]]) ?? [:])
            .mapValues { $0.filter { (1...100).contains($0) }.sorted() }
        limitAlertsToTelegram = defaults.bool(forKey: Keys.limitAlertsToTelegram)
        renewClaudeLogin = defaults.bool(Keys.renewClaudeLogin, default: true)
        resourceAlerts = defaults.bool(Keys.resourceAlerts, default: true)
        clipboardLimit = defaults.positiveInt(Keys.clipboardLimit, default: 50)
        clipboardRemember = defaults.bool(forKey: Keys.clipboardRemember)
        approvalsFromClaudePult = defaults.bool(Keys.approvalsFromClaudePult, default: true)
        telegramApprovals = defaults.bool(forKey: Keys.telegramApprovals)
        pullRequestAlerts = defaults.bool(Keys.pullRequestAlerts, default: true)
        nightStartHour = defaults.int(Keys.nightStartHour, default: 1)
        panelHotKey = defaults.value(PanelHotKey.self, forKey: Keys.panelHotKey) ?? .controlOptionC
        openPanelHotKey = defaults.value(OpenPanelHotKey.self, forKey: Keys.openPanelHotKey) ?? .controlOptionB
        pullRequestAlertsToTelegram = defaults.bool(forKey: Keys.pullRequestAlertsToTelegram)
        telegramApprovalsChatID = defaults.string(forKey: Keys.telegramApprovalsChatID) ?? ""
        clipboardExcludedApps = defaults.stringArray(forKey: Keys.clipboardExcludedApps) ?? ClipboardPolicy.defaultExcludedApps
        notesFolder = defaults.string(forKey: Keys.notesFolder) ?? "~/Documents/ClaudePult Notes"
        quickCommands = defaults.decoded([QuickCommand].self, forKey: Keys.quickCommands) ?? QuickCommand.examples
        claudeAccounts = defaults.decoded([ClaudeAccount].self, forKey: Keys.claudeAccounts) ?? []
        quickToggles = defaults.stringArray(forKey: Keys.quickToggles)?.compactMap(QuickToggle.init(rawValue:)) ?? QuickToggle.allCases
        keepAwakeRules = defaults.decoded(KeepAwakeRules.self, forKey: Keys.keepAwakeRules) ?? KeepAwakeRules()
        notch = defaults.decoded(NotchSettings.self, forKey: Keys.notch) ?? NotchSettings()
        betaUpdates = defaults.bool(forKey: Keys.betaUpdates)
        layout = defaults.decoded(LayoutSettings.self, forKey: Keys.layout) ?? LayoutSettings()
        quickPrompt = defaults.decoded(QuickPromptSettings.self, forKey: Keys.quickPrompt) ?? QuickPromptSettings()
        telegramBot = defaults.decoded(TelegramBotSettings.self, forKey: Keys.telegramBot) ?? TelegramBotSettings()
        resourceDiskBelowGB = defaults.positiveInt(Keys.resourceDiskBelowGB, default: 20)
        panelTextSize = defaults.value(PanelTextSize.self, forKey: Keys.panelTextSize) ?? .normal
        panelWidth = defaults.value(PanelWidth.self, forKey: Keys.panelWidth) ?? .normal
        panelDensity = defaults.value(PanelDensity.self, forKey: Keys.panelDensity) ?? .normal
        panelTheme = defaults.value(PanelTheme.self, forKey: Keys.panelTheme) ?? .system
        panelBackground = defaults.value(PanelBackground.self, forKey: Keys.panelBackground) ?? .standard
        panelAnimations = defaults.bool(Keys.panelAnimations, default: true)
        hiddenBlocks = Set((defaults.stringArray(forKey: Keys.hiddenBlocks) ?? []).compactMap(PanelBlock.init(rawValue:)))
        hubDisabled = Set(defaults.stringArray(forKey: Keys.hubDisabled) ?? [])
        hubGeminiQuota = defaults.bool(forKey: Keys.hubGeminiQuota)
        hubGeminiDailyLimit = defaults.positiveInt(Keys.hubGeminiDailyLimit, default: 1000)
        hubCursor = defaults.bool(forKey: Keys.hubCursor)
        runGuardPercent = defaults.int(Keys.runGuardPercent, default: 95)
        weeklySummary = defaults.bool(Keys.weeklySummary, default: true)
        telegramChatID = defaults.string(forKey: Keys.telegramChatID) ?? ""
        notificationFrequencies = defaults.dictionary(forKey: Keys.notificationFrequencies) as? [String: String] ?? [:]
        savedPrompts = defaults.decoded([SavedPrompt].self, forKey: Keys.savedPrompts) ?? SavedPrompt.examples
        weeklySummaryWeekday = defaults.int(Keys.weeklySummaryWeekday, default: 1)
        weeklySummaryHour = defaults.int(Keys.weeklySummaryHour, default: 19)
    }

    var reportScript: String {
        (dailyReportDirectory as NSString).appendingPathComponent("report.py")
    }

    private enum Keys {
        static let projectsDirectory = "projectsDirectory"
        static let dailyReportDirectory = "dailyReportDirectory"
        static let claudePath = "claudePath"
        static let defaultLaunchMode = "defaultLaunchMode"
        static let layoutAccessAsked = "layoutAccessAsked"
        static let telegramForBackground = "telegramForBackground"
        static let backgroundTimeLimitMinutes = "backgroundTimeLimitMinutes"
        static let menuBarUsageMode = "menuBarUsageMode"
        static let menuBarConfig = "menuBarConfig"
        static let aiServices = "aiServices"
        static let calendarReminderHours = "calendarReminderHours"
        static let calendarRemindersToTelegram = "calendarRemindersToTelegram"
        static let limitThresholds = "limitThresholds"
        static let serviceThresholds = "serviceThresholds"
        static let limitAlertsToTelegram = "limitAlertsToTelegram"
        static let renewClaudeLogin = "renewClaudeLogin"
        static let resourceAlerts = "resourceAlerts"
        static let clipboardLimit = "clipboardLimit"
        static let clipboardRemember = "clipboardRemember"
        static let approvalsFromClaudePult = "approvalsFromClaudePult"
        static let telegramApprovals = "telegramApprovals"
        static let pullRequestAlerts = "pullRequestAlerts"
        static let panelHotKey = "panelHotKey"
        static let openPanelHotKey = "openPanelHotKey"
        static let nightStartHour = "nightStartHour"
        static let pullRequestAlertsToTelegram = "pullRequestAlertsToTelegram"
        static let telegramApprovalsChatID = "telegramApprovalsChatID"
        static let clipboardExcludedApps = "clipboardExcludedApps"
        static let notesFolder = "notesFolder"
        static let quickCommands = "quickCommands"
        static let claudeAccounts = "claudeAccounts"
        static let quickToggles = "quickToggles"
        static let keepAwakeRules = "keepAwakeRules"
        static let notch = "notch"
        static let layout = "layout"
        static let quickPrompt = "quickPrompt"
        static let telegramBot = "telegramBot"
        static let betaUpdates = "betaUpdates"
        static let resourceDiskBelowGB = "resourceDiskBelowGB"
        static let panelTextSize = "panelTextSize"
        static let panelWidth = "panelWidth"
        static let panelDensity = "panelDensity"
        static let panelTheme = "panelTheme"
        static let panelBackground = "panelBackground"
        static let panelAnimations = "panelAnimations"
        static let hiddenBlocks = "hiddenBlocks"
        static let hubDisabled = "hubDisabled"
        static let hubGeminiQuota = "hubGeminiQuota"
        static let hubGeminiDailyLimit = "hubGeminiDailyLimit"
        static let hubCursor = "hubCursor"
        static let runGuardPercent = "runGuardPercent"
        static let weeklySummary = "weeklySummary"
        static let savedPrompts = "savedPrompts"
        static let notificationFrequencies = "notificationFrequencies"
        static let telegramChatID = "telegramChatID"
        static let weeklySummaryWeekday = "weeklySummaryWeekday"
        static let weeklySummaryHour = "weeklySummaryHour"
    }
}

extension AppSettings {
    /// The setting behind a module's Telegram place (its «Telegram» chip) and `Telegram.notify`.
    func isOn(_ toggle: TelegramToggle) -> Bool {
        switch toggle {
        case .limitAlerts: limitAlertsToTelegram
        case .backgroundResults: telegramForBackground
        case .calendarReminders: calendarRemindersToTelegram
        case .pullRequests: pullRequestAlertsToTelegram
        }
    }

    func set(_ toggle: TelegramToggle, _ on: Bool) {
        switch toggle {
        case .limitAlerts: limitAlertsToTelegram = on
        case .backgroundResults: telegramForBackground = on
        case .calendarReminders: calendarRemindersToTelegram = on
        case .pullRequests: pullRequestAlertsToTelegram = on
        }
    }

    /// The setting behind a module's own notifications switch.
    func isOn(_ toggle: NotificationSwitch) -> Bool {
        switch toggle {
        case .resourceAlerts: resourceAlerts
        case .pullRequestAlerts: pullRequestAlerts
        case .calendarReminders: !calendarReminderHours.isEmpty
        }
    }

    func set(_ toggle: NotificationSwitch, _ on: Bool) {
        switch toggle {
        case .resourceAlerts: resourceAlerts = on
        case .pullRequestAlerts: pullRequestAlerts = on
        case .calendarReminders: calendarReminderHours = on ? (calendarReminderHours.isEmpty ? [24] : calendarReminderHours) : []
        }
    }
}

/// How `AppSettings` reads and writes its keys — one way for each kind of value (SPEC-refactor §6).
extension UserDefaults {
    /// A stored Bool, or `fallback` when the key was never written.
    func bool(_ key: String, default fallback: Bool) -> Bool { object(forKey: key) as? Bool ?? fallback }

    /// A stored Int (0 included), or `fallback` when the key was never written.
    func int(_ key: String, default fallback: Int) -> Int { object(forKey: key) as? Int ?? fallback }

    /// A stored Int above 0, else `fallback` (for sizes and limits, where 0 means «not set»).
    func positiveInt(_ key: String, default fallback: Int) -> Int {
        let value = integer(forKey: key)
        return value > 0 ? value : fallback
    }

    func value<Value: RawRepresentable>(_ type: Value.Type, forKey key: String) -> Value? where Value.RawValue == String {
        string(forKey: key).flatMap(Value.init(rawValue:))
    }

    func decoded<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    func setEncoded(_ value: some Encodable, forKey key: String) {
        set(try? JSONEncoder().encode(value), forKey: key)
    }
}
