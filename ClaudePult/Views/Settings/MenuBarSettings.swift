import SwiftUI

/// Settings → «Строка меню» (SPEC-settings §5): the live item on top, the order with dividers below it — drag to
/// reorder, click for an element's options — then the elements by module and the dividers to drag in.
struct MenuBarSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(UsageStore.self) private var usage
    @Environment(ModeStore.self) private var modes
    @State private var sample = true
    @State private var selection: Selection?

    enum Selection: Hashable {
        case element(MenuBarElement.Kind)
        case divider(String)
    }

    var body: some View {
        Form {
            Section {
                preview
            }
            Section {
                order
                inspector
            } header: {
                Text("Порядок слева направо")
            } footer: {
                Footnote(text: String(localized: "Перетащите элемент на другой — встанет на его место. Разделитель, брошенный на элемент, встаёт сразу после него. Клик — настройки элемента."))
            }
            Section {
                DividerPalette { style in edit { $0.addDivider(style, after: lastShown) } }
            } header: {
                Text("Разделители — сколько угодно раз")
            }
            Section {
                ElementPalette(config: modes.menuBar, modules: modes.activeModules) { kind in
                    edit { config in config.set(kind) { $0.enabled.toggle() } }
                    if modes.menuBar.element(kind).enabled { selection = .element(kind) }
                }
            } header: {
                Text("Элементы")
            } footer: {
                Footnote(text: String(localized: "Клик включает или убирает элемент; его можно и перетащить в нужное место в порядке. Элементов выключенных модулей здесь нет."))
            }
            Section {
                Picker("Набор", systemImage: "wand.and.stars", selection: Binding(
                    get: { modes.menuBar.preset },
                    set: { choose($0) }
                )) {
                    ForEach(MenuBarConfig.Preset.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Вид", systemImage: "capsule", selection: binding(\.look)) {
                    ForEach(MenuBarConfig.Look.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Между числами без своего разделителя", systemImage: "circle.fill", selection: binding(\.separator)) {
                    ForEach(MenuBarConfig.Separator.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Мелкий текст", systemImage: "textformat.size.smaller", isOn: binding(\.smallText))
                Toggle("Цвет по уровню (зелёный · оранжевый · красный)", systemImage: "paintpalette", isOn: binding(\.colored))
            } header: {
                Text("Вид")
            } footer: {
                Footnote(text: String(localized: "«Минимум» — значок, проблемы и ожидающие ответа. «Лимиты» — ещё сессия и неделя. «Всё» — всё, что есть. Набор меняет элементы, разделители остаются. «Капсулы» рисуют группы между «Новыми группами» на общей подложке. Строка меню у каждого профиля своя."))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Preview

    private var data: MenuBarData { (sample ? MenuBarData.sample : liveData).without(modes.silencedModules) }

    private var preview: some View {
        let config = modes.menuBar
        let width = MenuBarRenderer.width(config, data)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Предпросмотр", systemImage: "eye").font(.headline)
                Spacer()
                Picker("", selection: $sample) {
                    Text("Пример со всем").tag(true)
                    Text("Сейчас").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            HStack(spacing: 14) {
                Spacer()
                MenuBarItemImage(config: config, data: data)
                    .scaleEffect(1.4, anchor: .trailing)
                    .frame(height: 30)
                Text(Date.now.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 13 * 1.2, weight: .medium))
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary))
            if width > MenuBarRenderer.wideWidth {
                Label("Строка широкая (\(Int(width)) pt): на MacBook с вырезом её может закрыть вырез или скрыть система.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if !sample {
                Text("Так строка выглядит сейчас. Пустые элементы (0, нет данных) не показываются, их разделители тоже.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// Only what Settings can see; the real menu bar also counts sessions, runs and the queue.
    private var liveData: MenuBarData {
        var data = MenuBarData()
        data.session = usage.snapshot?.session?.utilization
        data.week = usage.snapshot?.week?.utilization
        data.modelWeeks = Dictionary((usage.snapshot?.otherWindows ?? []).map { ($0.key, $0.utilization) }) { first, _ in first }
        data.sessionResetsAt = usage.snapshot?.session?.resetsAt
        if case let .runsOutAt(date) = usage.forecast { data.forecastRunsOut = date }
        return data
    }

    // MARK: Order

    /// The switched-on elements and the dividers after each, in menu bar order.
    private var tokens: [OrderToken] {
        let config = modes.menuBar
        var result = config.dividers.filter { $0.after == nil }.map(OrderToken.divider)
        for element in config.elements {
            if element.enabled { result.append(.element(element.kind)) }
            result += config.dividers.filter { $0.after == element.kind }.map(OrderToken.divider)
        }
        return result
    }

    private var lastShown: MenuBarElement.Kind? { modes.menuBar.elements.last(where: \.enabled)?.kind }

    private var order: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(tokens.enumerated()), id: \.element.id) { index, token in
                OrderChip(token: token, isSelected: selection == token.selection) {
                    selection = selection == token.selection ? nil : token.selection
                } onDrop: { payload in
                    drop(payload, onto: token)
                }
                .contextMenu {
                    Button("Левее") { shift(at: index, by: -1) }.disabled(index == 0)
                    Button("Правее") { shift(at: index, by: 1) }.disabled(index == tokens.count - 1)
                    Divider()
                    Button("Убрать") { remove(token) }
                }
                .accessibilityAction(named: Text("Левее")) { shift(at: index, by: -1) }
                .accessibilityAction(named: Text("Правее")) { shift(at: index, by: 1) }
                .accessibilityAction(named: Text("Убрать")) { remove(token) }
            }
        }
        .padding(.vertical, 4)
        .animation(.snappy(duration: 0.2), value: tokens)
    }

    /// Swaps a chip with its neighbour — for the keyboard, the context menu and VoiceOver.
    private func shift(at index: Int, by offset: Int) {
        var list = tokens
        guard list.indices.contains(index), list.indices.contains(index + offset) else { return }
        list.swapAt(index, index + offset)
        edit { $0.arrange(list.map(\.arrangement)) }
    }

    private func remove(_ token: OrderToken) {
        switch token {
        case let .element(kind): edit { $0.set(kind) { $0.enabled = false } }
        case let .divider(divider): edit { $0.removeDivider(divider.id) }
        }
        if selection == token.selection { selection = nil }
    }

    /// The selected chip's place among the chips.
    private var selectedIndex: Int? { tokens.firstIndex { $0.selection == selection } }

    @ViewBuilder private func moveButtons() -> some View {
        if let index = selectedIndex {
            Button { shift(at: index, by: -1) } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0)
                .help("Левее")
            Button { shift(at: index, by: 1) } label: { Image(systemName: "chevron.right") }
                .disabled(index == tokens.count - 1)
                .help("Правее")
        }
    }

    /// An element dropped on an element takes its place; a divider dropped on an element goes right after it, on a
    /// divider — next to it.
    private func drop(_ payload: DragPayload, onto token: OrderToken) -> Bool {
        let target: MenuBarElement.Kind? = switch token {
        case let .element(kind): kind
        case let .divider(divider): divider.after
        }
        switch payload {
        case let .element(kind):
            guard case let .element(onto) = token else { return false }
            edit { config in
                config.set(kind) { $0.enabled = true }
                config.move(kind, onto: onto)
            }
            selection = .element(kind)
        case let .newDivider(style):
            edit { $0.addDivider(style, after: target) }
        case let .placedDivider(id):
            edit { $0.moveDivider(id, after: target) }
        }
        return true
    }

    @ViewBuilder private var inspector: some View {
        switch selection {
        case let .element(kind) where modes.menuBar.element(kind).enabled:
            let element = modes.menuBar.element(kind)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(element.kind.title, systemImage: element.kind.symbol).font(.headline)
                    Spacer()
                    moveButtons()
                    Button("Убрать") {
                        edit { $0.set(kind) { $0.enabled = false } }
                        selection = nil
                    }
                }
                ElementOptions(element: element, models: usage.snapshot?.otherWindows ?? []) { new in
                    edit { $0.set(kind) { $0 = new } }
                }
            }
        case let .divider(id):
            if let divider = modes.menuBar.dividers.first(where: { $0.id == id }) {
                HStack {
                    HStack(spacing: 8) {
                        DividerGlyph(style: divider.style)
                        Text(divider.style.title)
                    }
                    .font(.headline)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { divider.style },
                        set: { style in edit { config in
                            if let index = config.dividers.firstIndex(where: { $0.id == id }) { config.dividers[index].style = style }
                        } }
                    )) {
                        ForEach(MenuBarConfig.Divider.Style.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    moveButtons()
                    Button("Убрать") {
                        edit { $0.removeDivider(id) }
                        selection = nil
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: Editing

    private func choose(_ preset: MenuBarConfig.Preset) {
        var config = modes.menuBar
        if preset != .custom {
            let made = MenuBarConfig.make(preset)
            config.elements = made.elements
        }
        config.preset = preset
        modes.setMenuBar(config)
    }

    private func edit(_ change: (inout MenuBarConfig) -> Void) {
        var config = modes.menuBar
        change(&config)
        config.preset = .custom
        modes.setMenuBar(config)
    }

    private func binding<Value>(_ path: WritableKeyPath<MenuBarConfig, Value>) -> Binding<Value> {
        Binding(
            get: { modes.menuBar[keyPath: path] },
            set: { var config = modes.menuBar; config[keyPath: path] = $0; modes.setMenuBar(config) }
        )
    }
}

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

private enum OrderToken: Identifiable, Hashable {
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
private struct OrderChip: View {
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
private struct DividerPalette: View {
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
private struct DividerGlyph: View {
    let style: MenuBarConfig.Divider.Style

    var body: some View {
        Text(verbatim: style.glyph)
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// The elements by module; only working modules (SPEC-settings §5).
private struct ElementPalette: View {
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
private struct ElementOptions: View {
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
