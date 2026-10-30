import SwiftUI

/// Settings → «Строка меню»: the menu bar builder (SPEC-modes §7) with a live preview on top.
struct MenuBarSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(UsageStore.self) private var usage
    @Environment(ModeStore.self) private var modes
    @State private var sample = false

    var body: some View {
        VStack(spacing: 0) {
            preview
            Divider()
            Form {
                Section {
                    Picker("Набор", selection: Binding(
                        get: { settings.menuBarConfig.preset },
                        set: { choose($0) }
                    )) {
                        ForEach(MenuBarConfig.Preset.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Footnote(text: String(localized: "«Минимум» — значок, проблемы и ожидающие ответа. «Лимиты» — ещё сессия и неделя. «Всё» — всё, что есть. Любая правка ниже делает набор «Своим»."))
                }

                Section("Элементы — в порядке слева направо") {
                    ForEach(Array(settings.menuBarConfig.elements.enumerated()), id: \.element.id) { index, element in
                        ElementRow(
                            element: element,
                            canMoveUp: index > 0,
                            canMoveDown: index < settings.menuBarConfig.elements.count - 1,
                            models: usage.snapshot?.otherWindows ?? [],
                            onChange: { new in edit { $0.set(element.kind) { $0 = new } } },
                            onMove: { offset in edit { move(&$0, from: index, by: offset) } }
                        )
                    }
                }

                Section {
                    Picker("Разделитель", selection: binding(\.separator)) {
                        ForEach(MenuBarConfig.Separator.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Мелкий текст", isOn: binding(\.smallText))
                    Toggle("Цвет по уровню (зелёный · оранжевый · красный)", isOn: binding(\.colored))
                } header: {
                    Text("Вид")
                } footer: {
                    Footnote(text: String(localized: "Разделитель ставится между числами; значки и счётчики отделяются небольшим отступом. Набор общий для всех профилей."))
                }
            }
            .formStyle(.grouped)
        }
        .frame(height: 600)
    }

    // MARK: Preview

    private var preview: some View {
        let data = sample ? MenuBarData.sample : liveData
        let config = settings.menuBarConfig
        let groups = MenuBarComposer.groups(config, data)
        let width = MenuBarRenderer.width(config, data)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Предпросмотр").font(.headline)
                Spacer()
                Picker("", selection: $sample) {
                    Text("Сейчас").tag(false)
                    Text("Пример со всем").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                Spacer()
                Group {
                    if let symbol = MenuBarComposer.plainSymbol(groups) {
                        Image(systemName: symbol)
                    } else {
                        Image(nsImage: MenuBarRenderer.image(groups, config: config))
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                Spacer()
            }
            .padding(.vertical, 6)
            if width > MenuBarRenderer.wideWidth {
                Label("Строка широкая (\(Int(width)) pt): на MacBook с вырезом её может закрыть вырез или скрыть система.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(sample ? String(localized: "Так выглядит строка, когда есть что показать.") : String(localized: "Так строка выглядит сейчас. Пустые элементы (0, нет данных) не показываются."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
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

    // MARK: Editing

    private func choose(_ preset: MenuBarConfig.Preset) {
        var config = settings.menuBarConfig
        if preset != .custom {
            let made = MenuBarConfig.make(preset)
            config.elements = made.elements
        }
        config.preset = preset
        store(config)
    }

    private func edit(_ change: (inout MenuBarConfig) -> Void) {
        var config = settings.menuBarConfig
        change(&config)
        config.preset = .custom
        store(config)
    }

    /// The menu bar belongs to the current profile (SPEC-profiles §6): every change goes to it as well.
    private func store(_ config: MenuBarConfig) {
        settings.menuBarConfig = config
        modes.setMenuBar(config)
    }

    private func move(_ config: inout MenuBarConfig, from index: Int, by offset: Int) {
        let target = index + offset
        guard config.elements.indices.contains(target) else { return }
        config.elements.swapAt(index, target)
    }

    private func binding<Value>(_ path: WritableKeyPath<MenuBarConfig, Value>) -> Binding<Value> {
        Binding(
            get: { settings.menuBarConfig[keyPath: path] },
            set: { var config = settings.menuBarConfig; config[keyPath: path] = $0; store(config) }
        )
    }
}

/// One element: on/off, its options when on, and «выше / ниже».
private struct ElementRow: View {
    let element: MenuBarElement
    let canMoveUp: Bool
    let canMoveDown: Bool
    let models: [UsageWindow]
    let onChange: (MenuBarElement) -> Void
    let onMove: (Int) -> Void

    private static let symbols: [(String, String)] = [
        ("sparkle", String(localized: "✦ Искра")), ("star", String(localized: "Звезда")), ("bolt", String(localized: "Молния")), ("brain", String(localized: "Мозг")), ("terminal", String(localized: "Терминал")),
        ("mode", String(localized: "Значок профиля")), ("none", String(localized: "Без значка")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(element.kind.title, isOn: value(\.enabled))
                Spacer()
                Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(!canMoveUp)
                    .help("Левее")
                Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(!canMoveDown)
                    .help("Правее")
            }
            .buttonStyle(.borderless)
            if element.enabled {
                options
                    .padding(.leading, 20)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var options: some View {
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
        case .session, .week, .modelWeek, .cpu, .memory:
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
        case .projectsAlert, .forecast, .waiting, .running, .background, .queued, .deadline:
            EmptyView()
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
