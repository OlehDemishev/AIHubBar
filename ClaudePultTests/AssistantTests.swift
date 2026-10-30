import Foundation
import Testing
@testable import ClaudePult

struct AssistantDraftTests {
    func draft(firstLaunch: Bool = false) -> AssistantDraft {
        AssistantDraft(firstLaunch: firstLaunch, menuBar: .make(.limits), hiddenBlocks: [], reminderHours: [24])
    }

    @Test func stepsDependOnTheSource() throws {
        var d = draft(firstLaunch: true)
        #expect(d.step == .importSettings)
        #expect(d.steps.count == AssistantDraft.Step.allCases.count)
        d.mode.source = .gitBuiltin(projects: "~/Code")
        #expect(!d.steps.contains(.stages) && !d.steps.contains(.commands) && !d.steps.contains(.calendar))
        #expect(draft().steps.first == .template, "import only on the first launch")
        d.next()
        #expect(d.step == .template)
        d.back()
        #expect(d.step == .importSettings && d.isFirst)
        d.step = .name
        #expect(d.isLast)
    }

    @Test func templatesAndFolders() throws {
        let templates = ModeTemplate.loadAll()
        var d = draft()
        d.setFolder(NSHomeDirectory() + "/Videos", analysis: .init(repositories: 0, folders: 3, files: 1))
        d.choose(templates.first { $0.id == "video" })
        #expect(d.templateID == "video")
        #expect(d.mode.source == .folders("~/Videos"), "a chosen folder survives a template change")
        #expect(d.mode.commands.contains { $0.title == "Хуки" })

        d.setFolder(NSHomeDirectory() + "/Code", analysis: .init(repositories: 4, folders: 5, files: 0))
        #expect(d.mode.source == .gitBuiltin(projects: "~/Code"))
        #expect(d.mode.card == .statusMD && d.mode.permissions == .code)
        d.setFolder(NSHomeDirectory() + "/Docs", analysis: .init(repositories: 1, folders: 6, files: 2))
        #expect(d.mode.source == .folders("~/Docs"))
        #expect(d.mode.permissions == .filesOnly)

        d.choose(nil)
        #expect(d.templateID == nil && d.mode.name == "Новый режим")
        d.choose(templates.first { $0.id == "developer" })
        #expect(d.menuBar.preset == .limits)
    }

    @Test func analysesAFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "claudepult-assistant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "repo/.git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "plain"), withIntermediateDirectories: true)
        try "x".write(to: root.appending(path: "note.md"), atomically: true, encoding: .utf8)
        let analysis = AssistantDraft.FolderAnalysis.of(root.path)
        #expect(analysis == .init(repositories: 1, folders: 2, files: 1))
        #expect(analysis.suggestsGit)
        #expect(analysis.text == "Внутри git-репозиториев: 1, обычных папок: 1, файлов: 1.")
        #expect(AssistantDraft.FolderAnalysis().text.hasPrefix("Папка пуста"))
    }
}

@MainActor
struct AssistantModeStoreTests {
    @Test func firstStartWithoutDailyReportGetsTheAssistant() throws {
        let name = "claudepult-starter-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.dailyReportDirectory = "/nonexistent/_daily-report"
        let dir = FileManager.default.temporaryDirectory.appending(path: name)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModeStore(settings: settings, directory: dir)
        #expect(store.needsAssistant)
        #expect(store.modes.map(\.template) == ["starter"])
        #expect(!settings.shows(.projects))

        var mode = AssistantDraft.blank
        mode.name = "Видео"
        let added = store.addFromAssistant(mode)
        #expect(store.modes.map(\.id) == [added.id], "the starter placeholder is replaced")
        #expect(store.currentID == added.id)
        #expect(!store.needsAssistant)
        #expect(ModeStore(settings: settings, directory: dir).modes.map(\.name) == ["Видео"])
    }
}
