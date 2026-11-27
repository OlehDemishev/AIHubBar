import Foundation

/// «Экономика AI»: public list prices of the models behind an API, to compare what one task would cost with each.
///
/// The prices are not shipped with the app (DECISIONS, «API»: they change). They are downloaded from models.dev — an
/// open list under the MIT licence, dollars per million tokens — when the person opens the window, and kept in
/// `model-prices.json` until the next day. The prices a person enters per provider in Settings stay what the app's
/// own spend is counted with; this list is only for comparing.
struct ModelPrice: Codable, Equatable, Identifiable, Sendable {
    /// `APIProvider.rawValue`.
    var provider: String
    /// The model's id as the provider's API takes it.
    var model: String
    var name: String
    /// Dollars per million tokens.
    var input: Double
    var output: Double
    var cacheRead: Double?
    var cacheWrite: Double?
    /// The context window, in tokens.
    var context: Int?
    /// `yyyy-MM-dd`.
    var released: String?

    var id: String { provider + "/" + model }
    var providerTitle: String { APIProvider(rawValue: provider)?.title ?? provider }

    /// What `tokens` would cost. A provider that names no cache price is counted as the app counts elsewhere
    /// (`UsageDay.cost`): a cache read at a tenth of the input price, a cache write a quarter above it.
    func cost(_ tokens: TaskTokens) -> Double {
        let read = cacheRead ?? input * 0.1
        let write = cacheWrite ?? input * 1.25
        let sum = Double(tokens.input) * input + Double(tokens.cacheRead) * read
            + Double(tokens.cacheWrite) * write + Double(tokens.output) * output
        return sum / 1_000_000
    }
}

/// The tokens of one piece of work, split the way the providers bill them.
struct TaskTokens: Equatable, Sendable {
    var input = 0
    var cacheRead = 0
    var cacheWrite = 0
    var output = 0

    var isEmpty: Bool { input + cacheRead + cacheWrite + output == 0 }

    /// The person's own Claude Code tokens of these days.
    static func of(_ days: [UsageDay]) -> TaskTokens {
        days.reduce(into: TaskTokens()) { sum, day in
            sum.input += day.input
            sum.cacheRead += day.cacheRead
            sum.cacheWrite += day.cacheWrite
            sum.output += day.output
        }
    }
}

/// Three sizes of work to price a model with. The numbers are an assumption, not a measurement: an agent rereads its
/// context at every step, so most of a long task is cache reads. They are shown in the window beside the choice.
enum TaskSize: String, CaseIterable, Identifiable, Sendable {
    /// One question with a short answer, nothing cached.
    case question
    /// An agent's task of about twenty steps: a fix with its tests.
    case task
    /// A long agent session: a feature across many files.
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .question: String(localized: "Вопрос")
        case .task: String(localized: "Задача агента")
        case .large: String(localized: "Большая задача")
        }
    }

    var tokens: TaskTokens {
        switch self {
        case .question: TaskTokens(input: 3_000, output: 1_000)
        case .task: TaskTokens(input: 40_000, cacheRead: 1_200_000, cacheWrite: 80_000, output: 12_000)
        case .large: TaskTokens(input: 200_000, cacheRead: 9_000_000, cacheWrite: 500_000, output: 80_000)
        }
    }
}

/// The downloaded list as it is kept on disk.
struct ModelPriceList: Codable, Equatable, Sendable {
    var fetchedAt: Date
    var models: [ModelPrice]

    /// A day: list prices change a few times a year, and the download is seven megabytes before compression.
    static let lifetime: TimeInterval = 24 * 3600

    func isStale(now: Date) -> Bool { now.timeIntervalSince(fetchedAt) > Self.lifetime }
}

/// Reads models.dev's `api.json`: `{provider id: {"models": {model id: {...}}}}`, cost in dollars per million tokens.
enum ModelPriceParser {
    static let sourceURL = URL(string: "https://models.dev/api.json")!
    static let sourcePage = URL(string: "https://models.dev")!

    /// The app's providers under models.dev's ids. Only a provider's own API is taken — the same model resold by a
    /// cloud is another price list. Alibaba, Moonshot, Z.ai and MiniMax: the international entries, as the app's
    /// endpoints are (`APIProvider.defaultBaseURL`).
    static let sources: [(provider: APIProvider, id: String)] = [
        (.anthropic, "anthropic"), (.openai, "openai"), (.google, "google"), (.xai, "xai"), (.deepseek, "deepseek"),
        (.mistral, "mistral"), (.qwen, "alibaba"), (.kimi, "moonshotai"), (.glm, "zai"), (.minimax, "minimax"),
    ]

    /// Text models that take tools and have a price: what an agent or a command could run on. Embeddings, image and
    /// audio models and the ones the provider has retired are left out. Sorted by provider, newest first.
    static func parse(_ data: Data) -> [ModelPrice] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var found: [ModelPrice] = []
        for source in sources {
            let models = (root[source.id] as? [String: Any])?["models"] as? [String: Any] ?? [:]
            for (key, value) in models {
                guard let entry = value as? [String: Any], let price = price(entry, key: key, provider: source.provider) else { continue }
                found.append(price)
            }
        }
        let order = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1.provider.rawValue, $0) })
        return found.sorted {
            if $0.provider != $1.provider { return (order[$0.provider] ?? 0) < (order[$1.provider] ?? 0) }
            if $0.released != $1.released { return ($0.released ?? "") > ($1.released ?? "") }
            return $0.model < $1.model
        }
    }

    private static func price(_ entry: [String: Any], key: String, provider: APIProvider) -> ModelPrice? {
        guard let cost = entry["cost"] as? [String: Any],
              let input = number(cost["input"]), let output = number(cost["output"]), input > 0, output > 0,
              entry["tool_call"] as? Bool == true,
              entry["status"] as? String != "deprecated" else { return nil }
        let modalities = entry["modalities"] as? [String: Any]
        guard (modalities?["output"] as? [String])?.contains("text") == true else { return nil }
        let model = entry["id"] as? String ?? key
        return ModelPrice(
            provider: provider.rawValue, model: model, name: entry["name"] as? String ?? model,
            input: input, output: output,
            cacheRead: number(cost["cache_read"]), cacheWrite: number(cost["cache_write"]),
            context: number((entry["limit"] as? [String: Any])?["context"]).map(Int.init),
            released: entry["release_date"] as? String
        )
    }

    private static func number(_ value: Any?) -> Double? {
        // A JSON `true` is an NSNumber too; a price is never a boolean.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}

/// One line of the «Экономика AI» table: a model with what the chosen task and the person's month would cost.
struct ModelPriceRow: Identifiable, Equatable, Sendable {
    var price: ModelPrice
    /// The chosen task at this model's prices, in dollars.
    var taskCost: Double
    /// The person's own tokens of the last 30 days at this model's prices; zero when there are none.
    var monthCost: Double

    var id: String { price.id }
    // Plain values for the table's sorting.
    var name: String { price.name }
    var providerTitle: String { price.providerTitle }
    var input: Double { price.input }
    var output: Double { price.output }
    var context: Int { price.context ?? 0 }
    var released: String { price.released ?? "" }

    /// `since` (`yyyy-MM-dd`): only models released on that day or later; a model without a date is then left out.
    static func rows(_ models: [ModelPrice], task: TaskTokens, month: TaskTokens, provider: String?, search: String, since: String? = nil) -> [ModelPriceRow] {
        let words = search.lowercased().split(separator: " ")
        return models.compactMap { model in
            if let provider, model.provider != provider { return nil }
            if let since, (model.released ?? "") < since { return nil }
            let text = (model.name + " " + model.model + " " + model.providerTitle).lowercased()
            guard words.allSatisfy({ text.contains($0) }) else { return nil }
            return ModelPriceRow(price: model, taskCost: model.cost(task), monthCost: model.cost(month))
        }
    }

    /// A year back from `now`, as models.dev writes dates: the window's «only recent models».
    static func yearAgo(from now: Date, calendar: Calendar = .current) -> String {
        UsageDays.formatter.string(from: calendar.date(byAdding: .year, value: -1, to: now) ?? now)
    }

    /// Small sums keep their cents: a question costs fractions of a cent, a month — hundreds of dollars.
    static func money(_ dollars: Double) -> String {
        let digits = dollars >= 100 ? 0 : dollars >= 1 ? 2 : dollars >= 0.01 ? 3 : 4
        return dollars.formatted(.currency(code: "USD").precision(.fractionLength(digits)))
    }

    static func perMillion(_ dollars: Double) -> String {
        dollars.formatted(.currency(code: "USD").precision(.fractionLength(dollars < 1 ? 2...3 : 0...2)))
    }

    static func contextText(_ tokens: Int) -> String {
        tokens > 0 ? TokenBreakdown.tokensText(tokens) : "—"
    }
}
