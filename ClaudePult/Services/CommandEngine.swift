import AppKit
import Foundation
import Observation

/// Runs mode commands on folder projects (SPEC-modes §3, §11): Claude Code in the background with the mode's
/// permissions (or in Terminal), other agents in Terminal, models by API from here — the result always a new file
/// in the project folder. Also keeps the API spend and «Сравнить».
@MainActor
@Observable
final class CommandEngine {
    struct Job: Identifiable, Equatable {
        enum State: Equatable {
            case running
            /// Waits for a background `claude -p` run.
            case background(runID: String)
            case openedInTerminal(String)
            case done
            case failed(String)
        }

        var id = UUID().uuidString
        var projectPath: String
        var title: String
        var service: String
        var resultFile: String
        var state: State
        var startedAt = Date.now
    }

    /// Results of one «Сравнить», shown side by side.
    struct Comparison: Equatable {
        var title: String
        var projectPath: String
        var files: [(label: String, path: String)]

        static func == (a: Comparison, b: Comparison) -> Bool {
            a.title == b.title && a.projectPath == b.projectPath && a.files.map(\.path) == b.files.map(\.path)
        }
    }

    private(set) var jobs: [Job] = []
    private(set) var spend: [SpendRecord] = []
    var comparison: Comparison?

    private let settings: AppSettings
    private let runs: RunStore
    private static var spendURL: URL { SessionFiles.supportDirectory.appending(path: "api-spend.json") }

    init(settings: AppSettings, runs: RunStore) {
        self.settings = settings
        self.runs = runs
        spend = Self.loadSpend()
    }

    func jobs(for projectPath: String) -> [Job] {
        jobs.filter { $0.projectPath == projectPath }.map { job in
            guard case let .background(runID) = job.state, let run = runs.run(id: runID), run.state.isFinished else { return job }
            var finished = job
            finished.state = run.state == .succeeded && FileManager.default.fileExists(atPath: job.resultFile)
                ? .done : .failed(run.summary ?? String(localized: "Фоновая задача: \(run.state.rawValue)"))
            return finished
        }
    }

    func clearFinished(in projectPath: String) {
        let finished = Set(jobs(for: projectPath).filter { $0.state != .running && !isBackgroundRunning($0) }.map(\.id))
        jobs.removeAll { finished.contains($0.id) }
    }

    private func isBackgroundRunning(_ job: Job) -> Bool {
        if case let .background(runID) = job.state { return runs.run(id: runID)?.state == .running }
        return false
    }

    // MARK: - Running

    func context(_ template: CommandTemplate, project: FolderProject, mode: Mode, text: String?) -> CommandContext {
        CommandContext(
            projectName: project.name, projectPath: project.path,
            file: template.input == .mainFile ? project.mainFile : nil,
            format: project.card.values[.format], platform: project.card.values[.platform],
            duration: FolderMetric.duration.text(for: project, wordsPerMinute: mode.wordsPerMinute),
            text: text?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Starts one command; returns the result file it will write.
    @discardableResult
    func run(_ template: CommandTemplate, project: FolderProject, mode: Mode, service: AIService, text: String?,
             suffix: String? = nil) -> String {
        let context = context(template, project: project, mode: mode, text: text)
        let folder = URL(fileURLWithPath: project.path)
        let name = CommandText.uniqueName(CommandText.outputName(template.output, context, suffix: suffix)) {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
        let resultPath = folder.appending(path: name).path
        let task = CommandText.fill(template.task, context)
        var job = Job(projectPath: project.path, title: template.title, service: service.shortName(compatibleName: settings.aiServices.compatibleName),
                      resultFile: resultPath, state: .running)
        AppLog.info("Command «\(template.title)» → \(service.id) in \(project.path) → \(name)")

        switch service {
        case let .api(provider):
            jobs.append(job)
            let fileText = context.file.flatMap { FolderScanner.text(of: folder.appending(path: $0)) }
            let prompt = CommandText.apiPrompt(task: task, context: context, fileText: fileText)
            let config = settings.aiServices
            let id = job.id
            Task {
                do {
                    let reply = try await APIClient.complete(provider, config: config, prompt: prompt)
                    try reply.text.write(toFile: resultPath, atomically: true, encoding: .utf8)
                    record(SpendRecord(date: .now, provider: provider, model: config.model(provider) ?? "?",
                                       inputTokens: reply.inputTokens, outputTokens: reply.outputTokens))
                    update(id) { $0.state = .done }
                    Notifier.post(id: "command-\(id)", title: String(localized: "Готово: \(template.title)"), body: "\(project.name) · \(name)",
                                  target: .file(path: resultPath))
                } catch {
                    update(id) { $0.state = .failed(error.localizedDescription) }
                    AppLog.error("Command «\(template.title)» via \(provider.rawValue) failed: \(error.localizedDescription)")
                }
            }

        case .agent(.claudeCode):
            let prompt = CommandText.agentPrompt(task: task, context: context, output: name)
            let claude = ClaudeLocator.resolve(configured: settings.claudePath)
            if mode.launchMode == .terminal {
                openInTerminal(ShellQuote.claudeCommandLine(folder: project.path, claude: claude, prompt: prompt), job: &job)
            } else {
                do {
                    let run = try runs.launch(
                        title: template.title, prompt: prompt, project: project.name, projectPath: project.path,
                        folder: project.path, worktreeBranch: nil, profile: mode.permissions, resultFile: resultPath,
                        claudePath: claude
                    )
                    job.state = .background(runID: run.id)
                } catch {
                    job.state = .failed(error.localizedDescription)
                }
            }
            jobs.append(job)

        case let .agent(kind):
            // Other agents only in Terminal (their «no actions» modes are not checked live yet): the agent opens in
            // the folder and the task is put on the clipboard to paste.
            let prompt = CommandText.agentPrompt(task: task, context: context, output: name)
            if let path = kind == .claudeCode ? nil : kind.detect() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt, forType: .string)
                openInTerminal(kind.terminalCommandLine(folder: project.path, path: path), job: &job)
                job.state = .openedInTerminal(String(localized: "\(kind.title) открыт в Терминале — задача скопирована, вставьте ⌘V"))
            } else {
                job.state = .failed(String(localized: "\(kind.title) не установлен"))
            }
            jobs.append(job)
        }
        return resultPath
    }

    /// «Сравнить»: the same command with 2–3 services, results named `хуки (Claude).md`, `хуки (OpenAI).md`.
    func compare(_ template: CommandTemplate, project: FolderProject, mode: Mode, services: [AIService], text: String?) {
        var files: [(String, String)] = []
        for service in services {
            let label = service.shortName(compatibleName: settings.aiServices.compatibleName)
            files.append((label, run(template, project: project, mode: mode, service: service, text: text, suffix: label)))
        }
        comparison = Comparison(title: template.title, projectPath: project.path, files: files)
    }

    private func openInTerminal(_ commandLine: String, job: inout Job) {
        job.state = .openedInTerminal(String(localized: "Открыто в Терминале"))
        let id = job.id
        Task {
            do {
                try await TerminalLauncher.run(commandLine)
            } catch {
                update(id) { $0.state = .failed(error.localizedDescription) }
            }
        }
    }

    private func update(_ id: String, _ change: (inout Job) -> Void) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[index]) }
    }

    // MARK: - Spend

    var monthStart: Date { Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now }

    func summary(since start: Date) -> SpendSummary {
        SpendSummary.of(spend, since: start, prices: settings.aiServices.prices)
    }

    private func record(_ record: SpendRecord) {
        spend.append(record)
        let yearAgo = Date.now.addingTimeInterval(-400 * 86_400)
        spend.removeAll { $0.date < yearAgo }
        Self.saveSpend(spend)
        warnAboutBudget()
    }

    private func warnAboutBudget() {
        guard let budget = settings.aiServices.monthlyBudget, budget > 0,
              let cost = summary(since: monthStart).cost else { return }
        let month = Date.now.formatted(.iso8601.year().month())
        for level in [100, 80] where cost >= budget * Double(level) / 100 {
            let key = "spendWarned-\(month)-\(level)"
            guard !UserDefaults.standard.bool(forKey: key) else { return }
            UserDefaults.standard.set(true, forKey: key)
            Notifier.post(id: key, title: String(localized: "Расход по API: \(level) % бюджета"),
                          body: String(format: String(localized: "$%.2f из $%.2f в этом месяце"), cost, budget), target: .window(id: "settings"))
            return
        }
    }

    private static func loadSpend() -> [SpendRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: spendURL)).flatMap { try? decoder.decode([SpendRecord].self, from: $0) } ?? []
    }

    private static func saveSpend(_ records: [SpendRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: SessionFiles.supportDirectory, withIntermediateDirectories: true)
        try? encoder.encode(records).write(to: spendURL, options: .atomic)
    }
}
