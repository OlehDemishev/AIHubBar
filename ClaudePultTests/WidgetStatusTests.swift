import Foundation
import Testing
@testable import ClaudePult

/// The widget's file and the Control Center toggle's way back into the app.
@MainActor
struct WidgetStatusTests {
    @Test func fileShapeTheWidgetReads() throws {
        let status = WidgetStatus(waiting: ["Survikon"], running: 2, problems: ["Ambo"], keepAwake: true, keepAwakeInstalled: true)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        // ClaudePultWidget/StatusWidget.swift decodes exactly these keys.
        #expect(Set(object.keys) == ["waiting", "running", "problems", "keepAwake", "keepAwakeInstalled"])
    }

    @Test func controlRequestsArriveAsDarwinNotifications() async throws {
        var received: [Bool] = []
        KeepAwakeRequests.handler = { received.append($0) }
        KeepAwakeRequests.listen()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(WidgetStatus.keepAwakeOn as CFString), nil, nil, true)
        CFNotificationCenterPostNotification(center, CFNotificationName(WidgetStatus.keepAwakeOff as CFString), nil, nil, true)
        for _ in 0..<40 where received.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(received == [true, false])
        KeepAwakeRequests.handler = nil
    }
}
