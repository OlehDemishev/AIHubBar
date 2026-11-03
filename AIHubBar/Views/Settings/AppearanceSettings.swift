import AppKit
import SwiftUI

struct AppearanceSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        @Bindable var settings = settings
        SettingsPage {
            Section("Панель") {
                Picker("Тема", systemImage: "circle.lefthalf.filled", selection: $settings.panelTheme) {
                    ForEach(PanelTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Фон панели", systemImage: "square.on.square", selection: $settings.panelBackground) {
                    ForEach(PanelBackground.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!glassSupported)
                if let backgroundNote {
                    Footnote(text: backgroundNote)
                }
                Picker("Размер текста", systemImage: "textformat.size", selection: $settings.panelTextSize) {
                    ForEach(PanelTextSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Ширина", systemImage: "arrow.left.and.right", selection: $settings.panelWidth) {
                    ForEach(PanelWidth.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Плотность строк", systemImage: "line.3.horizontal", selection: $settings.panelDensity) {
                    ForEach(PanelDensity.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Анимации при открытии", systemImage: "sparkle", isOn: $settings.panelAnimations)
                TextSizePreview(scale: settings.panelTextSize.scale)
            }

            Section {
            } footer: {
                Footnote(text: String(localized: "Какие блоки показывать в панели и в каком порядке — у каждого профиля: вкладка «Профили» → «Панель»."))
            }

            Section {
                Button("Сбросить внешний вид") { settings.resetAppearance() }
            }
        }
    }
}

extension AppearanceSettings {
    var glassSupported: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    var backgroundNote: String? {
        if !glassSupported { return String(localized: "Стекло — в macOS 26 и новее.") }
        if settings.panelBackground == .glass, reduceTransparency {
            return String(localized: "Включено «Уменьшить прозрачность» — панель остаётся с обычным фоном.")
        }
        return nil
    }
}

/// A sample line at the chosen text size, so the effect is visible without opening the panel.
struct TextSizePreview: View {
    let scale: CGFloat

    var body: some View {
        IconRow("Пример", systemImage: "textformat") {
            VStack(alignment: .trailing, spacing: 2) {
                Text("Cantero · claude/feature")
                    .font(ScaledFont.font(.body, scale: scale, weight: .medium))
                Text("22 файла · 15 мин назад")
                    .font(ScaledFont.font(.caption, scale: scale))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
