import Foundation
import Testing
@testable import ClaudePult

/// How full a session's context is, from the end of its journal.
struct ContextUsageTests {
    private func line(_ input: Int, cacheRead: Int, model: String = "claude-opus-5-5", sidechain: Bool = false) -> String {
        #"{"type":"assistant","isSidechain":\#(sidechain),"timestamp":"2026-10-30T19:00:00Z","sessionId":"s","cwd":"/p","message":{"id":"m\#(input)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":\#(cacheRead),"output_tokens":10}}}"#
    }

    @Test func lastMainThreadMessageCounts() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ctx-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = [line(5, cacheRead: 50_000), line(10, cacheRead: 150_000), #"{"type":"user","message":{"content":"x"}}"#,
                    line(1, cacheRead: 3_000, sidechain: true)].joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let record = try #require(ContextUsage.lastRecord(transcript: url))
        // The subagent's line at the end is skipped; the user line has no usage.
        #expect(ContextUsage.tokens(record) == 150_010)
        #expect(abs(ContextUsage.fraction(record) - 0.75005) < 0.0001)
    }

    @Test func windowSize() {
        #expect(ContextUsage.window(tokens: 150_000, model: "claude-sonnet-5-5") == 200_000)
        #expect(ContextUsage.window(tokens: 150_000, model: "claude-opus-5-5[1m]") == 1_000_000)
        // Past 200 000 the session can only be on a 1M window.
        #expect(ContextUsage.window(tokens: 779_031, model: "claude-opus-5-5") == 1_000_000)
        #expect(ContextUsage.lastRecord(transcript: URL(fileURLWithPath: "/nonexistent.jsonl")) == nil)
    }
}
