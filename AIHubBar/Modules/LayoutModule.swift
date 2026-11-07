import AppKit
import SwiftUI

// «Раскладка» (docs/specs/SPEC-refactor.md §3): what the module is, its Settings sections and its «Панель сейчас» line.

extension ModuleDefinition {
    static let layout = ModuleDefinition(
        kind: .layout,
        group: .mac,
        symbol: "keyboard",
        title: String(localized: "Раскладка"),
        summary: String(localized: "Слово, набранное не в той раскладке («ghbdtn»), исправляется само («привет»), и раскладка переключается."),
        tagline: String(localized: "Исправляет текст не в той раскладке"),
        isPanelBlock: false,
        places: [.menuBar],
        ownMenuBarItem: true,
        keywords: [String(localized: "Исправлять раскладку сам"), String(localized: "Двойной Shift — последнее слово"),
            String(localized: "⌥⇧ — выделенный текст"), String(localized: "Язык в строке меню")]
    )
}

extension ModuleUI {
    static let layout = ModuleUI(
        settings: { AnyView(LayoutSection()) },
        sketch: nil
    )
}

/// «Раскладка» (SPEC-layout §4): the permission, the layouts it switches between and the few switches it has.
struct LayoutSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LayoutSwitcher.self) private var switcher

    var body: some View {
        @Bindable var settings = settings
        Section {
            if !switcher.trusted {
                LabeledContent {
                    Button("Открыть настройки") { switcher.requestAccess() }
                } label: {
                    Label("Нужно разрешение «Универсальный доступ»", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            IconRow("Раскладки", systemImage: "keyboard", value: switcher.layouts.isEmpty ? String(localized: "нет подходящих") : switcher.layouts.map(\.name).joined(separator: ", "))
            Toggle("Исправлять раскладку сам", systemImage: "wand.and.stars", isOn: $settings.layout.auto)
            Toggle("Не исправлять в терминалах", systemImage: "terminal", isOn: $settings.layout.skipTerminals)
                .disabled(!settings.layout.auto)
            Toggle("Двойной Shift — последнее слово", systemImage: "shift", isOn: $settings.layout.doubleShift)
            Toggle("⌥⇧ — выделенный текст", systemImage: "option", isOn: $settings.layout.optionShift)
                // The language in the menu bar is the chip under «Где показывать».
                .onChange(of: settings.layout.menuBarIcon) { switcher.sync() }
        } footer: {
            Footnote(text: switcher.layouts.count < 2
                ? String(localized: "Нужны хотя бы две раскладки из: русская, английская, украинская, немецкая, французская, испанская, португальская. Добавьте их в Системных настройках → Клавиатура → Источники ввода.")
                : String(localized: "Слово проверяется системным словарём, когда вы ставите пробел, Enter или Tab. Двойной Shift сразу после исправления отменяет его и запоминает слово. Пароли и поля паролей не читаются, набранное никуда не записывается."))
        }
        Section {
            if settings.layout.learned.isEmpty {
                Text("Пока пусто")
                    .foregroundStyle(.secondary)
            }
            ForEach(settings.layout.learned, id: \.self) { word in
                LabeledContent(word) {
                    Button("Убрать") { switcher.forgetLearned(word) }
                        .controlSize(.small)
                }
            }
        } header: {
            Text("Не исправлять")
        } footer: {
            Footnote(text: String(localized: "Слова, исправление которых вы отменили двойным Shift или ⌘Z. Уберите слово, чтобы оно снова исправлялось."))
        }
    }
}
