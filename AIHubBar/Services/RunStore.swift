import Darwin
import Foundation
import Observation

/// Background `claude -p` runs: start, time limit, stop, result, notification and Telegram (docs/specs/SPEC.md §2.4).
/// Claude writes straight into the log file, so a run keeps going if AI Hub Bar quits; on the next start
/// the app picks it up again from `runs/<id>.json`.
@MainActor
@Observable
final class RunStore {
    /// Set from outside only by the tests.
    var runs: [BackgroundRun] = []
    /// The run shown in the «Журнал» window.
    var selectedLogRunID: String?
    /// The pair shown in the «Сравнение» window (`PairCompareWindow`).
    var selectedPair: String?

    private let settings: AppSettings
    private var processes: [String: Process] = [:]
    /// Why a run was stopped, applied when its process exits.
    private var stopReasons: [String: BackgroundRun.State] = [:]
    private var monitor: Task<Void, Never>?

    nonisolated static let keepFinishedFor: TimeInterval = 30 * 86_400

    init(settings: AppSettings) {
        self.settings = settings
    }

    var running: [BackgroundRun] { runs.filter { $0.state == .running } }
    var paused: [BackgroundRun] { runs.filter(\.isPaused) }

    func run(id: String) -> BackgroundRun? { runs.first { $0.id == id } }

    func start() {
        guard monitor == nil else { return }
        try? FileManager.default.createDirectory(at: BackgroundRun.runsDirectory, withIntermediateDirectories: true)
        runs = Self.loadRuns()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkRuns()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - Launch

    func launch(
        command: ClaudeCommand, project: String, projectPath: String, folder: String,
        worktreeBranch: String?, claudePath: String
    ) throws -> BackgroundRun {
        try launch(
            title: command.title, prompt: command.prompt, project: project, projectPath: projectPath, folder: folder,
            worktreeBranch: worktreeBranch, profile: .code, resultFile: nil, claudePath: claudePath
        )
    }

    /// A command of a folder mode (SPEC-modes §3): its own permission profile and the file it should write.
    func launch(
        title: String, prompt: String, project: String, projectPath: String, folder: String, worktreeBranch: String?,
        profile: PermissionProfile, resultFile: String?, claudePath: String, taskTitle: String? = nil,
        codexPath: String? = nil, reviewOf: String? = nil, pair: String? = nil
    ) throws -> BackgroundRun {
        let id = UUID().uuidString.lowercased()
        var run = BackgroundRun(
            id: id, project: project, projectPath: projectPath, folder: folder, worktreeBranch: worktreeBranch,
            commandTitle: title, task: taskTitle ?? Session.taskTitle(prompt), startedAt: .now,
            timeLimitMinutes: settings.backgroundTimeLimitMinutes, pid: nil, state: .running, notified: false,
            resultFile: resultFile, agent: codexPath == nil ? nil : CodexExec.agent, prompt: prompt, reviewOf: reviewOf, pair: pair
        )

        try FileManager.default.createDirectory(at: BackgroundRun.runsDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: run.logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: run.logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath ?? claudePath)
        process.arguments = codexPath == nil
            ? BackgroundPermissions.arguments(prompt: prompt, sessionID: id, profile: profile, readOnly: reviewOf != nil)
            : CodexExec.arguments(
                prompt: prompt + (reviewOf == nil && CodexExec.isWorktree(folder: folder) ? CodexExec.worktreeNote : ""),
                gitDirectory: CodexExec.gitDirectory(folder: folder), readOnly: reviewOf != nil
            )
        process.currentDirectoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        process.environment = ProcessRunner.environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] _ in
            try? log.close()
            Task { @MainActor in self?.finish(id: id) }
        }
        do {
            try process.run()
        } catch {
            try? log.close()
            throw ProcessError.launchFailed(codexPath == nil ? "claude -p" : "codex exec", underlying: error.localizedDescription)
        }

        run.pid = process.processIdentifier
        processes[id] = process
        save(run)
        runs.insert(run, at: 0)
        AppLog.info("Background run \(id) (\(run.agent ?? "claude")) started: «\(title)» in \(folder), profile \(profile.rawValue), limit \(run.timeLimitMinutes) min")
        return run
    }

    // MARK: - Stop and time limit

    func stop(_ id: String, reason: BackgroundRun.State = .stopped) {
        guard let run = run(id: id), run.state == .running, let pid = run.pid else { return }
        // The run can have ended while the app was closed, and its pid can belong to something else by now.
        guard isOurs(run, pid: pid) else { finish(id: id); return }
        stopReasons[id] = reason
        AppLog.info("Background run \(id): stopping (\(reason.rawValue))")
        kill(pid, SIGTERM)
        // A stopped process only gets the signal once it runs again.
        if run.pausedAt != nil { kill(pid, SIGCONT) }
        // Claude runs SessionEnd hooks on SIGTERM; give it a moment, then make sure it is gone.
        Task {
            try? await Task.sleep(for: .seconds(10))
            if Self.isRunProcessAlive(pid, startedAt: run.startedAt) { kill(pid, SIGKILL) }
            if processes[id] == nil { finish(id: id) }
        }
    }

    /// The limit guard: stops the process where it is (SIGSTOP), so the work isn't lost to a hit limit.
    func pause(_ id: String) {
        guard var run = run(id: id), run.state == .running, run.pausedAt == nil, let pid = run.pid, isOurs(run, pid: pid) else { return }
        kill(pid, SIGSTOP)
        run.pausedAt = .now
        update(run)
        AppLog.info("Background run \(id): paused by the limit guard")
    }

    func resume(_ id: String) {
        guard var run = run(id: id), let pausedAt = run.pausedAt, let pid = run.pid else { return }
        if isOurs(run, pid: pid) { kill(pid, SIGCONT) }
        run.pausedSeconds = (run.pausedSeconds ?? 0) + Date.now.timeIntervalSince(pausedAt)
        run.pausedAt = nil
        update(run)
        AppLog.info("Background run \(id): resumed")
    }

    /// Whether `pid` is still this run's process: started by this app instance, or alive with the run's start time.
    /// Checked before every signal, because a pid kept in a file outlives its process.
    private func isOurs(_ run: BackgroundRun, pid: Int32) -> Bool {
        processes[run.id] != nil || Self.isRunProcessAlive(pid, startedAt: run.startedAt)
    }

    /// «Оставить этот вариант»: the pair's other run loses its worktree and branch and is marked as removed.
    func keepVariant(_ keep: BackgroundRun) async throws {
        guard let pair = keep.pair, let sides = PairCompare.sides(pair, runs: runs), PairCompare.canKeep(keep, sides: sides),
              var other = sides.first(where: { $0.id != keep.id }), let branch = other.worktreeBranch else { return }
        try await GitService.discardWorktree(other.folder, branch: branch, projectPath: other.projectPath)
        other.discarded = true
        update(other)
        AppLog.info("Pair \(pair): kept \(keep.agent ?? "claude"), removed \(other.agent ?? "claude")")
    }

    /// «Влить в …»: the variant's branch goes into the branch the project's folder is on.
    func mergeVariant(_ run: BackgroundRun, into target: String) async throws {
        guard var saved = self.run(id: run.id), let branch = saved.worktreeBranch, saved.mergedInto == nil, saved.discarded != true else { return }
        try await GitService.mergeBranch(branch, into: target, projectPath: saved.projectPath)
        saved.mergedInto = target
        update(saved)
    }

    private func update(_ run: BackgroundRun) {
        save(run)
        if let index = runs.firstIndex(where: { $0.id == run.id }) { runs[index] = run }
    }

    private func checkRuns() {
        // Runs started from the command line by another AI Hub Bar process.
        let known = Set(runs.map(\.id))
        let added = Self.loadRuns().filter { !known.contains($0.id) }
        if !added.isEmpty { runs = (runs + added).sorted { $0.startedAt > $1.startedAt } }

        for var run in runs where run.state == .running {
            if run.agent == CodexExec.agent, run.threadID == nil,
               let thread = CodexExec.threadID(fromLog: (try? String(contentsOf: run.logURL, encoding: .utf8)) ?? "") {
                run.threadID = thread
                update(run)
            }
            if processes[run.id] == nil, !(run.pid.map { Self.isRunProcessAlive($0, startedAt: run.startedAt) } ?? false) {
                // Started before an app restart: no termination handler, so detect the exit here. Before the time
                // limit: a run that ended while the app was closed did not time out.
                finish(id: run.id)
            } else if !run.isPaused, Date.now >= run.deadline(), stopReasons[run.id] == nil {
                stop(run.id, reason: .timedOut)
            }
        }
    }

    // MARK: - Finish

    private func finish(id: String) {
        processes[id] = nil
        guard var run = run(id: id), run.state == .running else { return }
        let log = (try? String(contentsOf: run.logURL, encoding: .utf8)) ?? ""
        let outcome = StreamJSON.outcome(fromLog: log)

        if let reason = stopReasons.removeValue(forKey: id) {
            run.state = reason
        } else {
            run.state = outcome.map { $0.isError ? .failed : .succeeded } ?? .failed
        }
        run.finishedAt = .now
        if run.threadID == nil { run.threadID = CodexExec.threadID(fromLog: log) }
        run.summary = StreamJSON.summary(outcome?.result) ?? (outcome == nil && run.state == .failed
            ? (run.agent == nil ? String(localized: "Claude завершился без результата — см. журнал")
                : String(localized: "\(run.agentTitle) завершился без результата — см. журнал")) : nil)
        if let denied = outcome?.deniedTools, !denied.isEmpty {
            let list = Array(Set(denied)).sorted().joined(separator: ", ")
            run.summary = [run.summary, String(localized: "Отклонено правилами фона: \(list)")].compactMap { $0 }.joined(separator: "\n")
        }
        run.pullRequestURL = StreamJSON.pullRequestURL(in: outcome?.result)
        if let file = run.resultFile, run.state == .succeeded, !FileManager.default.fileExists(atPath: file) {
            run.summary = [run.summary, String(localized: "Файл результата не появился: \((file as NSString).lastPathComponent)")].compactMap { $0 }.joined(separator: "\n")
        }
        AppLog.info("Background run \(id) finished: \(run.state.rawValue)")
        announce(&run)
        save(run)
        if let index = runs.firstIndex(where: { $0.id == id }) { runs[index] = run }
        // Codex cannot commit in a worktree; in a pair Claude's side is committed too when it left its work
        // uncommitted (seen live 2026-11-19: its background rules denied the commit), so branch meets branch.
        if run.agent == CodexExec.agent || run.pair != nil, run.reviewOf == nil, run.state == .succeeded,
           CodexExec.isWorktree(folder: run.folder) {
            Task { await commitLeftovers(id: id) }
        }
    }

    /// Codex cannot commit in a worktree (`CodexExec.worktreeNote`): what it left there is committed here, on the
    /// worktree's branch, so the branch holds the work and can be compared or merged.
    private func commitLeftovers(id: String) async {
        guard let run = run(id: id) else { return }
        do {
            let status = try await GitService.run(["status", "--porcelain"], in: run.folder, timeout: .seconds(20))
            guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            try await GitService.run(["add", "-A"], in: run.folder, timeout: .seconds(30))
            try await GitService.run(["commit", "-m", RunMessage.taskStart(run.task)], in: run.folder, timeout: .seconds(30))
            AppLog.info("Background run \(id): Codex's changes committed on \(run.worktreeBranch ?? "the worktree's branch")")
            guard var saved = self.run(id: id) else { return }
            let note = saved.agent == CodexExec.agent
                ? String(localized: "Коммит сделал AI Hub Bar: в worktree Codex этого не может.")
                : String(localized: "Коммит сделал AI Hub Bar: изменения оставались без коммита.")
            saved.summary = [saved.summary, note].compactMap { $0 }.joined(separator: "\n")
            save(saved)
            if let index = runs.firstIndex(where: { $0.id == id }) { runs[index] = saved }
        } catch {
            AppLog.error("Background run \(id): committing Codex's changes failed: \(error.localizedDescription)")
        }
    }

    private func announce(_ run: inout BackgroundRun) {
        guard !run.notified else { return }
        run.notified = true
        // A run that finished long before AI Hub Bar noticed (the app was not running) is not announced.
        let lastWrite = (try? run.logURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
        guard Date.now.timeIntervalSince(lastWrite) < 3600 else { return }
        Notifier.post(
            id: "run-\(run.id)", title: RunMessage.notificationTitle(run), body: RunMessage.notificationBody(run),
            target: run.resultFile.flatMap { FileManager.default.fileExists(atPath: $0) ? .file(path: $0) : nil }
                ?? .run(id: run.id, pullRequest: run.pullRequestURL)
        )
        Telegram.notify(.backgroundResults, html: RunMessage.telegramHTML(run), settings: settings)
    }

    // MARK: - Files

    private func save(_ run: BackgroundRun) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        AppLog.attempt("Run \(run.id) not saved") { try encoder.encode(run).write(to: run.metadataURL, options: .atomic) }
    }

    nonisolated static func loadRuns(from directory: URL = BackgroundRun.runsDirectory, now: Date = .now) -> [BackgroundRun] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var runs: [BackgroundRun] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let run = try? decoder.decode(BackgroundRun.self, from: data) else { continue }
            if let finished = run.finishedAt, now.timeIntervalSince(finished) > keepFinishedFor {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: run.logURL)
                continue
            }
            runs.append(run)
        }
        return runs.sorted { $0.startedAt > $1.startedAt }
    }

    /// The run's process still exists: the PID is alive and its process started within 30 s of the run,
    /// so a PID reused by another process later does not count.
    nonisolated static func isRunProcessAlive(_ pid: Int32, startedAt: Date) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        let processStart = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
        return abs(processStart.timeIntervalSince(startedAt)) < 30
    }
}
