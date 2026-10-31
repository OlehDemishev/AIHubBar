import Foundation
import Testing
@testable import ClaudePult

/// Which kind a notification is, and how often the same one may come again.
struct NotificationSettingsTests {
    @Test func kindsFromIDs() {
        #expect(NotificationKind(id: "waiting-abc") == .waiting)
        #expect(NotificationKind(id: "run-guard") == .background)
        #expect(NotificationKind(id: "run-123") == .background)
        #expect(NotificationKind(id: "limit-five_hour-80") == .limits)
        #expect(NotificationKind(id: "hub-codex|5 ч|0|80") == .limits)
        #expect(NotificationKind(id: "spendWarned-2026-10-80") == .limits)
        #expect(NotificationKind(id: "resources-memory") == .resources)
        #expect(NotificationKind(id: "pr-x") == .pullRequests)
        #expect(NotificationKind(id: "quick-1") == .commands)
        #expect(NotificationKind(id: "test") == nil)
    }

    @Test func throttle() {
        let throttle = NotificationThrottle(defaults: UserDefaults(suiteName: "throttle-\(UUID())")!)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(throttle.allows(id: "resources-memory", frequency: .hourly, now: now))
        throttle.record(id: "resources-memory", now: now)
        #expect(!throttle.allows(id: "resources-memory", frequency: .hourly, now: now.addingTimeInterval(1800)))
        #expect(throttle.allows(id: "resources-memory", frequency: .hourly, now: now.addingTimeInterval(3600)))
        #expect(throttle.allows(id: "resources-memory", frequency: .always, now: now.addingTimeInterval(1)))
        // Another event of the same kind isn't held back.
        #expect(throttle.allows(id: "resources-disk", frequency: .hourly, now: now.addingTimeInterval(60)))
        #expect(!throttle.allows(id: "resources-disk", frequency: .off, now: now))
    }

    @MainActor @Test func choicesPersist() {
        let defaults = UserDefaults(suiteName: "freq-\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.frequency(.resources) == .hourly)
        #expect(settings.frequency(.waiting) == .always)
        settings.notificationFrequencies[NotificationKind.waiting.rawValue] = NotificationFrequency.quarterHour.rawValue
        #expect(AppSettings(defaults: defaults).frequency(.waiting) == .quarterHour)
    }
}
