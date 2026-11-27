import Foundation
import Testing
@testable import AIHubBar

/// Batch tasks (SPEC-content §5): one command over several folder projects, one after another. Models by API are
/// answered here; nothing leaves the Mac, and everything is written to a temporary folder.
@MainActor
struct BatchRunnerTests {
    @MainActor
    final class Bench {
        let base: URL
        let engine: CommandEngine
        let runner: BatchRunner
        let mode = Profile(name: "Тексты")
        let template = CommandTemplate(title: "Редактура", task: "Отредактируй {файл}.", output: "редактура.md")
        var prompts: [String] = []
        var failing: Set<String> = []
        var held = false
        var announced: [Batch] = []
        /// Banners of single commands: a batch sends none.
        var posted: [String] = []
        /// Replies wait here until the test lets them go, so «one at a time» can be seen.
        var gate: [CheckedContinuation<Void, Never>] = []
        var gated = false

        init() throws {
            let name = "batch-\(UUID().uuidString)"
            base = FileManager.default.temporaryDirectory.appending(path: name)
            let defaults = try #require(UserDefaults(suiteName: name))
            let settings = AppSettings(defaults: defaults)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            engine = CommandEngine(settings: settings, runs: RunStore(settings: settings), spendURL: base.appending(path: "spend.json"), defaults: defaults)
            runner = BatchRunner(engine: engine, url: base.appending(path: "batches.json"))
            engine.post = { [self] id, _, _, _ in posted.append(id) }
            engine.complete = { [self] _, _, prompt in
                prompts.append(prompt)
                if gated { await withCheckedContinuation { gate.append($0) } }
                if let name = failing.first(where: { prompt.contains($0) }) { throw Failure(name: name) }
                return APIClient.Reply(text: "Готово", inputTokens: 10, outputTokens: 10)
            }
            runner.profile = { [mode] id in id == mode.id ? mode : nil }
            runner.isHeld = { [self] in held }
            runner.announce = { [self] in announced.append($0) }
        }

        struct Failure: LocalizedError {
            var name: String
            var errorDescription: String? { "нет связи" }
        }

        func project(_ name: String) throws -> FolderProject {
            let folder = base.appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "Текст про \(name)".write(to: folder.appending(path: "текст.md"), atomically: true, encoding: .utf8)
            return FolderScanner.project(folder)
        }

        /// Ticks until `done`, giving the commands' own tasks room to work.
        func run(until done: () -> Bool) async {
            for _ in 0..<400 where !done() {
                runner.tick()
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: base) }
    }

    @Test func projectsGoOneAfterAnotherAndOneSummaryComes() async throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        let projects = try ["Кофе", "Чай", "Какао"].map(bench.project)
        bench.gated = true

        let batch = try #require(bench.runner.add(bench.template, projects: projects, mode: bench.mode, service: .api(.openai), text: nil, when: .now))
        #expect(batch.items.map(\.name) == ["Кофе", "Чай", "Какао"])
        await bench.run { bench.gate.count == 1 }
        bench.runner.tick()
        #expect(bench.prompts.count == 1, "the second project waits for the first")
        #expect(bench.runner.batches[0].items.map(\.state) == [.running, .waiting, .waiting])
        #expect(bench.runner.batches[0].status() == "0 из 3")

        // Let each reply go as it comes.
        bench.gated = false
        bench.gate.removeFirst().resume()
        await bench.run { bench.runner.batches[0].isFinished }

        #expect(bench.prompts.count == 3)
        #expect(bench.runner.batches[0].items.allSatisfy { $0.state == .done })
        for project in projects {
            #expect(FileManager.default.fileExists(atPath: project.path + "/редактура.md"))
        }
        #expect(bench.announced.count == 1, "one summary for the whole batch")
        #expect(bench.posted.isEmpty, "and no banner per project")
        #expect(bench.announced[0].summary.title == "Пакет «Редактура»: ✅ 3, ❌ 0")
        bench.runner.tick()
        #expect(bench.announced.count == 1)
        #expect(bench.runner.batches[0].status() == "готово: 3 из 3")
        bench.runner.dismiss(batch.id)
        #expect(bench.runner.batches.isEmpty)
    }

    @Test func aFailureDoesNotStopTheRest() async throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        let projects = try ["Кофе", "Чай", "Какао"].map(bench.project)
        bench.failing = ["Чай"]
        // The folder of the third one is gone by the time its turn comes.
        try FileManager.default.removeItem(atPath: projects[2].path)

        bench.runner.add(bench.template, projects: projects, mode: bench.mode, service: .api(.openai), text: nil, when: .now)
        await bench.run { bench.runner.batches[0].isFinished }

        let items = bench.runner.batches[0].items
        #expect(items.map(\.state) == [.done, .failed, .failed])
        #expect(items[1].note == "нет связи" && items[2].note == "папки больше нет")
        let summary = try #require(bench.announced.first).summary
        #expect(summary.title == "Пакет «Редактура»: ✅ 1, ❌ 2")
        #expect(summary.body == "✅ Кофе\n❌ Чай: нет связи\n❌ Какао: папки больше нет")
        #expect(bench.runner.batches[0].status() == "готово: 1 из 3, не получилось: 2")
    }

    @Test func aBatchWaitsForItsTimeAndForTheLimit() async throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        let projects = try ["Кофе", "Чай"].map(bench.project)
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let night = now.addingTimeInterval(3 * 3600)
        bench.runner.nightStart = { _ in night }
        bench.runner.resetsAt = { now.addingTimeInterval(1800) }

        #expect(bench.runner.startDate(.now, now: now) == now)
        #expect(bench.runner.startDate(.night, now: now) == night)
        #expect(bench.runner.startDate(.afterReset, now: now) == now.addingTimeInterval(1800 + 120))

        bench.runner.add(bench.template, projects: projects, mode: bench.mode, service: .api(.openai), text: nil, when: .night, now: now)
        bench.runner.tick(now: now.addingTimeInterval(3600))
        #expect(bench.prompts.isEmpty, "not before the night")
        #expect(bench.runner.batches[0].items.allSatisfy { $0.state == .waiting })
        bench.runner.tick(now: night.addingTimeInterval(1))
        #expect(bench.runner.batches[0].items[0].state == .running)

        // Near Claude's limit a Claude batch waits; a model by API has its own budget and goes on.
        var claude = bench.runner.batches[0]
        claude.serviceID = AIService.claudeCode.id
        #expect(claude.waitsForLimit && !bench.runner.batches[0].waitsForLimit)
    }

    @Test func whatHasNotStartedCanBeCancelled() async throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        let projects = try ["Кофе", "Чай", "Какао"].map(bench.project)
        bench.gated = true
        let batch = try #require(bench.runner.add(bench.template, projects: projects, mode: bench.mode, service: .api(.openai), text: nil, when: .now))
        await bench.run { bench.gate.count == 1 }

        bench.runner.cancel(batch.id)
        #expect(bench.runner.batches[0].items.map(\.name) == ["Кофе"], "the one at work finishes")
        bench.gated = false
        bench.gate.removeFirst().resume()
        await bench.run { bench.runner.batches.first?.isFinished ?? true }
        #expect(bench.prompts.count == 1)
        #expect(bench.announced.first?.summary.title == "Пакет «Редактура»: ✅ 1, ❌ 0")

        // A batch that has not begun goes away whole.
        bench.runner.nightStart = { _ in .distantFuture }
        let later = try #require(bench.runner.add(bench.template, projects: projects, mode: bench.mode, service: .api(.openai), text: nil, when: .night))
        bench.runner.cancel(later.id)
        #expect(!bench.runner.batches.contains { $0.id == later.id })
    }

    @Test func stopAllDropsWhatHasNotStartedInEveryBatch() async throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        bench.gated = true
        let projects = try ["Кофе", "Чай", "Какао"].map(bench.project)
        bench.runner.add(bench.template, projects: projects, mode: bench.mode, service: .api(.openai), text: nil, when: .now)
        bench.runner.nightStart = { _ in .distantFuture }
        let later = try #require(bench.runner.add(bench.template, projects: projects, mode: bench.mode, service: .api(.openai), text: nil, when: .night))
        await bench.run { bench.gate.count == 1 }

        bench.runner.cancelAll()
        #expect(bench.runner.batches.count == 1 && !bench.runner.batches.contains { $0.id == later.id }, "a batch that had not begun goes away whole")
        #expect(bench.runner.batches[0].items.map(\.name) == ["Кофе"], "the one at work is left to the run store")
        bench.gated = false
        bench.gate.removeFirst().resume()
        await bench.run { bench.runner.batches.first?.isFinished ?? true }
        #expect(bench.prompts.count == 1, "nothing else started")
        bench.runner.cancelAll()
        #expect(bench.runner.batches.count == 1, "a finished batch stays until it is dismissed")
    }

    @Test func theQueueSurvivesARestart() async throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        let projects = try ["Кофе", "Чай"].map(bench.project)
        bench.runner.nightStart = { _ in .distantFuture }
        bench.runner.add(bench.template, projects: projects, mode: bench.mode, service: .api(.openai), text: "  дружелюбнее ", when: .night)

        let again = BatchRunner(engine: bench.engine, url: bench.base.appending(path: "batches.json"))
        #expect(again.batches.count == 1)
        #expect(again.batches[0].items.map(\.name) == ["Кофе", "Чай"] && again.batches[0].text == "дружелюбнее")
        #expect(again.batches[0].template == bench.template && again.batches[0].when == .night)

        // A model by API that was working when the app closed: nothing knows about it, so the file decides.
        var lost = again.batches[0]
        lost.startAt = .distantPast
        lost.items[0].state = .running
        lost.items[0].resultFile = projects[0].path + "/редактура.md"
        let data = try JSONEncoder.iso.encode([lost])
        try data.write(to: bench.base.appending(path: "batches.json"))
        let third = BatchRunner(engine: bench.engine, url: bench.base.appending(path: "batches.json"))
        third.profile = bench.runner.profile
        third.tick()
        #expect(third.batches[0].items[0].state == .failed && third.batches[0].items[0].note == "прервано: приложение было закрыто")
        #expect(third.batches[0].items[1].state == .running, "the batch goes on with the next project")
    }

    @Test func onlyBackgroundServicesTakeABatch() throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        var terminal = Profile(name: "Т")
        terminal.launchMode = .terminal
        #expect(Batch.canRun(.api(.openai), mode: terminal))
        #expect(Batch.canRun(.claudeCode, mode: bench.mode) && !Batch.canRun(.claudeCode, mode: terminal))
        #expect(!Batch.canRun(.agent(.codex), mode: bench.mode), "other agents open in Terminal and wait for a paste")
        #expect(bench.runner.add(bench.template, projects: [try bench.project("Кофе")], mode: bench.mode, service: .agent(.codex), text: nil, when: .now) == nil)
        #expect(bench.runner.add(bench.template, projects: [], mode: bench.mode, service: .api(.openai), text: nil, when: .now) == nil)
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
