import Foundation
import Testing
@testable import ClaudePult

struct ProjectsReportTests {
    private static let fullReport = #"""
    {
      "version": 1,
      "generated": "2026-10-29T19:52:52.333282+01:00",
      "since": "2026-10-28T19:52:52.333282+01:00",
      "disk_free_bytes": 11058995200,
      "other_folders": ["reports"],
      "future_field": {"anything": true},
      "projects": [{
        "name": "Alpha", "path": "/tmp/Projects/Alpha",
        "branch": "feat/x", "default_branch": "origin/main",
        "remote": "git@github.com:owner/alpha.git",
        "health": "red",
        "last_activity": "2026-10-29T12:29:55+01:00",
        "dirty": 21, "dirty_sample": ["a.swift"], "stashes": 1,
        "commits": [], "merged_prs": [],
        "open_prs": [
          {"number": 5, "title": "Fix it", "headRefName": "fix/it", "isDraft": false,
           "url": "https://github.com/owner/alpha/pull/5", "ci": "ok", "updatedAt": "2026-10-29T17:34:14Z"},
          {"number": 6, "title": "Draft", "headRefName": "d", "isDraft": true, "url": "https://github.com/owner/alpha/pull/6", "ci": "fail"}
        ],
        "local_only": [], "unpushed": [],
        "worktrees": [{"path": "/tmp/Projects/Alpha/.claude/worktrees/w", "branch": "w", "dirty": 3}],
        "attention": [
          {"level": "high", "text": "срочно"},
          {"level": "severe", "text": "новый уровень"}
        ],
        "status": {
          "path": "docs/STATUS.md",
          "summary": {"stage": "Stage 2", "updated": "2026-10-29", "now": ["a"], "next": ["b", "c"], "needs": []},
          "latest_entry": {"date": "2026-10-29", "title": "Something"}
        }
      }]
    }
    """#

    @Test func decodesFullReport() throws {
        let report = try ReportService.decode(Data(Self.fullReport.utf8))
        #expect(report.version == 1)
        #expect(report.diskFreeBytes == 11_058_995_200)
        let generated = try #require(report.generated)
        #expect(abs(generated.timeIntervalSince(try #require(ISODate.parse("2026-10-29T18:52:52.333Z")))) < 0.001)
        #expect(report.hasRedProject)

        let project = try #require(report.projects.first)
        #expect(project.id == "/tmp/Projects/Alpha")
        #expect(project.health == .red)
        #expect(project.dirty == 21)
        #expect(project.lastActivity == ISODate.parse("2026-10-29T11:29:55Z"))
        #expect(project.openPRs?.count == 2)
        #expect(project.openPRs?.last?.isDraft == true)
        #expect(project.pullRequestsCI == .fail)
        #expect(project.worktrees.first?.dirty == 3)
        #expect(project.attention.map(\.level) == [.high, .unknown])
        #expect(project.status?.summary?.next == ["b", "c"])
        #expect(project.status?.latestEntry?.title == "Something")
    }

    @Test func toleratesNullsAndMissingFields() throws {
        let json = #"""
        {"projects": [
          {"path": "/p/Bare", "open_prs": null, "status": null, "health": "purple", "last_activity": null},
          {"path": "/p/NoSummary", "name": "NoSummary", "status": {"path": "docs/STATUS.md", "summary": null}},
          {"name": "broken project without path"}
        ]}
        """#
        let report = try ReportService.decode(Data(json.utf8))
        #expect(report.projects.count == 2)

        let bare = report.projects[0]
        #expect(bare.name == "Bare")
        #expect(bare.openPRs == nil)
        #expect(bare.status == nil)
        #expect(bare.health == .unknown)
        #expect(bare.lastActivity == nil)
        #expect(bare.dirty == 0)
        #expect(bare.attention.isEmpty)
        #expect(bare.pullRequestsCI == .none)

        let noSummary = report.projects[1]
        #expect(noSummary.status != nil)
        #expect(noSummary.status?.summary == nil)
        #expect(!report.hasRedProject)
    }

    @Test func emptyOpenPRsDiffersFromMissingGh() throws {
        let json = #"{"projects": [{"path": "/p/A", "open_prs": []}]}"#
        let report = try ReportService.decode(Data(json.utf8))
        #expect(report.projects[0].openPRs?.isEmpty == true)
    }

    @Test func attentionSkipsNeedsAlreadyInStatus() throws {
        let json = #"""
        {"projects": [{"path": "/p/A",
          "attention": [{"level": "mid", "text": "нужно от вас: Pick a branch"}, {"level": "high", "text": "1 stash"}],
          "status": {"summary": {"needs": ["Pick a branch"], "now": [], "next": []}}}]}
        """#
        let project = try #require(try ReportService.decode(Data(json.utf8)).projects.first)
        #expect(project.attentionNotInStatus.map(\.text) == ["1 stash"])
    }

    @Test func reportArguments() {
        #expect(ReportService.arguments(script: "/r/report.py", projectsDirectory: "/P", fetch: false)
            == ["python3", "/r/report.py", "--json", "--projects-dir", "/P", "--no-fetch"])
        #expect(ReportService.arguments(script: "/r/report.py", projectsDirectory: "/P", fetch: true)
            == ["python3", "/r/report.py", "--json", "--projects-dir", "/P"])
    }
}
