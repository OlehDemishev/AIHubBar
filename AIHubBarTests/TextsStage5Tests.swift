import Foundation
import Testing
@testable import AIHubBar

/// SPEC-content stage 5: the calendar as an `.ics` file and «Цель по словам».
struct CalendarICSTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func entry(_ title: String, _ date: Date, hasTime: Bool, kind: CalendarEntry.Kind = .deadline, detail: String? = nil, path: String = "/p/a") -> CalendarEntry {
        CalendarEntry(date: date, hasTime: hasTime, kind: kind, title: title, detail: detail, modeID: "m", modeName: "Тексты", modeIcon: "doc",
                      openPath: path, source: .card(path: path + "/проект.md", key: kind == .publish ? .publish : .deadline))
    }

    @Test func anAllDayDateAndATimedOne() {
        let day = Date(timeIntervalSince1970: 1_793_750_400) // 2026-11-04 00:00 UTC
        let timed = day.addingTimeInterval(18 * 3600)
        let text = CalendarICS.text([entry("Статья", day, hasTime: false), entry("Пост", timed, hasTime: true, kind: .publish, path: "/p/b")],
                                    now: day, calendar: utc)
        #expect(text.hasPrefix("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"))
        #expect(text.hasSuffix("END:VCALENDAR\r\n"))
        #expect(text.contains("DTSTART;VALUE=DATE:20261104\r\nDTEND;VALUE=DATE:20261105\r\n"))
        #expect(text.contains("DTSTART:20261104T180000Z\r\nDURATION:PT30M\r\n"))
        #expect(text.components(separatedBy: "BEGIN:VEVENT").count == 3)
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "only CRLF line ends")
    }

    @Test func textIsEscapedAndLongLinesFolded() {
        let long = String(repeating: "Очень длинное название, с запятой; ", count: 5)
        let text = CalendarICS.text([entry(long, .now, hasTime: false, detail: "Telegram\nчерновик")])
        #expect(text.contains("\\, с запятой\\; ") || text.replacingOccurrences(of: "\r\n ", with: "").contains("\\, с запятой\\; "))
        #expect(text.replacingOccurrences(of: "\r\n ", with: "").contains("DESCRIPTION:Telegram\\nчерновик\\nТексты"))
        for line in text.components(separatedBy: "\r\n") { #expect(line.utf8.count <= 75) }
        #expect(CalendarICS.folded("короткая") == ["короткая"])
    }

    @Test func theSameDateKeepsItsUIDWhenItMoves() {
        let first = entry("Статья", .now, hasTime: false)
        let moved = entry("Статья", .now.addingTimeInterval(86_400 * 3), hasTime: false)
        #expect(CalendarICS.uid(first) == CalendarICS.uid(moved))
        #expect(CalendarICS.uid(first) != CalendarICS.uid(entry("Статья", .now, hasTime: false, path: "/p/other")))
    }
}

struct WordGoalTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private let morning = Date(timeIntervalSince1970: 1_793_750_400 + 9 * 3600) // 2026-11-04 09:00 UTC

    @Test func theFirstLookStartsFromWhatIsThere() {
        let record = WordGoal.advanced(nil, counts: ["/a": 500], now: morning, calendar: calendar)
        #expect(record.day == "2026-11-04")
        #expect(record.written(["/a": 500]) == 0)
        #expect(record.written(["/a": 620]) == 120)
    }

    @Test func cutTextDoesNotGoBelowZeroAndANewFileStartsFromItself() {
        var record = WordGoal.advanced(nil, counts: ["/a": 500, "/b": 300], now: morning, calendar: calendar)
        record = WordGoal.advanced(record, counts: ["/a": 400, "/b": 350, "/c": 2000], now: morning.addingTimeInterval(3600), calendar: calendar)
        #expect(record.written(["/a": 400, "/b": 350, "/c": 2000]) == 50)
        #expect(record.written(["/a": 400, "/b": 350, "/c": 2100]) == 150)
    }

    @Test func aNewDayStartsFromYesterdaysLastLook() {
        let yesterday = WordGoal.advanced(nil, counts: ["/a": 500], now: morning.addingTimeInterval(-86_400), calendar: calendar)
        let evening = WordGoal.advanced(yesterday, counts: ["/a": 700], now: morning.addingTimeInterval(-86_400 + 3600 * 10), calendar: calendar)
        // Written at night, seen in the morning: it is today's.
        let today = WordGoal.advanced(evening, counts: ["/a": 760], now: morning, calendar: calendar)
        #expect(today.day == "2026-11-04")
        #expect(today.written(["/a": 760]) == 60)
    }

    @Test func afterALongerBreakTheDayStartsFromNow() {
        let old = WordGoal.advanced(nil, counts: ["/a": 500], now: morning.addingTimeInterval(-86_400 * 5), calendar: calendar)
        let today = WordGoal.advanced(old, counts: ["/a": 3000], now: morning, calendar: calendar)
        #expect(today.written(["/a": 3000]) == 0)
    }

    @Test func aFinishedDayGoesToTheHistoryAndDaysInARowAreCounted() {
        var record = WordGoal.advanced(nil, counts: ["/a": 0], now: morning.addingTimeInterval(-86_400 * 2), calendar: calendar)
        record = WordGoal.advanced(record, counts: ["/a": 400], now: morning.addingTimeInterval(-86_400 * 2 + 3600), calendar: calendar)
        record = WordGoal.advanced(record, counts: ["/a": 400], now: morning.addingTimeInterval(-86_400), calendar: calendar)
        record = WordGoal.advanced(record, counts: ["/a": 750], now: morning.addingTimeInterval(-86_400 + 3600), calendar: calendar)
        record = WordGoal.advanced(record, counts: ["/a": 750], now: morning, calendar: calendar)
        #expect(record.history == ["2026-11-02": 400, "2026-11-03": 350])
        // Today is not over: two days behind count while today's goal is open, three once it is reached.
        #expect(record.streak(goal: 300, today: 0, now: morning, calendar: calendar) == 2)
        #expect(record.streak(goal: 300, today: 300, now: morning, calendar: calendar) == 3)
        #expect(record.streak(goal: 380, today: 0, now: morning, calendar: calendar) == 0)
        #expect(record.streak(goal: 0, today: 100, now: morning, calendar: calendar) == 0)
    }

    @Test func theAnnouncedDayStaysThroughTheDaysLooks() {
        var record = WordGoal.advanced(nil, counts: ["/a": 0], now: morning, calendar: calendar)
        record.announcedDay = record.day
        record = WordGoal.advanced(record, counts: ["/a": 900], now: morning.addingTimeInterval(3600), calendar: calendar)
        #expect(record.announcedDay == "2026-11-04")
        let next = WordGoal.advanced(record, counts: ["/a": 900], now: morning.addingTimeInterval(86_400), calendar: calendar)
        #expect(next.announcedDay == nil)
        #expect(next.history == ["2026-11-04": 900])
    }

    @Test func theRecordSurvivesTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "word-goals-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let record = WordGoal.advanced(nil, counts: ["/a": 5], now: morning, calendar: calendar)
        WordGoal.save(["p": record], to: url)
        #expect(WordGoal.load(from: url) == ["p": record])
    }

    @Test func aProfileFileWithoutTheGoalHasNone() throws {
        let old = try JSONDecoder().decode(Profile.self, from: Data(#"{"name":"x"}"#.utf8))
        #expect(old.wordGoal == 0)
        var profile = Profile(name: "Тексты", wordGoal: 500)
        profile = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        #expect(profile.wordGoal == 500)
    }
}
