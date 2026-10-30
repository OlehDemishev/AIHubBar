import Foundation
import Testing
import UserNotifications
@testable import ClaudePult

struct NotificationTests {
    @Test(arguments: [
        NotificationTarget.session(id: "s1"),
        .run(id: "r1", pullRequest: "https://github.com/O/A/pull/7"),
        .run(id: "r2", pullRequest: nil),
        .file(path: "/P/_daily-report/reports/latest.html"),
        .window(id: "cleanup-output"),
        .none,
    ])
    func userInfoRoundTrip(target: NotificationTarget) {
        let userInfo: [AnyHashable: Any] = target.userInfo
        #expect(NotificationTarget(userInfo: userInfo) == target)
    }

    @Test func unknownUserInfoIsNone() {
        #expect(NotificationTarget(userInfo: [:]) == .none)
        #expect(NotificationTarget(userInfo: ["target": "session"]) == .none)
        #expect(NotificationTarget(userInfo: ["target": "rocket", "id": "x"]) == .none)
    }

    @Test func categories() {
        #expect(NotificationTarget.session(id: "s").category == NotificationAction.sessionCategory)
        #expect(NotificationTarget.run(id: "r", pullRequest: "https://x/pull/1").category == NotificationAction.runWithPRCategory)
        #expect(NotificationTarget.run(id: "r", pullRequest: nil).category == NotificationAction.runCategory)
        #expect(NotificationTarget.file(path: "/x").category == nil)
        let ids = Set(NotificationAction.categories.map(\.identifier))
        #expect(ids == [NotificationAction.sessionCategory, NotificationAction.runCategory, NotificationAction.runWithPRCategory, NotificationAction.approvalCategory])
    }

    @Test func clicksLeadToTheRightPlace() throws {
        let click = UNNotificationDefaultActionIdentifier
        let pr = "https://github.com/O/A/pull/7"
        #expect(NotificationAction.resolve(.session(id: "s"), action: click) == .showSession(id: "s"))
        #expect(NotificationAction.resolve(.session(id: "s"), action: NotificationAction.show) == .showSession(id: "s"))
        #expect(NotificationAction.resolve(.run(id: "r", pullRequest: pr), action: click) == .openURL(try #require(URL(string: pr))))
        #expect(NotificationAction.resolve(.run(id: "r", pullRequest: pr), action: NotificationAction.openPR) == .openURL(try #require(URL(string: pr))))
        #expect(NotificationAction.resolve(.run(id: "r", pullRequest: pr), action: NotificationAction.log) == .openRunLog(id: "r"))
        #expect(NotificationAction.resolve(.run(id: "r", pullRequest: nil), action: click) == .openRunLog(id: "r"))
        #expect(NotificationAction.resolve(.run(id: "r", pullRequest: "javascript:alert(1)"), action: click) == .openRunLog(id: "r"))
        #expect(NotificationAction.resolve(.file(path: "/a.html"), action: click) == .openFile(path: "/a.html"))
        #expect(NotificationAction.resolve(.window(id: "cleanup-output"), action: click) == .openWindow(id: "cleanup-output"))
        #expect(NotificationAction.resolve(.none, action: click) == .nothing)
    }
}
