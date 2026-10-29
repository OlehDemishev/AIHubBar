import Foundation
import Testing
@testable import ClaudePult

struct CommonCommandTests {
    private static let reportOutput = """
    20:41:02 сбор: Ambo
    20:41:05 сбор: Cantero
    20:41:20 AI-резюме через claude -p …
    20:42:31 отчёт: /Users/me/Projects/_daily-report/reports/2026-10-29.html
    20:42:33 Telegram: отправлено

    """

    private static let cleanupOutput = """
    Можно освободить: 18.9 ГБ · свободно на диске 15.7 ГБ
      (dry-run)   1.4 ГБ  /Users/me/Projects/Cantero/apps/web/.next
      пропущено (менялось недавно): /Users/me/Projects/Survikon/ios
    """

    @Test func summaries() {
        #expect(CommonCommand.reportNow.summary(of: Self.reportOutput) == "Telegram: отправлено")
        #expect(CommonCommand.cleanupCheck.summary(of: Self.cleanupOutput) == "Можно освободить: 18.9 ГБ · свободно на диске 15.7 ГБ")
        #expect(CommonCommand.quickSummary.summary(of: "") == nil)
    }

    @Test func failures() {
        #expect(!CommonCommand.reportNow.isFailure(exitCode: 0, summary: "Telegram: отправлено"))
        #expect(CommonCommand.reportNow.isFailure(exitCode: 0, summary: "Telegram не настроен (python3 report.py --setup-telegram)"))
        #expect(CommonCommand.quickSummary.isFailure(exitCode: 0, summary: "Telegram: HTTP Error 400: Bad Request"))
        #expect(CommonCommand.cleanupRun.isFailure(exitCode: 1, summary: "x"))
        #expect(!CommonCommand.cleanupCheck.isFailure(exitCode: 0, summary: "Можно освободить: 0 МБ"))
        #expect(CommonCommand.cleanupRun.isFailure(exitCode: 0, summary: "Идёт сборка — очистку пропускаю: /usr/bin/xcodebuild"))
    }

    @Test func tokensAreRedacted() {
        let text = "Telegram: <urlopen https://api.telegram.org/bot123456:AA-bb_CC/sendMessage>"
        #expect(CommonCommand.redactingTokens(text) == "Telegram: <urlopen https://api.telegram.org/bot<token>/sendMessage>")
    }

    @Test func scriptArguments() throws {
        #expect(try #require(CommonCommand.reportNow.script).arguments == ["--since-hours", "24", "--no-open"])
        #expect(try #require(CommonCommand.quickSummary.script).arguments == ["--no-ai", "--no-document", "--no-open", "--since-hours", "24"])
        #expect(try #require(CommonCommand.cleanupCheck.script).arguments == ["--dry-run"])
        #expect(try #require(CommonCommand.cleanupRun.script).arguments == ["--now"])
        #expect(CommonCommand.openLatestReport.script == nil)
    }

    @Test func executesAgainstAFakeDailyReport() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "claudepult-dr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        import sys
        print("20:00:00 args:", " ".join(sys.argv[1:]))
        print("20:00:01 Telegram: bot999:secret-token failed")
        """.write(to: dir.appending(path: "report.py"), atomically: true, encoding: .utf8)

        let (result, output) = await CommandStore.execute(.quickSummary, dailyReportDirectory: dir.path)
        #expect(result.isError)
        #expect(result.text == "Telegram: bot<token> failed")
        #expect(output?.contains("--no-ai --no-document --no-open --since-hours 24") == true)
        #expect(output?.contains("secret-token") == false)

        let (missing, _) = await CommandStore.execute(.cleanupCheck, dailyReportDirectory: dir.path)
        #expect(missing.isError)
        #expect(missing.text.hasPrefix("Не найден cleanup.py"))
    }

    @Test func lowDiskThreshold() {
        #expect(11_058_995_200 < CommandStore.lowDiskBytes)
        #expect(CommandStore.diskText(15_700_000_000).contains("15,7") || CommandStore.diskText(15_700_000_000).contains("15.7"))
    }
}
