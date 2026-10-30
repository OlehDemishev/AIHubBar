import AppKit
import Foundation
import Observation

/// A command from the «Быстрые команды» library (SPEC-profiles §4.3). Stored in UserDefaults.
struct QuickCommand: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// A shell command in the background; the result arrives as a notification.
        case script
        /// A shell command typed into a new Terminal window.
        case terminal
        /// A shortcut from the Shortcuts app, by name.
        case shortcut
        /// A link, file, folder or app.
        case open

        var title: String {
            switch self {
            case .script: String(localized: "Скрипт в фоне")
            case .terminal: String(localized: "Скрипт в Терминале")
            case .shortcut: String(localized: "Ярлык из «Команд»")
            case .open: String(localized: "Открыть ссылку, файл или папку")
            }
        }
    }

    /// What running a command does, worked out without running it.
    enum Invocation: Equatable, Sendable {
        case process(executable: String, arguments: [String])
        case terminal(String)
        case open(URL)
        case invalid
    }

    var id: String = UUID().uuidString.lowercased()
    var title: String
    var symbol: String = "bolt"
    var kind: Kind
    var value: String
    /// Ask «Запустить?» first.
    var confirm = false

    var invocation: Invocation {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .invalid }
        switch kind {
        case .script: return .process(executable: "/bin/zsh", arguments: ["-lc", value])
        case .terminal: return .terminal(value)
        case .shortcut: return .process(executable: "/usr/bin/shortcuts", arguments: ["run", value])
        case .open:
            if value.contains("://"), let url = URL(string: value) { return .open(url) }
            return .open(URL(fileURLWithPath: PathText.expand(value)))
        }
    }

    /// A starting library: harmless examples to edit or delete.
    static let examples = [
        QuickCommand(title: String(localized: "Загрузки"), symbol: "arrow.down.circle", kind: .open, value: "~/Downloads"),
        QuickCommand(title: String(localized: "Мой IP в сети"), symbol: "network", kind: .script, value: "ipconfig getifaddr en0 || ipconfig getifaddr en1"),
    ]
}

/// One of the «Быстрые переключатели» (SPEC-profiles §4.4). Each runs only when the person clicks it.
enum QuickToggle: String, Codable, CaseIterable, Sendable {
    case darkMode, desktopIcons, lockScreen, displaySleep, ejectDisks, emptyTrash

    /// Under the tile in the panel; the full title is its hover hint.
    var shortTitle: String {
        switch self {
        case .darkMode: String(localized: "Тема")
        case .desktopIcons: String(localized: "Значки")
        case .lockScreen: String(localized: "Замок")
        case .displaySleep: String(localized: "Экран")
        case .ejectDisks: String(localized: "Диски")
        case .emptyTrash: String(localized: "Корзина")
        }
    }

    var title: String {
        switch self {
        case .darkMode: String(localized: "Тёмная тема")
        case .desktopIcons: String(localized: "Значки на рабочем столе")
        case .lockScreen: String(localized: "Заблокировать экран")
        case .displaySleep: String(localized: "Погасить экран")
        case .ejectDisks: String(localized: "Извлечь диски")
        case .emptyTrash: String(localized: "Очистить корзину")
        }
    }

    var symbol: String {
        switch self {
        case .darkMode: "circle.lefthalf.filled"
        case .desktopIcons: "menubar.dock.rectangle"
        case .lockScreen: "lock"
        case .displaySleep: "display"
        case .ejectDisks: "eject"
        case .emptyTrash: "trash"
        }
    }

    /// Can't be undone: asked first.
    var needsConfirmation: Bool { self == .emptyTrash }
}

/// Runs quick commands and toggles, one at a time each, and keeps the last result to show.
@MainActor
@Observable
final class QuickToolsController {
    struct Result: Equatable {
        var text: String
        var isError: Bool
    }

    private(set) var running: Set<String> = []
    private(set) var results: [String: Result] = [:]
    /// Toggle states that can be read: dark mode, desktop icons.
    private(set) var darkMode = false
    private(set) var desktopIconsShown = true

    func refreshStates() {
        darkMode = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String == "Dark"
        desktopIconsShown = UserDefaults(suiteName: "com.apple.finder")?.object(forKey: "CreateDesktop") as? Bool ?? true
    }

    func isOn(_ toggle: QuickToggle) -> Bool? {
        switch toggle {
        case .darkMode: darkMode
        case .desktopIcons: desktopIconsShown
        default: nil
        }
    }

    func run(_ command: QuickCommand) {
        guard !running.contains(command.id) else { return }
        let invocation = command.invocation
        switch invocation {
        case .invalid:
            results[command.id] = Result(text: String(localized: "Команда пустая — заполните её в Настройках → «Модули»."), isError: true)
        case let .open(url):
            let opened = NSWorkspace.shared.open(url)
            results[command.id] = opened ? nil : Result(text: String(localized: "Не открылось: \(url.isFileURL ? url.path : url.absoluteString)"), isError: true)
        case let .terminal(line):
            running.insert(command.id)
            Task {
                defer { running.remove(command.id) }
                do {
                    try await TerminalLauncher.run(line)
                    results[command.id] = nil
                } catch {
                    results[command.id] = Result(text: error.localizedDescription, isError: true)
                }
            }
        case let .process(executable, arguments):
            running.insert(command.id)
            Task {
                defer { running.remove(command.id) }
                let home = FileManager.default.homeDirectoryForCurrentUser
                let result = try? await ProcessRunner.run(executable, arguments, currentDirectory: home, timeout: .seconds(600))
                let output = Self.summary(stdout: result?.stdoutText ?? "", stderr: result.map { String(decoding: $0.stderr, as: UTF8.self) } ?? "")
                let failed = result?.exitCode != 0
                let text = failed ? String(localized: "Ошибка (код \(result.map { Int($0.exitCode) } ?? -1))") + (output.isEmpty ? "" : ": \(output)")
                    : (output.isEmpty ? String(localized: "Готово") : output)
                results[command.id] = Result(text: text, isError: failed)
                Notifier.post(id: "quick-\(command.id)", title: command.title, body: text)
                AppLog.info("Quick command «\(command.title)»: exit \(result.map { "\($0.exitCode)" } ?? "none")")
            }
        }
    }

    /// The last non-empty line of the output, short enough for a notification.
    nonisolated static func summary(stdout: String, stderr: String) -> String {
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stderr : stdout
        let line = text.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > 140 ? String(line.prefix(139)) + "…" : line
    }

    func perform(_ toggle: QuickToggle) {
        guard !running.contains(toggle.rawValue) else { return }
        running.insert(toggle.rawValue)
        Task {
            defer {
                running.remove(toggle.rawValue)
                refreshStates()
            }
            let error: String?
            switch toggle {
            case .darkMode:
                error = await Self.osascript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
            case .desktopIcons:
                refreshStates()
                let show = !desktopIconsShown
                _ = try? await ProcessRunner.run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", show ? "true" : "false"], timeout: .seconds(10))
                _ = try? await ProcessRunner.run("/usr/bin/killall", ["Finder"], timeout: .seconds(10))
                error = nil
            case .lockScreen:
                error = Self.lockScreen() ? nil : await Self.displaySleep()
            case .displaySleep:
                error = await Self.displaySleep()
            case .ejectDisks:
                let ejected = Self.ejectDisks()
                error = nil
                results[toggle.rawValue] = Result(text: ejected == 0 ? String(localized: "Нечего извлекать") : String(localized: "Извлечено дисков: \(ejected)"), isError: false)
            case .emptyTrash:
                error = await Self.osascript("tell application \"Finder\" to empty trash")
            }
            if let error {
                results[toggle.rawValue] = Result(text: error, isError: true)
            } else if toggle != .ejectDisks {
                results[toggle.rawValue] = nil
            }
        }
    }

    /// The first run asks for the Automation permission (System Events, Finder).
    private static func osascript(_ line: String) async -> String? {
        guard let result = try? await ProcessRunner.run("/usr/bin/osascript", ["-e", line], timeout: .seconds(60)) else {
            return String(localized: "Не удалось выполнить")
        }
        guard result.exitCode != 0 else { return nil }
        let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.contains("-1743") ? String(localized: "Нет разрешения: Системные настройки → Конфиденциальность → Автоматизация → ClaudePult") : message
    }

    private static func displaySleep() async -> String? {
        let result = try? await ProcessRunner.run("/usr/bin/pmset", ["displaysleepnow"], timeout: .seconds(10))
        return result?.exitCode == 0 ? nil : String(localized: "Не удалось погасить экран")
    }

    /// The system's own «Заблокировать экран» (the one in the Apple menu), from the login framework.
    private static func lockScreen() -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias Lock = @convention(c) () -> Int32
        _ = unsafeBitCast(symbol, to: Lock.self)()
        return true
    }

    /// External and removable volumes, ejected the way Finder does it.
    private static func ejectDisks() -> Int {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var ejected = 0
        for volume in volumes where volume.path != "/" {
            guard let values = try? volume.resourceValues(forKeys: Set(keys)),
                  values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsInternal == false else { continue }
            if (try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)) != nil { ejected += 1 }
        }
        return ejected
    }
}
