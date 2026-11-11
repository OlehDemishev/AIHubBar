import SwiftUI

/// Settings → «Строка меню» (SPEC-settings §5): the live item on top, the order with dividers below it — drag to
/// reorder, click for an element's options — then the elements by module and the dividers to drag in.
struct MenuBarSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(UsageStore.self) private var usage
    @Environment(HubLimitsStore.self) private var hub
    @State private var replacing: MenuBarConfig.Preset?
    @Environment(NotchIsland.self) private var island
    @Environment(ProfileStore.self) private var modes
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
                    set: { preset in
                        // A ready-made set overwrites what the person arranged by hand.
                        if modes.menuBar.preset == .custom, preset != .custom { replacing = preset } else { choose(preset) }
                    }
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
        .confirmationDialog("Заменить свой порядок элементов?", isPresented: Binding(
            get: { replacing != nil },
            set: { if !$0 { replacing = nil } }
        )) {
            Button("Заменить", role: .destructive) {
                if let replacing { choose(replacing) }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    // MARK: Preview

    private var data: MenuBarData { sample ? MenuBarData.sample : liveData }

    private var preview: some View {
        let config = (island.takesMenuBarSummary ? modes.menuBar.iconOnly : modes.menuBar).without(modes.silencedModules)
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
            if island.takesMenuBarSummary {
                Text("Лимиты и сессии сейчас в острове: в строке меню остаются значок и красная точка проектов.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        // The two numbers are the main service's: Claude, or another one for whoever has no Claude.
        let main = MainService.current(usage: usage, hub: hub, settings: settings)
        data.session = main?.firstLimit?.percent
        data.week = main?.secondLimit?.percent
        data.modelWeeks = Dictionary((usage.snapshot?.otherWindows ?? []).map { ($0.key, $0.utilization) }) { first, _ in first }
        data.sessionResetsAt = main?.firstLimit?.resetsAt
        if case let .runsOutAt(date) = main?.forecast { data.forecastRunsOut = date }
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
            Button { shift(at: index, by: -1) } label: { Label("Левее", systemImage: "chevron.left").labelStyle(.iconOnly) }
                .disabled(index == 0)
                .help("Левее")
            Button { shift(at: index, by: 1) } label: { Label("Правее", systemImage: "chevron.right").labelStyle(.iconOnly) }
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
