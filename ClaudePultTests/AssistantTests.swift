import Foundation
import Testing
@testable import ClaudePult

struct AssistantDraftTests {
    func draft(firstLaunch: Bool = false) -> AssistantDraft {
        AssistantDraft(firstLaunch: firstLaunch, menuBar: .make(.limits), hiddenBlocks: [], reminderHours: [24])
    }

    @Test func stepsDependOnTheSource() throws {
        var d = draft(firstLaunch: true)
        #expect(d.step == .welcome, "a new Mac starts with the welcome screen")
        d.next()
        #expect(d.step == .importSettings)
        #expect(d.steps.count == AssistantDraft.Step.allCases.count)
        d.mode.source = .gitBuiltin(projects: "~/Code")
        #expect(!d.steps.contains(.stages) && !d.steps.contains(.commands) && !d.steps.contains(.calendar))
        #expect(draft().steps.first == .template, "welcome and import only on the first launch")
        d.next()
        #expect(d.step == .template)
        d.back()
        #expect(d.step == .importSettings && !d.isFirst)
        d.back()
        #expect(d.step == .welcome && d.isFirst)
        d.step = .name
        #expect(d.isLast)
    }

    @Test func modulesDecideTheSteps() {
        var d = draft()
        d.choose(nil)
        #expect(d.hasModule(.projects) && d.hasModule(.upcoming) && d.hasModule(.limits))
        #expect(d.steps.contains(.folder) && d.steps.contains(.commands) && d.steps.contains(.modules))

        d.setModule(.projects, false)
        #expect(!d.hasModule(.projects) && !d.hasModule(.upcoming))
        #expect(d.steps == [.template, .modules, .menuBar, .name], "no project steps without projects")
        #expect(!d.canChange(.upcoming))

        d.setModule(.projects, true)
        #expect(d.mode.source == AssistantDraft.blank.source && d.mode.calendar == .dates, "switched back on as it was")
        d.setModule(.upcoming, false)
        d.setModule(.sessions, false)
        #expect(!d.steps.contains(.calendar) == false, "the calendar step stays for folder projects")
        #expect(d.mode.calendar == .off && d.hiddenBlocks == [.sessions])
        d.mode.modules = nil
        #expect(d.mode.normalizedModules(hiddenBlocks: d.hiddenBlocks).map(\.kind) == [.limits, .sessions, .projects])
        #expect(d.mode.normalizedModules(hiddenBlocks: d.hiddenBlocks)[1].shown == false)
    }

    @Test func templatesAndFolders() throws {
        let templates = ModeTemplate.loadAll(language: .ru)
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
        #expect(d.templateID == nil && d.mode.name == "Новый профиль")
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
        #expect(store.modes.isEmpty, "an empty start: no placeholder profile (SPEC-profiles §2)")

        var mode = AssistantDraft.blank
        mode.name = "Видео"
        let added = store.addFromAssistant(mode)
        #expect(store.modes.map(\.id) == [added.id])
        #expect(store.installedModules.contains(.limits), "the first profile installs its modules")
        #expect(store.currentID == added.id)
        #expect(!store.needsAssistant)
        #expect(ModeStore(settings: settings, directory: dir).modes.map(\.name) == ["Видео"])
    }
}
