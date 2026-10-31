import Foundation
import Testing
@testable import ClaudePult

/// The widget's file, the Control Center toggle's and widget buttons' way back into the app, the widgets' links.
@MainActor
struct WidgetStatusTests {
    @Test func fileShapeTheWidgetReads() throws {
        let status = WidgetStatus(waiting: ["Survikon"], waitingSessions: [.init(id: "abc", project: "Survikon")], running: 2,
                                  problems: ["Ambo"], keepAwake: true, keepAwakeInstalled: true)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        // ClaudePultWidget/StatusWidget.swift decodes exactly these keys.
        #expect(Set(object.keys) == ["waiting", "waitingSessions", "running", "problems", "keepAwake", "keepAwakeInstalled"])
        let session = try #require((object["waitingSessions"] as? [[String: Any]])?.first)
        #expect(Set(session.keys) == ["id", "project"])
    }

    @Test func widgetRequestsArriveAsDarwinNotifications() async throws {
        var received: [Bool] = []
        var refreshes = 0
        WidgetRequests.keepAwake = { received.append($0) }
        WidgetRequests.refreshLimits = { refreshes += 1 }
        WidgetRequests.listen()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in [WidgetStatus.keepAwakeOn, WidgetStatus.keepAwakeOff, WidgetStatus.refreshLimits] {
            CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
        }
        for _ in 0..<40 where received.count < 2 || refreshes < 1 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(received == [true, false])
        #expect(refreshes == 1)
        WidgetRequests.keepAwake = nil
        WidgetRequests.refreshLimits = nil
    }

    @Test func widgetLinks() throws {
        #expect(WidgetLink.resolve(try #require(URL(string: "aihubbar://limits"))) == .openWindow(id: "limits"))
        #expect(WidgetLink.resolve(try #require(URL(string: "aihubbar://search"))) == .openWindow(id: "search"))
        #expect(WidgetLink.resolve(try #require(URL(string: "aihubbar://session/5f1c-42"))) == .showSession(id: "5f1c-42"))
        #expect(WidgetLink.resolve(try #require(URL(string: "AIHubBar://Limits"))) == .openWindow(id: "limits"))
        #expect(WidgetLink.resolve(try #require(URL(string: "aihubbar://session"))) == nil)
        #expect(WidgetLink.resolve(try #require(URL(string: "aihubbar://settings"))) == nil)
        #expect(WidgetLink.resolve(try #require(URL(string: "https://limits"))) == nil)
    }
}
