import AppKit
import SwiftUI

// «Отчёты _daily-report» (docs/SPEC-refactor.md §3): what the module is, its Settings sections and its «Панель сейчас» line.

extension ModuleDefinition {
    static let reports = ModuleDefinition(
        kind: .reports,
        group: .work,
        symbol: "doc.text.magnifyingglass",
        title: String(localized: "Отчёты _daily-report"),
        summary: String(localized: "Команды _daily-report: отчёт, быстрая сводка, очистка сборок."),
        tagline: String(localized: "Отчёт, сводка, очистка сборок"),
        isBuiltIn: true,
        notifications: [.commands],
        bringIn: .dailyReport,
        keywords: ["_daily-report"]
    )
}

extension ModuleUI {
    static let reports = ModuleUI(
        settings: { AnyView(ReportsSection()) },
        sketch: nil
    )
}

/// «Отчёты» has no settings of its own: the `_daily-report` folder belongs to the profile.
struct ReportsSection: View {
    var body: some View {
        Section {
            Text("Команды _daily-report: отчёт, быстрая сводка, очистка сборок. Папка _daily-report — у профиля.")
                .foregroundStyle(.secondary)
        }
    }
}
