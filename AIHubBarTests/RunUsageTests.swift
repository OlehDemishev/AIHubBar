import Foundation
import Testing
@testable import AIHubBar

struct RunUsageTests {
    /// The end of a real `claude -p --output-format stream-json` log (2026-11), cut down to what is read.
    static let claude = #"""
    {"type":"assistant","message":{"content":[{"type":"text","text":"Готово"}]}}
    {"type":"result","subtype":"success","is_error":false,"result":"Готово","total_cost_usd":1.6995,"usage":{"input_tokens":48,"cache_creation_input_tokens":50085,"cache_read_input_tokens":1117272,"output_tokens":9181},"modelUsage":{"claude-haiku-5-5":{"inputTokens":1322,"outputTokens":282,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"costUSD":0.0002},"claude-opus-5-5":{"inputTokens":48,"outputTokens":9181,"cacheReadInputTokens":1117272,"cacheCreationInputTokens":50085,"costUSD":0.8079}}}
    """#

    @Test func claudesResultIsSummedOverItsModels() throws {
        let usage = try #require(StreamJSON.usage(fromLog: Self.claude))
        #expect(usage.input == 1370 && usage.output == 9463, "the main model and the small one it calls")
        #expect(usage.cacheRead == 1_117_272 && usage.cacheWrite == 50_085)
        #expect(usage.cost == 1.6995)
        #expect(usage.tokens == 1370 + 9463 + 50_085, "without cache reads")
    }

    @Test func withoutModelUsageTheTotalIsRead() throws {
        let log = #"{"type":"result","is_error":false,"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}"#
        let usage = try #require(StreamJSON.usage(fromLog: log))
        #expect(usage == RunUsage(input: 10, output: 20, cacheRead: 30, cacheWrite: 40, cost: nil))
    }

    @Test func aRunWithoutAnEndHasNoUsage() {
        #expect(StreamJSON.usage(fromLog: #"{"type":"assistant","message":{"content":[]}}"#) == nil)
        #expect(StreamJSON.usage(fromLog: "") == nil)
        #expect(StreamJSON.usage(fromLog: #"{"type":"result","is_error":true}"#) == nil, "killed before anything was counted")
    }

    @Test func codexCountsCachedInputApart() throws {
        let log = """
        {"type":"thread.started","thread_id":"t"}
        {"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50}}
        {"type":"turn.completed","usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":25}}
        """
        let usage = try #require(StreamJSON.usage(fromLog: log))
        #expect(usage == RunUsage(input: 700, output: 75, cacheRead: 800, cacheWrite: 0, cost: nil), "every turn, cached input out of the input")
        #expect(CodexExec.usage(fromLog: Self.claude) == nil)
    }

    @Test func theCostIsTheAgentsOwnOrThePersonsPrice() {
        let price = APIPrice(input: 2, output: 10)
        let codex = RunUsage(input: 1_000_000, output: 100_000, cacheRead: 1_000_000)
        #expect(codex.cost(at: nil) == nil)
        #expect(abs((codex.cost(at: price) ?? 0) - (2 + 0.2 + 1)) < 0.000_1, "a cache read at a tenth, as in the usage history")
        #expect(RunUsage(input: 1, cost: 1.5).cost(at: price) == 1.5, "the agent's own figure wins")
    }

    @Test func theLineNamesTokensAndTheCostWhenThereIsOne() {
        let usage = RunUsage(input: 400_000, output: 800_000, cost: 1.7)
        let line = usage.line(price: nil)
        #expect(line.contains(TokenBreakdown.tokensText(1_200_000)) && line.contains("·"))
        #expect(!RunUsage(input: 10).line(price: nil).contains("·"), "no price, no sum")
    }

    @Test func anOldRunFileStillReads() throws {
        let old = #"{"id":"r","project":"p","projectPath":"/p","folder":"/p","commandTitle":"c","task":"t","startedAt":"2026-11-09T11:41:40Z","timeLimitMinutes":90,"state":"succeeded","notified":true}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(BackgroundRun.self, from: Data(old.utf8))
        #expect(run.usage == nil)
    }
}
