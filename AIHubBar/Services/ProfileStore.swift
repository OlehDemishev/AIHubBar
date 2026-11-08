import Foundation
import Observation

/// Everything that goes into an exported `*.claudepult` file (SPEC-modes §12): all settings, or one mode.
/// Never contains keys, tokens, logs or session data.
struct SettingsBundle: Codable, Equatable, Sendable {
    static let settingsFormat = "claudepult-settings"
    static let modeFormat = "claudepult-mode"

    struct General: Codable, Equatable, Sendable {
        var claudePath: String?
        var backgroundTimeLimitMinutes: Int
        var telegramForBackground: Bool
        var limitThresholds: [Int]
        var limitAlertsToTelegram: Bool
    }

    struct Appearance: Codable, Equatable, Sendable {
        var textSize: String
        var width: String
        var density: String
        var theme: String
        var animations: Bool
        var showLimits: Bool
        var showSessions: Bool
        /// The pre-builder setting, still written so older versions can read the file.
        var menuBar: String
        var menuBarConfig: MenuBarConfig?
    }

    var format: String
    var version: Int
    var exportedAt: Date
    var general: General?
    var appearance: Appearance?
    var services: AIServicesConfig?
    var modes: [Profile]
    var enabled: [String]?
    var current: String?
    /// Installed modules (version 2, SPEC-profiles §1); a version 1 file installs what its modes use.
    var installed: [String]?
    /// Modules switched off with their main switch (SPEC-settings §1); missing in older files — all on.
    var off: [String]?

    /// Version 2: modes are profiles with modules, plus the installed modules.
    static let currentVersion = 2
}

/// Profiles: storage, the active one, enabling and ordering, export and import.
/// The active mode is *applied* to `AppSettings` (projects folder, `_daily-report`, launch mode, project and
/// command blocks), so the rest of the app keeps reading `AppSettings` as before.
@MainActor
@Observable
final class ProfileStore {
    private(set) var modes: [Profile] = []
    private(set) var enabledIDs: [String] = []
    private(set) var currentID: String = ""
    /// Modules installed from the catalog (SPEC-profiles §1). Until the catalog has its own screen (stage 2) it is
    /// what the profiles use.
    private(set) var installedModules: [ModuleKind] = []
    /// Installed modules switched off with their main switch (SPEC-settings §1): they keep their place in the profiles
    /// but do nothing — no background work, no panel block, no menu bar elements, no notifications.
    private(set) var switchedOff: [ModuleKind] = []
    /// A file opened from Finder, waiting for «Заменить» / «Добавить» in Settings → Режимы.
    private(set) var pendingImport: (url: URL, bundle: SettingsBundle)?
    private(set) var lastMessage: String?

    /// Called after the active mode changed what the app shows (refresh projects, hooks).
    var didApply: (() -> Void)?

    private let settings: AppSettings
    private let directory: URL

    struct State: Codable {
        var order: [String]
        var enabled: [String]
        var current: String
        var installed: [String]?
        var off: [String]?
    }

    static var defaultDirectory: URL { SessionFiles.supportDirectory.appending(path: "modes", directoryHint: .isDirectory) }

    /// Read-only: nothing is written to disk and the settings are left alone — for command-line commands that only
    /// look (`--modes`, `--calendar`, `--export-settings`; SPEC-refactor §2.7).
    private let readOnly: Bool

    init(settings: AppSettings, directory: URL = ProfileStore.defaultDirectory, readOnly: Bool = false) {
        self.settings = settings
        self.directory = directory
        self.readOnly = readOnly
        load()
    }

    var current: Profile? { modes.first { $0.id == currentID } }
    var enabledModes: [Profile] { modes.filter { enabledIDs.contains($0.id) } }

    // MARK: - Loading and migration

    private func load() {
        let decoder = Self.decoder
        var loaded: [Profile] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" && url.lastPathComponent != "state.json" {
            if let data = try? Data(contentsOf: url), let mode = try? decoder.decode(Profile.self, from: data) {
                loaded.append(mode)
            }
        }
        let state = (try? Data(contentsOf: directory.appending(path: "state.json"))).flatMap { try? decoder.decode(State.self, from: $0) }
        installedModules = (state?.installed ?? []).compactMap(ModuleKind.init(rawValue:))
        switchedOff = (state?.off ?? []).compactMap(ModuleKind.init(rawValue:))

        if loaded.isEmpty, state == nil, FileManager.default.fileExists(atPath: settings.reportScript) {
            // The setup AI Hub Bar had before modes (report.py, `_daily-report`) becomes the first profile, unchanged.
            let mode = Self.migrated(from: settings)
            modes = [mode]
            enabledIDs = [mode.id]
            currentID = mode.id
            saveAll()
            AppLog.info("Profiles: created «\(mode.name)» from the existing settings")
        } else if loaded.isEmpty {
            // An empty start (SPEC-profiles §2): no profile, nothing installed, the assistant opens.
            modes = []
            enabledIDs = []
            currentID = ""
            installedModules = []
            needsAssistant = state == nil
        } else {
            let order = state?.order ?? []
            modes = loaded.sorted { (order.firstIndex(of: $0.id) ?? Int.max, $0.name) < (order.firstIndex(of: $1.id) ?? Int.max, $1.name) }
            enabledIDs = (state?.enabled ?? modes.map(\.id)).filter { id in modes.contains { $0.id == id } }
            if enabledIDs.isEmpty, let first = modes.first { enabledIDs = [first.id] }
            let saved = state.map(\.current).flatMap { enabledIDs.contains($0) ? $0 : nil }
            currentID = saved ?? enabledIDs.first ?? ""
        }
        // Profiles become profiles (SPEC-profiles §7): files without modules or a menu bar of their own are rewritten.
        if readOnly {
            modes = modes.map(synced)
            installModules(of: modes)
            return
        }
        for mode in modes where synced(mode) != mode {
            save(mode)
            AppLog.info("Profiles: «\(mode.name)» updated to modules and its own menu bar")
        }
        installModules(of: modes)
        if let current { apply(current) }
    }

    /// Set on a first start without `_daily-report`: the app opens the assistant.
    private(set) var needsAssistant = false

    /// The assistant's mode, enabled and made current; it replaces the starter placeholder.
    @discardableResult
    func addFromAssistant(_ draft: Profile) -> Profile {
        var mode = draft
        mode.id = UUID().uuidString.lowercased()
        mode.name = uniqueName(mode.name.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Новый профиль") : mode.name)
        modes.append(mode)
        enabledIDs.append(mode.id)
        save(mode)
        saveState()
        select(mode.id)
        for starter in modes where starter.template == "starter" && starter.id != mode.id { delete(starter.id) }
        needsAssistant = false
        AppLog.info("Profile «\(mode.name)» added by the assistant")
        return mode
    }

    /// The pre-modes settings as a mode. With `_daily-report` present it is the report.py developer setup.
    static func migrated(from settings: AppSettings) -> Profile {
        return Profile.developerWithReport(
            projectsDirectory: settings.projectsDirectory,
            dailyReportDirectory: settings.dailyReportDirectory,
            launchMode: settings.defaultLaunchMode,
            showProjects: settings.shows(.projects),
            showCommonCommands: settings.shows(.commands)
        )
    }

    // MARK: - Applying

    /// Pushes the mode's blocks into `AppSettings`, which the rest of the app reads.
    private func apply(_ mode: Profile) {
        switch mode.source {
        case let .gitReport(projects, dailyReport):
            settings.projectsDirectory = PathText.expand(projects)
            settings.dailyReportDirectory = PathText.expand(dailyReport)
        case let .gitBuiltin(path), let .folders(path), let .inbox(path):
            settings.projectsDirectory = PathText.expand(path)
        case .none:
            break
        }
        settings.defaultLaunchMode = mode.launchMode
        settings.activeSource = mode.source
        settings.activeResultPatterns = mode.resultPatterns
        settings.promptStyle = mode.template == "developer-report" ? .workspace : .generic
        // The built-in git scanner arrives with the templates (SPEC-modes §9, stage 6).
        // The profile's modules decide what the panel shows (SPEC-profiles §9.2); the blocks in `AppSettings` follow
        // them for the code that still reads those.
        // What the panel shows is `panelModules` (SPEC-refactor §4); the old blocks in `AppSettings` are only read for
        // files from before profiles. The settings keep a copy of the profile's menu bar for when there is no profile.
        if let menuBar = mode.menuBar, menuBar != settings.menuBarConfig { settings.menuBarConfig = menuBar }
        didApply?()
    }

    /// The current profile's shown, working modules in panel order.
    var panelModules: [ModuleKind] { (current?.panelModules ?? []).filter(isOn) }

    /// Installed and not switched off: the module works (SPEC-settings §1).
    func isOn(_ kind: ModuleKind) -> Bool {
        installedModules.contains(kind) && !switchedOff.contains(kind) && (!kind.isBeta || settings.betaUpdates)
    }

    /// `_daily-report/report.py` is on this Mac: «Отчёты» can be switched on in a profile.
    var hasDailyReport: Bool { FileManager.default.fileExists(atPath: settings.reportScript) }

    /// «Раскладка» and other beta modules work only with beta builds.
    var isBetaAllowed: Bool { settings.betaUpdates }

    /// Installed but not working — switched off, or a beta module without beta builds: its notifications and its
    /// menu bar data are dropped. The one rule for both (SPEC-refactor §2.2); a module no profile uses yet still
    /// speaks (Oleh, 2026-11-03: limit alerts come without a profile).
    func isSilenced(_ kind: ModuleKind) -> Bool { installedModules.contains(kind) && !isOn(kind) }

    var silencedModules: [ModuleKind] { ModuleKind.allCases.filter(isSilenced) }

    /// The working modules, in catalog order.
    var activeModules: [ModuleKind] { ModuleKind.allCases.filter(isOn) }

    /// The module's main switch (SPEC-settings §1). On installs an optional module that isn't installed yet; a built-in
    /// one comes with the profile settings that call for it, so the switch only lets it work again. Off keeps the
    /// module in the profiles, where it was.
    func setOn(_ kind: ModuleKind, _ on: Bool) {
        if on {
            switchedOff.removeAll { $0 == kind }
            if !kind.isBuiltIn, !installedModules.contains(kind) { install(kind) }
        } else if !switchedOff.contains(kind) {
            switchedOff = ModuleKind.allCases.filter { switchedOff.contains($0) || $0 == kind }
        }
        saveState()
        AppLog.info("Module \(kind.rawValue) switched \(on ? "on" : "off")")
        if let current { apply(current) }
    }

    /// The menu bar shown now: the current profile's, else the one kept in the settings (no profile yet).
    var menuBar: MenuBarConfig { current?.menuBar ?? settings.menuBarConfig }

    /// The one way to change the menu bar (SPEC-refactor §4): the current profile's, and the settings' copy.
    func setMenuBar(_ config: MenuBarConfig) {
        if settings.menuBarConfig != config { settings.menuBarConfig = config }
        guard var mode = current, mode.menuBar != config else { return }
        mode.menuBar = config
        update(mode)
    }

    func select(_ id: String) {
        guard id != currentID, let mode = modes.first(where: { $0.id == id }) else { return }
        if !enabledIDs.contains(id) { enabledIDs.append(id) }
        currentID = id
        saveState()
        apply(mode)
        AppLog.info("Profile switched to «\(mode.name)»")
    }

    /// Saves edits from Settings → Режимы; the active mode is applied at once.
    func update(_ mode: Profile) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        modes[index] = mode
        save(mode)
        if mode.id == currentID { apply(mode) }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        if enabled {
            if !enabledIDs.contains(id) { enabledIDs.append(id) }
        } else {
            // At least one mode stays on.
            guard enabledIDs.count > 1 else { return }
            enabledIDs.removeAll { $0 == id }
            if currentID == id, let next = enabledModes.first { select(next.id) }
        }
        enabledIDs = modes.map(\.id).filter { enabledIDs.contains($0) }
        saveState()
    }

    func move(_ id: String, by offset: Int) {
        guard let index = modes.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), modes.count - 1)
        guard target != index else { return }
        modes.insert(modes.remove(at: index), at: target)
        enabledIDs = modes.map(\.id).filter { enabledIDs.contains($0) }
        saveState()
    }

    @discardableResult
    func duplicate(_ id: String) -> Profile? {
        guard let original = modes.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID().uuidString.lowercased()
        copy.name = uniqueName(original.name + String(localized: " (копия)"))
        modes.insert(copy, at: (modes.firstIndex { $0.id == id } ?? modes.count - 1) + 1)
        save(copy)
        saveState()
        return copy
    }

    /// A new mode from a template, enabled and made current.
    @discardableResult
    func add(_ template: ProfileTemplate, folder: String) -> Profile {
        let mode = template.makeMode(folder: folder, name: uniqueName(template.mode.name))
        modes.append(mode)
        enabledIDs.append(mode.id)
        save(mode)
        saveState()
        select(mode.id)
        AppLog.info("Profile «\(mode.name)» added from template \(template.id)")
        return mode
    }

    /// The last profile can go too: AI Hub Bar is then empty again (SPEC-profiles §2) and modules no profile uses
    /// stop working.
    func delete(_ id: String) {
        modes.removeAll { $0.id == id }
        enabledIDs.removeAll { $0 == id }
        if enabledIDs.isEmpty, let first = modes.first { enabledIDs = [first.id] }
        if FileManager.default.fileExists(atPath: fileURL(id).path) {
            AppLog.attempt("Profile \(id) not deleted") { try FileManager.default.removeItem(at: fileURL(id)) }
        }
        if currentID == id {
            currentID = ""
            if let next = enabledModes.first { select(next.id) }
        }
        // Built-in modules work only for profiles; an optional one stays installed until removed in «Модули».
        let used = Set(modes.flatMap { $0.modules ?? [] }.map(\.kind))
        installedModules = modes.isEmpty ? [] : installedModules.filter { used.contains($0) || !$0.isBuiltIn }
        saveState()
    }

    // MARK: - Optional modules (SPEC-profiles §1)

    /// Installs an optional module and adds it to the current profile, shown, at the bottom of its panel (a module
    /// that is not a panel block only gets installed).
    func install(_ kind: ModuleKind) {
        guard !kind.isBuiltIn else { return }
        if !installedModules.contains(kind) {
            installedModules = ModuleKind.allCases.filter { installedModules.contains($0) || $0 == kind }
            saveState()
            AppLog.info("Module installed: \(kind.rawValue)")
        }
        if kind.isPanelBlock, let current { addModule(kind, to: current.id) }
    }

    /// Removes an optional module from every profile and stops it; its settings stay for a later install.
    func uninstall(_ kind: ModuleKind) {
        guard !kind.isBuiltIn else { return }
        for mode in modes where mode.modules?.contains(where: { $0.kind == kind }) == true {
            var changed = mode
            changed.modules?.removeAll { $0.kind == kind }
            update(changed)
        }
        installedModules.removeAll { $0 == kind }
        switchedOff.removeAll { $0 == kind }
        saveState()
        AppLog.info("Module removed: \(kind.rawValue)")
    }

    func addModule(_ kind: ModuleKind, to profileID: String) {
        guard var mode = modes.first(where: { $0.id == profileID }), !(mode.modules ?? []).contains(where: { $0.kind == kind }) else { return }
        mode.modules = (mode.modules ?? []) + [ProfileModule(kind)]
        update(mode)
    }

    func removeModule(_ kind: ModuleKind, from profileID: String) {
        guard !kind.isBuiltIn, var mode = modes.first(where: { $0.id == profileID }) else { return }
        mode.modules?.removeAll { $0.kind == kind }
        update(mode)
    }

    private func uniqueName(_ base: String) -> String {
        var name = base
        var counter = 2
        while modes.contains(where: { $0.name == name }) {
            name = "\(base) \(counter)"
            counter += 1
        }
        return name
    }

    // MARK: - Export / import (SPEC-modes §12)

    func exportBundle() -> SettingsBundle {
        SettingsBundle(
            format: SettingsBundle.settingsFormat, version: SettingsBundle.currentVersion, exportedAt: .now,
            general: .init(
                claudePath: settings.claudePath.isEmpty ? nil : PathText.tilde(settings.claudePath),
                backgroundTimeLimitMinutes: settings.backgroundTimeLimitMinutes,
                telegramForBackground: settings.telegramForBackground,
                limitThresholds: settings.limitThresholds,
                limitAlertsToTelegram: settings.limitAlertsToTelegram
            ),
            appearance: .init(
                textSize: settings.panelTextSize.rawValue, width: settings.panelWidth.rawValue,
                density: settings.panelDensity.rawValue, theme: settings.panelTheme.rawValue,
                animations: settings.panelAnimations, showLimits: current?.shows(.limits) ?? true,
                showSessions: current?.shows(.sessions) ?? true, menuBar: menuBar.legacyMode.rawValue,
                menuBarConfig: menuBar
            ),
            services: settings.aiServices,
            modes: modes.map(synced), enabled: enabledIDs, current: currentID,
            installed: installedModules.map(\.rawValue),
            off: switchedOff.isEmpty ? nil : switchedOff.map(\.rawValue)
        )
    }

    func exportMode(_ id: String) -> SettingsBundle? {
        guard let mode = modes.first(where: { $0.id == id }) else { return nil }
        return SettingsBundle(format: SettingsBundle.modeFormat, version: SettingsBundle.currentVersion, exportedAt: .now, modes: [synced(mode)])
    }

    static func encode(_ bundle: SettingsBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    static func decodeBundle(_ data: Data) -> SettingsBundle? {
        guard let bundle = try? decoder.decode(SettingsBundle.self, from: data),
              [SettingsBundle.settingsFormat, SettingsBundle.modeFormat].contains(bundle.format),
              !bundle.modes.isEmpty else { return nil }
        return bundle
    }

    enum ImportStyle { case replace, add }

    /// `.replace`: all settings and modes from the file. `.add`: only its modes, as new ones (fresh ids,
    /// unique names); the current settings stay.
    func importBundle(_ bundle: SettingsBundle, style: ImportStyle) {
        switch style {
        case .replace where bundle.format == SettingsBundle.settingsFormat:
            if let general = bundle.general {
                settings.claudePath = general.claudePath.map(PathText.expand) ?? ""
                settings.backgroundTimeLimitMinutes = general.backgroundTimeLimitMinutes
                settings.telegramForBackground = general.telegramForBackground
                settings.limitThresholds = general.limitThresholds
                settings.limitAlertsToTelegram = general.limitAlertsToTelegram
            }
            if let look = bundle.appearance {
                settings.panelTextSize = PanelTextSize(rawValue: look.textSize) ?? .normal
                settings.panelWidth = PanelWidth(rawValue: look.width) ?? .normal
                settings.panelDensity = PanelDensity(rawValue: look.density) ?? .normal
                settings.panelTheme = PanelTheme(rawValue: look.theme) ?? .system
                settings.panelAnimations = look.animations
                settings.setShows(.limits, look.showLimits)
                settings.setShows(.sessions, look.showSessions)
                settings.menuBarConfig = look.menuBarConfig
                    ?? MenuBarConfig.migrated(from: MenuBarUsageMode(rawValue: look.menuBar) ?? .session)
            }
            if let services = bundle.services { settings.aiServices = services }
            for mode in modes { try? FileManager.default.removeItem(at: fileURL(mode.id)) }
            modes = bundle.modes
            let ids = modes.map(\.id)
            enabledIDs = (bundle.enabled ?? ids).filter(ids.contains)
            if enabledIDs.isEmpty { enabledIDs = Array(ids.prefix(1)) }
            currentID = bundle.current.flatMap { enabledIDs.contains($0) ? $0 : nil } ?? enabledIDs[0]
            installedModules = (bundle.installed ?? []).compactMap(ModuleKind.init(rawValue:))
            // The file's switches, not this Mac's old ones (SPEC-refactor §2.1).
            switchedOff = (bundle.off ?? []).compactMap(ModuleKind.init(rawValue:))
            saveAll()
            if let current { apply(current) }
            lastMessage = String(localized: "Настройки импортированы: \(modes.count) профиль(ов).")
        case .replace, .add:
            for var mode in bundle.modes {
                mode.id = UUID().uuidString.lowercased()
                mode.name = uniqueName(mode.name)
                modes.append(mode)
                enabledIDs.append(mode.id)
                save(mode)
            }
            saveState()
            lastMessage = String(localized: "Добавлено профилей: \(bundle.modes.count).")
        }
        pendingImport = nil
        AppLog.info("Settings import (\(style == .replace ? "replace" : "add")): \(bundle.modes.count) mode(s)")
    }

    /// A `*.claudepult` file opened from Finder or the command line.
    func prepareImport(from url: URL) {
        guard let data = try? Data(contentsOf: url), let bundle = Self.decodeBundle(data) else {
            lastMessage = String(localized: "Не удалось прочитать «\(url.lastPathComponent)»: это не файл настроек AI Hub Bar.")
            return
        }
        pendingImport = (url, bundle)
    }

    func cancelImport() { pendingImport = nil }

    /// Folders of a mode that do not exist on this Mac (after an import from another one).
    static func missingFolders(_ mode: Profile) -> [String] {
        var paths: [String] = []
        switch mode.source {
        case let .gitReport(projects, dailyReport): paths = [projects, dailyReport]
        case let .gitBuiltin(path), let .folders(path), let .inbox(path): paths = [path]
        case .none: break
        }
        return paths.filter { !FileManager.default.fileExists(atPath: PathText.expand($0)) }
    }

    // MARK: - Files

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func fileURL(_ id: String) -> URL { directory.appending(path: "\(id).json") }

    /// The profile with its modules in order (SPEC-profiles §1) and a menu bar of its own. The old block flags are
    /// written from the modules, so an older AI Hub Bar reading the file shows the same.
    private func synced(_ mode: Profile) -> Profile {
        var mode = mode
        let modules = mode.normalizedModules(hiddenBlocks: settings.hiddenBlocks)
        mode.modules = modules
        if let projects = modules.first(where: { $0.kind == .projects }) { mode.showProjects = projects.shown }
        if let reports = modules.first(where: { $0.kind == .reports }) { mode.showCommonCommands = reports.shown }
        if mode.menuBar == nil { mode.menuBar = settings.menuBarConfig }
        return mode
    }

    private func save(_ mode: Profile) {
        guard !readOnly else { return }
        let mode = synced(mode)
        if let index = modes.firstIndex(where: { $0.id == mode.id }), modes[index] != mode { modes[index] = mode }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        AppLog.attempt("Profile \(mode.id) not saved") {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(mode).write(to: fileURL(mode.id), options: .atomic)
        }
        installModules(of: [mode])
    }

    /// A profile can only show installed modules: whatever the given profiles use gets installed.
    private func installModules(of modes: [Profile]) {
        let used = modes.flatMap { $0.modules ?? [] }.map(\.kind)
        let missing = ModuleKind.allCases.filter { used.contains($0) && !installedModules.contains($0) }
        guard !missing.isEmpty else { return }
        installedModules = ModuleKind.allCases.filter { installedModules.contains($0) || missing.contains($0) }
        saveState()
        AppLog.info("Modules installed: \(missing.map(\.rawValue).joined(separator: ", "))")
    }

    private func saveState() {
        guard !readOnly else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let state = State(order: modes.map(\.id), enabled: enabledIDs, current: currentID, installed: installedModules.map(\.rawValue),
                          off: switchedOff.isEmpty ? nil : switchedOff.map(\.rawValue))
        AppLog.attempt("Profile state not saved") {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(state).write(to: directory.appending(path: "state.json"), options: .atomic)
        }
    }

    private func saveAll() {
        modes.forEach(save)
        saveState()
    }
}

extension ProjectSource {
    var isReport: Bool {
        if case .gitReport = self { return true }
        return false
    }
}
