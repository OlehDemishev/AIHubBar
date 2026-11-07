import AppKit
import SwiftUI

// «Ближайшее» (docs/specs/SPEC-refactor.md §3): what the module is, its Settings sections and its «Панель сейчас» line.

extension ModuleDefinition {
    static let upcoming = ModuleDefinition(
        kind: .upcoming,
        group: .work,
        symbol: "calendar",
        title: String(localized: "Ближайшее"),
        summary: String(localized: "Дедлайны, публикации и контент-план на 7 дней вперёд — из профилей с календарём."),
        tagline: String(localized: "Дедлайны и публикации на 7 дней"),
        isBuiltIn: true,
        places: [.panel, .menuBar, .notifications, .telegram],
        menuBarKinds: [.deadline],
        primaryMenuBarKinds: [.deadline],
        notifications: [.calendar],
        notificationSwitch: .calendarReminders,
        telegram: .calendarReminders,
        bringIn: .calendar,
        keywords: [String(localized: "Напоминания"), String(localized: "Календарь")]
    )
}

extension ModuleUI {
    static let upcoming = ModuleUI(
        settings: { AnyView(ReminderSection()) },
        sketch: { AnyView(UpcomingSketch()) }
    )
}

/// «Панель сейчас»: the nearest date.
private struct UpcomingSketch: View {
    @Environment(CalendarStore.self) private var calendar

    var body: some View {
        SketchLine(calendar.nearest().map { CalendarText.menuBar($0) } ?? String(localized: "Ничего на 7 дней"))
    }
}

struct ReminderSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("Напоминать", systemImage: "alarm", selection: Binding(
                get: { settings.calendarReminderHours },
                set: { settings.calendarReminderHours = $0 }
            )) {
                Text("не напоминать").tag([Int]())
                Text("за 2 часа").tag([2])
                Text("за сутки").tag([24])
                Text("за сутки и за 2 часа").tag([24, 2])
                Text("за 3 дня и за сутки").tag([72, 24])
            }
        } header: {
            Text("Напоминания")
        } footer: {
            Footnote(text: String(localized: "Даты — из проект.md (дедлайн, публикация) и контент-план.md у профилей с календарём."))
        }
    }
}
