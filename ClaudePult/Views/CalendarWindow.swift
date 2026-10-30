import AppKit
import SwiftUI

/// The «Календарь» window (SPEC-modes §6): month or week, all enabled modes or the current one, colour per mode.
/// Dragging an entry to another day writes the new date into its file; a double click on a day adds a date.
struct CalendarWindow: View {
    enum Scope: String, CaseIterable { case month, week }

    @Environment(CalendarStore.self) private var store
    @Environment(ModeStore.self) private var modes
    @AppStorage("calendarScope") private var scope: Scope = .month
    @AppStorage("calendarCurrentModeOnly") private var currentOnly = false
    @State private var anchor = Date.now
    @State private var newEntryDay: Date?

    private var calendar: Calendar { Calendar.current }

    private var entries: [CalendarEntry] {
        currentOnly ? store.entries.filter { $0.modeID == modes.currentID } : store.entries
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !store.isActive {
                Text("Календарь включается у профиля с проектами-папками: Настройки → «Профили» → «Календарь».")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                weekdayHeader
                grid
            }
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.orange).padding(6)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .task { await store.refresh() }
        .sheet(item: Binding(get: { newEntryDay.map(DayID.init) }, set: { newEntryDay = $0?.date })) { day in
            NewEntrySheet(day: day.date) { newEntryDay = nil }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Button("Сегодня") { anchor = .now }
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            Toggle("Только текущий профиль", isOn: $currentOnly)
                .toggleStyle(.checkbox)
            Picker("", selection: $scope) {
                Text("Месяц").tag(Scope.month)
                Text("Неделя").tag(Scope.week)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Перечитать файлы")
        }
        .buttonStyle(.borderless)
        .padding(10)
    }

    private var title: String {
        switch scope {
        case .month: return anchor.formatted(.dateTime.month(.wide).year())
        case .week:
            let days = self.days
            guard let first = days.first, let last = days.last else { return "" }
            return first.formatted(.dateTime.day().month(.abbreviated)) + " – " + last.formatted(.dateTime.day().month(.abbreviated).year())
        }
    }

    private func shift(_ step: Int) {
        anchor = calendar.date(byAdding: scope == .month ? .month : .weekOfYear, value: step, to: anchor) ?? anchor
    }

    /// Whole weeks covering the month, or the anchor's week.
    private var days: [Date] {
        let start: Date
        let count: Int
        switch scope {
        case .month:
            let month = calendar.dateInterval(of: .month, for: anchor)
            let first = month?.start ?? anchor
            start = calendar.dateInterval(of: .weekOfYear, for: first)?.start ?? first
            let last = calendar.date(byAdding: .day, value: -1, to: month?.end ?? first) ?? first
            let end = calendar.dateInterval(of: .weekOfYear, for: last)?.end ?? last
            count = calendar.dateComponents([.day], from: start, to: end).day ?? 35
        case .week:
            start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
            count = 7
        }
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(days.prefix(7), id: \.self) { day in
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    private var grid: some View {
        let days = self.days
        let rows = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        return VStack(spacing: 0) {
            ForEach(rows, id: \.first) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        DayCell(
                            day: day,
                            entries: byDay[calendar.startOfDay(for: day)] ?? [],
                            inMonth: scope == .week || calendar.isDate(day, equalTo: anchor, toGranularity: .month),
                            tall: scope == .week,
                            colorIndex: { modeIndex($0) }
                        )
                        .onTapGesture(count: 2) { newEntryDay = day }
                        .dropDestination(for: String.self) { ids, _ in
                            guard let id = ids.first, let entry = store.entries.first(where: { $0.id == id }) else { return false }
                            store.move(entry, to: day)
                            return true
                        }
                    }
                }
            }
        }
    }

    private func modeIndex(_ entry: CalendarEntry) -> Int {
        modes.modes.firstIndex { $0.id == entry.modeID } ?? 0
    }
}

private struct DayID: Identifiable {
    var date: Date
    var id: Date { date }
}

private struct DayCell: View {
    let day: Date
    let entries: [CalendarEntry]
    let inMonth: Bool
    let tall: Bool
    let colorIndex: (CalendarEntry) -> Int

    private static let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .green, .indigo, .brown]

    var body: some View {
        let isToday = Calendar.current.isDateInToday(day)
        VStack(alignment: .leading, spacing: 3) {
            Text(day.formatted(.dateTime.day()))
                .font(.caption.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.white : inMonth ? Color.primary : Color.secondary)
                .padding(.horizontal, 5)
                .background(Capsule().fill(isToday ? Color.accentColor : .clear))
            ForEach(entries.prefix(tall ? 20 : 4)) { entry in
                EntryChip(entry: entry, color: Self.palette[colorIndex(entry) % Self.palette.count])
            }
            if entries.count > (tall ? 20 : 4) {
                Text("ещё \(entries.count - 4)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(inMonth ? Color.clear : Color.primary.opacity(0.03))
        .overlay(Rectangle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .contentShape(Rectangle())
        .help("Двойной клик — новая дата")
    }
}

private struct EntryChip: View {
    let entry: CalendarEntry
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: entry.kind.symbol).font(.system(size: 9))
            if entry.hasTime {
                Text(entry.date.formatted(date: .omitted, time: .shortened)).monospacedDigit()
            }
            Text(entry.title).lineLimit(1)
        }
        .font(.caption2)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(entry.isOverdue() && entry.kind == .deadline ? 0.45 : 0.2)))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 2) }
        .help([entry.kind.title, entry.title, entry.detail, entry.modeName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: entry.openPath)) }
        .draggable(entry.id)
    }
}

/// A new date on a day: a content-plan row, or a deadline / publication of a project.
private struct NewEntrySheet: View {
    let day: Date
    let done: () -> Void

    enum Kind: String, CaseIterable { case plan, deadline, publish }

    @Environment(CalendarStore.self) private var store
    @Environment(ModeStore.self) private var modes
    @State private var kind: Kind = .plan
    @State private var modeID = ""
    @State private var projectPath = ""
    @State private var time = ""
    @State private var platform = ""
    @State private var topic = ""
    @State private var projects: [FolderProject] = []

    private var calendarModes: [Mode] { modes.enabledModes.filter { $0.calendar != .off && $0.source.isFolders } }
    private var mode: Mode? { calendarModes.first { $0.id == modeID } }

    var body: some View {
        Form {
            Text(day.formatted(date: .complete, time: .omitted)).font(.headline)
            Picker("Профиль", selection: $modeID) {
                ForEach(calendarModes) { Text($0.name).tag($0.id) }
            }
            Picker("Что", selection: $kind) {
                if mode?.calendar == .contentPlan { Text("Запись контент-плана").tag(Kind.plan) }
                Text("Дедлайн проекта").tag(Kind.deadline)
                Text("Публикация проекта").tag(Kind.publish)
            }
            TextField("Время", text: $time, prompt: Text("18:00 — можно пусто"))
            if kind == .plan {
                TextField("Площадка", text: $platform, prompt: Text("Instagram"))
                TextField("Тема", text: $topic)
            } else {
                Picker("Проект", selection: $projectPath) {
                    ForEach(projects) { Text($0.name).tag($0.path) }
                }
            }
            HStack {
                Spacer()
                Button("Отмена", action: done)
                Button("Добавить", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(kind == .plan ? topic.trimmingCharacters(in: .whitespaces).isEmpty : projectPath.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear {
            modeID = calendarModes.first(where: { $0.id == modes.currentID })?.id ?? calendarModes.first?.id ?? ""
            loadProjects()
        }
        .onChange(of: modeID) { loadProjects() }
    }

    private func loadProjects() {
        guard let mode else { projects = []; return }
        if mode.calendar != .contentPlan, kind == .plan { kind = .deadline }
        let source = mode.source
        projects = FolderScanner.scan(source: source)
        projectPath = projects.first?.path ?? ""
    }

    private func add() {
        guard let mode else { return }
        let clock = time.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .plan:
            store.addPlanRow(mode: mode, date: day, time: clock, platform: platform, topic: topic)
        case .deadline, .publish:
            let date = ProjectCardFile.date(CalendarScanner.text(day, withTime: false) + (clock.isEmpty ? "" : " " + clock)) ?? day
            store.setProjectDate(projectPath: projectPath, key: kind == .deadline ? .deadline : .publish, date: date, withTime: !clock.isEmpty)
        }
        done()
    }
}
