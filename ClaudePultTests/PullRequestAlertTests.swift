import Foundation
import Testing
@testable import ClaudePult

/// CI going red or green, PRs closing: what changes between two project reports.
struct PullRequestAlertTests {
    private func project(_ name: String, _ prs: [(Int, String)]?) throws -> Project {
        var object: [String: Any] = ["name": name, "path": "/p/\(name)", "health": "green", "dirty": 0, "stashes": 0,
                                     "worktrees": [], "attention": []]
        if let prs {
            object["open_prs"] = prs.map { ["number": $0.0, "title": "PR \($0.0)", "url": "https://github.com/o/\(name)/pull/\($0.0)", "ci": $0.1] }
        } else {
            object["open_prs"] = NSNull()
        }
        return try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func redGreenAndClosed() throws {
        let old = [try project("Ambo", [(1, "pending"), (2, "fail"), (3, "ok")]), try project("Cantero", [(9, "ok")])]
        let new = [try project("Ambo", [(1, "fail"), (2, "ok")]), try project("Cantero", [(9, "ok")])]
        let url = { (n: Int) in URL(string: "https://github.com/o/Ambo/pull/\(n)") }
        #expect(PullRequestAlerts.changes(from: old, to: new) == [
            .ciFailed(project: "Ambo", number: 1, title: "PR 1", url: url(1)),
            .ciFixed(project: "Ambo", number: 2, title: "PR 2", url: url(2)),
            .closed(project: "Ambo", number: 3, title: "PR 3", url: url(3)),
        ])
    }

    @Test func noDataIsNotClosed() throws {
        // `gh` missing or offline this time: open_prs is null — nothing closed.
        let old = [try project("Ambo", [(1, "ok")])]
        #expect(PullRequestAlerts.changes(from: old, to: [try project("Ambo", nil)]).isEmpty)
        // A project that left the list says nothing either.
        #expect(PullRequestAlerts.changes(from: old, to: []).isEmpty)
        // Still failing: no repeat.
        let failing = [try project("Ambo", [(1, "fail")])]
        #expect(PullRequestAlerts.changes(from: failing, to: failing).isEmpty)
    }

    @Test func notificationLinksToThePR() throws {
        let target = NotificationTarget.link(try #require(URL(string: "https://github.com/o/a/pull/1")))
        #expect(NotificationTarget(userInfo: target.userInfo) == target)
        #expect(NotificationAction.resolve(target, action: "x") == .openURL(URL(string: "https://github.com/o/a/pull/1")!))
        // Only https links are followed.
        #expect(NotificationTarget(userInfo: ["target": "link", "url": "file:///etc/passwd"]) == .none)
    }
}
