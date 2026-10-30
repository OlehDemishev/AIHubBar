import Foundation
import Testing
@testable import ClaudePult

struct MenuBarConfigTests {
    @Test func migrationKeepsTheOldLook() {
        let on = { (config: MenuBarConfig) in config.elements.filter(\.enabled).map(\.kind) }
        #expect(on(.migrated(from: .iconOnly)) == [.icon, .projectsAlert, .waiting])
        #expect(on(.migrated(from: .session)) == [.icon, .projectsAlert, .session, .waiting])
        #expect(on(.migrated(from: .sessionAndWeek)) == [.icon, .projectsAlert, .session, .week, .waiting])
        let ring = MenuBarConfig.migrated(from: .ring)
        #expect(ring.element(.session).style == .ring)
        #expect(!ring.element(.week).enabled)
        for mode in MenuBarUsageMode.allCases {
            #expect(MenuBarConfig.migrated(from: mode).legacyMode == mode)
        }
    }

    @Test func presetsContainEveryKindOnce() {
        for preset in MenuBarConfig.Preset.allCases {
            let kinds = MenuBarConfig.make(preset).elements.map(\.kind)
            #expect(kinds == MenuBarElement.Kind.allCases)
        }
        #expect(MenuBarConfig.make(.everything).element(.deadline).enabled)
        #expect(MenuBarConfig.make(.everything).element(.disk).enabled)
    }

    @Test func tolerantDecoding() throws {
        let json = """
        {"elements": [{"kind": "week", "enabled": true, "style": "bar"}, {"kind": "future-thing", "enabled": true},
                      {"kind": "week", "enabled": false}, {"kind": "icon", "enabled": true, "symbol": "bolt"}],
         "separator": "nope", "preset": "limits"}
        """
        let config = try JSONDecoder().decode(MenuBarConfig.self, from: Data(json.utf8))
        #expect(config.elements.count == MenuBarElement.Kind.allCases.count)
        #expect(config.elements.prefix(2).map(\.kind) == [.week, .icon])
        #expect(config.element(.week).style == .bar)
        #expect(config.element(.icon).symbol == "bolt")
        #expect(!config.element(.session).enabled)
        #expect(config.separator == .dot)
        #expect(config.preset == .limits)
        let again = try JSONDecoder().decode(MenuBarConfig.self, from: JSONEncoder().encode(config))
        #expect(again == config)
    }
}

struct MenuBarComposerTests {
    let now = Date(timeIntervalSince1970: 1_793_300_000)

    @Test func olehsLookIsUnchanged() {
        let config = MenuBarConfig.migrated(from: .sessionAndWeek)
        let data = MenuBarData(showsAlert: true, waiting: 1, session: 17, week: 58)
        #expect(MenuBarComposer.groups(config, data) == [
            [.symbol("sparkle"), .dot],
            [.text("17%", .level(17))],
            [.text("58%", .level(58))],
            [.labeled(symbol: "hand.raised.fill", text: "1", .label)],
        ])
        #expect(MenuBarComposer.accessibilityText(config, data)
            == "ClaudePult, сессия 17 %, неделя 58 %, есть проекты с проблемами, ждут ответа: 1")
    }

    @Test func tooltipNamesEverythingShown() {
        var config = MenuBarConfig.make(.limits)
        for kind in [MenuBarElement.Kind.running, .queued, .deadline, .cpu, .memory, .keepAwake, .mode] {
            if let index = config.elements.firstIndex(where: { $0.kind == kind }) { config.elements[index].enabled = true }
        }
        var data = MenuBarData(running: 2, queued: 1, session: 40, deadline: "Ролик · 2 дн", modeName: "Видео", cpu: 23, memory: 71, keepingAwake: true)
        data.week = nil
        let text = MenuBarComposer.accessibilityText(config, data)
        for part in ["сессия 40 %", "работают сессии: 2", "отложенных запусков: 1", "ближайшее: Ролик · 2 дн",
                     "процессор 23 %", "память 71 %", "Mac не засыпает", "профиль «Видео»"] {
            #expect(text.contains(part), "\(part) in \(text)")
        }
        // Switched-off elements stay out of it.
        config.elements = config.elements.map { var e = $0; e.enabled = e.kind == .session; return e }
        #expect(MenuBarComposer.accessibilityText(config, data) == "ClaudePult, сессия 40 %")
    }

    @Test func dragMovesOntoTarget() {
        var config = MenuBarConfig.make(.limits)
        func order() -> [MenuBarElement.Kind] { config.elements.map(\.kind) }
        let start = order()
        // Rightwards: lands after the target.
        config.move(start[0], onto: start[2])
        #expect(Array(order().prefix(3)) == [start[1], start[2], start[0]])
        // Leftwards: lands before it.
        config.move(start[0], onto: start[1])
        #expect(Array(order().prefix(3)) == [start[0], start[1], start[2]])
        // Onto itself or an unknown element: nothing changes.
        config.move(start[0], onto: start[0])
        #expect(order() == start)
        // Every element stays exactly once.
        config.move(start.last!, onto: start[0])
        #expect(Set(order()) == Set(start) && order().count == start.count && order().first == start.last)
    }

    @Test func plainSymbolOnlyWithoutExtras() {
        let config = MenuBarConfig.make(.limits)
        #expect(MenuBarComposer.plainSymbol(MenuBarComposer.groups(config, MenuBarData())) == "sparkle")
        #expect(MenuBarComposer.plainSymbol(MenuBarComposer.groups(config, MenuBarData(session: 40))) == nil)
        #expect(MenuBarComposer.plainSymbol(MenuBarComposer.groups(.make(.minimum), MenuBarData(session: 40))) == "sparkle")
        #expect(MenuBarComposer.plainSymbol(MenuBarComposer.groups(config, MenuBarData(waiting: 2))) == nil)
    }

    @Test func nothingToShowStillLeavesAnIcon() {
        var config = MenuBarConfig.make(.minimum)
        config.set(.icon) { $0.symbol = "none" }
        #expect(MenuBarComposer.groups(config, MenuBarData()) == [[.symbol("sparkle")]])
        #expect(MenuBarComposer.groups(config, MenuBarData(showsAlert: true)) == [[.dot]])
    }

    @Test func gaugeStylesThresholdAndMono() {
        var config = MenuBarConfig.make(.limits)
        config.set(.session) { $0.style = .ring }
        config.set(.week) { $0.style = .bar; $0.showAbove = 80 }
        config.colored = false
        let groups = MenuBarComposer.groups(config, MenuBarData(session: 34, week: 58))
        #expect(groups == [[.symbol("sparkle")], [.ring(34, .label)]])
        #expect(MenuBarComposer.groups(config, MenuBarData(session: 34, week: 85)).last == [.bar(85, .label)])
    }

    @Test func modelWeekPicksTheChosenOrFirstWindow() {
        var config = MenuBarConfig.make(.minimum)
        config.set(.modelWeek) { $0.enabled = true }
        let data = MenuBarData(modelWeeks: ["seven_day_sonnet": 40, "seven_day_opus": 12])
        #expect(MenuBarComposer.groups(config, data).last == [.text("12%", .level(12))])
        config.set(.modelWeek) { $0.model = "seven_day_sonnet" }
        #expect(MenuBarComposer.groups(config, data).last == [.text("40%", .level(40))])
    }

    @Test func countersOnlyAboveZero() {
        var config = MenuBarConfig.make(.minimum)
        for kind in [MenuBarElement.Kind.running, .background, .queued] { config.set(kind) { $0.enabled = true } }
        #expect(MenuBarComposer.groups(config, MenuBarData()) == [[.symbol("sparkle")]])
        let groups = MenuBarComposer.groups(config, MenuBarData(running: 2, background: 0, queued: 3))
        #expect(groups.dropFirst().map { $0.first } == [
            .labeled(symbol: "bolt.fill", text: "2", .label),
            .labeled(symbol: "clock", text: "3", .label),
        ])
    }

    @Test func countdownDiskAndMode() {
        var config = MenuBarConfig.make(.minimum)
        config.set(.icon) { $0.symbol = "mode" }
        for kind in [MenuBarElement.Kind.resetCountdown, .disk, .mode] { config.set(kind) { $0.enabled = true } }
        config.set(.mode) { $0.showName = true }
        var data = MenuBarData(sessionResetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60 + 30), diskFreeBytes: 30_000_000_000,
                               modeName: "Видео", modeIcon: "video", now: now)
        #expect(MenuBarComposer.groups(config, data) == [
            [.symbol("video")],
            [.labeled(symbol: "arrow.clockwise", text: "2:14", .secondary)],
            [.text("Видео", .secondary)],
        ])
        data.diskFreeBytes = 8_000_000_000
        config.set(.resetCountdown) { $0.longFormat = true }
        let groups = MenuBarComposer.groups(config, data)
        #expect(groups[1] == [.labeled(symbol: "arrow.clockwise", text: "2 ч 14 мин", .secondary)])
        #expect(groups[2] == [.labeled(symbol: "internaldrive", text: "8 ГБ", .warning)])
        // Past the reset: nothing to count down.
        data.now = now.addingTimeInterval(3 * 3600)
        #expect(!MenuBarComposer.groups(config, data).contains { $0.first == .labeled(symbol: "arrow.clockwise", text: "0:00", .secondary) })
    }

    @Test func separatorOnlyBetweenNumbers() {
        let text: [MenuBarSegment] = [.text("17%", .label)]
        let ring: [MenuBarSegment] = [.ring(10, .label)]
        let icon: [MenuBarSegment] = [.symbol("sparkle")]
        let counter: [MenuBarSegment] = [.labeled(symbol: "clock", text: "1", .label)]
        #expect(MenuBarComposer.usesSeparator(between: text, and: ring))
        #expect(!MenuBarComposer.usesSeparator(between: icon, and: text))
        #expect(!MenuBarComposer.usesSeparator(between: text, and: counter))
        #expect(MenuBarComposer.countdown(to: now.addingTimeInterval(45 * 60), now: now, long: true) == "45 мин")
        #expect(MenuBarComposer.countdown(to: now.addingTimeInterval(9 * 60), now: now, long: false) == "0:09")
    }
}
