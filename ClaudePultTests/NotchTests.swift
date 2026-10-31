import Foundation
import Testing
@testable import ClaudePult

/// SPEC-notch stage 1: where the notch is and how the island sits around it.
struct NotchTests {
    /// What a 13.6" MacBook Air reports at its default resolution (1470 × 956 points).
    private let air = CGRect(x: 0, y: 0, width: 1470, height: 956)

    @Test func notchFromScreenAreas() throws {
        let geometry = try #require(NotchGeometry(
            screen: air, safeAreaTop: 32,
            topLeftArea: CGRect(x: 0, y: 924, width: 640, height: 32),
            topRightArea: CGRect(x: 830, y: 924, width: 640, height: 32)
        ))
        #expect(geometry.notch == CGRect(x: 640, y: 924, width: 190, height: 32))
        #expect(geometry.restFrame.width == 190 + 2 * NotchGeometry.earWidth)
        #expect(geometry.restFrame.maxY == air.maxY, "the island hangs from the top edge")
    }

    @Test func noNotch() {
        #expect(NotchGeometry(screen: air, safeAreaTop: 0, topLeftArea: nil, topRightArea: nil) == nil)
        #expect(NotchGeometry(screen: air, safeAreaTop: 32, topLeftArea: nil, topRightArea: nil) == nil)
        #expect(NotchGeometry(screen: air, safeAreaTop: 32,
                              topLeftArea: CGRect(x: 0, y: 924, width: 800, height: 32),
                              topRightArea: CGRect(x: 700, y: 924, width: 770, height: 32)) == nil, "areas that overlap")
    }

    @Test func windowCentredUnderNotch() {
        let geometry = NotchGeometry(notch: CGRect(x: 640, y: 924, width: 190, height: 32), screen: air)
        let window = geometry.windowFrame
        #expect(window.width == NotchGeometry.cardWidth)
        #expect(window.maxY == air.maxY)
        #expect(abs(window.midX - geometry.notch.midX) < 0.5)
        #expect(geometry.notchOffsetInWindow == geometry.notch.minX - window.minX)
    }

    @Test func windowStaysOnScreen() {
        // A second screen to the right, and a notch that would push the card past an edge.
        let screen = CGRect(x: 1470, y: 0, width: 300, height: 900)
        let geometry = NotchGeometry(notch: CGRect(x: 1480, y: 868, width: 100, height: 32), screen: screen)
        #expect(geometry.windowFrame.minX >= screen.minX)
        #expect(geometry.windowFrame.maxX <= screen.maxX)
    }
}

/// The island is a module of the screen, not of the panel (SPEC-notch §6).
struct NotchModuleTests {
    @Test func developersGetItOnlyWithANotch() throws {
        var draft = AssistantDraft(firstLaunch: false, menuBar: .make(.limits), hiddenBlocks: [], reminderHours: [24])
        let developer = try #require(ModeTemplate.loadAll(language: .ru).first { $0.id == "developer" })
        draft.choose(developer, hasNotch: true)
        #expect(draft.hasModule(.notch))
        draft.choose(developer, hasNotch: false)
        #expect(!draft.hasModule(.notch), "no notch, no island")
        draft.choose(nil, hasNotch: true)
        #expect(!draft.hasModule(.notch), "other templates leave it to the person")
    }

    @MainActor
    @Test func installingDoesNotTouchThePanel() throws {
        let name = "claudepult-notch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.dailyReportDirectory = "/nonexistent"
        let dir = FileManager.default.temporaryDirectory.appending(path: name)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModeStore(settings: settings, directory: dir)
        let template = try #require(ModeTemplate.loadAll(language: .ru).first { $0.id == "utilities" })
        _ = store.add(template, folder: "")
        let panel = store.panelModules

        store.install(.notch)
        #expect(store.installedModules.contains(.notch))
        #expect(store.panelModules == panel, "the island is not a block of the panel")
        #expect(store.current?.modules?.contains { $0.kind == .notch } != true)

        store.uninstall(.notch)
        #expect(!store.installedModules.contains(.notch))
    }

    @Test func settingsDecode() throws {
        let old = try JSONDecoder().decode(NotchSettings.self, from: Data(#"{"rightEar": "background", "future": 1}"#.utf8))
        #expect(old.rightEar == .background && old.leftEar == .sessionLimit && old.openOnHover)
        let unknown = try JSONDecoder().decode(NotchSettings.self, from: Data(#"{"leftEar": "weather"}"#.utf8))
        #expect(unknown.leftEar == .sessionLimit, "an ear from a newer version falls back to the default")
        #expect(old.events == NotchEventKind.defaultOn && !old.replaceNotifications, "stage 1 settings get the default events")
        let events = try JSONDecoder().decode(NotchSettings.self, from: Data(#"{"events": ["request", "weather", "limits"]}"#.utf8))
        #expect(events.events == [.request, .limits], "a kind from a newer version is skipped, not the whole list")
    }
}

/// SPEC-notch stage 2: the banner queue and the guard on «Разрешить».
struct NotchEventTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func event(_ id: String, _ kind: NotchEventKind, at seconds: TimeInterval = 0) -> NotchEvent {
        NotchEvent(id: id, kind: kind, title: id, body: "", target: .none, arrived: t0.addingTimeInterval(seconds))
    }

    @Test func mostImportantFirstThenOldest() {
        var queue = NotchEventQueue()
        queue.push(event("pr", .pullRequests))
        queue.push(event("limit", .limits, at: 1))
        queue.push(event("done-a", .done, at: 2))
        queue.push(event("done-b", .done, at: 3))
        #expect(queue.current?.id == "done-a")
        queue.push(event("req", .request, at: 4))
        #expect(queue.current?.id == "req", "a request goes ahead of everything")
    }

    @Test func timeStartsWhenShown() {
        var queue = NotchEventQueue()
        queue.push(event("done", .done))
        queue.push(event("limit", .limits))
        queue.tick(now: t0.addingTimeInterval(10), paused: false)
        #expect(queue.current?.id == "done", "waiting in the queue does not use up its time")
        #expect(queue.deadline == t0.addingTimeInterval(14))
        queue.tick(now: t0.addingTimeInterval(13.9), paused: false)
        #expect(queue.current?.id == "done")
        queue.tick(now: t0.addingTimeInterval(14), paused: false)
        #expect(queue.current?.id == "limit")
        queue.tick(now: t0.addingTimeInterval(17.9), paused: false)
        #expect(queue.current?.id == "limit", "its own time started only when it was shown")
        queue.tick(now: t0.addingTimeInterval(18), paused: false)
        #expect(queue.isEmpty)
    }

    @Test func pointerKeepsTheBanner() {
        var queue = NotchEventQueue()
        queue.push(event("waiting", .waiting))
        queue.tick(now: t0, paused: false)
        queue.tick(now: t0.addingTimeInterval(20), paused: true)
        #expect(queue.current?.id == "waiting")
        #expect(queue.deadline == t0.addingTimeInterval(26), "full time again after the pointer leaves")
    }

    @Test func requestsStayUntilAnswered() {
        var queue = NotchEventQueue()
        let request = event("request-1", .request)
        queue.syncRequests([request])
        queue.tick(now: t0.addingTimeInterval(3600), paused: false)
        #expect(queue.current == request)
        #expect(queue.deadline == nil)
        queue.syncRequests([request])
        #expect(queue.items.count == 1, "the same request is not queued twice")
        queue.syncRequests([])
        #expect(queue.isEmpty, "answered or cancelled")
    }

    @Test func sameIDReplaces() {
        var queue = NotchEventQueue()
        queue.push(event("limit", .limits))
        var newer = event("limit", .limits, at: 5)
        newer.title = "90 %"
        queue.push(newer)
        #expect(queue.items.count == 1 && queue.current?.title == "90 %")
    }

    @Test func oldestLeastImportantDroppedFirst() {
        var queue = NotchEventQueue()
        queue.push(event("req", .request))
        for i in 0..<NotchEventQueue.limit { queue.push(event("cmd-\(i)", .commands, at: Double(i + 1))) }
        #expect(queue.items.count == NotchEventQueue.limit)
        #expect(queue.items.contains { $0.id == "req" })
        #expect(!queue.items.contains { $0.id == "cmd-0" })
    }

    @Test func kindsFromNotifications() {
        #expect(NotchEventKind(.waiting) == .waiting)
        #expect(NotchEventKind(.pullRequests) == .pullRequests)
        #expect(!NotchEventKind.defaultOn.contains(.resources))
        #expect(NotchEventKind.request.duration == nil && NotchEventKind.waiting.duration == 6 && NotchEventKind.done.duration == 4)
    }

    @Test func guardWaitsForTimeAndMovement() {
        var guardrail = NotchClickGuard(shownAt: t0, pointer: CGPoint(x: 100, y: 100))
        #expect(!guardrail.isArmed(now: t0.addingTimeInterval(5)), "the pointer has not moved")
        guardrail.pointer(at: CGPoint(x: 101, y: 101))
        #expect(!guardrail.isArmed(now: t0.addingTimeInterval(5)), "a twitch is not a move")
        guardrail.pointer(at: CGPoint(x: 110, y: 100))
        #expect(!guardrail.isArmed(now: t0.addingTimeInterval(0.5)), "too soon")
        #expect(guardrail.isArmed(now: t0.addingTimeInterval(0.6)))
    }
}
