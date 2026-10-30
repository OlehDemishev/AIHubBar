import Foundation
import Testing
@testable import ClaudePult

struct CommandTextTests {
    let now = Date(timeIntervalSince1970: 1_793_300_000)

    var context: CommandContext {
        CommandContext(projectName: "Кофе", projectPath: "/V/Кофе", file: "текст/сценарий.md", format: "YouTube 8–10 мин",
                       platform: nil, duration: "8:00", text: "английский", now: now)
    }

    @Test func fillsPlaceholders() {
        #expect(CommandText.fill("{проект}: {файл}, {формат}, {площадка}, {хронометраж}, {язык}", context)
            == "Кофе: текст/сценарий.md, YouTube 8–10 мин, не указана, 8:00, английский")
    }

    @Test func outputNames() {
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd-HHmm"
            return f.string(from: now)
        }()
        #expect(CommandText.outputName("хуки.md", context) == "хуки.md")
        #expect(CommandText.outputName("сценарий-{язык}.md", context) == "сценарий-английский.md")
        #expect(CommandText.outputName("результат-<время>.md", context) == "результат-\(stamp).md")
        #expect(CommandText.outputName("конспект-<файл>", context) == "конспект-сценарий.md", "extension added")
        #expect(CommandText.outputName("a/b:c.md", context) == "a-b-c.md")
        #expect(CommandText.outputName(".md", context) == "результат.md")
        #expect(CommandText.outputName("хуки.md", context, suffix: "OpenAI") == "хуки (OpenAI).md")
    }

    @Test func neverOverwrites() {
        let existing: Set = ["хуки.md", "хуки-2.md"]
        #expect(CommandText.uniqueName("хуки.md") { existing.contains($0) } == "хуки-3.md")
        #expect(CommandText.uniqueName("новое.md") { existing.contains($0) } == "новое.md")
    }

    @Test func wrappersFollowTemplatesMD() {
        let agent = CommandText.agentPrompt(task: "Сделай хуки", context: context, output: "хуки.md")
        #expect(agent.contains("папке проекта «Кофе»"))
        #expect(agent.contains("ничего в них не меняй"))
        #expect(agent.contains("новый файл хуки.md"))
        #expect(agent.hasSuffix("Задача: Сделай хуки"))
        let api = CommandText.apiPrompt(task: "Сделай хуки", context: context, fileText: "ТЕКСТ")
        #expect(api.contains("Ниже — текст файла «текст/сценарий.md».\n---\nТЕКСТ\n---"))
        #expect(api.contains("Ответь только результатом в Markdown"))
        #expect(!CommandText.apiPrompt(task: "x", context: context, fileText: nil).contains("---"))
    }

    @Test func templatesAreTolerant() throws {
        let template = try JSONDecoder().decode(CommandTemplate.self, from: Data(#"{"title":"Хуки","task":"t","input":"nope"}"#.utf8))
        #expect(template.input == .mainFile)
        #expect(template.output == "результат-<время>.md")
        let mode = try JSONDecoder().decode(Mode.self, from: Data(#"{"name":"V","commands":[{"title":"Хуки"}]}"#.utf8))
        #expect(mode.commands.map(\.title) == ["Хуки"])
        #expect(CommandTemplate.customTask.asks != nil)
    }
}

struct APIClientTests {
    @Test func requests() throws {
        let anthropic = try #require(APIClient.request(.anthropic, baseURL: "https://api.anthropic.com/v1", key: "k-1234567", model: "m", prompt: "hi"))
        #expect(anthropic.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(anthropic.httpMethod == "POST")
        #expect(anthropic.value(forHTTPHeaderField: "x-api-key") == "k-1234567")
        let body = try #require(anthropic.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["model"] as? String == "m")
        #expect(body["max_tokens"] != nil)
        let openai = try #require(APIClient.request(.openai, baseURL: "https://api.openai.com/v1/", key: "k-1234567", model: "m", prompt: "hi"))
        #expect(openai.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(openai.value(forHTTPHeaderField: "Authorization") == "Bearer k-1234567")
        #expect(APIClient.request(.compatible, baseURL: "nope", key: nil, model: "m", prompt: "hi") == nil)
    }

    @Test func parsesReplies() {
        let anthropic = Data(#"{"content":[{"type":"text","text":"Привет"},{"type":"thinking","thinking":"x"}],"usage":{"input_tokens":10,"output_tokens":3}}"#.utf8)
        #expect(APIClient.parse(anthropic, provider: .anthropic) == .init(text: "Привет", inputTokens: 10, outputTokens: 3))
        let openai = Data(#"{"choices":[{"message":{"role":"assistant","content":"Ответ"}}],"usage":{"prompt_tokens":7,"completion_tokens":2}}"#.utf8)
        #expect(APIClient.parse(openai, provider: .deepseek) == .init(text: "Ответ", inputTokens: 7, outputTokens: 2))
        #expect(APIClient.parse(Data("{}".utf8), provider: .openai) == nil)
        #expect(APIClient.errorMessage(Data(#"{"error":{"message":"model not found"}}"#.utf8)) == "model not found")
        #expect(APIClient.errorMessage(Data(#"{"detail":"Invalid API Key"}"#.utf8)) == "Invalid API Key")
    }

    @Test func spendSummary() {
        let start = Date(timeIntervalSince1970: 1000)
        let records = [
            SpendRecord(date: Date(timeIntervalSince1970: 500), provider: .openai, model: "m", inputTokens: 999, outputTokens: 999),
            SpendRecord(date: Date(timeIntervalSince1970: 2000), provider: .openai, model: "m", inputTokens: 1_000_000, outputTokens: 500_000),
            SpendRecord(date: Date(timeIntervalSince1970: 3000), provider: .mistral, model: "m", inputTokens: 100, outputTokens: 100),
        ]
        let summary = SpendSummary.of(records, since: start, prices: ["openai": APIPrice(input: 2, output: 8)])
        #expect(summary.tokens == 1_500_200)
        #expect(summary.cost == 6.0, "only priced providers count")
        #expect(SpendSummary.of(records, since: start, prices: [:]).cost == nil)
    }
}

struct PermissionProfileTests {
    @Test func filesOnlyHasNoShellOrNetwork() throws {
        let rules = BackgroundPermissions.rules(.filesOnly)
        #expect(!rules.allow.contains { $0.hasPrefix("Bash") || $0.hasPrefix("Web") })
        #expect(rules.allow.contains("Edit(./**)"))
        #expect(Set(["Bash", "WebFetch", "WebSearch"]).isSubset(of: Set(rules.deny)))
        #expect(rules.deny.contains("Read(~/.ssh/**)"))
        let web = BackgroundPermissions.rules(.filesAndWeb)
        #expect(web.allow.contains("WebFetch") && web.deny.contains("Bash"))
        for profile in PermissionProfile.allCases {
            let object = try JSONSerialization.jsonObject(with: Data(BackgroundPermissions.settingsJSON(profile).utf8)) as? [String: Any]
            let permissions = try #require(object?["permissions"] as? [String: Any])
            #expect(permissions["blockReadsOutsideWorkingDirectories"] as? Bool == true)
        }
        let args = BackgroundPermissions.arguments(prompt: "p", sessionID: "s", profile: .filesOnly)
        #expect(args.contains("dontAsk"))
        #expect(args.last?.contains("\"Bash\"") == true)
    }

    @Test func oldRunsDecodeWithoutResultFile() throws {
        let json = #"{"id":"a","project":"P","projectPath":"/P","folder":"/P","commandTitle":"t","task":"t","startedAt":0,"timeLimitMinutes":90,"state":"running","notified":false}"#
        let run = try JSONDecoder().decode(BackgroundRun.self, from: Data(json.utf8))
        #expect(run.resultFile == nil)
    }
}
