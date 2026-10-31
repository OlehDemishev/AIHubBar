import Foundation
import Testing
@testable import ClaudePult

struct AIServiceTests {
    @Test func idsRoundTrip() {
        let all = AgentKind.allCases.map(AIService.agent) + APIProvider.allCases.map(AIService.api)
        for service in all { #expect(AIService(id: service.id) == service) }
        #expect(AIService.claudeCode.id == "claude-code")
        #expect(AIService(id: "agent:nope") == nil)
        #expect(AIService(id: "whatever") == nil)
    }

    @Test func modelsRequests() throws {
        let anthropic = try #require(APIProvider.anthropic.modelsRequest(baseURL: APIProvider.anthropic.defaultBaseURL, key: "sk-test-1234"))
        #expect(anthropic.url?.absoluteString == "https://api.anthropic.com/v1/models")
        #expect(anthropic.value(forHTTPHeaderField: "x-api-key") == "sk-test-1234")
        #expect(anthropic.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(anthropic.value(forHTTPHeaderField: "Authorization") == nil)

        let google = try #require(APIProvider.google.modelsRequest(baseURL: APIProvider.google.defaultBaseURL + "/", key: "g-key-1234"))
        #expect(google.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai/models")
        #expect(google.value(forHTTPHeaderField: "Authorization") == "Bearer g-key-1234")

        let local = try #require(APIProvider.compatible.modelsRequest(baseURL: "http://localhost:1234/v1", key: nil))
        #expect(local.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(APIProvider.compatible.modelsRequest(baseURL: "localhost", key: nil) == nil)
        #expect(APIProvider.allCases.filter { !$0.keyRequired } == [.compatible])
    }

    @Test func parsesModelLists() {
        let openAI = Data(#"{"object":"list","data":[{"id":"gpt-b"},{"id":"gpt-a"},{"id":"gpt-a"}]}"#.utf8)
        #expect(APIProvider.parseModels(openAI) == ["gpt-a", "gpt-b"])
        let bare = Data(#"[{"id":"mistral-large"},{"name":"no id"}]"#.utf8)
        #expect(APIProvider.parseModels(bare) == ["mistral-large"])
        let google = Data(#"{"data":[{"id":"models/gemini-pro"}]}"#.utf8)
        #expect(APIProvider.parseModels(google) == ["gemini-pro"])
        #expect(APIProvider.parseModels(Data("nope".utf8)) == nil)
    }

    @Test func checkResults() {
        let list = Data(#"{"data":[{"id":"m"}]}"#.utf8)
        #expect(APICheck.from(status: 200, body: list) == .ok(models: ["m"]))
        #expect(APICheck.from(status: 200, body: Data("<html>".utf8)) == .failed("Ответ в неизвестном формате"))
        #expect(APICheck.from(status: 401, body: Data()) == .badKey)
        // Google and xAI answer 400 for a bad key, with the key named in the message.
        #expect(APICheck.from(status: 400, body: Data(#"{"error":{"message":"Please pass a valid API key"}}"#.utf8)) == .badKey)
        #expect(APICheck.from(status: 400, body: Data(#"{"error":"bad model"}"#.utf8)) == .failed("Ошибка HTTP 400"))
        #expect(APICheck.from(status: 429, body: Data()) == .failed("Слишком много запросов (HTTP 429)"))
        #expect(APICheck.ok(models: ["a", "b"]).text == "Работает · моделей: 2")
    }

    @Test func keyValidation() {
        #expect(APIKeyStore.isValid("sk-proj-AbC_123.xyz"))
        #expect(APIKeyStore.isValid("abcDEF123._-~+/=:"))
        #expect(!APIKeyStore.isValid("short"))
        #expect(!APIKeyStore.isValid("has space 12345"))
        #expect(!APIKeyStore.isValid("quote\"12345678"))
        #expect(!APIKeyStore.isValid("ключ12345678"))
    }

    @Test func preferredModelSkipsNonChatModels() {
        #expect(AIServiceStore.preferredModel(["text-embedding-3", "tts-1", "gpt-x"]) == "gpt-x")
        #expect(AIServiceStore.preferredModel(["whisper-1"]) == nil)
    }

    @Test func agentDetectionAndTerminalLine() {
        let home = "/Users/test"
        #expect(AgentLocator.candidates("codex", home: home).contains("/Users/test/.local/bin/codex"))
        #expect(AgentKind.codex.detect { $0 == "/usr/local/bin/codex" } == "/usr/local/bin/codex")
        #expect(AgentKind.gemini.detect { _ in false } == nil)
        #expect(AgentKind.codex.terminalCommandLine(folder: "/P/My App", path: "/opt/homebrew/bin/codex")
            == "cd $'/P/My App' && $'/opt/homebrew/bin/codex'")
        #expect(Set(AgentKind.allCases.map(\.binary)).count == AgentKind.allCases.count)
    }

    @Test func servicesConfigIsTolerant() throws {
        let config = try JSONDecoder().decode(AIServicesConfig.self, from: Data(#"{"models":{"openai":"gpt-x"},"extra":1}"#.utf8))
        #expect(config.model(.openai) == "gpt-x")
        #expect(config.baseURL(.compatible) == APIProvider.compatible.defaultBaseURL)
        #expect(config.baseURL(.mistral) == "https://api.mistral.ai/v1")
        let mode = try JSONDecoder().decode(Mode.self, from: Data(#"{"name":"V","service":"api:openai"}"#.utf8))
        #expect(mode.service == "api:openai")
        #expect(try JSONDecoder().decode(Mode.self, from: Data(#"{"name":"V"}"#.utf8)).service == nil)
        #expect(try JSONDecoder().decode(Mode.self, from: Data(#"{"name":"V"}"#.utf8)).wordsPerMinute == 150)
        #expect(Mode(name: "V", stages: ["идея", "", "готово"]).stageList == ["идея", "готово"])
    }
}
