import AppKit

/// «Предложить идею» / «Сообщить о проблеме»: the repository's issue forms (.github/ISSUE_TEMPLATE) with the version
/// and macOS already filled in. Nothing is sent by the app itself — the person sees the whole form on GitHub first.
enum Feedback {
    static let repository = URL(string: "https://github.com/OlehDemishev/AIHubBar")!

    enum Template: String {
        case bug = "bug_report.yml"
        case idea = "feature_request.yml"
    }

    /// GitHub fills an issue form's fields from query items named by the fields' ids. Too long a link is refused
    /// (414), so callers keep long values short.
    static func issueURL(_ template: Template, title: String? = nil, fields: KeyValuePairs<String, String> = [:]) -> URL {
        var components = URLComponents(url: repository.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "template", value: template.rawValue)]
        if let title { items.append(URLQueryItem(name: "title", value: title)) }
        items += fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        return components.url!
    }

    /// «0.2.2 (345)», as in Settings → General.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// «macOS 27.2, Apple Silicon», the bug form's placeholder format.
    static var system: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let chip = "Apple Silicon"
        #else
        let chip = "Intel"
        #endif
        return "macOS \(version.majorVersion).\(version.minorVersion), \(chip)"
    }

    @MainActor static func suggestIdea() {
        NSWorkspace.shared.open(issueURL(.idea))
    }

    @MainActor static func reportProblem() {
        NSWorkspace.shared.open(issueURL(.bug, fields: ["version": appVersion, "macos": system]))
    }

    /// The home folder and the account name out of anything that goes into an issue.
    static func redacted(_ text: String, home: String = NSHomeDirectory(), user: String = NSUserName()) -> String {
        var text = text.replacingOccurrences(of: home, with: "~")
        if !user.isEmpty { text = text.replacingOccurrences(of: "/Users/\(user)", with: "/Users/USER") }
        return text
    }
}

/// A crash of AI Hub Bar as macOS wrote it: `~/Library/Logs/DiagnosticReports/AIHubBar-<date>.ips` — a JSON header
/// line, then the JSON report. The app is not sandboxed, so it can read them.
struct CrashReport: Equatable, Sendable {
    var file: URL
    var date: Date
    var appVersion: String
    var system: String
    /// «EXC_BAD_ACCESS (SIGSEGV)».
    var exception: String
    /// Swift's «Fatal error: …» and similar, when the report kept it.
    var message: String?
    /// The crashed thread's top frames, «AIHubBar  ProjectStore.refresh() + 120».
    var frames: [String]

    static let frameCount = 8

    /// nil for another app's report, an unreadable one, and crashes of the unit tests (they run inside the app).
    static func parse(_ text: String, file: URL, date: Date, bundleID: String) -> CrashReport? {
        guard let newline = text.firstIndex(of: "\n"),
              let header = try? JSONSerialization.jsonObject(with: Data(text[..<newline].utf8)) as? [String: Any],
              header["bundleID"] as? String == bundleID,
              let body = try? JSONSerialization.jsonObject(with: Data(text[newline...].utf8)) as? [String: Any]
        else { return nil }
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
        if images.contains(where: { $0.hasSuffix("Tests") || $0.hasSuffix(".xctest") || $0 == "xctest" }) { return nil }

        let exception = body["exception"] as? [String: Any]
        let type = exception?["type"] as? String ?? (body["termination"] as? [String: Any])?["indicator"] as? String ?? "?"
        let signal = exception?["signal"] as? String
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
        let frames = (threads.indices.contains(faulting) ? threads[faulting]["frames"] as? [[String: Any]] ?? [] : [])
            .prefix(frameCount)
            .map { frame -> String in
                let index = frame["imageIndex"] as? Int ?? -1
                let image = images.indices.contains(index) ? images[index] : "?"
                if let symbol = frame["symbol"] as? String {
                    return "\(image)  \(symbol) + \(frame["symbolLocation"] as? Int ?? 0)"
                }
                return "\(image)  + \(frame["imageOffset"] as? Int ?? 0)"
            }
        // `asi` («application specific information») holds Swift's fatal-error text by library.
        let message = (body["asi"] as? [String: [String]])?.values.flatMap { $0 }.first

        let version = header["app_version"] as? String ?? "?"
        let build = header["build_version"] as? String ?? "?"
        return CrashReport(
            file: file, date: date, appVersion: "\(version) (\(build))",
            system: header["os_version"] as? String ?? "?",
            exception: signal.map { "\(type) (\($0))" } ?? type,
            message: message, frames: frames
        )
    }

    /// The issue title: the exception and the first frame of the app itself (or the top frame).
    var title: String {
        guard let frame = frames.first(where: { $0.hasPrefix("AIHubBar ") || $0.hasPrefix("ClaudePult ") }) ?? frames.first
        else { return "Crash: \(exception)" }
        let place = frame.replacingOccurrences(of: "  ", with: " ")
        return "Crash: \(exception) in \(place.count > 90 ? String(place.prefix(90)) + "…" : place)"
    }

    /// The «What happened» field: a line for the person to fill, then the crash in short.
    var summary: String {
        var lines = ["AI Hub Bar crashed on \(date.ISO8601Format(.iso8601(timeZone: .current))).",
                     "", "What I was doing: ", "", "```", exception]
        if let message { lines.append(message) }
        lines += frames
        lines.append("```")
        return lines.joined(separator: "\n")
    }
}

@MainActor
enum CrashReports {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
    /// The executable was AI Hub Bar before the rename; those reports are still ours.
    nonisolated static let prefixes = ["AIHubBar-", "ClaudePult-"]
    private static let checkedKey = "crashReportsCheckedAt"
    static let askKey = "askAfterCrash"

    /// Off with «Больше не предлагать» in the alert; back on in Settings → General.
    static var asksAfterCrash: Bool {
        get { UserDefaults.standard.object(forKey: askKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: askKey) }
    }

    /// Our reports written after `since`, newest first.
    nonisolated static func reports(in directory: URL, since: Date, bundleID: String) -> [CrashReport] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files.compactMap { file -> CrashReport? in
            guard file.pathExtension == "ips", prefixes.contains(where: file.lastPathComponent.hasPrefix),
                  let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  date > since,
                  let text = try? String(contentsOf: file, encoding: .utf8)
            else { return nil }
            return CrashReport.parse(text, file: file, date: date, bundleID: bundleID)
        }
        .sorted { $0.date > $1.date }
    }

    /// At launch: a crash since the last check (the first check looks one day back) → offer to report it.
    static func checkAtLaunch() {
        let defaults = UserDefaults.standard
        let since = (defaults.object(forKey: checkedKey) as? Date) ?? .now.addingTimeInterval(-86_400)
        defaults.set(Date.now, forKey: checkedKey)
        guard asksAfterCrash, let bundleID = Bundle.main.bundleIdentifier else { return }
        Task {
            let directory = directory
            let found = await Task.detached { reports(in: directory, since: since, bundleID: bundleID) }.value
            guard let report = found.first else { return }
            AppLog.info("Crash report found: \(report.file.lastPathComponent) (\(found.count) since the last check)")
            ask(report)
        }
    }

    private static func ask(_ report: CrashReport) {
        let alert = NSAlert()
        alert.messageText = String(localized: "В прошлый раз AI Hub Bar закрылся с ошибкой")
        alert.informativeText = String(localized: "Сбой \(report.date.formatted(date: .abbreviated, time: .shortened)). Можно сообщить о нём на GitHub: откроется форма с описанием сбоя, версией и macOS — перед отправкой видно всё, что уходит. Полный отчёт появится в Finder, его можно перетащить в форму.")
        alert.addButton(withTitle: String(localized: "Сообщить на GitHub…"))
        alert.addButton(withTitle: String(localized: "Не сейчас"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Больше не предлагать")
        NSApp.activate()
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { asksAfterCrash = false }
        if response == .alertFirstButtonReturn { send(report) }
    }

    /// Opens the bug form filled from the report, and shows a copy of the full report (home folder removed) to attach.
    static func send(_ report: CrashReport) {
        if let text = try? String(contentsOf: report.file, encoding: .utf8) {
            let copy = AppLog.directory.appending(path: report.file.deletingPathExtension().lastPathComponent + ".txt")
            do {
                try FileManager.default.createDirectory(at: AppLog.directory, withIntermediateDirectories: true)
                try Feedback.redacted(text).write(to: copy, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([copy])
            } catch {
                AppLog.error("Crash report copy failed: \(error.localizedDescription)")
            }
        }
        NSWorkspace.shared.open(issueURL(report, log: Feedback.redacted(recentLog())))
    }

    /// GitHub refuses links much over 8 KB; the log loses its oldest lines until the link fits.
    nonisolated static let maxURLLength = 7_500

    nonisolated static func issueURL(_ report: CrashReport, log: String) -> URL {
        var log = log
        while true {
            let url = Feedback.issueURL(.bug, title: report.title, fields: [
                "what": Feedback.redacted(report.summary),
                "version": report.appVersion,
                "macos": Feedback.system,
                "area": "Something else",
                "log": log,
            ])
            guard url.absoluteString.count > maxURLLength, !log.isEmpty else { return url }
            log = log.firstIndex(of: "\n").map { String(log[log.index(after: $0)...]) } ?? ""
        }
    }

    /// The log's last lines before the crash, kept short enough for the link.
    private static func recentLog(lines: Int = 25, characters: Int = 2_000) -> String {
        AppLog.flush()
        guard let text = try? String(contentsOf: AppLog.fileURL, encoding: .utf8) else { return "" }
        let tail = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
        return tail.count > characters ? String(tail.suffix(characters)) : tail
    }
}
