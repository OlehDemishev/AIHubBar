import SwiftUI

/// Text size of the panel. macOS ignores `dynamicTypeSize` for text styles (checked), so the panel scales its own
/// fonts through `scaledFont` and the `panelTextScale` environment value.
enum PanelTextSize: String, CaseIterable, Sendable {
    case small, normal, large, extraLarge

    var title: String {
        switch self {
        case .small: "Мелкий"
        case .normal: "Обычный"
        case .large: "Крупный"
        case .extraLarge: "Очень крупный"
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
        case .narrow: "Узкая"
        case .normal: "Обычная"
        case .wide: "Широкая"
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
        case .compact: "Плотно"
        case .normal: "Обычно"
        case .spacious: "Просторно"
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
        case .system: "Как в системе"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Blocks of the panel that can be hidden.
enum PanelBlock: String, CaseIterable, Identifiable, Sendable {
    case limits, sessions, projects, commands

    var id: String { rawValue }

    var title: String {
        switch self {
        case .limits: "Лимиты"
        case .sessions: "Сессии"
        case .projects: "Проекты"
        case .commands: "Команды"
        }
    }
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
