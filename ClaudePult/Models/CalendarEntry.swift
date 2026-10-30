import Foundation

/// One date in the calendar (SPEC-modes §6): a project's deadline or publication from `проект.md`, or a row of a
/// `контент-план.md` table. Dates are written back to those files — ClaudePult keeps no calendar of its own.
struct CalendarEntry: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case deadline, publish, plan

        var title: String {
            switch self {
            case .deadline: "Дедлайн"
            case .publish: "Публикация"
            case .plan: "Контент-план"
            }
        }

        var symbol: String {
            switch self {
            case .deadline: "flag"
            case .publish: "paperplane"
            case .plan: "calendar.badge.clock"
            }
        }
    }

    /// Where the date lives, for writing it back.
    enum Source: Hashable, Sendable {
        case card(path: String, key: ProjectCardFile.Key)
        /// Line index of the row in the file when it was read.
        case plan(path: String, line: Int)
    }

    var date: Date
    var hasTime: Bool
    var kind: Kind
    var title: String
    /// Platform, status — whatever helps to recognise it.
    var detail: String?
    var modeID: String
    var modeName: String
    var modeIcon: String
    /// What a click opens: the project folder, the plan row's file, or the plan.
    var openPath: String
    var source: Source

    var id: String {
        switch source {
        case let .card(path, key): "\(path)#\(key.rawValue)"
        case let .plan(path, line): "\(path)#\(line)"
        }
    }

    /// Stable across edits of other rows, for reminders.
    var reminderKey: String {
        "\(openPath)|\(kind.rawValue)|\(title)|\(Int(date.timeIntervalSince1970))"
    }

    /// Only date-only deadlines become overdue the day after; timed ones right after the time.
    func isOverdue(now: Date = .now) -> Bool {
        hasTime ? date < now : date < Calendar.current.startOfDay(for: now)
    }
}

/// `контент-план.md` (SPEC-modes §6): a Markdown table `| Дата | Время | Площадка | Тема | Статус | Файл |`, editable
/// by hand and by Claude. Columns are found by their header; other columns and all other text are kept.
struct ContentPlan: Equatable, Sendable {
    static let fileName = "контент-план.md"

    enum Column: String, CaseIterable, Sendable {
        case date, time, platform, topic, status, file

        var headers: [String] {
            switch self {
            case .date: ["дата", "date"]
            case .time: ["время", "time"]
            case .platform: ["площадка", "platform"]
            case .topic: ["тема", "topic", "title"]
            case .status: ["статус", "status"]
            case .file: ["файл", "file"]
            }
        }
    }

    struct Row: Equatable, Sendable {
        var line: Int
        var cells: [String]
        var columns: [Column: Int]

        func value(_ column: Column) -> String? {
            columns[column].flatMap { $0 < cells.count ? cells[$0] : nil }.flatMap { $0.isEmpty ? nil : $0 }
        }

        /// `2026-11-03` + `18:00`; the time column may also be missing or empty.
        var date: (Date, hasTime: Bool)? {
            guard let day = value(.date) else { return nil }
            if let time = value(.time), let date = ProjectCardFile.date("\(day) \(time)") { return (date, true) }
            return ProjectCardFile.date(day).map { ($0, day.contains(":")) }
        }
    }

    var rows: [Row] = []
    var columns: [Column: Int] = [:]
    /// The line of the table's last row (or its separator when empty), where a new row goes after.
    var lastLine: Int?
    var columnCount = 0

    static func cells(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return nil }
        var body = trimmed.dropFirst()
        if body.hasSuffix("|") { body = body.dropLast() }
        // `\|` is a pipe inside a cell.
        let placeholder = "\u{1}"
        return body.replacingOccurrences(of: "\\|", with: placeholder).split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: placeholder, with: "\\|").trimmingCharacters(in: .whitespaces) }
    }

    static func parse(_ text: String) -> ContentPlan {
        let lines = text.components(separatedBy: "\n")
        var plan = ContentPlan()
        var index = 0
        while index < lines.count {
            guard let header = cells(lines[index]) else { index += 1; continue }
            var columns: [Column: Int] = [:]
            for (position, name) in header.enumerated() {
                let name = name.lowercased()
                if let column = Column.allCases.first(where: { $0.headers.contains(name) }), columns[column] == nil {
                    columns[column] = position
                }
            }
            guard columns[.date] != nil, index + 1 < lines.count,
                  let separator = cells(lines[index + 1]), separator.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) else {
                index += 1
                continue
            }
            plan.columns = columns
            plan.columnCount = header.count
            plan.lastLine = index + 1
            var line = index + 2
            while line < lines.count, let row = cells(lines[line]) {
                plan.rows.append(Row(line: line, cells: row, columns: columns))
                plan.lastLine = line
                line += 1
            }
            return plan
        }
        return plan
    }

    /// A new value for one cell of a row; returns nil when the row or column is not where it was.
    static func setting(_ column: Column, of line: Int, to value: String, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        let plan = parse(text)
        guard line < lines.count, var cells = cells(lines[line]), let position = plan.columns[column],
              plan.rows.contains(where: { $0.line == line }) else { return nil }
        while cells.count <= position { cells.append("") }
        cells[position] = value
        lines[line] = "| " + cells.joined(separator: " | ") + " |"
        return lines.joined(separator: "\n")
    }

    /// Appends a row to the table, or creates the file's table when there is none.
    static func appending(_ values: [Column: String], to text: String) -> String {
        let plan = parse(text)
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        guard let last = plan.lastLine else {
            let header = Column.allCases
            var block = [
                "| Дата | Время | Площадка | Тема | Статус | Файл |",
                "|---|---|---|---|---|---|",
                "| " + header.map { values[$0] ?? "" }.joined(separator: " | ") + " |",
            ]
            if !lines.isEmpty, lines.last?.isEmpty == false { block.insert("", at: 0) }
            if lines.isEmpty { block.insert(contentsOf: ["# Контент-план", ""], at: 0) }
            return (lines + block).joined(separator: "\n") + "\n"
        }
        var cells = Array(repeating: "", count: max(plan.columnCount, 1))
        for (column, value) in values { if let position = plan.columns[column], position < cells.count { cells[position] = value } }
        lines.insert("| " + cells.joined(separator: " | ") + " |", at: last + 1)
        return lines.joined(separator: "\n")
    }
}

/// Collects calendar entries of modes from their folders. Pure file work, off the main actor.
enum CalendarScanner {
    struct ModeInfo: Sendable {
        var id: String
        var name: String
        var icon: String
        var source: ProjectSource
        var calendar: CalendarMode
    }

    static func entries(for modes: [ModeInfo]) -> [CalendarEntry] {
        modes.filter { $0.calendar != .off && $0.source.isFolders }.flatMap(entries)
    }

    static func entries(for mode: ModeInfo) -> [CalendarEntry] {
        var result: [CalendarEntry] = []
        let projects = FolderScanner.scan(source: mode.source)
        for project in projects {
            for (key, kind) in [(ProjectCardFile.Key.deadline, CalendarEntry.Kind.deadline), (.publish, .publish)] {
                guard let text = project.card.values[key], let date = ProjectCardFile.date(text) else { continue }
                result.append(CalendarEntry(
                    date: date, hasTime: text.contains(":"), kind: kind, title: project.name,
                    detail: project.card.values[.platform] ?? project.card.stage,
                    modeID: mode.id, modeName: mode.name, modeIcon: mode.icon, openPath: project.path,
                    source: .card(path: project.path + "/" + ProjectCardFile.fileName, key: key)
                ))
            }
        }
        guard mode.calendar == .contentPlan, let root = mode.source.folder.map(PathText.expand) else { return result }
        // The mode's own plan and each campaign's plan.
        var folders = [root]
        for path in projects.map(\.path) where !folders.contains(path) { folders.append(path) }
        for folder in folders {
            let path = folder + "/" + ContentPlan.fileName
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for row in ContentPlan.parse(text).rows {
                guard let (date, hasTime) = row.date else { continue }
                let file = row.value(.file).map { folder + "/" + $0 }
                result.append(CalendarEntry(
                    date: date, hasTime: hasTime, kind: .plan, title: row.value(.topic) ?? "Без темы",
                    detail: [row.value(.platform), row.value(.status)].compactMap { $0 }.joined(separator: " · "),
                    modeID: mode.id, modeName: mode.name, modeIcon: mode.icon,
                    openPath: file.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? path,
                    source: .plan(path: path, line: row.line)
                ))
            }
        }
        return result
    }

    /// The date as it is written back: `2026-11-05` or `2026-11-05 18:00`.
    static func text(_ date: Date, withTime: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = withTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
