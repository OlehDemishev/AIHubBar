import Foundation
import Observation

/// The calendar of all enabled modes (SPEC-modes §6): dates from `проект.md` and `контент-план.md`, refreshed on
/// panel open if older than 60 s and every 5 minutes; reminders before each date; moving a date writes it back.
@MainActor
@Observable
final class CalendarStore {
    private(set) var entries: [CalendarEntry] = []
    private(set) var lastUpdated: Date?
    private(set) var lastError: String?
    private var isRefreshing = false

    private let settings: AppSettings
    private let modes: ModeStore
    private var loop: Task<Void, Never>?
    private static var remindedURL: URL { SessionFiles.supportDirectory.appending(path: "calendar-reminded.json") }

    init(settings: AppSettings, modes: ModeStore) {
        self.settings = settings
        self.modes = modes
    }

    /// Any enabled mode has a calendar.
    var isActive: Bool { modes.enabledModes.contains { $0.calendar != .off && $0.source.isFolders } }

    /// Modes whose new plan rows go into their `контент-план.md`.
    var planModes: [Mode] { modes.enabledModes.filter { $0.calendar == .contentPlan && $0.source.isFolders } }

    func upcoming(days: Int = 7, now: Date = .now) -> [CalendarEntry] {
        let end = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: now)) ?? now
        // Overdue deadlines stay until they are moved; overdue publications and plan rows only for a day.
        let since = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: now)) ?? now
        return entries.filter { entry in
            entry.date < end && (entry.date >= since || entry.kind == .deadline)
        }
    }

    /// The nearest date that is not past, for the menu bar.
    func nearest(now: Date = .now) -> CalendarEntry? {
        entries.first { !$0.isOverdue(now: now) }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }
    }

    func refreshIfStale() {
        if let lastUpdated, Date.now.timeIntervalSince(lastUpdated) < 60 { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let infos = modes.enabledModes.map {
            CalendarScanner.ModeInfo(id: $0.id, name: $0.name, icon: $0.icon, source: $0.source, calendar: $0.calendar)
        }
        let found = await Task.detached(priority: .utility) { CalendarScanner.entries(for: infos) }.value
        entries = found.sorted { $0.date < $1.date }
        lastUpdated = .now
        remind()
    }

    // MARK: - Writing back

    /// Moves an entry to another day, keeping its time.
    func move(_ entry: CalendarEntry, to day: Date) {
        let calendar = Calendar.current
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        let time = calendar.dateComponents([.hour, .minute], from: entry.date)
        parts.hour = time.hour
        parts.minute = time.minute
        guard let date = calendar.date(from: parts) else { return }
        setDate(entry, to: date)
    }

    func setDate(_ entry: CalendarEntry, to date: Date) {
        let ok: Bool
        switch entry.source {
        case let .card(path, key):
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            ok = write(ProjectCardFile.setting(key, to: CalendarScanner.text(date, withTime: entry.hasTime), in: text), to: path)
        case let .plan(path, line):
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  var changed = ContentPlan.setting(.date, of: line, to: CalendarScanner.text(date, withTime: false), in: text) else {
                lastError = "Строка контент-плана сдвинулась — обновите календарь"
                return
            }
            if entry.hasTime, let withTime = ContentPlan.setting(.time, of: line, to: date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)), in: changed) {
                changed = withTime
            }
            ok = write(changed, to: path)
        }
        guard ok else { return }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].date = date
            entries.sort { $0.date < $1.date }
        }
        AppLog.info("Calendar: «\(entry.title)» moved to \(CalendarScanner.text(date, withTime: entry.hasTime))")
    }

    /// A new row in a mode's own `контент-план.md` (created if missing).
    func addPlanRow(mode: Mode, date: Date, time: String, platform: String, topic: String) {
        guard let root = mode.source.folder.map(PathText.expand) else { return }
        let path = root + "/" + ContentPlan.fileName
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let values: [ContentPlan.Column: String] = [
            .date: CalendarScanner.text(date, withTime: false), .time: time, .platform: platform, .topic: topic, .status: "идея",
        ]
        guard write(ContentPlan.appending(values, to: text), to: path) else { return }
        Task { await refresh() }
    }

    /// Sets a project's deadline or publication date in its card.
    func setProjectDate(projectPath: String, key: ProjectCardFile.Key, date: Date, withTime: Bool) {
        let path = projectPath + "/" + ProjectCardFile.fileName
        let name = (projectPath as NSString).lastPathComponent
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ProjectCardFile.template(name: name, stage: nil)
        guard write(ProjectCardFile.setting(key, to: CalendarScanner.text(date, withTime: withTime), in: text), to: path) else { return }
        Task { await refresh() }
    }

    private func write(_ text: String, to path: String) -> Bool {
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            lastError = nil
            return true
        } catch {
            lastError = "Не удалось записать \((path as NSString).lastPathComponent): \(error.localizedDescription)"
            AppLog.error("Calendar write \(path) failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Reminders

    /// Each entry is announced once per reminder offset, when that moment has come and the date is still ahead.
    private func remind(now: Date = .now) {
        var reminded = Self.loadReminded()
        let due = Self.due(entries, hours: settings.calendarReminderHours, reminded: reminded, now: now)
        guard !due.isEmpty else { return }
        for (entry, key) in due {
            reminded.insert(key)
            let when = CalendarText.relative(entry.date, hasTime: entry.hasTime, now: now)
            Notifier.post(id: "calendar-\(abs(key.hashValue))", title: "\(entry.kind.title): \(entry.title)",
                          body: [when, entry.detail, entry.modeName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                          target: .file(path: entry.openPath))
            if settings.calendarRemindersToTelegram,
               let credentials = Telegram.credentials(dailyReportDirectory: settings.dailyReportDirectory) {
                let html = "📅 <b>\(RunMessage.escape(entry.kind.title)): \(RunMessage.escape(entry.title))</b>\n\(RunMessage.escape(when))"
                Task { _ = await Telegram.send(html: html, with: credentials) }
            }
        }
        Self.saveReminded(reminded)
    }

    /// Entries to announce now with their reminder keys: one per entry (the closest offset that has come), and only
    /// offsets not announced before. A date that has passed is not announced.
    nonisolated static func due(_ entries: [CalendarEntry], hours: [Int], reminded: Set<String>, now: Date) -> [(CalendarEntry, String)] {
        let offsets = hours.filter { $0 > 0 }.sorted()
        var result: [(CalendarEntry, String)] = []
        for entry in entries where entry.date > now {
            guard let offset = offsets.first(where: { now >= entry.date.addingTimeInterval(-Double($0) * 3600) }) else { continue }
            let key = entry.reminderKey + "|\(offset)"
            if !reminded.contains(key) { result.append((entry, key)) }
        }
        return result
    }

    private static func loadReminded() -> Set<String> {
        Set((try? Data(contentsOf: remindedURL)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
    }

    private static func saveReminded(_ keys: Set<String>) {
        try? FileManager.default.createDirectory(at: SessionFiles.supportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Array(keys.sorted().suffix(2000))).write(to: remindedURL, options: .atomic)
    }
}

enum CalendarText {
    /// «сегодня 18:00», «завтра», «через 3 дн», «просрочено 2 дн».
    static func relative(_ date: Date, hasTime: Bool, now: Date = .now) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let time = hasTime ? " " + date.formatted(date: .omitted, time: .shortened) : ""
        switch days {
        case ..<0: return "просрочено \(-days) дн"
        case 0: return "сегодня" + time
        case 1: return "завтра" + time
        default: return "через \(days) дн" + time
        }
    }

    /// For the menu bar: «Ролик · 2 дн».
    static func menuBar(_ entry: CalendarEntry, now: Date = .now) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: entry.date)).day ?? 0
        let title = entry.title.count > 14 ? String(entry.title.prefix(13)) + "…" : entry.title
        let when = days <= 0 ? (entry.hasTime ? entry.date.formatted(date: .omitted, time: .shortened) : "сегодня")
            : days == 1 ? "завтра" : "\(days) дн"
        return "\(title) · \(when)"
    }
}
