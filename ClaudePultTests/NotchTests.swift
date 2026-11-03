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
        var draft = AssistantDraft(firstLaunch: false, menuBar: .make(.limits), reminderHours: [24])
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

/// SPEC-notch stage 3: which screen, the pill on screens without a notch, the summary in the menu bar or the island.
struct NotchPlacementTests {
    private let builtIn = NotchGeometry.Screen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
        safeAreaTop: 38, topLeftArea: CGRect(x: 0, y: 944, width: 664, height: 38), topRightArea: CGRect(x: 848, y: 944, width: 664, height: 38),
        isMain: false)
    private let monitor = NotchGeometry.Screen(
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1080), visibleFrame: CGRect(x: 1572, y: 0, width: 2500, height: 1050),
        safeAreaTop: 0, topLeftArea: nil, topRightArea: nil, isMain: true)

    @Test func notchScreenFirst() throws {
        let geometry = try #require(NotchGeometry.choose([builtIn, monitor], on: .notch, pill: true).first)
        #expect(!geometry.isPill && geometry.notch.width == 184)
        let main = try #require(NotchGeometry.choose([builtIn, monitor], on: .main, pill: true).first)
        #expect(main.isPill && main.screen == monitor.frame, "the main screen has no notch: its pill")
        #expect(NotchGeometry.choose([builtIn, monitor], on: .main, pill: false).isEmpty)
    }

    @Test func everyScreen() {
        let both = NotchGeometry.choose([builtIn, monitor], on: .all, pill: true)
        #expect(both.count == 2)
        #expect(!both[0].isPill && both[0].screen == builtIn.frame, "the notch on the built-in screen")
        #expect(both[1].isPill && both[1].screen == monitor.frame, "the pill on the monitor")
        let notchOnly = NotchGeometry.choose([builtIn, monitor], on: .all, pill: false)
        #expect(notchOnly.count == 1 && !notchOnly[0].isPill, "no pill: only the screen with the notch")
        #expect(NotchGeometry.choose([monitor], on: .all, pill: false).isEmpty)
        #expect(NotchGeometry.choose([monitor, builtIn], on: .notch, pill: true).count == 1, "the other choices stay one island")
    }

    @Test func simulatedNotch() throws {
        var screen = monitor
        screen.simulateNotch()
        let geometry = try #require(screen.notchGeometry)
        #expect(geometry.notch.width == 184 && geometry.notch.midX == monitor.frame.midX)
        #expect(geometry.notch.height == 32 && geometry.notch.maxY == monitor.frame.maxY)
    }

    @Test func pillUnderTheMenuBar() throws {
        let pill = try #require(NotchGeometry.choose([monitor], on: .notch, pill: true).first)
        #expect(pill.isPill && pill.notch.height == 0 && pill.notch.minY == 1050, "just under the 30 pt menu bar")
        #expect(pill.notch.midX == monitor.frame.midX)
        #expect(pill.windowFrame.maxY == 1050 && pill.windowFrame.height == NotchGeometry.windowHeight)
        #expect(pill.restFrame.height == 0, "nothing to hover at rest")
        #expect(NotchGeometry.choose([monitor], on: .notch, pill: false).isEmpty)
    }

    @Test func pillDefaultAndOldSettings() throws {
        let old = try JSONDecoder().decode(NotchSettings.self, from: Data(#"{"leftEar": "weekLimit"}"#.utf8))
        #expect(old.summary == .both && old.screen == .notch && old.pill == nil && !old.hidden)
        #expect(old.showsPill(macHasNotch: false) && !old.showsPill(macHasNotch: true), "by default only where no notch exists")
        var chosen = old
        chosen.pill = false
        chosen.summary = .island
        let round = try JSONDecoder().decode(NotchSettings.self, from: JSONEncoder().encode(chosen))
        #expect(round.pill == false && round.summary == .island)
        #expect(!round.showsPill(macHasNotch: false))
    }

    @Test func menuBarIconOnly() {
        let config = MenuBarConfig.make(.everything).iconOnly
        #expect(Set(config.elements.filter(\.enabled).map(\.kind)) == [.icon, .projectsAlert])
        var noIcon = MenuBarConfig.make(.limits)
        noIcon.set(.icon) { $0.enabled = false }
        #expect(noIcon.iconOnly.elements.contains { $0.kind == .icon && $0.enabled }, "something stays to click")
    }
}

/// SPEC-notch stage 3, part 2: full-screen apps, ⌃⌥Y / ⌃⌥N, the first-setup answers.
struct NotchFullScreenAndKeysTests {
    private let screen = CGRect(x: 0, y: 0, width: 2560, height: 1080)

    @Test func fullScreenIsAnotherAppsWindowOverTheWholeScreen() {
        let full = FullScreenDetector.Window(bounds: CGRect(x: 0, y: 0, width: 2560, height: 1080), layer: 0, pid: 42)
        let zoomed = FullScreenDetector.Window(bounds: CGRect(x: 0, y: 30, width: 2560, height: 1050), layer: 0, pid: 42)
        let menuBar = FullScreenDetector.Window(bounds: CGRect(x: 0, y: 0, width: 2560, height: 1080), layer: 25, pid: 42)
        let own = FullScreenDetector.Window(bounds: CGRect(x: 0, y: 0, width: 2560, height: 1080), layer: 0, pid: 7)
        #expect(FullScreenDetector.covers([full], screen: screen, mainHeight: 1080, ownPID: 7))
        #expect(!FullScreenDetector.covers([zoomed, menuBar, own], screen: screen, mainHeight: 1080, ownPID: 7), "zoomed, not normal or our own")
        // A second screen to the right, shorter than the main one: Quartz y counts down from the main display's top.
        let side = CGRect(x: 2560, y: 0, width: 1920, height: 1080 - 0)
        let sideFull = FullScreenDetector.Window(bounds: CGRect(x: 2560, y: 0, width: 1920, height: 1080), layer: 0, pid: 42)
        #expect(FullScreenDetector.covers([sideFull], screen: side, mainHeight: 1080, ownPID: 7))
    }

    @Test func keysNeedOnlyTime() {
        let shown = Date(timeIntervalSince1970: 1_000_000)
        let guardian = NotchClickGuard(shownAt: shown, pointer: .zero)
        #expect(!guardian.keysArmed(now: shown.addingTimeInterval(0.3)))
        #expect(guardian.keysArmed(now: shown.addingTimeInterval(NotchClickGuard.delay)))
        #expect(!guardian.isArmed(now: shown.addingTimeInterval(5)), "clicks still need the pointer to move")
    }

    @Test func fullScreenKeepsRequestsAndWaits() {
        var queue = NotchEventQueue()
        let at = Date(timeIntervalSince1970: 1_000_000)
        for (id, kind) in [("r", NotchEventKind.request), ("w", .waiting), ("l", .limits), ("d", .done)] {
            queue.push(NotchEvent(id: id, kind: kind, title: id, body: "", target: .none, arrived: at))
        }
        queue.keepOnly([.request, .waiting])
        #expect(Set(queue.items.map(\.id)) == ["r", "w"])
    }

    @Test func setupAnswersDecode() throws {
        let old = try JSONDecoder().decode(NotchSettings.self, from: Data(#"{"summary": "island"}"#.utf8))
        #expect(!old.hotKeys && !old.setupDone, "set up before stage 3: the window asks once")
        var answered = old
        answered.hotKeys = true
        answered.setupDone = true
        let round = try JSONDecoder().decode(NotchSettings.self, from: JSONEncoder().encode(answered))
        #expect(round.hotKeys && round.setupDone && round.summary == .island)
    }
}
