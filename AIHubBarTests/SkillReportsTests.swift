import Foundation
import Testing
@testable import AIHubBar

/// Complaints and the block list (`SkillReports`), in a made-up home: a complaint stays on this Mac, a blocked skill
/// can't be installed or updated, and the GitHub pages carry the catalog's facts and nothing from this Mac's paths.
struct SkillReportsTests {
    private final class Home {
        let url = FileManager.default.temporaryDirectory.appending(path: "reports-\(UUID().uuidString)").resolvingSymlinksInPath()
        deinit { try? FileManager.default.removeItem(at: url) }
        func write(_ path: String, _ text: String) {
            let file = url.appending(path: path)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
        var place: SkillCatalog.Place { .init(roots: .under(url), backups: url.appending(path: "backups"), now: "2026-11-26T12:00:00Z") }
    }

    private func setUp() throws -> (Home, SkillCatalog, Int) {
        let home = Home()
        home.write("Downloads/notes/SKILL.md", "---\nname: notes\ndescription: Notes.\nlicense: MIT\nmetadata:\n  repository: https://github.com/example/notes-skill.git\n---\n# notes\n")
        let catalog = try SkillCatalog(path: ":memory:")
        let id = try catalog.importFolder(home.url.appending(path: "Downloads/notes"))
        return (home, catalog, id)
    }

    @Test func aComplaintIsKeptAndMarkedWhereItWasOpened() throws {
        let (_, catalog, id) = try setUp()
        let first = try catalog.report(id, reason: .misleading, details: "  It deletes files it shouldn't.  ")
        try catalog.report(id, reason: .falseAlarm, details: "")
        var reports = try catalog.reports(kind: "skill", name: "notes")
        #expect(reports.map(\.reason) == [.falseAlarm, .misleading] && reports[1].details == "It deletes files it shouldn't.")
        try catalog.markSent(first, to: "author")
        try catalog.markSent(first, to: "aihubbar")
        try catalog.markSent(first, to: "author")
        reports = try catalog.reports(kind: "skill", name: "notes")
        #expect(reports[1].sentTo == ["author", "aihubbar"] && reports[0].sentTo.isEmpty)
        var filters = SkillCatalog.Filters()
        filters.withReport = true
        #expect(try catalog.search(filters).rows.map(\.reports) == [2])
        try catalog.deleteReport(first)
        #expect(try catalog.reports(kind: "skill", name: "notes").count == 1)
        #expect(throws: SkillCatalog.Refusal.missing) { try catalog.report(9999, reason: .other, details: "") }
    }

    @Test func aBlockedSkillIsNeitherInstalledNorUpdated() throws {
        let (home, catalog, id) = try setUp()
        try catalog.block(id, everyVersion: false, reason: "Sends notes somewhere")
        #expect(try catalog.blockOf(id) == SkillCatalog.Block(isThisVersion: true, reason: "Sends notes somewhere", createdAt: try #require(try catalog.blockOf(id)?.createdAt)))
        let plan = try catalog.planInstall(id, for: .claude, home.place)
        #expect(plan.blocked == "blocked")
        #expect(throws: SkillCatalog.Refusal(code: "blocked")) { try catalog.install(id, for: .claude, contentHash: plan.contentHash, acknowledged: true, home.place) }
        #expect(!FileManager.default.fileExists(atPath: home.url.appending(path: ".claude").path))
        var filters = SkillCatalog.Filters()
        filters.blockedOnly = true
        #expect(try catalog.search(filters).rows.map(\.name) == ["notes"])

        // A block on this version only: a new version is free again, until every version is blocked.
        home.write("Downloads/notes/extra.md", "new\n")
        let newer = try catalog.importFolder(home.url.appending(path: "Downloads/notes"))
        #expect(try catalog.planInstall(newer, for: .claude, home.place).blocked == nil)
        try catalog.block(newer, everyVersion: true)
        #expect(try catalog.planInstall(newer, for: .claude, home.place).blocked == "blocked")
        #expect(try catalog.blockOf(newer)?.isThisVersion == false)
        try catalog.unblock(newer)
        #expect(try catalog.blockOf(newer) == nil)
        #expect(try catalog.search(filters).rows.isEmpty)

        // An installed copy whose source is blocked later gets no update.
        let installed = try catalog.planInstall(newer, for: .claude, home.place)
        let done = try catalog.install(newer, for: .claude, contentHash: installed.contentHash, acknowledged: true, home.place)
        home.write("Downloads/notes/more.md", "more\n")
        let source = try catalog.importFolder(home.url.appending(path: "Downloads/notes"))
        try catalog.block(source, everyVersion: true)
        #expect(try catalog.planUpdate(done.installPath, home.place).blocked == "blocked")
    }

    @Test func whereAComplaintCanGo() throws {
        #expect(SkillCatalog.githubRepository("https://github.com/example/notes-skill.git")?.absoluteString == "https://github.com/example/notes-skill")
        #expect(SkillCatalog.githubRepository("https://github.com/example/notes-skill/tree/main/skills/notes")?.absoluteString == "https://github.com/example/notes-skill")
        for wrong in [nil, "", "http://github.com/a/b", "https://gitlab.com/a/b", "https://github.com/onlyone", "https://github.com/../b", "javascript:alert(1)", "https://github.com.evil.example/a/b"] {
            #expect(SkillCatalog.githubRepository(wrong) == nil, "\(wrong ?? "nil")")
        }
        let home = Home()
        home.write("plug/.claude-plugin/plugin.json", #"{"name": "plug", "repository": {"type": "git", "url": "https://github.com/example/plug"}}"#)
        let catalog = try SkillCatalog(path: ":memory:")
        let plug = try catalog.importFolder(home.url.appending(path: "plug"))
        #expect(try catalog.card(plug)?.row.homepage == "https://github.com/example/plug")
    }

    @Test @MainActor func theGitHubPagesCarryTheFactsAndNoPaths() throws {
        let (home, catalog, id) = try setUp()
        let card = try #require(try catalog.card(id))
        try catalog.report(id, reason: .malicious, details: "It reads \(NSHomeDirectory())/.ssh/id_rsa and \(home.url.path)")
        let report = try #require(try catalog.reports(kind: "skill", name: "notes").first)
        let repository = try #require(SkillCatalog.githubRepository(card.row.homepage))
        let author = SkillReportBox.authorIssue(repository, report: report, card: card).absoluteString.removingPercentEncoding ?? ""
        #expect(author.hasPrefix("https://github.com/example/notes-skill/issues/new?"))
        #expect(author.contains("Content hash: \(card.row.contentHash)") && author.contains("Looks malicious") && author.contains("~/.ssh/id_rsa"))
        #expect(!author.contains(NSHomeDirectory()), "the home folder is never in a link")
        let ours = SkillReportBox.aiHubBarIssue(report, card: card).absoluteString.removingPercentEncoding ?? ""
        #expect(ours.hasPrefix("https://github.com/OlehDemishev/AIHubBar/issues/new?template=skill_report.yml"))
        #expect(ours.contains("reason=Looks malicious") && ours.contains("hash=\(card.row.contentHash)") && !ours.contains(NSHomeDirectory()))
    }
}
