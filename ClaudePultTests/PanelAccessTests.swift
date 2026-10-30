import Foundation
import Testing
@testable import ClaudePult

/// The panel from the keyboard: search, the hot key presets and the Shortcuts limits answer.
struct PanelAccessTests {
    private let sessions = [PanelSearch.Item(id: "s1", name: "Survikon", detail: "Завис?"),
                            PanelSearch.Item(id: "s2", name: "AI Hub Bar", detail: "Смерджи")]
    private let projects = [PanelSearch.Item(id: "/p/Survikon", name: "Survikon", detail: "main"),
                            PanelSearch.Item(id: "/p/Ambo", name: "Ambo", detail: "feat/survey")]

    @Test func searchOrderAndScope() {
        let results = PanelSearch.results("surv", sessions: sessions, projects: projects,
                                          quickCommands: [.init(id: "q", name: "Загрузки", detail: "")], commands: CommonCommand.allCases)
        #expect(results.map(\.id) == ["s-s1", "p-/p/Survikon", "p-/p/Ambo"])
        #expect(PanelSearch.results("  ", sessions: sessions, projects: projects, quickCommands: [], commands: []).isEmpty)
        // Case and ё/е don't matter the way Finder search doesn't care.
        #expect(PanelSearch.results("SMERDZHI", sessions: sessions, projects: [], quickCommands: [], commands: []).isEmpty)
        #expect(PanelSearch.results("смердж", sessions: sessions, projects: [], quickCommands: [], commands: []).map(\.id) == ["s-s2"])
    }

    @Test func wrongKeyboardLayout() {
        #expect(PanelSearch.swappedLayout("ыгкм") == "surv")
        #expect(PanelSearch.swappedLayout("ghbdtn") == "привет")
        #expect(PanelSearch.results("ыгкм", sessions: sessions, projects: [], quickCommands: [], commands: []).map(\.id) == ["s-s1"])
    }

    @Test func destructiveCleanupIsNotSearchable() {
        let results = PanelSearch.results("Очистка", sessions: [], projects: [], quickCommands: [], commands: CommonCommand.allCases)
        #expect(results == [.command(.cleanupCheck)])
    }

    @Test func hotKeysAreDistinct() {
        let keys = PanelHotKey.allCases.filter { $0 != .off }.map { "\($0.keyCode)-\($0.modifiers)" }
        #expect(Set(keys).count == keys.count)
        #expect(PanelHotKey.off.keyCode == 0)
    }

    @Test func limitsForShortcuts() throws {
        let now = ISODate.parse("2026-10-30T18:00:00Z")!
        let json = #"{"five_hour":{"utilization":24,"resets_at":"2026-10-30T19:10:00Z"},"seven_day":{"utilization":84.4,"resets_at":"2026-11-02T09:00:00Z"}}"#
        let text = LimitsSummary.text(fromUsageFile: Data(json.utf8), now: now)
        #expect(text.hasPrefix("Сессия 24 %, сброс через 1 ч 10 мин; неделя 84 %, сброс "))
        #expect(LimitsSummary.text(fromUsageFile: nil).contains("откройте панель"))
    }
}
