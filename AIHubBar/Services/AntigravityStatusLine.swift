import Foundation

/// Antigravity's quota and plan without anyone's sign-in: `agy` passes them to a custom status line command
/// (`statusLine` in `~/.gemini/antigravity-cli/settings.json`, the same as its `/statusline <command>`), so AI Hub
/// Bar's command only keeps that JSON in a file and prints nothing; `stack_with_default` leaves Antigravity's own
/// line on screen. Checked live with agy 1.5.5 on the free plan, 2026-11-11. The other ways were ruled out the same
/// day: the Code Assist address answers only to a client that calls itself Antigravity, and print mode (`-p`) starts
/// no status line. A status line the person set up themselves is never replaced.
struct AntigravityStatusLine {
    var settingsURL: URL
    var scriptURL: URL

    static let script = """
    #!/bin/sh
    # AI Hub Bar: keeps what Antigravity passes to its status line (quota, plan). Prints nothing.
    umask 077
    out="$(dirname "$0")/antigravity-status.json"
    cat > "$out.$$" && mv -f "$out.$$" "$out"

    """

    static var live: AntigravityStatusLine {
        AntigravityStatusLine(
            settingsURL: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".gemini/antigravity-cli/settings.json"),
            scriptURL: SessionFiles.supportDirectory.appending(path: "antigravity-statusline.sh")
        )
    }

    /// What the script keeps, next to it.
    var statusURL: URL { scriptURL.deletingLastPathComponent().appending(path: "antigravity-status.json") }

    var command: String { HookInstaller.singleQuote(scriptURL.path) }

    private var entry: [String: Any] { ["type": "command", "command": command, "stack_with_default": true] }

    private var file: HookJSONFile { HookJSONFile(url: settingsURL, shownAs: "~/.gemini/antigravity-cli/settings.json") }

    private var scriptIsCurrent: Bool { (try? String(contentsOf: scriptURL, encoding: .utf8)) == Self.script }

    private func isOurs(_ settings: [String: Any]) -> Bool {
        (settings["statusLine"] as? [String: Any])?["command"] as? String == command
    }

    func status() -> HookStatus {
        guard let settings = try? file.read(), isOurs(settings) else { return .notInstalled }
        let same = NSDictionary(dictionary: settings["statusLine"] as? [String: Any] ?? [:]).isEqual(to: entry)
        return same && scriptIsCurrent ? .installed : .outdated
    }

    /// Writes the script and adds `statusLine`; returns the backup of the settings (nil when there was no file).
    @discardableResult
    func install() throws -> URL? {
        var settings = try file.read() ?? [:]
        if settings["statusLine"] != nil, !isOurs(settings) { throw Failure.ownStatusLine }
        try writeScript()
        if NSDictionary(dictionary: settings["statusLine"] as? [String: Any] ?? [:]).isEqual(to: entry) { return nil }
        settings["statusLine"] = entry
        let backup = try file.backup()
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.write(settings)
        AppLog.info("Antigravity status line installed into \(settingsURL.path)" + (backup.map { ", backup \($0.lastPathComponent)" } ?? ""))
        return backup
    }

    /// Takes our `statusLine` out and removes what was kept; a settings file left empty is removed (AI Hub Bar made it).
    @discardableResult
    func uninstall() throws -> URL? {
        try? FileManager.default.removeItem(at: statusURL)
        guard var settings = try file.read(), isOurs(settings) else { return nil }
        settings["statusLine"] = nil
        let backup = try file.backup()
        if settings.isEmpty {
            try FileManager.default.removeItem(at: settingsURL)
        } else {
            try file.write(settings)
        }
        return backup
    }

    /// While our line is set, keeps the script this version ships.
    @discardableResult
    func updateScriptIfNeeded() throws -> Bool {
        guard status() == .outdated, let settings = try? file.read(), isOurs(settings),
              NSDictionary(dictionary: settings["statusLine"] as? [String: Any] ?? [:]).isEqual(to: entry) else { return false }
        try writeScript()
        return true
    }

    private func writeScript() throws {
        try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    enum Failure: LocalizedError {
        case ownStatusLine

        var errorDescription: String? {
            String(localized: "В Antigravity уже настроена своя строка состояния — AI Hub Bar её не заменяет.")
        }
    }

    // MARK: Reading what was kept

    /// How long the kept status counts as current: Antigravity runs the command while it is open.
    static let fresh: TimeInterval = 10 * 60

    /// The limit for the panel: the windows whose reset is still ahead, the plan as a note, and the time of the data
    /// once Antigravity has been closed for a while.
    func limit(now: Date = .now) -> HubLimit {
        guard let data = try? Data(contentsOf: statusURL), let at = HubFetch.modified(statusURL),
              let status = HubParse.antigravityStatus(data, now: now) else {
            return HubLimit(source: .antigravity, windows: [], error: String(localized: "откройте Antigravity (agy), чтобы увидеть квоту"))
        }
        var limit = HubLimit(source: .antigravity, windows: status.windows)
        limit.notes = status.plan.map { [ServiceNote(text: String(localized: "План: \($0)"), symbol: "person.crop.circle")] } ?? []
        if now.timeIntervalSince(at) > Self.fresh {
            let time = Calendar.current.isDate(at, inSameDayAs: now) ? at.formatted(date: .omitted, time: .shortened)
                : at.formatted(date: .abbreviated, time: .shortened)
            limit.error = String(localized: "данные на \(time) — обновятся, когда открыт Antigravity")
        }
        return limit
    }
}

extension HubParse {
    // Antigravity's status line JSON: quota{} — a bucket per model family and period («gemini-weekly», «3p-weekly»)
    // with remaining_fraction (left out when nothing is left), reset_time; plan_tier.
    static func antigravityStatus(_ data: Data, now: Date = .now) -> (windows: [HubLimit.Window], plan: String?)? {
        guard let object = object(data), let quota = object["quota"] as? [String: Any] else { return nil }
        // Gemini first, then the rest by name: the first two are the rings.
        let names = quota.keys.sorted { ($0.hasPrefix("gemini") ? 0 : 1, $0) < ($1.hasPrefix("gemini") ? 0 : 1, $1) }
        let windows = names.compactMap { name -> HubLimit.Window? in
            guard let bucket = quota[name] as? [String: Any] else { return nil }
            var reset = date(bucket["reset_time"])
            if reset == nil, let seconds = number(bucket["reset_in_seconds"]) { reset = now.addingTimeInterval(seconds) }
            if let reset, reset <= now { return nil }
            let left = min(max(number(bucket["remaining_fraction"]) ?? 0, 0), 1)
            return HubLimit.Window(title: antigravityTitle(name), percent: (1 - left) * 100, resetsAt: reset)
        }
        guard !windows.isEmpty else { return nil }
        return (windows, (object["plan_tier"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// «gemini-weekly» → «Gemini», «3p-weekly» → «другие модели», «gemini-5h» → «Gemini · 5h»: a week is the usual
    /// period and the reset is shown anyway.
    static func antigravityTitle(_ bucket: String) -> String {
        var parts = bucket.split(separator: "-").map(String.init)
        let period = parts.count > 1 ? parts.removeLast() : nil
        let family = parts.joined(separator: "-")
        let name = switch family {
        case "gemini": "Gemini"
        case "3p": String(localized: "другие модели")
        default: family
        }
        guard let period, period != "weekly" else { return name }
        return "\(name) · \(period)"
    }
}
