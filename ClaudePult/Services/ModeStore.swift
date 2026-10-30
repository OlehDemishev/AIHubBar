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
    var modes: [Mode]
    var enabled: [String]?
    var current: String?
}

/// Modes: storage, the active one, enabling and ordering, export and import.
/// The active mode is *applied* to `AppSettings` (projects folder, `_daily-report`, launch mode, project and
/// command blocks), so the rest of the app keeps reading `AppSettings` as before.
@MainActor
@Observable
final class ModeStore {
    private(set) var modes: [Mode] = []
    private(set) var enabledIDs: [String] = []
    private(set) var currentID: String = ""
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
    }

    static var defaultDirectory: URL { SessionFiles.supportDirectory.appending(path: "modes", directoryHint: .isDirectory) }

    init(settings: AppSettings, directory: URL = ModeStore.defaultDirectory) {
        self.settings = settings
        self.directory = directory
        load()
    }

    var current: Mode? { modes.first { $0.id == currentID } }
    var enabledModes: [Mode] { modes.filter { enabledIDs.contains($0.id) } }

    // MARK: - Loading and migration

    private func load() {
        let decoder = Self.decoder
        var loaded: [Mode] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" && url.lastPathComponent != "state.json" {
            if let data = try? Data(contentsOf: url), let mode = try? decoder.decode(Mode.self, from: data) {
                loaded.append(mode)
            }
        }
        let state = (try? Data(contentsOf: directory.appending(path: "state.json"))).flatMap { try? decoder.decode(State.self, from: $0) }

        if loaded.isEmpty {
            // First start with modes: the settings ClaudePult had so far become the first mode, unchanged.
            let mode = Self.migrated(from: settings)
            modes = [mode]
            enabledIDs = [mode.id]
            currentID = mode.id
            saveAll()
            AppLog.info("Modes: created «\(mode.name)» from the existing settings")
        } else {
            let order = state?.order ?? []
            modes = loaded.sorted { (order.firstIndex(of: $0.id) ?? Int.max, $0.name) < (order.firstIndex(of: $1.id) ?? Int.max, $1.name) }
            enabledIDs = (state?.enabled ?? modes.map(\.id)).filter { id in modes.contains { $0.id == id } }
            if enabledIDs.isEmpty, let first = modes.first { enabledIDs = [first.id] }
            let saved = state.map(\.current).flatMap { enabledIDs.contains($0) ? $0 : nil }
            currentID = saved ?? enabledIDs.first ?? ""
        }
        if let current { apply(current) }
    }

    /// The pre-modes settings as a mode. With `_daily-report` present it is the report.py developer setup.
    static func migrated(from settings: AppSettings) -> Mode {
        return Mode.developerWithReport(
            projectsDirectory: settings.projectsDirectory,
            dailyReportDirectory: settings.dailyReportDirectory,
            launchMode: settings.defaultLaunchMode,
            showProjects: settings.shows(.projects),
            showCommonCommands: settings.shows(.commands)
        )
    }

    // MARK: - Applying

    /// Pushes the mode's blocks into `AppSettings`, which the rest of the app reads.
    private func apply(_ mode: Mode) {
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
        // Projects come only from report.py until the other sources arrive (SPEC-modes §9, stages 4 and 6).
        settings.setShows(.projects, mode.showProjects && mode.source.isReport)
        settings.setShows(.commands, mode.showCommonCommands && mode.commonCommands == .dailyReport)
        didApply?()
    }

    func select(_ id: String) {
        guard id != currentID, let mode = modes.first(where: { $0.id == id }) else { return }
        if !enabledIDs.contains(id) { enabledIDs.append(id) }
        currentID = id
        saveState()
        apply(mode)
        AppLog.info("Mode switched to «\(mode.name)»")
    }

    /// Saves edits from Settings → Режимы; the active mode is applied at once.
    func update(_ mode: Mode) {
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
    func duplicate(_ id: String) -> Mode? {
        guard let original = modes.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID().uuidString.lowercased()
        copy.name = uniqueName(original.name + " (копия)")
        modes.insert(copy, at: (modes.firstIndex { $0.id == id } ?? modes.count - 1) + 1)
        save(copy)
        saveState()
        return copy
    }

    func delete(_ id: String) {
        guard modes.count > 1 else { return }
        modes.removeAll { $0.id == id }
        enabledIDs.removeAll { $0 == id }
        if enabledIDs.isEmpty, let first = modes.first { enabledIDs = [first.id] }
        try? FileManager.default.removeItem(at: fileURL(id))
        if currentID == id, let next = enabledModes.first {
            currentID = ""
            select(next.id)
        }
        saveState()
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
            format: SettingsBundle.settingsFormat, version: 1, exportedAt: .now,
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
                animations: settings.panelAnimations, showLimits: settings.shows(.limits),
                showSessions: settings.shows(.sessions), menuBar: settings.menuBarConfig.legacyMode.rawValue,
                menuBarConfig: settings.menuBarConfig
            ),
            services: settings.aiServices,
            modes: modes, enabled: enabledIDs, current: currentID
        )
    }

    func exportMode(_ id: String) -> SettingsBundle? {
        guard let mode = modes.first(where: { $0.id == id }) else { return nil }
        return SettingsBundle(format: SettingsBundle.modeFormat, version: 1, exportedAt: .now, modes: [mode])
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
            saveAll()
            if let current { apply(current) }
            lastMessage = "Настройки импортированы: \(modes.count) режим(ов)."
        case .replace, .add:
            for var mode in bundle.modes {
                mode.id = UUID().uuidString.lowercased()
                mode.name = uniqueName(mode.name)
                modes.append(mode)
                enabledIDs.append(mode.id)
                save(mode)
            }
            saveState()
            lastMessage = "Добавлено режимов: \(bundle.modes.count)."
        }
        pendingImport = nil
        AppLog.info("Settings import (\(style == .replace ? "replace" : "add")): \(bundle.modes.count) mode(s)")
    }

    /// A `*.claudepult` file opened from Finder or the command line.
    func prepareImport(from url: URL) {
        guard let data = try? Data(contentsOf: url), let bundle = Self.decodeBundle(data) else {
            lastMessage = "Не удалось прочитать «\(url.lastPathComponent)»: это не файл настроек ClaudePult."
            return
        }
        pendingImport = (url, bundle)
    }

    func cancelImport() { pendingImport = nil }

    /// Folders of a mode that do not exist on this Mac (after an import from another one).
    static func missingFolders(_ mode: Mode) -> [String] {
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

    private func save(_ mode: Mode) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoder.encode(mode).write(to: fileURL(mode.id), options: .atomic)
    }

    private func saveState() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = State(order: modes.map(\.id), enabled: enabledIDs, current: currentID)
        try? encoder.encode(state).write(to: directory.appending(path: "state.json"), options: .atomic)
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
