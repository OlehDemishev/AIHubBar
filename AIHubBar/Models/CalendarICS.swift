import CryptoKit
import Foundation

/// The calendar's dates as an iCalendar file (SPEC-modes §6, SPEC-content stage 5) for the system Calendar, Google
/// Calendar and the like. A file, written when the person asks: AI Hub Bar asks for no access to their calendars.
/// A date without a time is an all-day event; a timed one lasts half an hour. The UID comes from where the date
/// lives, so importing a newer file moves the events instead of doubling them.
enum CalendarICS {
    static func text(_ entries: [CalendarEntry], now: Date = .now, calendar: Calendar = .current) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//AI Hub Bar//Calendar//EN", "CALSCALE:GREGORIAN",
                     "METHOD:PUBLISH", "X-WR-CALNAME:AI Hub Bar"]
        var seen: [String: Int] = [:]
        for entry in entries.sorted(by: { ($0.date, $0.id) < ($1.date, $1.id) }) {
            // Two rows with the same name are two events: the later one gets a number.
            var id = uid(entry)
            seen[id, default: 0] += 1
            if let count = seen[id], count > 1 { id = "\(count)-" + id }
            lines += ["BEGIN:VEVENT", "UID:\(id)", "DTSTAMP:\(utc(now))"]
            if entry.hasTime {
                lines += ["DTSTART:\(utc(entry.date))", "DURATION:PT30M"]
            } else {
                let next = calendar.date(byAdding: .day, value: 1, to: entry.date) ?? entry.date
                lines += ["DTSTART;VALUE=DATE:\(day(entry.date, calendar))", "DTEND;VALUE=DATE:\(day(next, calendar))"]
            }
            lines.append("SUMMARY:" + escaped("\(entry.kind.title): \(entry.title)"))
            let description = [entry.detail, entry.modeName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            if !description.isEmpty { lines.append("DESCRIPTION:" + escaped(description)) }
            if entry.isDone { lines.append("STATUS:CONFIRMED") }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.flatMap(folded).joined(separator: "\r\n") + "\r\n"
    }

    /// A plan row is known by its file, kind and title, not by its line: a row removed above it must not turn it
    /// into another event at the next import. A new date keeps the id, so the calendar moves the event.
    static func uid(_ entry: CalendarEntry) -> String {
        let key: String = switch entry.source {
        case .card: entry.id
        case let .plan(path, _): "\(path)|\(entry.kind.rawValue)|\(entry.title)"
        }
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return digest + "@aihubbar"
    }

    /// RFC 5545 §3.3.11: backslash, semicolon, comma and line breaks.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// RFC 5545 §3.1: a line is at most 75 octets; the rest goes on lines that start with a space. Cut between
    /// characters, never inside one.
    static func folded(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var size = 0
        for character in line {
            let width = String(character).utf8.count
            if size + width > (result.isEmpty ? 75 : 74) {
                result.append(result.isEmpty ? current : " " + current)
                current = ""
                size = 0
            }
            current.append(character)
            size += width
        }
        result.append(result.isEmpty ? current : " " + current)
        return result
    }

    private static func utc(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func day(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
