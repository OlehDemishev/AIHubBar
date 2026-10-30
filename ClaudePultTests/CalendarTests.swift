import Foundation
import Testing
@testable import ClaudePult

struct ContentPlanTests {
    let text = """
    # Контент-план

    Заметка над таблицей.

    | Дата | Время | Площадка | Тема | Статус | Файл | Комментарий |
    |---|:---:|---|---|---|---|---|
    | 2026-11-03 | 18:00 | Instagram | Закулисье \\| съёмки | черновик | посты/закулисье.md | x |
    | 2026-11-04 |  | Telegram | Анонс | идея |  |  |
    | потом |  | YouTube | Без даты | идея |  |  |

    Текст под таблицей.
    """

    @Test func parsesRowsByHeader() throws {
        let plan = ContentPlan.parse(text)
        #expect(plan.rows.count == 3)
        let first = plan.rows[0]
        #expect(first.value(.topic) == "Закулисье \\| съёмки")
        #expect(first.value(.file) == "посты/закулисье.md")
        let (date, hasTime) = try #require(first.date)
        #expect(hasTime)
        #expect(Calendar.current.component(.hour, from: date) == 18)
        #expect(plan.rows[1].date?.hasTime == false)
        #expect(plan.rows[2].date == nil)
        #expect(ContentPlan.parse("| Тема | Статус |\n|---|---|\n| a | b |").rows.isEmpty, "a table without a date column is not a plan")
        let english = ContentPlan.parse("| Date | Topic |\n|--|--|\n| 2026-01-02 | Hi |")
        #expect(english.rows.first?.value(.topic) == "Hi")
    }

    @Test func writesCellsBack() throws {
        let line = ContentPlan.parse(text).rows[1].line
        let changed = try #require(ContentPlan.setting(.date, of: line, to: "2026-11-10", in: text))
        let plan = ContentPlan.parse(changed)
        #expect(plan.rows[1].value(.date) == "2026-11-10")
        #expect(plan.rows[1].value(.topic) == "Анонс")
        #expect(changed.contains("Текст под таблицей.") && changed.contains("Заметка над таблицей."))
        #expect(ContentPlan.setting(.date, of: 0, to: "x", in: text) == nil, "not a row")
    }

    @Test func appendsRows() {
        let added = ContentPlan.appending([.date: "2026-11-05", .topic: "Новое", .status: "идея"], to: text)
        let plan = ContentPlan.parse(added)
        #expect(plan.rows.count == 4)
        #expect(plan.rows[3].value(.topic) == "Новое")
        #expect(plan.rows[3].cells.count == 7, "same number of columns as the header")
        #expect(added.contains("Текст под таблицей."))
        let fresh = ContentPlan.appending([.date: "2026-11-05", .topic: "Первая"], to: "")
        #expect(fresh.hasPrefix("# Контент-план"))
        #expect(ContentPlan.parse(fresh).rows.first?.value(.topic) == "Первая")
        let notes = ContentPlan.appending([.date: "2026-11-05", .topic: "X"], to: "Просто заметки")
        #expect(notes.hasPrefix("Просто заметки\n\n| Дата"))
    }
}

struct CalendarScannerTests {
    @Test func collectsCardsAndPlans() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "claudepult-calendar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "Кофе/посты"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "Чай"), withIntermediateDirectories: true)
        try "# Кофе\nДедлайн: 2026-11-05\nПубликация: 2026-11-06 18:00\nПлощадка: YouTube\n".write(to: root.appending(path: "Кофе/проект.md"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appending(path: "Кофе/посты/a.md"), atomically: true, encoding: .utf8)
        try "| Дата | Тема | Файл |\n|---|---|---|\n| 2026-11-07 | Пост | посты/a.md |\n".write(to: root.appending(path: "Кофе/контент-план.md"), atomically: true, encoding: .utf8)
        try "| Дата | Тема |\n|---|---|\n| 2026-11-08 | Общий |\n".write(to: root.appending(path: "контент-план.md"), atomically: true, encoding: .utf8)

        let mode = CalendarScanner.ModeInfo(id: "m", name: "Видео", icon: "video", source: .folders(root.path), calendar: .contentPlan)
        let entries = CalendarScanner.entries(for: [mode]).sorted { $0.date < $1.date }
        #expect(entries.map(\.title) == ["Кофе", "Кофе", "Пост", "Общий"])
        #expect(entries.map(\.kind) == [.deadline, .publish, .plan, .plan])
        #expect(entries[0].hasTime == false && entries[1].hasTime)
        #expect(entries[0].detail == "YouTube")
        #expect(entries[2].openPath.hasSuffix("посты/a.md"), "a plan row opens its file")
        #expect(entries[3].openPath.hasSuffix("контент-план.md"))

        var datesOnly = mode
        datesOnly.calendar = .dates
        #expect(CalendarScanner.entries(for: [datesOnly]).count == 2)
        datesOnly.calendar = .off
        #expect(CalendarScanner.entries(for: [datesOnly]).isEmpty)
    }

    @Test func remindersOncePerOffset() {
        let now = Date(timeIntervalSince1970: 1_793_300_000)
        func entry(in hours: Double) -> CalendarEntry {
            CalendarEntry(date: now.addingTimeInterval(hours * 3600), hasTime: true, kind: .deadline, title: "T\(hours)", detail: nil,
                          modeID: "m", modeName: "M", modeIcon: "video", openPath: "/p\(hours)",
                          source: .card(path: "/p\(hours)/проект.md", key: .deadline))
        }
        let entries = [entry(in: 30), entry(in: 20), entry(in: 1), entry(in: -1)]
        let due = CalendarStore.due(entries, hours: [24, 2], reminded: [], now: now)
        #expect(due.map(\.0.title) == ["T20.0", "T1.0"])
        #expect(due[0].1.hasSuffix("|24") && due[1].1.hasSuffix("|2"))
        let again = CalendarStore.due(entries, hours: [24, 2], reminded: Set(due.map(\.1)), now: now)
        #expect(again.isEmpty)
        #expect(CalendarStore.due(entries, hours: [], reminded: [], now: now).isEmpty)
    }

    @Test func texts() {
        let now = Date(timeIntervalSince1970: 1_793_300_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        #expect(CalendarText.relative(today, hasTime: false, now: now) == "сегодня")
        #expect(CalendarText.relative(calendar.date(byAdding: .day, value: 1, to: today)!, hasTime: false, now: now) == "завтра")
        #expect(CalendarText.relative(calendar.date(byAdding: .day, value: 3, to: today)!, hasTime: false, now: now) == "через 3 дн")
        #expect(CalendarText.relative(calendar.date(byAdding: .day, value: -2, to: today)!, hasTime: false, now: now) == "просрочено 2 дн")
        let entry = CalendarEntry(date: calendar.date(byAdding: .day, value: 2, to: today)!, hasTime: false, kind: .deadline,
                                  title: "Очень длинное название ролика", detail: nil, modeID: "m", modeName: "M", modeIcon: "v",
                                  openPath: "/p", source: .card(path: "/p", key: .deadline))
        #expect(CalendarText.menuBar(entry, now: now) == "Очень длинное…  · 2 дн".replacingOccurrences(of: "…  ", with: "… "))
        #expect(!entry.isOverdue(now: now))
        #expect(CalendarScanner.text(today, withTime: false).count == 10)
    }
}

@MainActor
struct CalendarStoreTests {
    @Test func movesDatesInTheirFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "claudepult-calstore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Кофе"), withIntermediateDirectories: true)
        let card = root.appending(path: "Кофе/проект.md")
        try "# Кофе\n\nДедлайн: 2026-11-05\n\nЗаметки.".write(to: card, atomically: true, encoding: .utf8)
        let planURL = root.appending(path: "контент-план.md")
        try "| Дата | Время | Тема |\n|---|---|---|\n| 2026-11-07 | 18:00 | Пост |\n".write(to: planURL, atomically: true, encoding: .utf8)

        let name = "claudepult-calstore-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.calendarReminderHours = []
        let modes = ModeStore(settings: settings, directory: root.appending(path: ".modes"))
        var mode = try #require(modes.current)
        mode.source = .folders(root.path)
        mode.calendar = .contentPlan
        modes.update(mode)
        let store = CalendarStore(settings: settings, modes: modes)
        await store.refresh()
        #expect(store.entries.count == 2)

        let target = try #require(ProjectCardFile.date("2026-11-20"))
        store.move(try #require(store.entries.first { $0.kind == .deadline }), to: target)
        store.move(try #require(store.entries.first { $0.kind == .plan }), to: target)
        let cardText = try String(contentsOf: card, encoding: .utf8)
        #expect(cardText.contains("Дедлайн: 2026-11-20") && cardText.hasSuffix("Заметки."))
        let planText = try String(contentsOf: planURL, encoding: .utf8)
        #expect(planText.contains("| 2026-11-20 | 18:00 | Пост |"))

        store.addPlanRow(mode: mode, date: target, time: "", platform: "TG", topic: "Новый")
        #expect(try String(contentsOf: planURL, encoding: .utf8).contains("Новый"))
        await store.refresh()
        #expect(store.entries.count == 3)
        #expect(store.nearest(now: try #require(ProjectCardFile.date("2026-11-01"))) != nil)
    }
}
