import Foundation
import Testing
@testable import ClaudePult

struct EnglishContentTests {
    @Test func templatesInBothLanguages() throws {
        let ru = ModeTemplate.loadAll(language: .ru)
        let en = ModeTemplate.loadAll(language: .en)
        #expect(ru.map(\.id) == en.map(\.id))
        #expect(en.first { $0.id == "video" }?.mode.name == "Video")
        #expect(ru.first { $0.id == "video" }?.mode.name == "Видео")
        let known = ["{проект}", "{файл}", "{формат}", "{площадка}", "{хронометраж}", "{язык}", "{текст}",
                     "{project}", "{file}", "{format}", "{platform}", "{duration}", "{language}", "{text}"]
        for template in en {
            #expect(template.language == "en")
            #expect(!template.mode.name.contains(where: { ("а"..."я").contains(String($0).lowercased()) }), "\(template.id)")
            for command in template.mode.commands {
                let placeholders = command.task.matches(of: /\{[^}]+\}/).map { String($0.output) }
                #expect(placeholders.allSatisfy(known.contains), "\(command.id): \(placeholders)")
                #expect(command.asks == nil || !command.task.isEmpty)
            }
            let ruCommands = ru.first { $0.id == template.id }?.mode.commands.map(\.id) ?? []
            #expect(template.mode.commands.map(\.id) == ruCommands, "same commands as the original")
        }
    }

    @Test func englishPlaceholdersAndWrappers() {
        let context = CommandContext(projectName: "Coffee", projectPath: "/V/Coffee", file: "script.md", format: nil, platform: nil,
                                     duration: "8:00", text: "German", now: Date(timeIntervalSince1970: 0))
        #expect(CommandText.fill("{project} {file} {format} {language} {проект}", context, language: .en) == "Coffee script.md not set German Coffee")
        #expect(CommandText.outputName("summary-<file>", context, language: .en) == "summary-script.md")
        #expect(CommandText.outputName("script-{language}.md", context, language: .en) == "script-German.md")
        #expect(CommandText.outputName("result-<time>.md", context, language: .en).hasPrefix("result-19"))
        #expect(CommandText.outputName("", context, language: .en) == "result.md")
        let agent = CommandText.agentPrompt(task: "Do it", context: context, output: "hooks.md", language: .en)
        #expect(agent.contains("change none of them") && agent.hasSuffix("Task: Do it"))
        let api = CommandText.apiPrompt(task: "Do it", context: context, fileText: "TEXT", language: .en)
        #expect(api.contains("Below is the text of the file «script.md».") && api.contains("Reply with the result only"))
        #expect(CommandText.agentPrompt(task: "x", context: context, output: "a.md", language: .ru).contains("ничего в них не меняй"))
    }

    @Test func englishDeveloperPrompts() {
        let next = ClaudeCommand.nextStep.prompt(.generic, language: .en)
        #expect(next.hasPrefix("Read the README"))
        #expect(ClaudeCommand.nextStep.prompt(.oleh, language: .en) == ClaudeCommand.nextStep.prompt, "Oleh's prompts stay")
        #expect(Session.taskTitle(next) == "Следующий шаг" || Session.taskTitle(next) == "Next step")
        #expect(Session.taskTitle(ClaudeCommand.customTask("Fix the build").prompt(.generic, language: .en)) == "Fix the build")
    }

    @Test func cardsKeepTheirLanguage() throws {
        let template = ProjectCardFile.template(name: "Coffee", stage: "idea", language: .en)
        #expect(template.contains("Stage: idea") && template.contains("Deadline: ") && template.contains("## Notes"))
        #expect(ProjectCardFile.parse(template).stage == "idea")
        #expect(ProjectCardFile.setting(.deadline, to: "2026-12-01", in: "# A\n\nStage: idea\n").contains("Deadline: 2026-12-01"))
        #expect(ProjectCardFile.setting(.deadline, to: "2026-12-01", in: "# A\n\nЭтап: идея\n").contains("Дедлайн: 2026-12-01"))
        #expect(ContentPlan.appending([.date: "2026-11-05", .topic: "Hi"], to: "", language: .en).hasPrefix("# Content plan\n\n| Date | Time | Platform |"))
        #expect(ContentPlan.parse(ContentPlan.appending([.date: "2026-11-05", .topic: "Hi"], to: "", language: .en)).rows.first?.value(.topic) == "Hi")
    }

    @Test func cardAndPlanFilesUnderEitherName() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "claudepult-en-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Coffee"), withIntermediateDirectories: true)
        try "# Coffee\nStage: script\nDeadline: 2026-11-05\nMain file: script.md\n".write(to: root.appending(path: "Coffee/project.md"), atomically: true, encoding: .utf8)
        try "one two three".write(to: root.appending(path: "Coffee/script.md"), atomically: true, encoding: .utf8)
        try "| Date | Topic |\n|---|---|\n| 2026-11-07 | Post |\n".write(to: root.appending(path: "content-plan.md"), atomically: true, encoding: .utf8)
        #expect(ProjectCardFile.path(in: root.appending(path: "Coffee").path).hasSuffix("/project.md"))
        let project = try #require(FolderScanner.scan(source: .folders(root.path)).first)
        #expect(project.card.stage == "script" && project.hasCardFile && project.words == 3)
        let mode = CalendarScanner.ModeInfo(id: "m", name: "Video", icon: "video", source: .folders(root.path), calendar: .contentPlan)
        #expect(CalendarScanner.entries(for: [mode]).map(\.title).sorted() == ["Coffee", "Post"])
    }
}
