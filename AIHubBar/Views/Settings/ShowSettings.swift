import SwiftUI

/// Settings → «Что показывать» (SPEC-settings §3): every module in one list with two switches — its block in the
/// panel and its elements in the menu bar. The profile's blocks come first, in panel order, and are dragged into
/// place; a click on a row opens the module's own settings. It replaced «Модули», «Панель» and the «Где показывать»
/// chips of each module (2026-11-10).
struct ShowSettings: View {
    let open: (SettingsPane) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(ProfileStore.self) private var modes
    @AppStorage(StorageKey.panelProfile) private var profileID = ""
    @State private var roomy = true
    @State private var targeted: ModuleKind?
    @State private var asked: ModuleCatalog.Preset?

    /// The chosen profile, else the current one.
    private var chosen: Profile? { modes.modes.first { $0.id == profileID } ?? modes.current }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    top
                    let blocks = blocks
                    if !blocks.isEmpty {
                        heading(String(localized: "Блоки панели"), columns: true)
                        card(blocks, draggable: true)
                        Text("Перетащите блок на другой, чтобы поменять порядок, или нажмите ⌃ / ⌄")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    let rest = rest
                    if !rest.isEmpty {
                        heading(blocks.isEmpty ? String(localized: "Модули") : String(localized: "Остальное"), columns: blocks.isEmpty)
                            .padding(.top, 6)
                        card(rest, draggable: false)
                    }
                    Button { open(.menuBar) } label: {
                        Label("Строка меню…", systemImage: "menubar.rectangle")
                    }
                    .padding(.top, 6)
                }
                // On a narrow window the rows need the room; the sketch only repeats them.
                if roomy, let mode = chosen {
                    PanelSketch(modules: mode.moduleList.filter { $0.shown && $0.kind.isPanelBlock && modes.isOn($0.kind) }.map(\.kind))
                        .frame(width: 220)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 900 } action: { roomy = $0 }
    }

    // MARK: The top line

    private var top: some View {
        HStack(spacing: 10) {
            if modes.modes.count > 1, let mode = chosen {
                Picker("Профиль", systemImage: "square.stack.3d.up", selection: Binding(get: { mode.id }, set: { profileID = $0 })) {
                    ForEach(modes.modes, id: \.id) { profile in
                        Text(profile.id == modes.currentID ? String(localized: "\(profile.name) — текущий") : profile.name).tag(profile.id)
                    }
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(presets, id: \.self) { preset in
                    Button { if preset == .everything { apply(preset) } else { asked = preset } } label: {
                        Label(preset.title, systemImage: preset.symbol)
                    }
                }
            } label: {
                Label("Готовый набор", systemImage: "wand.and.stars")
            }
            .fixedSize()
            .help(String(localized: "Включить модули набора и выключить остальные"))
            .confirmationDialog(asked?.title ?? "", isPresented: Binding(get: { asked != nil }, set: { if !$0 { asked = nil } })) {
                Button(asked?.title ?? "") { if let asked { apply(asked) } }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Включить модули набора и выключить остальные")
            }
        }
    }

    private func heading(_ title: String, columns: Bool) -> some View {
        HStack(spacing: 0) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if columns {
                Text("Панель").frame(width: ShowRow.column)
                Text("Строка меню").frame(width: ShowRow.column)
                Color.clear.frame(width: ShowRow.trailing, height: 1)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
    }

    private func card(_ kinds: [ModuleKind], draggable: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                if index > 0 { Divider().padding(.leading, draggable ? 68 : 48) }
                let row = ShowRow(kind: kind, mode: chosen, draggable: draggable,
                                  canMoveUp: draggable && index > 0, canMoveDown: draggable && index < kinds.count - 1,
                                  open: { open(.module(kind)) }) { offset in
                    guard kinds.indices.contains(index + offset) else { return }
                    move(kind, onto: kinds[index + offset])
                }
                .padding(.horizontal, 12)
                .background(targeted == kind ? Color.accentColor.opacity(0.15) : .clear)
                if draggable {
                    row
                        .draggable(kind.rawValue) {
                            Label(kind.title, systemImage: kind.symbol).padding(6)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let raw = items.first, let dragged = ModuleKind(rawValue: raw) else { return false }
                            move(dragged, onto: kind)
                            return true
                        } isTargeted: { inside in
                            if inside { targeted = kind } else if targeted == kind { targeted = nil }
                        }
                } else {
                    row
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
    }

    // MARK: What is listed

    private var listed: [ModuleKind] {
        ModuleDefinition.all.map(\.kind).filter { ModuleSwitch.isOffered($0, settings: settings, modes: modes) }
    }

    /// The profile's working blocks in panel order, hidden ones too: they keep their place.
    private var blocks: [ModuleKind] {
        (chosen?.moduleList ?? []).map(\.kind).filter { $0.isPanelBlock && modes.isOn($0) && listed.contains($0) }
    }

    /// Everything else: modules without a block, switched off, or not in this profile.
    private var rest: [ModuleKind] {
        let blocks = blocks
        return listed.filter { !blocks.contains($0) }
    }

    private var presets: [ModuleCatalog.Preset] { ModuleCatalog.Preset.allCases.filter { $0 != .layout || settings.betaUpdates } }

    private func apply(_ preset: ModuleCatalog.Preset) {
        for kind in listed where ModuleSwitch.canSwitch(kind, modes: modes) || !kind.isBuiltIn {
            let on = preset.includes(kind)
            if modes.isOn(kind) != on { modes.setOn(kind, on) }
        }
    }

    /// `kind` takes `target`'s place; modules switched off keep their places in the full list.
    private func move(_ kind: ModuleKind, onto target: ModuleKind) {
        guard var mode = chosen else { return }
        var list = mode.moduleList
        guard kind != target, let from = list.firstIndex(where: { $0.kind == kind }),
              let to = list.firstIndex(where: { $0.kind == target }) else { return }
        list.insert(list.remove(at: from), at: to)
        mode.modules = list
        modes.update(mode)
    }
}

/// One module on «Что показывать»: where it shows, and the way to its settings.
private struct ShowRow: View {
    static let column: CGFloat = 78
    static let trailing: CGFloat = 46

    let kind: ModuleKind
    /// The profile whose panel the row edits.
    let mode: Profile?
    let draggable: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let open: () -> Void
    /// -1 up, +1 down: the buttons, the context menu and VoiceOver, for whoever doesn't drag.
    let onMove: (Int) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(ProfileStore.self) private var modes

    private var module: ProfileModule? { mode?.moduleList.first { $0.kind == kind } }
    private var isOn: Bool { modes.isOn(kind) }
    private var canSwitch: Bool { ModuleSwitch.canSwitch(kind, modes: modes) }
    private var hasMenuBar: Bool { kind.definition.ownMenuBarItem || !kind.definition.menuBarKinds.isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            if draggable {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
            PaneIcon(pane: .module(kind), size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Button(action: open) {
                    HStack(spacing: 6) {
                        Text(kind.title)
                            .font(.system(size: 14))
                            .lineLimit(1)
                        if kind.isBeta { BetaBadge() }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Открыть настройки модуля"))
                detail
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            switches
            HStack(spacing: 0) {
                if draggable {
                    VStack(spacing: 0) {
                        Button { onMove(-1) } label: { Label("Выше", systemImage: "chevron.up").labelStyle(.iconOnly) }
                            .disabled(!canMoveUp)
                            .help("Выше")
                        Button { onMove(1) } label: { Label("Ниже", systemImage: "chevron.down").labelStyle(.iconOnly) }
                            .disabled(!canMoveDown)
                            .help("Ниже")
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
                Button(action: open) {
                    Label(String(localized: "Открыть настройки модуля"), systemImage: "chevron.forward")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Открыть настройки модуля"))
            }
            .frame(width: Self.trailing)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .opacity(isOn ? 1 : 0.6)
        .contextMenu {
            Button("Открыть настройки модуля", action: open)
            if draggable {
                Divider()
                Button("Выше") { onMove(-1) }.disabled(!canMoveUp)
                Button("Ниже") { onMove(1) }.disabled(!canMoveDown)
            }
            if let mode, module != nil, !kind.isBuiltIn {
                Divider()
                Button("Убрать из профиля") { modes.removeModule(kind, from: mode.id) }
            }
        }
        .accessibilityAction(named: Text("Выше")) { if canMoveUp { onMove(-1) } }
        .accessibilityAction(named: Text("Ниже")) { if canMoveDown { onMove(1) } }
    }

    /// Under the name: what the profile shows inside the block, a way to bring a built-in module in, or one line
    /// about a module that is off.
    @ViewBuilder private var detail: some View {
        if draggable, let module, module.shown {
            ProfileModuleOptions(module: module) { new in edit { $0 = new } }
                .fixedSize()
        } else if let action = ModuleSwitch.enableAction(kind, modes: modes) {
            Button(action: action.run) {
                Text(kind == .projects ? String(localized: "Нужен источник проектов") : String(localized: "Включить в профиле"))
                    .font(.system(size: 12))
            }
            .buttonStyle(.link)
            .help(action.title)
        } else if !draggable {
            Text(kind.tagline)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// Two columns, «Панель» and «Строка меню»; a module that has neither place gets its main switch across both.
    @ViewBuilder private var switches: some View {
        if kind.isPanelBlock || hasMenuBar {
            Group {
                if kind.isPanelBlock {
                    toggle(String(localized: "Панель"), isOn: panel, help: panelHelp)
                        .disabled(!panelAvailable)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: Self.column)
            Group {
                if hasMenuBar {
                    toggle(String(localized: "Строка меню"), isOn: menuBar,
                           help: String(localized: "Элементы модуля в строке меню; порядок и вид — «Строка меню»"))
                        .disabled(!canSwitch)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: Self.column)
        } else {
            toggle(String(localized: "Включён"), isOn: Binding(get: { isOn }, set: { modes.setOn(kind, $0) }),
                   help: isOn ? String(localized: "Выключить модуль: перестанет работать, место в профилях сохранится") : String(localized: "Включить модуль"))
                .disabled(!canSwitch)
                .frame(width: Self.column * 2)
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
        Toggle("\(kind.title): \(title)", isOn: isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .help(help)
    }

    // MARK: The panel

    /// A built-in module comes with the profile settings that call for it: until then there is no block to show.
    private var panelAvailable: Bool {
        guard mode != nil, canSwitch else { return false }
        return !kind.isBuiltIn || module != nil
    }

    private var panelHelp: String {
        guard let mode else { return String(localized: "Нет профиля: панель показывает модули профиля") }
        return panelAvailable ? String(localized: "Блок в панели профиля «\(mode.name)»") : ModuleSwitch.unavailableReason(kind)
    }

    private var panel: Binding<Bool> {
        Binding(get: { isOn && module?.shown == true }, set: { shown in
            // A block of a module that is off shows nothing: the switch brings the module back too.
            if shown, !isOn { modes.setOn(kind, true) }
            guard var changed = modes.modes.first(where: { $0.id == mode?.id }) else { return }
            var list = changed.moduleList
            if let index = list.firstIndex(where: { $0.kind == kind }) {
                list[index].shown = shown
            } else if shown {
                list.append(ProfileModule(kind))
            }
            changed.modules = list
            modes.update(changed)
        })
    }

    private func edit(_ change: (inout ProfileModule) -> Void) {
        guard var changed = mode else { return }
        var list = changed.moduleList
        guard let index = list.firstIndex(where: { $0.kind == kind }) else { return }
        change(&list[index])
        changed.modules = list
        modes.update(changed)
    }

    // MARK: The menu bar

    private var menuBar: Binding<Bool> {
        if kind.definition.ownMenuBarItem {
            // «Раскладка»'s language is an item of its own, not an element of the main one.
            return Binding(get: { isOn && settings.layout.menuBarIcon }, set: { on in
                if on, !isOn { modes.setOn(kind, true) }
                settings.layout.menuBarIcon = on
            })
        }
        let kinds = kind.definition.menuBarKinds
        return Binding(get: { isOn && kinds.contains { modes.menuBar.element($0).enabled } }, set: { on in
            if on, !isOn { modes.setOn(kind, true) }
            var config = modes.menuBar
            for element in on ? kind.definition.primaryMenuBarKinds : kinds {
                config.set(element) { $0.enabled = on }
            }
            config.preset = .custom
            modes.setMenuBar(config)
        })
    }
}
