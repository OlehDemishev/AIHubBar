import Foundation

enum HookInstallError: LocalizedError {
    case unreadableSettings(String)

    var errorDescription: String? {
        switch self {
        case let .unreadableSettings(detail):
            String(localized: "Не удалось прочитать ~/.claude/settings.json (\(detail)). Файл не изменён.")
        }
    }
}

enum HookStatus: Equatable, Sendable {
    case notInstalled
    case installed
    /// Some events are missing or point to an old command — «Обновить hooks» fixes it.
    case outdated

    var title: String {
        switch self {
        case .notInstalled: String(localized: "не установлены")
        case .installed: String(localized: "установлены")
        case .outdated: String(localized: "нужно обновить")
        }
    }
}

/// Installs the ClaudePult hook into the user-level Claude Code settings (docs/SPEC.md §2.3):
/// merges into the existing file, backs it up first, idempotent, and removable.
struct HookInstaller {
    /// Events the hook listens to (code.claude.com/docs/en/hooks). PermissionRequest fires as soon as Claude asks;
    /// Notification `permission_prompt` only after ~6 s without typing. PostToolUse marks a session running again
    /// after a permission was granted. Only PostToolUse gets a matcher ("*"); the hook filters the rest itself.
    static let events = [
        "SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification",
        "PostToolUse", "Stop", "StopFailure", "SessionEnd",
    ]
    /// Recognises our entries regardless of path or arguments.
    static let marker = "claudepult-hook"
    static let timeoutSeconds = 5

    var settingsURL: URL
    var scriptURL: URL
    var projectsDirectory: String

    static func live(projectsDirectory: String) -> HookInstaller {
        HookInstaller(
            settingsURL: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json"),
            scriptURL: SessionFiles.hookScriptURL,
            projectsDirectory: projectsDirectory
        )
    }

    /// Shell command stored in settings.json; paths are single-quoted because Application Support has a space.
    var command: String {
        "\(Self.singleQuote(scriptURL.path)) --projects-dir \(Self.singleQuote(projectsDirectory))"
    }

    // MARK: - Status

    func status() -> HookStatus {
        guard let settings = try? readSettings() else { return .notInstalled }
        let status = Self.status(of: settings, expectedCommand: command)
        return status == .installed && !scriptIsCurrent ? .outdated : status
    }

    private var scriptIsCurrent: Bool {
        (try? String(contentsOf: scriptURL, encoding: .utf8)) == HookScript.source
    }

    static func status(of settings: [String: Any], expectedCommand: String) -> HookStatus {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        var found = 0, current = 0
        for event in events {
            let commands = ourCommands(in: hooks[event])
            if !commands.isEmpty { found += 1 }
            if commands == [expectedCommand] { current += 1 }
        }
        if found == 0 { return .notInstalled }
        return current == events.count ? .installed : .outdated
    }

    // MARK: - Install / remove

    /// Writes the hook script, backs up settings.json and merges our entries into it.
    /// Returns the backup URL (nil when there was no settings file yet).
    @discardableResult
    func install() throws -> URL? {
        try HookScript.write(to: scriptURL)
        let current = try readSettings()
        let settings = Self.merged(current ?? [:], command: command)
        if let current, NSDictionary(dictionary: current).isEqual(to: settings) { return nil }
        let backup = try backupSettings()
        try writeSettings(settings)
        AppLog.info("Hooks installed into \(settingsURL.path)" + (backup.map { ", backup \($0.lastPathComponent)" } ?? ""))
        return backup
    }

    @discardableResult
    func uninstall() throws -> URL? {
        guard let current = try readSettings() else { return nil }
        let settings = Self.removed(current)
        if NSDictionary(dictionary: current).isEqual(to: settings) {
            try? FileManager.default.removeItem(at: scriptURL)
            return nil
        }
        let backup = try backupSettings()
        try writeSettings(settings)
        try? FileManager.default.removeItem(at: scriptURL)
        AppLog.info("Hooks removed from \(settingsURL.path)" + (backup.map { ", backup \($0.lastPathComponent)" } ?? ""))
        return backup
    }

    /// Pure merge: drops previous ClaudePult entries, then appends one group per event. Other hooks stay untouched.
    static func merged(_ settings: [String: Any], command: String) -> [String: Any] {
        var settings = removed(settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [Any] ?? []
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": command, "timeout": timeoutSeconds]],
            ]
            if event == "PostToolUse" { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    /// Pure removal of ClaudePult entries; empty groups, events and the `hooks` key itself are dropped.
    static func removed(_ settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let kept: [Any] = groups.compactMap { item in
                guard var group = item as? [String: Any], let entries = group["hooks"] as? [Any] else { return item }
                let remaining = entries.filter { !isOurs($0) }
                if remaining.count == entries.count { return item }
                if remaining.isEmpty { return nil }
                group["hooks"] = remaining
                return group
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    private static func isOurs(_ entry: Any) -> Bool {
        ((entry as? [String: Any])?["command"] as? String)?.contains(marker) == true
    }

    private static func ourCommands(in value: Any?) -> [String] {
        (value as? [Any] ?? []).flatMap { group -> [String] in
            ((group as? [String: Any])?["hooks"] as? [Any] ?? []).compactMap { entry in
                guard isOurs(entry) else { return nil }
                return (entry as? [String: Any])?["command"] as? String
            }
        }
    }

    // MARK: - Files

    private func readSettings() throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HookInstallError.unreadableSettings(String(localized: "корень не объект JSON"))
            }
            return object
        } catch let error as HookInstallError {
            throw error
        } catch {
            throw HookInstallError.unreadableSettings(error.localizedDescription)
        }
    }

    private func backupSettings() throws -> URL? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        // Local time, never overwriting an earlier backup (two changes within a second get -2, -3, …).
        let stamp = Date.now.formatted(Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
            timeZone: .current, calendar: Calendar(identifier: .gregorian)
        ))
        let folder = settingsURL.deletingLastPathComponent()
        var backup = folder.appending(path: "settings.json.claudepult-backup-\(stamp)")
        var counter = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = folder.appending(path: "settings.json.claudepult-backup-\(stamp)-\(counter)")
            counter += 1
        }
        try FileManager.default.copyItem(at: settingsURL, to: backup)
        return backup
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: settingsURL, options: .atomic)
    }

    static func singleQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
