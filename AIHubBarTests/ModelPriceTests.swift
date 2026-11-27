import Foundation
import Testing
@testable import AIHubBar

struct ModelPriceTests {
    /// The shape of models.dev's `api.json`, cut down to what the parser reads.
    static let sample = Data("""
    {
      "anthropic": {"id": "anthropic", "name": "Anthropic", "models": {
        "big": {"id": "big", "name": "Big", "tool_call": true, "release_date": "2026-11-09",
                "modalities": {"input": ["text", "image"], "output": ["text"]}, "limit": {"context": 1000000, "output": 128000},
                "cost": {"input": 8, "output": 40, "cache_read": 0.8, "cache_write": 10}},
        "old": {"id": "old", "name": "Old", "tool_call": true, "release_date": "2025-01-01", "status": "deprecated",
                "modalities": {"input": ["text"], "output": ["text"]}, "cost": {"input": 3, "output": 15}},
        "small": {"id": "small", "name": "Small", "tool_call": true, "release_date": "2026-10-01",
                  "modalities": {"input": ["text"], "output": ["text"]}, "cost": {"input": 1, "output": 5}}
      }},
      "openai": {"id": "openai", "name": "OpenAI", "models": {
        "embed": {"id": "embed", "name": "Embedding", "tool_call": false, "modalities": {"input": ["text"], "output": ["text"]},
                  "cost": {"input": 0.02, "output": 0}},
        "image": {"id": "image", "name": "Image", "tool_call": true, "modalities": {"input": ["text"], "output": ["image"]},
                  "cost": {"input": 5, "output": 40}},
        "free": {"id": "free", "name": "No price", "tool_call": true, "modalities": {"input": ["text"], "output": ["text"]}},
        "chat": {"id": "chat", "name": "Chat", "tool_call": true, "release_date": "2026-09-29",
                 "modalities": {"input": ["text"], "output": ["text"]}, "cost": {"input": 2, "output": 10, "cache_read": 0.1}}
      }},
      "zai": {"id": "zai", "name": "Z.AI", "models": {
        "glm": {"id": "glm", "name": "GLM", "tool_call": true, "modalities": {"input": ["text"], "output": ["text"]},
                "cost": {"input": 0.6, "output": 2.2}}
      }},
      "openrouter": {"id": "openrouter", "name": "OpenRouter", "models": {
        "anthropic/big": {"id": "anthropic/big", "name": "Big (resold)", "tool_call": true,
                          "modalities": {"input": ["text"], "output": ["text"]}, "cost": {"input": 9, "output": 45}}
      }}
    }
    """.utf8)

    @Test func onlyPricedTextModelsOfTheProvidersThemselves() {
        let models = ModelPriceParser.parse(Self.sample)
        #expect(models.map(\.id) == ["anthropic/big", "anthropic/small", "openai/chat", "glm/glm"],
                "by provider in the app's order, newest first; no retired, embedding, image, unpriced or resold model")
        #expect(models[0].context == 1_000_000 && models[0].cacheWrite == 10 && models[0].released == "2026-11-09")
        #expect(models[3].providerTitle == APIProvider.glm.title, "models.dev's «zai» is the app's GLM")
    }

    @Test func somethingElseIsAnEmptyList() {
        #expect(ModelPriceParser.parse(Data("[]".utf8)).isEmpty)
        #expect(ModelPriceParser.parse(Data("not json".utf8)).isEmpty)
        #expect(ModelPriceParser.parse(Data(#"{"anthropic": {"models": {"x": {"cost": {"input": true, "output": 1}}}}}"#.utf8)).isEmpty)
    }

    @Test func aTaskCostsItsTokensAtTheModelsPrices() {
        let big = ModelPriceParser.parse(Self.sample)[0]
        let tokens = TaskTokens(input: 1_000_000, cacheRead: 2_000_000, cacheWrite: 500_000, output: 100_000)
        #expect(abs(big.cost(tokens) - (8 + 1.6 + 5 + 4)) < 0.000_1)
    }

    @Test func aMissingCachePriceIsCountedAsElsewhereInTheApp() {
        let small = ModelPriceParser.parse(Self.sample)[1]
        let tokens = TaskTokens(cacheRead: 1_000_000, cacheWrite: 1_000_000)
        #expect(abs(small.cost(tokens) - (0.1 + 1.25)) < 0.000_1, "a tenth of the input price to read, a quarter more to write")
        let day = UsageDay(day: "2026-11-27", input: 0, output: 0, cacheWrite: 1_000_000, cacheRead: 1_000_000)
        #expect(abs(small.cost(TaskTokens.of([day])) - day.cost(APIPrice(input: 1, output: 5))) < 0.000_1)
    }

    @Test func theSizesGrow() {
        let chat = ModelPriceParser.parse(Self.sample)[2]
        let costs = TaskSize.allCases.map { chat.cost($0.tokens) }
        #expect(costs == costs.sorted() && costs[0] > 0)
        #expect(TaskSize.question.tokens.cacheRead == 0)
    }

    @Test func rowsFilterByProviderAndWords() {
        let models = ModelPriceParser.parse(Self.sample)
        let month = TaskTokens(input: 1_000_000)
        let all = ModelPriceRow.rows(models, task: TaskSize.task.tokens, month: month, provider: nil, search: "")
        #expect(all.count == 4 && all[0].monthCost == 8)
        #expect(ModelPriceRow.rows(models, task: TaskTokens(), month: TaskTokens(), provider: "openai", search: "").map(\.id) == ["openai/chat"])
        #expect(ModelPriceRow.rows(models, task: TaskTokens(), month: TaskTokens(), provider: nil, search: "anthropic SMALL").map(\.id) == ["anthropic/small"])
        let recent = ModelPriceRow.rows(models, task: TaskTokens(), month: TaskTokens(), provider: nil, search: "", since: "2026-10-01")
        #expect(recent.map(\.id) == ["anthropic/big", "anthropic/small"], "on the day counts; a model without a date is left out")
        #expect(ModelPriceRow.yearAgo(from: UsageDays.formatter.date(from: "2026-11-27")!) == "2025-11-27")
        #expect(all.sorted(using: [KeyPathComparator(\ModelPriceRow.taskCost)]).first?.id == "glm/glm")
    }

    @Test func moneyKeepsTheCentsOfSmallSums() {
        #expect(ModelPriceRow.money(0.0042).contains("0042"))
        #expect(!ModelPriceRow.money(1234.5).contains("5"), "whole dollars from a hundred up")
        #expect(ModelPriceRow.contextText(0) == "—")
    }

    @Test func aListIsStaleAfterADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!ModelPriceList(fetchedAt: now.addingTimeInterval(-3600), models: []).isStale(now: now))
        #expect(ModelPriceList(fetchedAt: now.addingTimeInterval(-25 * 3600), models: []).isStale(now: now))
    }

    @Test @MainActor func theStoreKeepsTheListAndSurvivesAFailedDownload() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "model-prices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ModelPriceStore(fileURL: file) { Self.sample }
        #expect(store.list == nil)
        await store.refreshIfStale(now: now)
        #expect(store.list?.models.count == 4 && store.failure == nil)

        let failing = ModelPriceStore(fileURL: file) { throw URLError(.notConnectedToInternet) }
        #expect(failing.list?.models.count == 4, "read back from the file")
        await failing.refreshIfStale(now: now.addingTimeInterval(3600))
        #expect(failing.failure == nil, "a fresh list is not asked for again")
        await failing.refresh(now: now)
        #expect(failing.failure != nil && failing.list?.models.count == 4, "the old list stays")

        let odd = ModelPriceStore(fileURL: file) { Data("{}".utf8) }
        await odd.refresh(now: now)
        #expect(odd.failure != nil && odd.list?.models.count == 4)
    }
}
