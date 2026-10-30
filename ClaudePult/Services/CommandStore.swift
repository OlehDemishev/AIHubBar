import AppKit
import Observation

/// Common commands from docs/SPEC.md §2.5, run through the `_daily-report` tools.
enum CommonCommand: String, CaseIterable, Identifiable, Sendable {
    case reportNow, quickSummary, openLatestReport, cleanupCheck, cleanupRun

    var id: String { rawValue }

    /// Period for the Telegram reports started from the panel (does not move report.py's own "since last run").
    static let reportHours = 24

    /// Name for `ClaudePult --command <name>`.
    var cliName: String {
        switch self {
        case .reportNow: "report"
        case .quickSummary: "summary"
        case .openLatestReport: "open-report"
        case .cleanupCheck: "cleanup-check"
        case .cleanupRun: "cleanup"
        }
    }

    var title: String {
        switch self {
        case .reportNow: "Отчёт сейчас"
        case .quickSummary: "Быстрая сводка"
        case .openLatestReport: "Последний отчёт"
        case .cleanupCheck: "Очистка: проверить"
        case .cleanupRun: "Очистка: выполнить"
        }
    }

    var systemImage: String {
        switch self {
        case .reportNow: "sparkles.rectangle.stack"
        case .quickSummary: "paperplane"
        case .openLatestReport: "doc.richtext"
        case .cleanupCheck: "magnifyingglass"
        case .cleanupRun: "trash"
        }
    }

    var help: String {
        switch self {
        case .reportNow: "Полный отчёт с AI-резюме за \(Self.reportHours) ч в Telegram (1–3 мин)"
        case .quickSummary: "Сводка без AI за \(Self.reportHours) ч в Telegram"
        case .openLatestReport: "Открыть reports/latest.html"
        case .cleanupCheck: "Показать, что удалит очистка сборок (cleanup.py --dry-run)"
        case .cleanupRun: "Удалить сборки, кэши и сбросить симуляторы (cleanup.py --now)"
        }
    }

    /// `python3 <script> <args>` relative to the `_daily-report` folder; nil for commands that only open a file.
    var script: (name: String, arguments: [String], timeout: Duration)? {
        let hours = String(Self.reportHours)
        switch self {
        case .reportNow: return ("report.py", ["--since-hours", hours, "--no-open"], .seconds(600))
        case .quickSummary: return ("report.py", ["--no-ai", "--no-document", "--no-open", "--since-hours", hours], .seconds(180))
        case .cleanupCheck: return ("cleanup.py", ["--dry-run"], .seconds(300))
        case .cleanupRun: return ("cleanup.py", ["--now"], .seconds(900))
        case .openLatestReport: return nil
        }
    }

    /// The line worth showing from the tool's output: cleanup puts its total first, report.py its outcome last.
    func summary(of output: String) -> String? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        switch self {
        case .cleanupCheck, .cleanupRun:
            return lines.first
        case .reportNow, .quickSummary:
            // report.py prefixes its log lines with HH:MM:SS.
            return lines.last.map { $0.replacing(/^\d{2}:\d{2}:\d{2}\s+/, with: "") }
        case .openLatestReport:
            return nil
        }
    }

    /// report.py exits 0 even when Telegram failed; its last line is «Telegram: отправлено» only on success.
    /// A cleanup skipped because of a running build did nothing, so it is not shown as done.
    func isFailure(exitCode: Int32, summary: String) -> Bool {
        if exitCode != 0 { return true }
        switch self {
        case .reportNow, .quickSummary: return summary.hasPrefix("Telegram") && summary != "Telegram: отправлено"
        // cleanup.py skips everything while a build runs and says so in its first line.
        case .cleanupCheck, .cleanupRun: return summary.hasPrefix("Идёт сборка")
        default: return false
        }
    }

    /// Telegram bot tokens never reach the panel or the log, even if a tool prints a request URL.
    static func redactingTokens(_ text: String) -> String {
        text.replacing(/bot\d+:[A-Za-z0-9_-]+/, with: "bot<token>")
    }
}

/// Runs the common commands without blocking the panel; results go to the panel and a notification.
@MainActor
@Observable
final class CommandStore {
    struct Result: Equatable, Sendable {
        var text: String
        var isError: Bool
        var date: Date
    }

    private(set) var running: Set<CommonCommand> = []
    private(set) var results: [CommonCommand: Result] = [:]
    /// Full output of the last cleanup run or check, for the «Очистка» window.
    private(set) var cleanupOutput: (command: CommonCommand, text: String, date: Date)?

    private let settings: AppSettings
    private let store: ProjectStore
    private let requests: AppRequests

    init(settings: AppSettings, store: ProjectStore, requests: AppRequests) {
        self.settings = settings
        self.store = store
        self.requests = requests
    }

    nonisolated static let lowDiskBytes: Int64 = 20_000_000_000

    func run(_ command: CommonCommand) {
        guard !running.contains(command) else { return }
        let directory = settings.dailyReportDirectory

        guard command.script != nil else {
            openLatestReport(in: directory)
            return
        }
        running.insert(command)
        AppLog.info("Command «\(command.title)» started")
        Task {
            let (result, output) = await Self.execute(command, dailyReportDirectory: directory)
            running.remove(command)
            finish(command, result, output: output)
        }
    }

    /// Runs a script command and returns the line to show plus the full (token-free) output.
    nonisolated static func execute(_ command: CommonCommand, dailyReportDirectory directory: String) async -> (Result, String?) {
        guard let script = command.script else { return (Result(text: "Нечего запускать", isError: true, date: .now), nil) }
        let path = (directory as NSString).appendingPathComponent(script.name)
        guard FileManager.default.fileExists(atPath: path) else {
            return (Result(text: "Не найден \(script.name) в \(directory)", isError: true, date: .now), nil)
        }
        do {
            let process = try await ProcessRunner.run(
                "/usr/bin/env", ["python3", path] + script.arguments,
                currentDirectory: URL(fileURLWithPath: directory), timeout: script.timeout
            )
            let text = CommonCommand.redactingTokens(
                String(decoding: process.stdout, as: UTF8.self) + String(decoding: process.stderr, as: UTF8.self)
            )
            let line = command.summary(of: text) ?? (process.exitCode == 0 ? "Готово" : "Код выхода \(process.exitCode)")
            return (Result(text: line, isError: command.isFailure(exitCode: process.exitCode, summary: line), date: .now), text)
        } catch {
            return (Result(text: error.localizedDescription, isError: true, date: .now), nil)
        }
    }

    private func finish(_ command: CommonCommand, _ result: Result, output: String?) {
        results[command] = result
        AppLog.info("Command «\(command.title)» finished\(result.isError ? " with error" : ""): \(result.text)")
        if let output, command == .cleanupCheck || command == .cleanupRun {
            cleanupOutput = (command, output, result.date)
            // The spec shows the cleanup check output in a window.
            if command == .cleanupCheck { requests.openWindow("cleanup-output") }
        }
        if command == .cleanupRun {
            Task { await store.refresh() }
        }
        Notifier.post(
            id: "command-\(command.rawValue)", title: "\(result.isError ? "❌" : "✅") \(command.title)", body: result.text,
            target: notificationTarget(for: command, failed: result.isError)
        )
    }

    /// A click on the result opens the report that was just made, or the cleanup output.
    private func notificationTarget(for command: CommonCommand, failed: Bool) -> NotificationTarget {
        switch command {
        case .reportNow, .quickSummary:
            let report = URL(fileURLWithPath: settings.dailyReportDirectory).appending(path: "reports/latest.html").path
            return failed ? .none : .file(path: report)
        case .cleanupCheck, .cleanupRun:
            return cleanupOutput == nil ? .none : .window(id: "cleanup-output")
        case .openLatestReport:
            return .none
        }
    }

    private func openLatestReport(in directory: String) {
        let url = URL(fileURLWithPath: directory).appending(path: "reports/latest.html")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            results[.openLatestReport] = Result(text: "Отчёта ещё нет: \(url.path)", isError: true, date: .now)
        }
    }

    nonisolated static func diskText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
