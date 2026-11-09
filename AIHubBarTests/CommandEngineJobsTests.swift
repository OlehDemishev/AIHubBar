import Foundation
import Testing
@testable import AIHubBar

/// `CommandEngine` running a command: results, spend and failures. No network, Terminal or notification is touched, and
/// everything is written to a temporary folder.
@MainActor
struct CommandEngineJobsTests {
    struct Failure: LocalizedError {
        var errorDescription: String? { "нет связи" }
    }

    @MainActor
    final class Bench {
        let settings: AppSettings
        let runs: RunStore
        let engine: CommandEngine
        let folder: URL
        let defaults: UserDefaults
        var prompts: [String] = []
        var posts: [(id: String, title: String)] = []
        var terminal: [String] = []
        var reply = APIClient.Reply(text: "Готовый текст", inputTokens: 1_000_000, outputTokens: 500_000)
        var failure: Error?
        var terminalFailure: Error?

        var spendURL: URL { folder.appending(path: "api-spend.json") }
        var project: FolderProject {
            FolderProject(name: "Кофе", path: folder.path, card: ProjectCardFile(), hasCardFile: false, mainFile: "текст.md",
                          words: nil, sources: 0, lastActivity: nil)
        }
        let template = CommandTemplate(title: "Хуки", task: "Сделай хуки для {проект}.", output: "хуки.md")

        init() throws {
            let name = "command-engine-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: name))
            settings = AppSettings(defaults: defaults)
            folder = FileManager.default.temporaryDirectory.appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "Исходный текст".write(to: folder.appending(path: "текст.md"), atomically: true, encoding: .utf8)
            runs = RunStore(settings: settings)
            engine = CommandEngine(settings: settings, runs: runs, spendURL: folder.appending(path: "api-spend.json"), defaults: defaults)
            engine.complete = { [self] _, _, prompt in
                prompts.append(prompt)
                if let failure { throw failure }
                return reply
            }
            engine.post = { [self] id, title, _, _ in posts.append((id, title)) }
            engine.runInTerminal = { [self] line in
                terminal.append(line)
                if let terminalFailure { throw terminalFailure }
            }
        }

        func run(_ service: AIService = .api(.openai), mode: Profile = Profile(name: "П"), suffix: String? = nil) -> String {
            engine.run(template, project: project, mode: mode, service: service, text: nil, suffix: suffix)
        }

        /// Waits for the work a command started in the background.
        func settle(until done: () -> Bool) async {
            for _ in 0..<2000 where !done() {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        func backgroundRun(_ id: String, _ state: BackgroundRun.State, summary: String? = nil) -> BackgroundRun {
            BackgroundRun(id: id, project: "Кофе", projectPath: folder.path, folder: folder.path, worktreeBranch: nil,
                          commandTitle: "Хуки", task: "", startedAt: .now, timeLimitMinutes: 90, pid: 1, state: state,
                          finishedAt: state == .running ? nil : .now, summary: summary, pullRequestURL: nil, notified: true)
        }

        func job(_ state: CommandEngine.Job.State, result: String = "нет.md") -> CommandEngine.Job {
            CommandEngine.Job(projectPath: folder.path, title: "Хуки", service: "Claude",
                              resultFile: folder.appending(path: result).path, state: state)
        }
    }

    // MARK: Through an API

    @Test func aResultIsWrittenAndCounted() async throws {
        let bench = try Bench()
        let path = bench.run()
        #expect(path.hasSuffix("/хуки.md"))
        await bench.settle { bench.engine.jobs.first?.state != .running }

        #expect(bench.engine.jobs.first?.state == .done)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "Готовый текст")
        #expect(bench.prompts.first?.contains("Сделай хуки для Кофе.") == true)
        #expect(bench.prompts.first?.contains("Исходный текст") == true)
        #expect(bench.engine.spend.first?.provider == .openai)
        #expect(bench.engine.spend.first?.inputTokens == 1_000_000)
        #expect(bench.posts.map(\.id).first?.hasPrefix("command-") == true)
    }

    @Test func spendSurvivesARestart() async throws {
        let bench = try Bench()
        _ = bench.run()
        await bench.settle { bench.engine.jobs.first?.state != .running }
        let again = CommandEngine(settings: bench.settings, runs: bench.runs, spendURL: bench.spendURL, defaults: bench.defaults)
        #expect(again.spend.count == 1)
    }

    @Test func aFailureLeavesNoFileAndCostsNothing() async throws {
        let bench = try Bench()
        bench.failure = Failure()
        let path = bench.run()
        await bench.settle { bench.engine.jobs.first?.state != .running }

        #expect(bench.engine.jobs.first?.state == .failed("нет связи"))
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(bench.engine.spend.isEmpty)
        #expect(bench.posts.isEmpty)
    }

    /// A result from before is never overwritten.
    @Test func anEarlierResultStays() async throws {
        let bench = try Bench()
        let earlier = bench.folder.appending(path: "хуки.md")
        try "Моя правка".write(to: earlier, atomically: true, encoding: .utf8)
        let path = bench.run()
        await bench.settle { bench.engine.jobs.first?.state != .running }

        #expect(path != earlier.path)
        #expect(try String(contentsOf: earlier, encoding: .utf8) == "Моя правка")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "Готовый текст")
    }

    @Test func compareNamesEachResultByItsService() async throws {
        let bench = try Bench()
        bench.engine.compare(bench.template, project: bench.project, mode: Profile(name: "П"),
                             services: [.api(.openai), .api(.anthropic)], text: nil)
        await bench.settle { bench.engine.jobs.allSatisfy { $0.state != .running } }

        let comparison = try #require(bench.engine.comparison)
        #expect(comparison.files.map(\.0) == ["OpenAI", "Claude API"])
        #expect(comparison.files[0].1.hasSuffix("хуки (OpenAI).md"))
        #expect(comparison.files[1].1.hasSuffix("хуки (Claude API).md"))
        #expect(bench.prompts.count == 2)
    }

    // MARK: Spend

    @Test func theBudgetWarnsOncePerLevel() async throws {
        let bench = try Bench()
        bench.settings.aiServices.monthlyBudget = 10
        bench.settings.aiServices.prices = ["openai": APIPrice(input: 9, output: 0)] // $9 a run: 90 %, then over

        _ = bench.run(suffix: "1")
        await bench.settle { bench.engine.spend.count == 1 }
        #expect(bench.posts.filter { $0.id.hasPrefix("spendWarned-") }.map(\.title).count == 1)
        #expect(bench.posts.contains { $0.title.contains("80") })

        _ = bench.run(suffix: "2")
        await bench.settle { bench.engine.spend.count == 2 }
        #expect(bench.posts.contains { $0.title.contains("100") })

        let warnings = bench.posts.filter { $0.id.hasPrefix("spendWarned-") }.count
        _ = bench.run(suffix: "3")
        await bench.settle { bench.engine.spend.count == 3 }
        #expect(bench.posts.filter { $0.id.hasPrefix("spendWarned-") }.count == warnings)
    }

    @Test func noBudgetNoWarning() async throws {
        let bench = try Bench()
        bench.settings.aiServices.prices = ["openai": APIPrice(input: 1000, output: 1000)]
        _ = bench.run()
        await bench.settle { bench.engine.spend.count == 1 }
        #expect(!bench.posts.contains { $0.id.hasPrefix("spendWarned-") })
    }

    // MARK: Claude Code in Terminal

    @Test func aTerminalCommandOpensInItsFolder() async throws {
        let bench = try Bench()
        var mode = Profile(name: "П")
        mode.launchMode = .terminal
        _ = bench.run(.claudeCode, mode: mode)
        await bench.settle { !bench.terminal.isEmpty }

        #expect(bench.terminal.first?.contains(bench.folder.lastPathComponent) == true)
        guard case .openedInTerminal = bench.engine.jobs.first?.state else {
            Issue.record("expected opened in Terminal, got \(String(describing: bench.engine.jobs.first?.state))")
            return
        }
        #expect(bench.runs.runs.isEmpty)
    }

    @Test func aTerminalThatFailsSaysSo() async throws {
        let bench = try Bench()
        bench.terminalFailure = Failure()
        var mode = Profile(name: "П")
        mode.launchMode = .terminal
        _ = bench.run(.claudeCode, mode: mode)
        await bench.settle { bench.engine.jobs.first?.state == .failed("нет связи") }
        #expect(bench.engine.jobs.first?.state == .failed("нет связи"))
    }

    // MARK: A background run's state

    @Test func aRunThatSucceededWithItsFileIsDone() throws {
        let bench = try Bench()
        bench.runs.runs = [bench.backgroundRun("r", .succeeded)]
        try "x".write(to: bench.folder.appending(path: "есть.md"), atomically: true, encoding: .utf8)
        bench.engine.jobs = [bench.job(.background(runID: "r"), result: "есть.md")]
        #expect(bench.engine.jobs(for: bench.folder.path).first?.state == .done)
    }

    /// The agent said it was done, but the promised file isn't there.
    @Test func aRunWithoutItsFileFailed() throws {
        let bench = try Bench()
        bench.runs.runs = [bench.backgroundRun("r", .succeeded, summary: "Готово")]
        bench.engine.jobs = [bench.job(.background(runID: "r"))]
        #expect(bench.engine.jobs(for: bench.folder.path).first?.state == .failed("Готово"))
    }

    @Test func aRunThatFailedSaysWhy() throws {
        let bench = try Bench()
        bench.runs.runs = [bench.backgroundRun("r", .failed, summary: "Упало")]
        try "x".write(to: bench.folder.appending(path: "есть.md"), atomically: true, encoding: .utf8)
        bench.engine.jobs = [bench.job(.background(runID: "r"), result: "есть.md")]
        #expect(bench.engine.jobs(for: bench.folder.path).first?.state == .failed("Упало"))
    }

    @Test func aRunStillGoingStaysInTheBackground() throws {
        let bench = try Bench()
        bench.runs.runs = [bench.backgroundRun("r", .running)]
        bench.engine.jobs = [bench.job(.background(runID: "r"))]
        #expect(bench.engine.jobs(for: bench.folder.path).first?.state == .background(runID: "r"))
    }

    @Test func jobsBelongToTheirProject() throws {
        let bench = try Bench()
        bench.engine.jobs = [bench.job(.done)]
        #expect(bench.engine.jobs(for: "/другая/папка").isEmpty)
        #expect(bench.engine.jobs(for: bench.folder.path).count == 1)
    }

    @Test func clearingKeepsWhatIsStillGoing() throws {
        let bench = try Bench()
        bench.runs.runs = [bench.backgroundRun("going", .running), bench.backgroundRun("over", .succeeded)]
        let going = bench.job(.background(runID: "going")), working = bench.job(.running)
        bench.engine.jobs = [going, working, bench.job(.done), bench.job(.failed("x")), bench.job(.background(runID: "over"))]
        bench.engine.clearFinished(in: bench.folder.path)
        #expect(bench.engine.jobs.map(\.id) == [going.id, working.id])
    }
}
