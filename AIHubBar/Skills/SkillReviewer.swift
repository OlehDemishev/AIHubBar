import Foundation

/// Sending a review request (`SkillReview.request`) to a model and getting the text back. Port of
/// `desktop/skill-catalog/src/reviewer.rs`. Two ways, both with no tools:
///
/// - Claude Code, `claude -p`: the person's own subscription. `--tools ""` gives the model nothing to act with,
///   `--setting-sources ""` and `--strict-mcp-config` keep the person's hooks, settings and MCP servers out,
///   `--no-session-persistence` keeps no transcript, and it runs in an empty folder so no CLAUDE.md is read. The
///   instructions go in a file and the skill on stdin: nothing of the skill is on a command line.
/// - The Anthropic API with the person's key (Settings → «Сервисы AI»), structured output fixing the answer's shape.
///
/// Either answer is then read strictly by `SkillReview.parse`.
enum SkillReviewer {
    /// The model asked unless the person chose another.
    static let defaultModel = "claude-opus-5-5"
    static let timeout: Duration = .seconds(600)
    static let api = URL(string: "https://api.anthropic.com/v1/messages")!

    struct Answer: Equatable, Sendable {
        var text: String
        var model: String
        var inputTokens: Int
        var outputTokens: Int
    }

    /// The answer's shape for the API's structured output. The strict reading afterwards stays: the answer is untrusted.
    static var schema: [String: Any] {
        let severity: [String: Any] = ["type": "string", "enum": ["low", "medium", "high", "critical"]]
        let finding: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["file", "line", "severity", "title", "explanation"],
            "properties": ["file": ["type": "string"], "line": ["type": "integer"], "severity": severity, "title": ["type": "string"], "explanation": ["type": "string"]],
        ]
        return [
            "type": "object", "additionalProperties": false, "required": ["verdict", "summary", "findings"],
            "properties": ["verdict": ["type": "string", "enum": ["safe", "review", "dangerous"]], "summary": ["type": "string"], "findings": ["type": "array", "items": finding]],
        ]
    }

    /// One request to a model: standing instructions, the data, and the answer's shape. A review is one; the plain-words
    /// search and the translations (`SkillAsk`) are others.
    struct Prompt: Equatable, Sendable {
        var system: String
        var user: String
        /// The answer's JSON schema, serialized (a dictionary is not `Sendable`).
        var schema: Data
        var effort = "high"
        var maxTokens = 16000
        /// The API tries its fallback model on a refusal. Not for Haiku, which has none.
        var fallbacks = true
    }

    static func prompt(_ request: SkillReview.Request) -> Prompt {
        Prompt(system: request.system, user: request.user, schema: (try? JSONSerialization.data(withJSONObject: schema)) ?? Data())
    }

    /// The Messages API request body. Thinking stays as the model has it (adaptive); a review's effort is high, since a
    /// missed attack costs more than the tokens. On a refusal the API tries the fallback model in the same call.
    static func apiBody(_ prompt: Prompt, model: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": prompt.maxTokens,
            "system": prompt.system,
            "messages": [["role": "user", "content": prompt.user]],
            "output_config": ["effort": prompt.effort, "format": ["type": "json_schema", "schema": (try? JSONSerialization.jsonObject(with: prompt.schema)) ?? [:]]],
        ]
        if prompt.fallbacks { body["fallbacks"] = "default" }
        return body
    }

    static func apiBody(_ request: SkillReview.Request, model: String) -> [String: Any] { apiBody(prompt(request), model: model) }

    /// The text of an API answer, or a short reason. A refusal or an answer cut at the token limit is no answer.
    static func apiAnswer(_ body: Data, model: String) -> Swift.Result<Answer, SkillCatalog.Refusal> {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return .failure(.init(code: "unreadable")) }
        switch root["stop_reason"] as? String {
        case "refusal": return .failure(.init(code: "refusal"))
        case "max_tokens": return .failure(.init(code: "too-long"))
        default: break
        }
        let text = ((root["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        let usage = root["usage"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        return .success(Answer(text: text, model: root["model"] as? String ?? model,
                               inputTokens: int("input_tokens") + int("cache_creation_input_tokens") + int("cache_read_input_tokens"), outputTokens: int("output_tokens")))
    }

    /// Asks the Anthropic API. The key is sent in its header and nowhere else, never logged.
    static func viaAPI(_ request: SkillReview.Request, key: String, model: String) async -> Swift.Result<Answer, SkillCatalog.Refusal> {
        await viaAPI(prompt(request), key: key, model: model)
    }

    static func viaAPI(_ prompt: Prompt, key: String, model: String) async -> Swift.Result<Answer, SkillCatalog.Refusal> {
        var http = URLRequest(url: api, timeoutInterval: 600)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("AIHubBar", forHTTPHeaderField: "User-Agent")
        http.setValue(key, forHTTPHeaderField: "x-api-key")
        http.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if prompt.fallbacks { http.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        http.httpBody = try? JSONSerialization.data(withJSONObject: apiBody(prompt, model: model))
        guard let (data, response) = try? await URLSession.shared.data(for: http), let status = (response as? HTTPURLResponse)?.statusCode else {
            return .failure(.init(code: "network"))
        }
        switch status {
        case 200..<300: return apiAnswer(data, model: model)
        case 401, 403: return .failure(.init(code: "bad-key"))
        default:
            let message = APIClient.errorMessage(data)
            return .failure(.init(code: "HTTP \(status)" + (message.isEmpty ? "" : ": \(message)")))
        }
    }

    /// `claude`'s arguments. The skill itself is not among them: it goes on stdin.
    static func claudeArguments(systemFile: String, model: String) -> [String] {
        ["-p", "--tools", "", "--output-format", "json", "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config",
         "--disable-slash-commands", "--model", model, "--system-prompt-file", systemFile]
    }

    /// The text of `claude -p --output-format json`'s one result object.
    static func claudeAnswer(_ stdout: String, model: String) -> Swift.Result<Answer, SkillCatalog.Refusal> {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(stdout.trimmingCharacters(in: .whitespacesAndNewlines).utf8))) as? [String: Any] else {
            return .failure(.init(code: "unreadable"))
        }
        if root["is_error"] as? Bool == true || (root["subtype"] as? String).map({ $0 != "success" }) == true {
            return .failure(.init(code: String(((root["result"] as? String) ?? "error").prefix(200))))
        }
        let usage = root["usage"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        // When a model declined and Claude Code fell back to another, both are listed: the one that wrote the answer is
        // the one that wrote the most.
        let used = (root["modelUsage"] as? [String: [String: Any]])?.max { a, b in
            ((a.value["outputTokens"] as? NSNumber)?.intValue ?? 0) < ((b.value["outputTokens"] as? NSNumber)?.intValue ?? 0)
        }?.key ?? model
        return .success(Answer(text: root["result"] as? String ?? "", model: used,
                               inputTokens: int("input_tokens") + int("cache_creation_input_tokens") + int("cache_read_input_tokens"), outputTokens: int("output_tokens")))
    }

    /// Asks Claude Code. `scratch` is a folder of the app's own, emptied for each review.
    static func viaClaude(_ request: SkillReview.Request, program: String, scratch: URL, model: String) async -> Swift.Result<Answer, SkillCatalog.Refusal> {
        await viaClaude(prompt(request), program: program, scratch: scratch, model: model)
    }

    static func viaClaude(_ prompt: Prompt, program: String, scratch: URL, model: String) async -> Swift.Result<Answer, SkillCatalog.Refusal> {
        let manager = FileManager.default
        try? manager.removeItem(at: scratch)
        defer { try? manager.removeItem(at: scratch) }
        let folder = scratch.appending(path: "work")
        let systemFile = scratch.appending(path: "instructions.txt")
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try prompt.system.write(to: systemFile, atomically: true, encoding: .utf8)
        } catch {
            return .failure(.init(code: error.localizedDescription))
        }
        do {
            let result = try await ProcessRunner.run(program, claudeArguments(systemFile: systemFile.path, model: model), currentDirectory: folder,
                                                     input: Data(prompt.user.utf8), timeout: timeout)
            return claudeAnswer(result.stdoutText, model: model)
        } catch ProcessError.timedOut {
            return .failure(.init(code: "timeout"))
        } catch {
            return .failure(.init(code: "no-claude"))
        }
    }

    /// Who reviews: Claude Code when it is installed (the person's subscription, no key), else the Anthropic API with
    /// the key kept in Settings → «Сервисы AI».
    enum Who: Equatable, Sendable {
        case claudeCode(String)
        case api(String)

        var via: String {
            switch self {
            case .claudeCode: "claude-code"
            case .api: "api"
            }
        }
    }

    /// Sends a prompt the way `who` can: Claude Code in an empty folder of its own, or the API.
    static func ask(_ prompt: Prompt, who: Who, model: String, scratch: URL) async -> Swift.Result<Answer, SkillCatalog.Refusal> {
        switch who {
        case .claudeCode(let program): await viaClaude(prompt, program: program, scratch: scratch, model: model)
        case .api(let key): await viaAPI(prompt, key: key, model: model)
        }
    }

    static func who() async -> Who? {
        if let claude = AgentLocator.detect("claude") { return .claudeCode(claude) }
        if let key = await APIKeyStore.read(.anthropic), !key.trimmingCharacters(in: .whitespaces).isEmpty { return .api(key) }
        return nil
    }

    /// Whether anything can review, without reading the key (no Keychain prompt): `claude-code`, `api` or nil.
    static func available() async -> String? {
        if AgentLocator.detect("claude") != nil { return "claude-code" }
        return await APIKeyStore.exists(.anthropic) ? "api" : nil
    }

    /// The interface language's English name, for the reviewer's explanations: «Russian», «German».
    static var languageName: String {
        Locale(identifier: "en").localizedString(forIdentifier: languageCode) ?? "English"
    }

    /// The interface language's code: «ru», «pt-BR».
    static var languageCode: String { Bundle.main.preferredLocalizations.first ?? "en" }
}
