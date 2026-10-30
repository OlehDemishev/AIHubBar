import Foundation

/// An AI service a mode can work with (SPEC-modes §11): an agent CLI that works on the project folder, or a model
/// behind an API that only gets text. Stored by `id` (`claude-code`, `agent:codex`, `api:openai`).
enum AIService: Hashable, Sendable {
    case agent(AgentKind)
    case api(APIProvider)

    static let claudeCode = AIService.agent(.claudeCode)

    var id: String {
        switch self {
        case .agent(.claudeCode): "claude-code"
        case let .agent(kind): "agent:" + kind.rawValue
        case let .api(provider): "api:" + provider.rawValue
        }
    }

    init?(id: String) {
        if id == "claude-code" { self = .claudeCode; return }
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "agent": guard let kind = AgentKind(rawValue: parts[1]) else { return nil }; self = .agent(kind)
        case "api": guard let provider = APIProvider(rawValue: parts[1]) else { return nil }; self = .api(provider)
        default: return nil
        }
    }

    var title: String {
        switch self {
        case let .agent(kind): kind.title
        case let .api(provider): provider.title + " (API)"
        }
    }

    /// For result names in a comparison: `хуки (Claude).md`, `хуки (OpenAI).md`.
    func shortName(compatibleName: String = "") -> String {
        switch self {
        case let .agent(kind):
            switch kind {
            case .claudeCode: "Claude"
            case .codex: "Codex"
            case .gemini: "Gemini CLI"
            case .antigravity: "Antigravity"
            case .copilot: "Copilot"
            case .cursor: "Cursor"
            }
        case let .api(provider):
            switch provider {
            case .anthropic: "Claude API"
            case .openai: "OpenAI"
            case .google: "Gemini"
            case .xai: "Grok"
            case .deepseek: "DeepSeek"
            case .mistral: "Mistral"
            case .compatible: compatibleName.isEmpty ? "Local" : compatibleName
            }
        }
    }
}

// MARK: - Agents

/// Agent CLIs. Flags were checked against their documentation on 2026-10-30 (DECISIONS.md); only Claude Code
/// runs in the background — the others open in Terminal until their permission flags are checked live.
enum AgentKind: String, CaseIterable, Codable, Sendable {
    case claudeCode = "claude"
    case codex
    case gemini
    case antigravity
    case copilot
    case cursor

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "OpenAI Codex CLI"
        case .gemini: "Google Gemini CLI"
        case .antigravity: "Google Antigravity CLI"
        case .copilot: "GitHub Copilot CLI"
        case .cursor: "Cursor CLI"
        }
    }

    var binary: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        case .antigravity: "agy"
        case .copilot: "copilot"
        case .cursor: "cursor-agent"
        }
    }

    var install: String {
        switch self {
        case .claudeCode: "npm install -g @anthropic-ai/claude-code"
        case .codex: "brew install --cask codex"
        case .gemini: "brew install gemini-cli"
        case .antigravity: String(localized: "см. README Gemini CLI (раздел про Antigravity)")
        case .copilot: "brew install --cask copilot-cli"
        case .cursor: String(localized: "см. cursor.com/cli")
        }
    }

    /// How the agent signs in; ClaudePult never touches their tokens.
    var login: String {
        switch self {
        case .claudeCode: "claude → /login"
        case .codex: "codex login"
        case .gemini: "gemini → Sign in with Google"
        case .antigravity: "agy"
        case .copilot: "copilot login"
        case .cursor: "cursor-agent login"
        }
    }

    var note: String? {
        switch self {
        case .gemini: String(localized: "Для Code Assist и платных ключей API. Бесплатный вход и Google AI Pro/Ultra с июня 2026 — в Antigravity CLI.")
        default: nil
        }
    }

    var versionArguments: [String] { ["--version"] }

    static func candidates(_ binary: String, home: String = NSHomeDirectory()) -> [String] {
        [
            "/opt/homebrew/bin/\(binary)",
            "/usr/local/bin/\(binary)",
            "\(home)/.local/bin/\(binary)",
            "\(home)/.npm-global/bin/\(binary)",
            "\(home)/.bun/bin/\(binary)",
        ] + (binary == "claude" ? ["\(home)/.claude/local/claude"] : [])
    }

    func detect(isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        Self.candidates(binary).first(where: isExecutable)
    }

    /// `cd <folder> && <agent>` — opens the agent in Terminal in the project folder.
    func terminalCommandLine(folder: String, path: String) -> String {
        "cd \(ShellQuote.quote(folder)) && \(ShellQuote.quote(path))"
    }
}

// MARK: - API models

/// Models behind an API key. Endpoints checked on 2026-10-30 against the docs and by an unauthenticated request
/// (every one answers «bad key», not «not found»).
enum APIProvider: String, CaseIterable, Codable, Sendable {
    case anthropic, openai, google, xai, deepseek, mistral, compatible

    var title: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .google: "Google Gemini"
        case .xai: "xAI Grok"
        case .deepseek: "DeepSeek"
        case .mistral: "Mistral"
        case .compatible: String(localized: "Совместимый с OpenAI")
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: "https://api.anthropic.com/v1"
        case .openai: "https://api.openai.com/v1"
        case .google: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .xai: "https://api.x.ai/v1"
        case .deepseek: "https://api.deepseek.com"
        case .mistral: "https://api.mistral.ai/v1"
        case .compatible: "http://localhost:11434/v1"
        }
    }

    /// Where to create a key.
    var keyPage: String? {
        switch self {
        case .anthropic: "https://console.anthropic.com/settings/keys"
        case .openai: "https://platform.openai.com/api-keys"
        case .google: "https://aistudio.google.com/apikey"
        case .xai: "https://console.x.ai"
        case .deepseek: "https://platform.deepseek.com/api_keys"
        case .mistral: "https://console.mistral.ai/api-keys"
        case .compatible: nil
        }
    }

    /// Local servers (Ollama, LM Studio) work without a key.
    var keyRequired: Bool { self != .compatible }

    /// Lists models: costs no tokens, so it is also the key check.
    func modelsRequest(baseURL: String, key: String?) -> URLRequest? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/models"), url.scheme?.hasPrefix("http") == true else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudePult", forHTTPHeaderField: "User-Agent")
        if let key, !key.isEmpty {
            if self == .anthropic {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    /// `{"data": [{"id": …}]}`, or a bare array (Mistral's example); Google's ids may come as `models/…`.
    static func parseModels(_ data: Data) -> [String]? {
        let object = try? JSONSerialization.jsonObject(with: data)
        let items = (object as? [String: Any])?["data"] as? [Any] ?? object as? [Any]
        guard let items else { return nil }
        let ids = items.compactMap { ($0 as? [String: Any])?["id"] as? String }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 }
        return Array(Set(ids)).sorted()
    }
}

/// The result of «Проверить».
enum APICheck: Equatable, Sendable {
    case ok(models: [String])
    case badKey
    case noKey
    case failed(String)

    var text: String {
        switch self {
        case let .ok(models): models.isEmpty ? String(localized: "Работает") : String(localized: "Работает · моделей: \(models.count)")
        case .badKey: String(localized: "Ключ не подошёл")
        case .noKey: String(localized: "Нет ключа")
        case let .failed(reason): reason
        }
    }

    /// 400 and 403 come back for a bad key too (Google, xAI), with the key named in the message.
    static func from(status: Int, body: Data) -> APICheck {
        switch status {
        case 200..<300:
            guard let models = APIProvider.parseModels(body) else { return .failed(String(localized: "Ответ в неизвестном формате")) }
            return .ok(models: models)
        case 401: return .badKey
        case 400, 403:
            let text = String(decoding: body.prefix(2000), as: UTF8.self).lowercased()
            return text.contains("key") || text.contains("auth") ? .badKey : .failed(String(localized: "Ошибка HTTP \(status)"))
        case 429: return .failed(String(localized: "Слишком много запросов (HTTP 429)"))
        default: return .failed(String(localized: "Ошибка HTTP \(status)"))
        }
    }
}

/// Per-provider choices that go into exports (never the keys).
struct AIServicesConfig: Codable, Equatable, Sendable {
    /// provider raw value → chosen model id.
    var models: [String: String] = [:]
    var compatibleBaseURL: String = APIProvider.compatible.defaultBaseURL
    /// A name for the compatible server, e.g. «Ollama» or «OpenRouter».
    var compatibleName: String = ""
    /// provider raw value → dollars per million tokens, as entered by the person.
    var prices: [String: APIPrice] = [:]
    /// Dollars per month; a notification at 80 % and 100 %.
    var monthlyBudget: Double?

    func model(_ provider: APIProvider) -> String? { models[provider.rawValue] }

    func baseURL(_ provider: APIProvider) -> String {
        provider == .compatible ? compatibleBaseURL : provider.defaultBaseURL
    }

    init() {}

    enum CodingKeys: String, CodingKey { case models, compatibleBaseURL, compatibleName, prices, monthlyBudget }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = (try? c.decodeIfPresent([String: String].self, forKey: .models)) ?? [:]
        compatibleBaseURL = (try? c.decodeIfPresent(String.self, forKey: .compatibleBaseURL)) ?? APIProvider.compatible.defaultBaseURL
        compatibleName = (try? c.decodeIfPresent(String.self, forKey: .compatibleName)) ?? ""
        prices = (try? c.decodeIfPresent([String: APIPrice].self, forKey: .prices)) ?? [:]
        monthlyBudget = try? c.decodeIfPresent(Double.self, forKey: .monthlyBudget)
    }
}
