import Foundation
import Testing
@testable import AIHubBar

/// Order among the installed skills (`SkillHousekeeping`): name conflicts, copies, unused skills, sets, and the export
/// with hashes and its check. In a made-up home.
struct SkillHousekeepingTests {
    private final class Home {
        let url = FileManager.default.temporaryDirectory.appending(path: "order-\(UUID().uuidString)").resolvingSymlinksInPath()
        deinit { try? FileManager.default.removeItem(at: url) }
        func write(_ path: String, _ text: String) {
            let file = url.appending(path: path)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
        func skill(_ folder: String, _ name: String, _ body: String = "") {
            write("\(folder)/\(name)/SKILL.md", "---\nname: \(name)\ndescription: The \(name) skill.\nlicense: MIT\n---\n# \(name)\n\(body)")
        }
        var roots: SkillRoots { .under(url) }
        var place: SkillCatalog.Place { .init(roots: roots, backups: url.appending(path: "backups"), now: "2026-11-26T12:00:00Z") }
    }

    private func names(_ groups: [SkillCatalog.Group]) -> [String] { groups.map(\.name) }

    @Test func conflictsCopiesAndUnusedSkills() throws {
        let home = Home()
        // «notes»: two different versions for Claude Code — a conflict.
        home.skill(".claude/skills", "notes")
        home.skill("Projects/app/.claude/skills", "notes", "Another version.\n")
        // «deploy»: different versions, but for different agents only — no conflict.
        home.skill(".gemini/skills", "deploy")
        home.skill(".cursor/skills", "deploy", "Cursor's own.\n")
        // «same»: one content copied into two folders — copies; «linked»: one folder linked into another — not a copy.
        home.skill(".claude/skills", "same")
        home.skill(".codex/skills", "same")
        home.skill(".agents/skills", "linked")
        try FileManager.default.createSymbolicLink(atPath: home.url.appending(path: ".claude/skills/linked").path, withDestinationPath: home.url.appending(path: ".agents/skills/linked").path)
        // «pdf»: synced from the Claude account — the catalog can't switch it off, so it is never «unused».
        home.skill(".claude/skills/synced/acc_1", "pdf")
        let catalog = try SkillCatalog(path: ":memory:")
        try catalog.refreshInstalled(home.roots)
        #expect(names(try catalog.conflicts()) == ["notes"])
        #expect(try catalog.conflicts().first?.versions == 2)
        #expect(names(try catalog.duplicates()) == ["same"])
        #expect(try catalog.duplicates().first?.copies.count == 2)

        // A conflict ends when one version is switched off.
        let projectCopy = try #require(try catalog.conflicts().first?.copies.first { $0.scope == "user" })
        try catalog.setEnabled(projectCopy.installPath, false, home.place)
        #expect(try catalog.conflicts().isEmpty)

        // Used skills are not «unused»; switched-off ones are not offered.
        let now = ISO8601DateFormatter().string(from: .now)
        home.write(".claude/projects/p/a.jsonl", #"{"type":"assistant","timestamp":"\#(now)","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"same"}}]}}"# + "\n")
        try catalog.readUsage(home.roots, since: .now.addingTimeInterval(-86400))
        let unused = names(try catalog.unusedSkills(since: .now.addingTimeInterval(-30 * 86400)))
        #expect(unused == ["deploy", "linked", "notes"], "«same» was used; «notes» stays for its project copy; «pdf» is the account's")
        #expect(try catalog.unused(since: .now.addingTimeInterval(-30 * 86400)) == 4, "the panel counts each version (deploy twice, linked, notes), not the account's pdf")
    }

    @Test func setsShowAndSwitchTheirSkillsTogether() throws {
        let home = Home()
        home.skill(".claude/skills", "notes")
        home.skill(".claude/skills", "counter")
        home.skill("Projects/app/.claude/skills", "deploy")
        let catalog = try SkillCatalog(path: ":memory:")
        try catalog.refreshInstalled(home.roots)
        func id(_ name: String) throws -> Int { try #require(try catalog.search(.init(query: name)).rows.first?.id) }
        try catalog.addToSet("Writing", skill: id("notes"))
        try catalog.addToSet("writing", skill: id("deploy"))
        try catalog.addToSet("Other", skill: id("counter"))
        #expect(try catalog.sets().map { "\($0.name) \($0.members)" } == ["Other 1", "Writing 2"], "a set's name is one regardless of case")
        #expect(try catalog.setsOf(kind: "skill", name: "notes") == ["Writing"])
        var filters = SkillCatalog.Filters()
        filters.set = "writing"
        #expect(Set(try catalog.search(filters).rows.map(\.name)) == ["notes", "deploy"])

        // Only the person's own folders are switched: the project's skill stays as it is.
        #expect(try catalog.setEnabled(set: "Writing", false, home.place) == 1)
        #expect(FileManager.default.fileExists(atPath: home.url.appending(path: ".claude/skills.disabled/notes").path))
        #expect(FileManager.default.fileExists(atPath: home.url.appending(path: "Projects/app/.claude/skills/deploy").path))
        #expect(try catalog.setEnabled(set: "Writing", false, home.place) == 0, "what is off stays off")
        #expect(try catalog.setEnabled(set: "Writing", true, home.place) == 1)
        try catalog.removeFromSet("Writing", skill: id("notes"))
        #expect(try catalog.sets().first { $0.name == "Writing" }?.members == 1)
        try catalog.deleteSet("Writing")
        #expect(try catalog.sets().map(\.name) == ["Other"])
        #expect(throws: SkillCatalog.Refusal(code: "name")) { try catalog.addToSet("  ", skill: try id("counter")) }
    }

    @Test func anExportCarriesHashesAndALaterLookIsCheckedAgainstIt() throws {
        let home = Home()
        home.skill(".claude/skills", "notes")
        home.skill(".claude/skills", "counter")
        home.write(".claude/skills/counter/scripts/count.py", "print(1)\n")
        let catalog = try SkillCatalog(path: ":memory:")
        try catalog.refreshInstalled(home.roots)
        let export = try catalog.export(now: "2026-11-26T12:00:00Z", home: home.url.path)
        #expect(export.format == "aihubbar-skills" && export.skills.map(\.name).sorted() == ["counter", "notes"])
        let counter = try #require(export.skills.first { $0.name == "counter" })
        #expect(counter.installPath == "~/.claude/skills/counter", "no account name in the file")
        #expect(counter.files.map(\.path) == ["SKILL.md", "scripts/count.py"] && counter.files.allSatisfy { $0.sha256.count == 64 })
        let data = try SkillCatalog.exportData(export)
        #expect(try SkillCatalog.readExport(data) == export)
        #expect(String(decoding: data, as: UTF8.self).contains("\"installPath\" : \"~/.claude/skills/counter\""))

        #expect(try catalog.compare(with: export, home: home.url.path) == .init(changed: [], missing: [], added: [], unchanged: 2))
        home.write(".claude/skills/counter/scripts/count.py", "print(2)\n")
        try FileManager.default.removeItem(at: home.url.appending(path: ".claude/skills/notes"))
        home.skill(".claude/skills", "fresh")
        try catalog.refreshInstalled(home.roots)
        let comparison = try catalog.compare(with: export, home: home.url.path)
        #expect(comparison.changed.map { "\($0.name) \($0.files)" } == ["counter [\"scripts/count.py\"]"])
        #expect(comparison.missing.map(\.name) == ["notes"] && comparison.added.map(\.name) == ["fresh"] && comparison.unchanged == 0)
        #expect(throws: (any Error).self) { try SkillCatalog.readExport(Data(#"{"format": "something else", "version": 1, "exportedAt": "", "scannerVersion": 2, "skills": []}"#.utf8)) }
    }
}
