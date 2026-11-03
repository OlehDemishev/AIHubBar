import SwiftUI

/// Settings → «Панель» (SPEC-settings §4): the current profile's modules top to bottom, dragged into order, with a
/// sketch of the panel beside them.
struct PanelBuilder: View {
    @Environment(ProfileStore.self) private var modes
    @AppStorage(StorageKey.panelProfile) private var profileID = ""

    @State private var targeted: ModuleKind?

    /// The chosen profile, else the current one.
    private var chosen: Profile? { modes.modes.first { $0.id == profileID } ?? modes.current }

    var body: some View {
        if let mode = chosen {
            ScrollView {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        if modes.modes.count > 1 {
                            Picker("Профиль", systemImage: "square.stack.3d.up", selection: Binding(get: { mode.id }, set: { profileID = $0 })) {
                                ForEach(modes.modes, id: \.id) { profile in
                                    Text(profile.id == modes.currentID ? String(localized: "\(profile.name) — текущий") : profile.name).tag(profile.id)
                                }
                            }
                            .fixedSize()
                        }
                        Text("Перетащите блок на другой, чтобы поменять порядок, или нажмите ⌃ / ⌄")
                            .foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(Array(visible(mode).enumerated()), id: \.element.kind) { index, module in
                                if index > 0 { Divider().padding(.leading, 52) }
                                PanelBuilderRow(module: module, mode: mode,
                                                canMoveUp: index > 0, canMoveDown: index < visible(mode).count - 1) { offset in
                                    let list = visible(mode)
                                    guard list.indices.contains(index + offset) else { return }
                                    move(mode, module.kind, onto: list[index + offset].kind)
                                }
                                    .padding(.horizontal, 12)
                                    .background(targeted == module.kind ? Color.accentColor.opacity(0.15) : .clear)
                                    .draggable(module.kind.rawValue) {
                                        Label(module.kind.title, systemImage: module.kind.symbol).padding(6)
                                    }
                                    .dropDestination(for: String.self) { items, _ in
                                        guard let raw = items.first, let dragged = ModuleKind(rawValue: raw) else { return false }
                                        move(mode, dragged, onto: module.kind)
                                        return true
                                    } isTargeted: { inside in
                                        if inside { targeted = module.kind } else if targeted == module.kind { targeted = nil }
                                    }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
                        let addable = modes.activeModules.filter { kind in
                            kind.isPanelBlock && !kind.isBuiltIn && !mode.moduleList.contains { $0.kind == kind }
                        }
                        if !addable.isEmpty {
                            Menu {
                                ForEach(addable, id: \.self) { kind in
                                    Button { modes.addModule(kind, to: mode.id) } label: { Label(kind.title, systemImage: kind.symbol) }
                                }
                            } label: {
                                Label("Добавить модуль", systemImage: "plus")
                            }
                            .fixedSize()
                        }
                        Footnote(text: String(localized: "Здесь только включённые модули. Остальные — на странице «Модули»; что показывает модуль в каждом профиле — «Профили»."))
                    }
                    PanelSketch(modules: visible(mode).filter(\.shown).map(\.kind))
                        .frame(width: 236)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
        } else {
            ContentUnavailableView("Нет профиля", systemImage: "rectangle.stack",
                                   description: Text("Панель показывает модули профиля. Создайте профиль на странице «Профили»."))
        }
    }

    private func visible(_ mode: Profile) -> [ProfileModule] {
        mode.moduleList.filter { $0.kind.isPanelBlock && modes.isOn($0.kind) }
    }

    /// `kind` takes `target`'s place; modules switched off keep their places in the full list.
    private func move(_ mode: Profile, _ kind: ModuleKind, onto target: ModuleKind) {
        var list = mode.moduleList
        guard kind != target, let from = list.firstIndex(where: { $0.kind == kind }),
              let to = list.firstIndex(where: { $0.kind == target }) else { return }
        list.insert(list.remove(at: from), at: to)
        var changed = mode
        changed.modules = list
        modes.update(changed)
    }
}

struct PanelBuilderRow: View {
    let module: ProfileModule
    let mode: Profile
    let canMoveUp: Bool
    let canMoveDown: Bool
    /// -1 up, +1 down: the buttons, the context menu and VoiceOver, for whoever doesn't drag.
    let onMove: (Int) -> Void

    @Environment(ProfileStore.self) private var modes

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            PaneIcon(pane: .module(module.kind), size: 26)
            Text(module.kind.title)
                .font(.system(size: 14))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            ProfileModuleOptions(module: module) { new in
                set { $0 = new }
            }
            .fixedSize()
            Toggle(module.kind.title, isOn: Binding(get: { module.shown }, set: { shown in set { $0.shown = shown } }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            HStack(spacing: 2) {
                Button { onMove(-1) } label: { Label("Выше", systemImage: "chevron.up").labelStyle(.iconOnly) }
                    .disabled(!canMoveUp)
                    .help("Выше")
                Button { onMove(1) } label: { Label("Ниже", systemImage: "chevron.down").labelStyle(.iconOnly) }
                    .disabled(!canMoveDown)
                    .help("Ниже")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .opacity(module.shown ? 1 : 0.55)
        .contextMenu {
            Button("Выше") { onMove(-1) }.disabled(!canMoveUp)
            Button("Ниже") { onMove(1) }.disabled(!canMoveDown)
            if !module.kind.isBuiltIn {
                Divider()
                Button("Убрать из профиля") { modes.removeModule(module.kind, from: mode.id) }
            }
        }
        .accessibilityAction(named: Text("Выше")) { if canMoveUp { onMove(-1) } }
        .accessibilityAction(named: Text("Ниже")) { if canMoveDown { onMove(1) } }
    }

    private func set(_ change: (inout ProfileModule) -> Void) {
        var changed = mode
        var list = mode.moduleList
        guard let index = list.firstIndex(where: { $0.kind == module.kind }) else { return }
        change(&list[index])
        changed.modules = list
        modes.update(changed)
    }
}

/// The panel in miniature: one card per shown block, in order, each with what it shows right now. Not the panel view
/// itself — that one takes over its window (glass, background) and refreshes on open.
struct PanelSketch: View {
    let modules: [ModuleKind]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Панель сейчас").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(modules, id: \.self) { kind in
                    HStack(spacing: 8) {
                        Image(systemName: kind.symbol)
                            .foregroundStyle(kind.group.tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.title).font(.system(size: 12, weight: .semibold))
                            live(kind)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                }
                if modules.isEmpty {
                    Text("Панель пуста").font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
            .animation(.snappy(duration: 0.2), value: modules)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Схема панели: ") + modules.map(\.title).joined(separator: ", "))
    }

    /// What the block shows now, from the module's own file; its tagline when it has nothing live to show.
    @ViewBuilder private func live(_ kind: ModuleKind) -> some View {
        if let sketch = ModuleUI.of(kind).sketch { sketch() } else { SketchLine(kind.tagline) }
    }
}

/// What a profile shows inside a module (SPEC-profiles §3): a menu of checkmarks, «все» when nothing is chosen.
/// Used by «Профили» and «Панель».
struct ProfileModuleOptions: View {
    let module: ProfileModule
    let change: (ProfileModule) -> Void

    @Environment(AppSettings.self) private var settings

    var body: some View {
        switch module.kind {
        case .resources:
            choiceMenu(String(localized: "Показатели"), chosen: module.metrics,
                       items: ResourceMetric.allCases.map { ($0.rawValue, $0.title) }) { new in edit { $0.metrics = new } }
        case .quickCommands:
            choiceMenu(String(localized: "Команды"), chosen: module.commands,
                       items: settings.quickCommands.map { ($0.id, $0.title) }) { new in edit { $0.commands = new } }
        case .toggles:
            // nil here means «as in the module's settings», so a choice made in the profile is always kept as a list.
            let all = QuickToggle.allCases.map(\.rawValue)
            choiceMenu(String(localized: "Переключатели"), chosen: module.toggles ?? settings.quickToggles.map(\.rawValue),
                       items: QuickToggle.allCases.map { ($0.rawValue, $0.title) }) { new in edit { $0.toggles = new ?? all } }
        case .keepAwake:
            Toggle("Таймеры", isOn: Binding(
                get: { module.showTimers != false },
                set: { on in edit { $0.showTimers = on ? nil : false } }
            ))
            .toggleStyle(.checkbox)
            .help("Кнопки «15 мин», «1 ч», «2 ч» в панели")
        default:
            EmptyView()
        }
    }

    private func edit(_ apply: (inout ProfileModule) -> Void) {
        var new = module
        apply(&new)
        change(new)
    }

    private func choiceMenu(_ title: String, chosen: [String]?, items: [(id: String, title: String)],
                            set: @escaping ([String]?) -> Void) -> some View {
        let all = items.map(\.id)
        let count = chosen.map { list in all.filter(list.contains).count } ?? all.count
        return Menu {
            ForEach(items, id: \.id) { item in
                Button {
                    set(ProfileModule.toggled(item.id, in: chosen, all: all))
                } label: {
                    if ProfileModule.includes(item.id, in: chosen) {
                        Label(item.title, systemImage: "checkmark")
                    } else {
                        Text(item.title)
                    }
                }
            }
        } label: {
            Text(count == all.count ? String(localized: "\(title): все") : String(localized: "\(title): \(count) из \(all.count)"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Что этот профиль показывает в блоке")
    }
}
