import AppKit
import SwiftUI

// «Быстрые переключатели» (docs/SPEC-refactor.md §3): what the module is, its Settings sections and its «Панель сейчас» line.

extension ModuleDefinition {
    static let toggles = ModuleDefinition(
        kind: .toggles,
        group: .mac,
        symbol: "switch.2",
        title: String(localized: "Быстрые переключатели"),
        summary: String(localized: "Тёмная тема, значки на рабочем столе, блокировка и выключение экрана, извлечение дисков, корзина — в один клик."),
        tagline: String(localized: "Тема, экран, диски, корзина"),
        keywords: [String(localized: "Какие переключатели показывать")]
    )
}

extension ModuleUI {
    static let toggles = ModuleUI(
        settings: { AnyView(QuickTogglesSection()) },
        sketch: { AnyView(TogglesSketch()) }
    )
}

/// «Панель сейчас»: how many toggles.
private struct TogglesSketch: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        SketchLine(String(localized: "Переключателей: \(settings.quickToggles.count)"))
    }
}

struct QuickTogglesSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModeStore.self) private var modes

    var body: some View {
        Section {
            ForEach(QuickToggle.available(installed: modes.activeModules), id: \.self) { toggle in
                Toggle(isOn: Binding(
                    get: { settings.quickToggles.contains(toggle) },
                    set: { on in settings.quickToggles = QuickToggle.allCases.filter { $0 == toggle ? on : settings.quickToggles.contains($0) } }
                )) {
                    Label(toggle.title, systemImage: toggle.symbol)
                }
            }
        } header: {
            Text("Какие переключатели показывать")
        } footer: {
            Footnote(text: String(localized: "Тёмная тема и корзина в первый раз попросят разрешение «Автоматизация» (System Events, Finder). Корзина очищается только после подтверждения."))
        }
    }
}
