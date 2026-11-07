import AppKit
import SwiftUI

// «Быстрый запрос» (docs/specs/SPEC-refactor.md §3): what the module is and its Settings section.

extension ModuleDefinition {
    static let quickPrompt = ModuleDefinition(
        kind: .quickPrompt,
        group: .ai,
        symbol: "text.bubble",
        title: String(localized: "Быстрый запрос"),
        summary: String(localized: "Горячая клавиша в любом приложении открывает окно: задача, проект и агент — и она уходит в фон или в новое окно Терминала."),
        tagline: String(localized: "Задача агенту из любого приложения"),
        isPanelBlock: false,
        places: [],
        keywords: [String(localized: "Горячая клавиша"), "Codex", "Terminal"]
    )
}

extension ModuleUI {
    static let quickPrompt = ModuleUI(
        settings: { AnyView(QuickPromptSection()) },
        sketch: nil
    )
}

/// «Быстрый запрос» (SPEC-quick-prompt §4): the hot key and a way to try the window.
struct QuickPromptSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(QuickPromptController.self) private var quickPrompt

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("Горячая клавиша", systemImage: "keyboard", selection: $settings.quickPrompt.hotKey) {
                ForEach(QuickPromptHotKey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            LabeledContent {
                Button("Открыть") { quickPrompt.show() }
            } label: {
                Label("Окно быстрого запроса", systemImage: "macwindow")
            }
        } footer: {
            Footnote(text: String(localized: "Проект — тот, что впереди (если «Универсальный доступ» уже выдан, например для «Раскладки»), иначе прошлый. Claude Code — в фоне или в Терминале, как «Своя задача…» у проекта; другие агенты открываются в Терминале, задача — в буфере обмена. Из скрипта: AIHubBar --app-command quick-prompt."))
        }
    }
}
