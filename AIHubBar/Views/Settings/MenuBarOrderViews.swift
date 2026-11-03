import SwiftUI

// MARK: - Drag and drop

/// What a chip carries while dragged, as text.
enum DragPayload {
    case element(MenuBarElement.Kind)
    case newDivider(MenuBarConfig.Divider.Style)
    case placedDivider(String)

    var text: String {
        switch self {
        case let .element(kind): "element:" + kind.rawValue
        case let .newDivider(style): "new-divider:" + style.rawValue
        case let .placedDivider(id): "divider:" + id
        }
    }

    init?(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "element": guard let kind = MenuBarElement.Kind(rawValue: parts[1]) else { return nil }; self = .element(kind)
        case "new-divider": guard let style = MenuBarConfig.Divider.Style(rawValue: parts[1]) else { return nil }; self = .newDivider(style)
        case "divider": self = .placedDivider(parts[1])
        default: return nil
        }
    }
}

enum OrderToken: Identifiable, Hashable {
    case element(MenuBarElement.Kind)
    case divider(MenuBarConfig.Divider)

    var id: String {
        switch self {
        case let .element(kind): "element:" + kind.rawValue
        case let .divider(divider): "divider:" + divider.id
        }
    }

    var selection: MenuBarSettings.Selection {
        switch self {
        case let .element(kind): .element(kind)
        case let .divider(divider): .divider(divider.id)
        }
    }

    var arrangement: MenuBarConfig.Arranged {
        switch self {
        case let .element(kind): .element(kind)
        case let .divider(divider): .divider(divider)
        }
    }

    var payload: DragPayload {
        switch self {
        case let .element(kind): .element(kind)
        case let .divider(divider): .placedDivider(divider.id)
        }
    }
}

/// One element or divider in the order: a drag source and a drop target.
struct OrderChip: View {
    let token: OrderToken
    let isSelected: Bool
    let onTap: () -> Void
    let onDrop: (DragPayload) -> Bool
    @State private var targeted = false

    var body: some View {
        label
            .padding(.horizontal, isDivider ? 7 : 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(targeted || isSelected ? Color.accentColor : Color.secondary.opacity(isDivider ? 0.35 : 0), style: StrokeStyle(lineWidth: 1, dash: isDivider && !targeted && !isSelected ? [3, 2] : [])))
            .contentShape(Capsule())
            .onTapGesture(perform: onTap)
            .draggable(token.payload.text) { label.padding(6) }
            .dropDestination(for: String.self) { items, _ in
                guard let payload = items.first.flatMap(DragPayload.init) else { return false }
                return onDrop(payload)
            } isTargeted: { targeted = $0 }
            .help(help)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var isDivider: Bool { if case .divider = token { true } else { false } }

    private var fill: Color {
        if targeted { return Color.accentColor.opacity(0.3) }
        if isSelected { return Color.accentColor.opacity(0.18) }
        return isDivider ? .clear : Color.secondary.opacity(0.14)
    }

    @ViewBuilder private var label: some View {
        switch token {
        case let .element(kind):
            Label(kind.shortTitle, systemImage: kind.symbol)
                .font(.system(size: 13))
        case let .divider(divider):
            DividerGlyph(style: divider.style)
                .frame(minWidth: 14)
        }
    }

    private var help: String {
        switch token {
        case let .element(kind): kind.title
        case let .divider(divider): divider.style.title
        }
    }
}

/// The dividers to drag into the order (a click puts one at the end).
struct DividerPalette: View {
    let add: (MenuBarConfig.Divider.Style) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(MenuBarConfig.Divider.Style.allCases, id: \.self) { style in
                Button { add(style) } label: {
                    HStack(spacing: 7) {
                        DividerGlyph(style: style)
                        Text(style.title)
                    }
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .draggable(DragPayload.newDivider(style).text) { Text(style.title).padding(6) }
                .help(String(localized: "Перетащите на элемент в порядке — встанет после него; клик — в конец"))
            }
        }
        .padding(.vertical, 4)
    }
}

/// A divider as it looks in the menu bar, for the chips.
struct DividerGlyph: View {
    let style: MenuBarConfig.Divider.Style

    var body: some View {
        Text(verbatim: style.glyph)
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// The elements by module; only working modules (SPEC-settings §5).
struct ElementPalette: View {
    let config: MenuBarConfig
    let modules: [ModuleKind]
    let toggle: (MenuBarElement.Kind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Label(group.title, systemImage: group.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(group.kinds, id: \.self) { kind in
                            let on = config.element(kind).enabled
                            Button { toggle(kind) } label: {
                                Label(kind.shortTitle, systemImage: on ? "checkmark" : kind.symbol)
                                    .font(.system(size: 13, weight: on ? .medium : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .foregroundStyle(on ? Color.accentColor : .primary)
                                    .background(Capsule().fill(on ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1)))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .draggable(DragPayload.element(kind).text) { Label(kind.shortTitle, systemImage: kind.symbol).padding(6) }
                            .help(kind.title)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var groups: [(title: String, symbol: String, kinds: [MenuBarElement.Kind])] {
        var result: [(String, String, [MenuBarElement.Kind])] = [(String(localized: "Общее"), "sparkle", [.icon, .mode, .disk])]
        for module in ModuleKind.allCases where modules.contains(module) {
            let kinds = MenuBarElement.Kind.allCases.filter { $0.module == module }
            if !kinds.isEmpty { result.append((module.title, module.symbol, kinds)) }
        }
        return result
    }
}

/// An element's own options: symbol, gauge look, threshold, format.
struct ElementOptions: View {
    let element: MenuBarElement
    let models: [UsageWindow]
    let onChange: (MenuBarElement) -> Void

    private static let symbols: [(String, String)] = [
        ("sparkle", String(localized: "✦ Искра")), ("star", String(localized: "Звезда")), ("bolt", String(localized: "Молния")), ("brain", String(localized: "Мозг")), ("terminal", String(localized: "Терминал")),
        ("mode", String(localized: "Значок профиля")), ("none", String(localized: "Без значка")),
    ]

    var body: some View {
        switch element.kind {
        case .icon:
            Picker("Символ", selection: value(\.symbol)) {
                ForEach(Self.symbols, id: \.0) { symbol, title in
                    if symbol == "mode" || symbol == "none" {
                        Text(title).tag(symbol)
                    } else {
                        Label(title, systemImage: symbol).tag(symbol)
                    }
                }
            }
        case .session, .week, .modelWeek, .cpu, .memory, .otherAI:
            if element.kind == .otherAI {
                Picker("Сервис", selection: value(\.model)) {
                    Text("Самый загруженный").tag(String?.none)
                    ForEach(HubLimit.Source.allCases) { Text($0.title).tag(String?.some($0.rawValue)) }
                }
            }
            if element.kind == .modelWeek {
                Picker("Модель", selection: value(\.model)) {
                    Text("Первая доступная").tag(String?.none)
                    ForEach(models, id: \.key) { Text($0.title).tag(String?.some($0.key)) }
                }
            }
            Picker("Как", selection: value(\.style)) {
                ForEach(MenuBarElement.GaugeStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Показывать", selection: value(\.showAbove)) {
                Text("всегда").tag(0)
                ForEach([50, 70, 80, 90], id: \.self) { Text("от \($0) %").tag($0) }
            }
        case .resetCountdown:
            Picker("Формат", selection: value(\.longFormat)) {
                Text("2:14").tag(false)
                Text("2 ч 14 мин").tag(true)
            }
            .pickerStyle(.segmented)
        case .disk:
            Picker("Показывать, когда свободно меньше", selection: value(\.diskBelowGB)) {
                ForEach([5, 10, 20, 50, 100], id: \.self) { Text("\($0) ГБ").tag($0) }
            }
        case .mode:
            Picker("Показывать", selection: value(\.showName)) {
                Text("Значок").tag(false)
                Text("Название").tag(true)
            }
            .pickerStyle(.segmented)
        case .projectsAlert, .forecast, .waiting, .running, .background, .queued, .deadline, .keepAwake:
            Text("Своих настроек нет.").foregroundStyle(.secondary)
        }
    }

    private func value<Value>(_ path: WritableKeyPath<MenuBarElement, Value>) -> Binding<Value> {
        Binding(
            get: { element[keyPath: path] },
            set: {
                var new = element
                new[keyPath: path] = $0
                onChange(new)
            }
        )
    }
}

extension MenuBarElement.Kind {
    /// For the chips in Settings.
    var symbol: String {
        switch self {
        case .icon: "sparkle"
        case .projectsAlert: "exclamationmark.circle"
        case .session: "clock"
        case .week: "calendar.day.timeline.left"
        case .modelWeek: "cube"
        case .resetCountdown: "arrow.clockwise"
        case .forecast: "chart.line.uptrend.xyaxis"
        case .waiting: "hand.raised"
        case .running: "bolt"
        case .background: "moon.zzz"
        case .queued: "clock.badge"
        case .deadline: "calendar"
        case .disk: "internaldrive"
        case .mode: "square.stack.3d.up"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .keepAwake: "cup.and.saucer"
        case .otherAI: "sparkles"
        }
    }
}
