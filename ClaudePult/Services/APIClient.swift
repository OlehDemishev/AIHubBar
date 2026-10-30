import Foundation

/// One text request to a model by API (SPEC-modes §11): Anthropic Messages, or OpenAI-style chat completions for the
/// others. Endpoints were checked on 2026-10-30 (each answers «bad key» to an invalid one, not «not found»).
enum APIClient {
    struct Reply: Equatable, Sendable {
        var text: String
        var inputTokens: Int
        var outputTokens: Int
    }

    enum APIError: LocalizedError, Equatable {
        case noKey, noModel, badKey, badURL
        case http(Int, String)
        case emptyReply
        case network(String)

        var errorDescription: String? {
            switch self {
            case .noKey: String(localized: "Нет ключа API — Настройки → «Сервисы AI»")
            case .noModel: String(localized: "Не выбрана модель — Настройки → «Сервисы AI» → «Проверить»")
            case .badKey: String(localized: "Ключ не подошёл")
            case .badURL: String(localized: "Неверный адрес сервера")
            case let .http(code, message): String(localized: "Ошибка HTTP \(code)") + (message.isEmpty ? "" : ": \(message)")
            case .emptyReply: String(localized: "Модель вернула пустой ответ")
            case let .network(message): String(localized: "Нет связи: \(message)")
            }
        }
    }

    static func request(_ provider: APIProvider, baseURL: String, key: String?, model: String, prompt: String) -> URLRequest? {
        let base = baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let anthropic = provider == .anthropic
        guard let url = URL(string: base + (anthropic ? "/messages" : "/chat/completions")), url.scheme?.hasPrefix("http") == true else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ClaudePult", forHTTPHeaderField: "User-Agent")
        if let key, !key.isEmpty {
            if anthropic {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        if anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        var body: [String: Any] = ["model": model, "messages": [["role": "user", "content": prompt]]]
        if anthropic { body["max_tokens"] = 16_000 }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Anthropic: `content[].text`, `usage.input_tokens/output_tokens`; others: `choices[0].message.content`,
    /// `usage.prompt_tokens/completion_tokens`.
    static func parse(_ data: Data, provider: APIProvider) -> Reply? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let usage = object["usage"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        if provider == .anthropic {
            let parts = (object["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            guard !parts.isEmpty else { return nil }
            return Reply(text: parts.joined(separator: "\n"), inputTokens: int("input_tokens"), outputTokens: int("output_tokens"))
        }
        guard let choices = object["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else { return nil }
        return Reply(text: text, inputTokens: int("prompt_tokens"), outputTokens: int("completion_tokens"))
    }

    /// The server's own words for an error, short.
    static func errorMessage(_ data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data)
        let message = ((object as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            ?? (object as? [String: Any])?["detail"] as? String
            ?? ((object as? [String: Any])?["error"] as? String)
        return String((message ?? "").prefix(200))
    }

    static func complete(_ provider: APIProvider, config: AIServicesConfig, prompt: String) async throws -> Reply {
        let key = await APIKeyStore.read(provider)
        if provider.keyRequired, key == nil { throw APIError.noKey }
        guard let model = config.model(provider) else { throw APIError.noModel }
        guard let request = request(provider, baseURL: config.baseURL(provider), key: key, model: model, prompt: prompt) else {
            throw APIError.badURL
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if case .badKey = APICheck.from(status: status, body: data) { throw APIError.badKey }
            throw APIError.http(status, errorMessage(data))
        }
        guard let reply = parse(data, provider: provider), !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.emptyReply
        }
        return reply
    }
}

/// Tokens ClaudePult spent through APIs (SPEC-modes §11.2), kept in `api-spend.json`; costs from the prices the person
/// entered per provider (prices change too often to ship them).
struct SpendRecord: Codable, Equatable, Sendable {
    var date: Date
    var provider: APIProvider
    var model: String
    var inputTokens: Int
    var outputTokens: Int
}

struct SpendSummary: Equatable, Sendable {
    var inputTokens = 0
    var outputTokens = 0
    var cost: Double?

    var tokens: Int { inputTokens + outputTokens }

    static func of(_ records: [SpendRecord], since start: Date, prices: [String: APIPrice]) -> SpendSummary {
        var summary = SpendSummary()
        var cost = 0.0
        var priced = false
        for record in records where record.date >= start {
            summary.inputTokens += record.inputTokens
            summary.outputTokens += record.outputTokens
            if let price = prices[record.provider.rawValue] {
                priced = true
                cost += Double(record.inputTokens) / 1_000_000 * price.input + Double(record.outputTokens) / 1_000_000 * price.output
            }
        }
        summary.cost = priced ? cost : nil
        return summary
    }
}

/// Dollars per million tokens.
struct APIPrice: Codable, Equatable, Hashable, Sendable {
    var input: Double
    var output: Double
}
