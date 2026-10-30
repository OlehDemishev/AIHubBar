import Darwin
import Foundation
import Observation

/// Background `claude -p` runs: start, time limit, stop, result, notification and Telegram (docs/SPEC.md §2.4).
/// Claude writes straight into the log file, so a run keeps going if ClaudePult quits; on the next start
/// the app picks it up again from `runs/<id>.json`.
@MainActor
@Observable
final class RunStore {
    private(set) var runs: [BackgroundRun] = []
    /// The run shown in the «Журнал» window.
    var selectedLogRunID: String?

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
        let id = UUID().uuidString.lowercased()
        var run = BackgroundRun(
            id: id, project: project, projectPath: projectPath, folder: folder, worktreeBranch: worktreeBranch,
            commandTitle: command.title, task: Session.taskTitle(command.prompt), startedAt: .now,
            timeLimitMinutes: settings.backgroundTimeLimitMinutes, pid: nil, state: .running, notified: false
        )

        try FileManager.default.createDirectory(at: BackgroundRun.runsDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: run.logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: run.logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = BackgroundPermissions.arguments(prompt: command.prompt, sessionID: id)
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
            throw ProcessError.launchFailed("claude -p", underlying: error.localizedDescription)
        }

        run.pid = process.processIdentifier
        processes[id] = process
        save(run)
        runs.insert(run, at: 0)
        AppLog.info("Background run \(id) started: «\(command.title)» in \(folder), limit \(run.timeLimitMinutes) min")
        return run
    }

    // MARK: - Stop and time limit

    func stop(_ id: String, reason: BackgroundRun.State = .stopped) {
        guard let run = run(id: id), run.state == .running, let pid = run.pid else { return }
        stopReasons[id] = reason
        AppLog.info("Background run \(id): stopping (\(reason.rawValue))")
        kill(pid, SIGTERM)
        // Claude runs SessionEnd hooks on SIGTERM; give it a moment, then make sure it is gone.
        Task {
            try? await Task.sleep(for: .seconds(10))
            if Self.isRunProcessAlive(pid, startedAt: run.startedAt) { kill(pid, SIGKILL) }
            if processes[id] == nil { finish(id: id) }
        }
    }

    private func checkRuns() {
        // Runs started from the command line by another ClaudePult process.
        let known = Set(runs.map(\.id))
        let added = Self.loadRuns().filter { !known.contains($0.id) }
        if !added.isEmpty { runs = (runs + added).sorted { $0.startedAt > $1.startedAt } }

        for run in runs where run.state == .running {
            if Date.now >= run.deadline, stopReasons[run.id] == nil {
                stop(run.id, reason: .timedOut)
            } else if processes[run.id] == nil, !(run.pid.map { Self.isRunProcessAlive($0, startedAt: run.startedAt) } ?? false) {
                // Started before an app restart: no termination handler, so detect the exit here.
                finish(id: run.id)
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
        run.summary = StreamJSON.summary(outcome?.result) ?? (outcome == nil && run.state == .failed
            ? "Claude завершился без результата — см. журнал" : nil)
        if let denied = outcome?.deniedTools, !denied.isEmpty {
            let list = Array(Set(denied)).sorted().joined(separator: ", ")
            run.summary = [run.summary, "Отклонено правилами фона: \(list)"].compactMap { $0 }.joined(separator: "\n")
        }
        run.pullRequestURL = StreamJSON.pullRequestURL(in: outcome?.result)
        AppLog.info("Background run \(id) finished: \(run.state.rawValue)")
        announce(&run)
        save(run)
        if let index = runs.firstIndex(where: { $0.id == id }) { runs[index] = run }
    }

    private func announce(_ run: inout BackgroundRun) {
        guard !run.notified else { return }
        run.notified = true
        // A run that finished long before ClaudePult noticed (the app was not running) is not announced.
        let lastWrite = (try? run.logURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
        guard Date.now.timeIntervalSince(lastWrite) < 3600 else { return }
        Notifier.post(
            id: "run-\(run.id)", title: RunMessage.notificationTitle(run), body: RunMessage.notificationBody(run),
            target: .run(id: run.id, pullRequest: run.pullRequestURL)
        )
        guard settings.telegramForBackground,
              let credentials = Telegram.credentials(dailyReportDirectory: settings.dailyReportDirectory) else { return }
        let html = RunMessage.telegramHTML(run)
        Task { _ = await Telegram.send(html: html, with: credentials) }
    }

    // MARK: - Files

    private func save(_ run: BackgroundRun) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(run).write(to: run.metadataURL, options: .atomic)
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
