import AppKit
import SwiftUI

/// Text size of the panel. macOS ignores `dynamicTypeSize` for text styles (checked), so the panel scales its own
/// fonts through `scaledFont` and the `panelTextScale` environment value.
enum PanelTextSize: String, CaseIterable, Sendable {
    case small, normal, large, extraLarge

    var title: String {
        switch self {
        case .small: String(localized: "Мелкий")
        case .normal: String(localized: "Обычный")
        case .large: String(localized: "Крупный")
        case .extraLarge: String(localized: "Очень крупный")
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: 0.9
        case .normal: 1
        case .large: 1.15
        case .extraLarge: 1.3
        }
    }
}

/// Panel width; text scaling widens it proportionally on top.
enum PanelWidth: String, CaseIterable, Sendable {
    case narrow, normal, wide

    var title: String {
        switch self {
        case .narrow: String(localized: "Узкая")
        case .normal: String(localized: "Обычная")
        case .wide: String(localized: "Широкая")
        }
    }

    var points: CGFloat {
        switch self {
        case .narrow: 380
        case .normal: 420
        case .wide: 500
        }
    }
}

/// Spacing of rows in the panel.
enum PanelDensity: String, CaseIterable, Sendable {
    case compact, normal, spacious

    var title: String {
        switch self {
        case .compact: String(localized: "Плотно")
        case .normal: String(localized: "Обычно")
        case .spacious: String(localized: "Просторно")
        }
    }

    /// Multiplier for vertical row padding.
    var spacing: CGFloat {
        switch self {
        case .compact: 0.5
        case .normal: 1
        case .spacious: 1.5
        }
    }
}

/// Light / dark / follow the system, for the panel and ClaudePult's windows.
enum PanelTheme: String, CaseIterable, Sendable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: String(localized: "Как в системе")
        case .light: String(localized: "Светлая")
        case .dark: String(localized: "Тёмная")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// `preferredColorScheme` doesn't reach the `MenuBarExtra` window (the panel stayed light with «Тёмная»),
    /// so the panel sets its window's appearance as well.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Blocks of the panel that can be hidden.
enum PanelBlock: String, CaseIterable, Identifiable, Sendable {
    case limits, sessions, calendar, projects, commands, resources, keepAwake, quickCommands, toggles, clipboard, notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .limits: String(localized: "Лимиты")
        case .sessions: String(localized: "Сессии")
        case .calendar: String(localized: "Ближайшее (календарь)")
        case .projects: String(localized: "Проекты")
        case .commands: String(localized: "Команды")
        case .resources: String(localized: "Ресурсы Mac")
        case .keepAwake: String(localized: "Не спать")
        case .quickCommands: String(localized: "Быстрые команды")
        case .toggles: String(localized: "Быстрые переключатели")
        case .clipboard: String(localized: "История буфера")
        case .notes: String(localized: "Заметки")
        }
    }
}

extension PanelBlock {
    /// Folded blocks, kept in `collapsedBlocks` as «limits,projects».
    static func collapsed(in raw: String) -> Set<PanelBlock> {
        Set(raw.split(separator: ",").compactMap { PanelBlock(rawValue: String($0)) })
    }

    static func toggling(_ block: PanelBlock, in raw: String) -> String {
        var set = collapsed(in: raw)
        if set.contains(block) { set.remove(block) } else { set.insert(block) }
        return allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
    }
}

/// A panel block's title that folds the block — the panel gets tall on a laptop screen. A click toggles it,
/// and the choice is kept between openings.
struct BlockTitle: View {
    let block: PanelBlock
    let title: LocalizedStringKey
    @AppStorage("collapsedBlocks") private var collapsedRaw = ""

    var body: some View {
        let collapsed = PanelBlock.collapsed(in: collapsedRaw).contains(block)
        Button {
            withAnimation(.snappy(duration: 0.2)) { collapsedRaw = PanelBlock.toggling(block, in: collapsedRaw) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .scaledFont(.caption2, weight: .semibold)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(title)
                    .scaledFont(.caption, weight: .semibold)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? String(localized: "Развернуть") : String(localized: "Свернуть"))
    }
}

/// The panel's blocks sit on rounded cards (design variant A, 2026-10-30) instead of between dividers.
private struct PanelCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055)))
            .padding(.horizontal, 8)
    }
}

extension View {
    func panelCard() -> some View { modifier(PanelCard()) }
}

extension EnvironmentValues {
    @Entry var panelTextScale: CGFloat = 1
    @Entry var panelDensity: CGFloat = 1
}

/// macOS sizes of the system text styles, in points.
enum ScaledFont {
    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        @unknown default: 13
        }
    }

    static func font(_ style: Font.TextStyle, scale: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        let defaultWeight: Font.Weight = style == .headline ? .bold : .regular
        return .system(size: (baseSize(style) * scale).rounded(), weight: weight ?? defaultWeight, design: design ?? .default)
    }
}

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.panelTextScale) private var scale
    let style: Font.TextStyle?
    let size: CGFloat?
    let weight: Font.Weight?
    let design: Font.Design?

    func body(content: Content) -> some View {
        if let size {
            content.font(.system(size: (size * scale).rounded(), weight: weight ?? .regular, design: design ?? .default))
        } else {
            content.font(ScaledFont.font(style ?? .body, scale: scale, weight: weight, design: design))
        }
    }
}

extension View {
    /// A system text style scaled by the panel's text size setting.
    func scaledFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(ScaledFontModifier(style: style, size: nil, weight: weight, design: design))
    }

    /// A fixed point size scaled by the panel's text size setting.
    func scaledFont(size: CGFloat, weight: Font.Weight? = nil) -> some View {
        modifier(ScaledFontModifier(style: nil, size: size, weight: weight, design: nil))
    }

    /// Vertical padding scaled by the density setting.
    func densityPadding(_ base: CGFloat) -> some View {
        modifier(DensityPadding(base: base))
    }
}

private struct DensityPadding: ViewModifier {
    @Environment(\.panelDensity) private var density
    let base: CGFloat

    func body(content: Content) -> some View {
        content.padding(.vertical, (base * density).rounded())
    }
}
