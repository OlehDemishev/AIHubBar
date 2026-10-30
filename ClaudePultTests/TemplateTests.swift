import Foundation
import Testing
@testable import ClaudePult

struct GitScannerTests {
    private func sh(_ args: [String], in dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir.path, "-c", "user.name=T", "-c", "user.email=t@example.com"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    @Test func scansReposLikeReportPy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "claudepult-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appending(path: "Alpha")
        try FileManager.default.createDirectory(at: repo.appending(path: "docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "not-a-repo"), withIntermediateDirectories: true)
        try sh(["init", "-q", "-b", "main"], in: repo)
        try """
        # Status

        <!-- summary:start -->
        **Stage:** beta
        **Updated:** 2026-10-30

        **Now:**
        - [ ] polishing

        **Next:**
        - release

        **Needs Anna:**
        - pick a name
        <!-- summary:end -->

        ## 2026-10-29 — First step (branch `a`)
        ## 2026-10-30 — Second step
        """.write(to: repo.appending(path: "docs/STATUS.md"), atomically: true, encoding: .utf8)
        try "a".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try sh(["add", "."], in: repo)
        try sh(["commit", "-q", "-m", "init"], in: repo)
        try "b".write(to: repo.appending(path: "b.txt"), atomically: true, encoding: .utf8)

        let report = try #require(await GitScanner.report(projectsDirectory: root.path, fetch: false))
        #expect(report.projects.map(\.name) == ["Alpha"])
        let project = try #require(report.projects.first)
        #expect(project.branch == "main")
        #expect(project.dirty == 1)
        #expect(project.health == .red)
        #expect(project.attention.contains { $0.text == "1 файл не закоммичено (ветка main)" })
        #expect(project.attention.contains { $0.text == "нужно от вас: pick a name" }, "any «Needs …» label")
        #expect(project.status?.summary?.stage == "beta")
        #expect(project.status?.summary?.now == ["polishing"])
        #expect(project.status?.latestEntry?.title == "Second step")
        #expect(project.openPRs == nil, "no remote, no PR lookup")
        #expect(report.diskFreeBytes != nil)

        try sh(["add", "."], in: repo)
        try sh(["commit", "-q", "-m", "b"], in: repo)
        try "changed".write(to: repo.appending(path: "docs/STATUS.md"), atomically: true, encoding: .utf8)
        let second = try #require(await GitScanner.report(projectsDirectory: root.path, fetch: false)?.projects.first)
        #expect(second.health == .green || second.health == .yellow)
        #expect(second.attention.contains { $0.text == "изменения в STATUS.md не закоммичены" }, "the first porcelain line keeps its leading space")
    }

    @Test func ciAndWords() {
        #expect(GitScanner.ciState([]) == "none")
        #expect(GitScanner.ciState([["conclusion": "SUCCESS"], ["status": "IN_PROGRESS"]]) == "pending")
        #expect(GitScanner.ciState([["conclusion": "SUCCESS"], ["conclusion": "FAILURE"]]) == "fail")
        #expect(GitScanner.ciState([["state": "SUCCESS"]]) == "ok")
        #expect([1, 2, 5, 11, 21, 22].map(Plural.files) == ["файл", "файла", "файлов", "файлов", "файл", "файла"])
        #expect(StatusText.summary("no markers") == nil)
    }
}

@MainActor
struct ModeTemplateTests {
    @Test func builtInTemplatesLoad() throws {
        let templates = ModeTemplate.loadAll()
        #expect(templates.map(\.id) == ["developer", "video", "texts", "research", "social", "custom"])
        let video = try #require(templates.first { $0.id == "video" })
        #expect(video.mode.stages.first == "идея")
        #expect(video.mode.commands.map(\.title).contains("Хуки"))
        #expect(video.mode.permissions == .filesOnly)
        #expect(templates.first { $0.id == "research" }?.mode.permissions == .filesAndWeb)
        #expect(templates.first { $0.id == "social" }?.mode.calendar == .contentPlan)
        if case .gitBuiltin = templates[0].mode.source {} else { Issue.record("developer uses the built-in scanner") }
        for template in templates {
            for command in template.mode.commands {
                #expect(!command.task.isEmpty && !command.output.isEmpty, "\(template.id)/\(command.id)")
                if let service = command.service { #expect(AIService(id: service) != nil) }
            }
        }
    }

    @Test func addsAModeFromATemplate() throws {
        let name = "claudepult-templates-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let dir = FileManager.default.temporaryDirectory.appending(path: name)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModeStore(settings: settings, directory: dir)
        let template = try #require(ModeTemplate.loadAll().first { $0.id == "video" })
        let mode = store.add(template, folder: NSHomeDirectory() + "/Videos")
        #expect(store.currentID == mode.id)
        #expect(store.enabledIDs.contains(mode.id))
        #expect(mode.source == .folders("~/Videos"))
        #expect(settings.activeSource == .folders("~/Videos"))
        #expect(settings.promptStyle == .generic)
        #expect(store.add(template, folder: "/tmp").name == "Видео 2")

        let developer = try #require(ModeTemplate.loadAll().first { $0.id == "developer" })
        store.add(developer, folder: NSHomeDirectory() + "/Code")
        #expect(settings.activeSource == .gitBuiltin(projects: "~/Code"))
        #expect(settings.shows(.projects))
    }
}

struct PromptStyleTests {
    @Test func genericPromptsHaveNoOlehRules() {
        for command in [ClaudeCommand.nextStep, .customTask("Сделай X"), .finishSession] {
            #expect(!command.prompt(.generic).contains("~/Projects/CLAUDE.md"))
            #expect(!command.prompt(.generic).contains("Олег"))
            #expect(command.prompt == command.prompt(.oleh))
        }
        #expect(ClaudeCommand.customTask("Сделай X").prompt(.generic).hasPrefix("Задача: Сделай X."))
        #expect(Session.taskTitle(ClaudeCommand.nextStep.prompt(.generic)) == "Следующий шаг")
        #expect(Session.taskTitle(ClaudeCommand.customTask("Сделай X").prompt(.generic)) == "Сделай X")
        #expect(Session.taskTitle(ClaudeCommand.customTask("Сделай Y").prompt(.oleh)) == "Сделай Y")
    }
}
