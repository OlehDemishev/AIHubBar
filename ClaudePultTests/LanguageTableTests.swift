import Foundation
import Testing
@testable import ClaudePult

/// Every language in `ContentLanguage` must be complete — this is what adding a language is checked against.
struct LanguageTableTests {
    @Test(arguments: ContentLanguage.allCases)
    func everyLanguageIsComplete(_ language: ContentLanguage) {
        let words = language.strings
        #expect(Set(words.cardLabels.keys) == Set(ProjectCardFile.Key.allCases), "\(language)")
        #expect(Set(words.planColumns.keys) == Set(ContentPlan.Column.allCases), "\(language)")
        for placeholder in ["{project}", "{file}", "{output}", "{task}"] {
            #expect(words.agentPrompt.contains(placeholder), "\(language) agentPrompt \(placeholder)")
        }
        #expect(words.apiHeader.contains("{project}") && words.apiHeader.contains("{format}"))
        #expect(words.apiFileIntro.contains("{file}") && words.apiTask.contains("{task}") && words.customTask.contains("{task}"))
        #expect(words.customTask.hasPrefix(words.taskPrefix))
        #expect(words.customTask.contains(words.rulesMarker))
        #expect(words.cardFile.hasSuffix(".md") && words.planFile.hasSuffix(".md"))
        // A card written in this language is recognised as this language and parsed back.
        let card = ProjectCardFile.template(name: "X", stage: "s1", language: language)
        #expect(ProjectCardFile.parse(card).stage == "s1")
        #expect(ProjectCardFile.language(of: card.components(separatedBy: "\n")) == language)
        let plan = ContentPlan.appending([.date: "2026-11-05", .topic: "T"], to: "", language: language)
        #expect(ContentPlan.parse(plan).rows.first?.value(.topic) == "T")
        // Session titles come back from the generic prompts.
        #expect(Session.taskTitle(ClaudeCommand.customTask("Arregla").prompt(.generic, language: language)) == "Arregla")
    }

    @Test func templatesExistForEveryLanguage() {
        let ids = ModeTemplate.loadAll(language: .ru).map(\.id)
        for language in ContentLanguage.allCases {
            let templates = ModeTemplate.loadAll(language: language)
            #expect(templates.map(\.id) == ids)
            #expect(templates.allSatisfy { $0.language == language.rawValue }, "\(language) has its own template files")
        }
    }

    @Test func spanish() throws {
        let video = try #require(ModeTemplate.loadAll(language: .es).first { $0.id == "video" })
        #expect(video.mode.name == "Vídeo" && video.mode.stages.first == "idea")
        #expect(video.mode.commands.first?.title == "Ganchos")
        let card = ProjectCardFile.setting(.deadline, to: "2026-12-01", in: "# A\n\nEtapa: guion\n")
        #expect(card.contains("Fecha límite: 2026-12-01"))
        #expect(ProjectCardFile.parse(card).deadline != nil)
        #expect(ProjectCardFile.fileNames.contains("proyecto.md") && ContentPlan.fileNames.contains("plan-de-contenido.md"))
        let context = CommandContext(projectName: "Café", projectPath: "/V", file: nil, format: nil, platform: nil, duration: nil, text: nil)
        #expect(CommandText.agentPrompt(task: "x", context: context, output: "a.md", language: .es).contains("no modifiques ninguno"))
        #expect(CommandText.outputName("", context, language: .es) == "resultado.md")
        #expect(Bundle.main.localizations.contains("es"))
    }

    @Test func everyLanguageShipsItsInterface() {
        for language in ContentLanguage.allCases where language != .ru {
            #expect(Bundle.main.localizations.contains(language.rawValue), "\(language.rawValue).lproj")
        }
    }
}
