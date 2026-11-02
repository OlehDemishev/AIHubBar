import SwiftUI

// MARK: - Main switch

/// Which modules have a main switch in Settings (SPEC-settings §1).
@MainActor
enum ModuleSwitch {
    /// A built-in module comes with the profile settings that call for it («Ближайшее» with a calendar…), so until a
    /// profile has it there is nothing to switch; «Раскладка» needs beta builds.
    static func canSwitch(_ kind: ModuleKind, modes: ModeStore) -> Bool {
        if kind.isBeta, !modes.isBetaAllowed { return false }
        return !kind.isBuiltIn || modes.installedModules.contains(kind)
    }

    /// Why a built-in module has no switch yet.
    static func unavailableReason(_ kind: ModuleKind) -> String {
        switch kind {
        case .upcoming: String(localized: "Появится, когда у профиля включён календарь — «Профили» → профиль.")
        case .projects: String(localized: "Появится, когда у профиля есть источник проектов — «Профили» → профиль.")
        case .reports: String(localized: "Появится, когда у профиля команды _daily-report — «Профили» → профиль.")
        default: String(localized: "Появится вместе с первым профилем.")
        }
    }
}

// MARK: - Places

/// «Где показывать» (SPEC-settings §1): shortcuts to settings that already exist, nothing stored of their own.
enum ModulePlace: CaseIterable, Sendable {
    case panel, menuBar, island, notifications, telegram

    var title: String {
        switch self {
        case .panel: String(localized: "Панель")
        case .menuBar: String(localized: "Строка меню")
        case .island: String(localized: "Остров")
        case .notifications: String(localized: "Уведомления")
        case .telegram: "Telegram"
        }
    }

    var symbol: String {
        switch self {
        case .panel: "rectangle.stack"
        case .menuBar: "menubar.rectangle"
        case .island: "capsule.tophalf.filled"
        case .notifications: "bell"
        case .telegram: "paperplane"
        }
    }

    /// The places a module has.
    static func of(_ kind: ModuleKind) -> [ModulePlace] {
        switch kind {
        case .limits, .sessions: [.panel, .menuBar, .island, .notifications, .telegram]
        case .upcoming, .projects: [.panel, .menuBar, .notifications, .telegram]
        case .resources: [.panel, .menuBar, .notifications]
        case .keepAwake: [.panel, .menuBar]
        case .reports, .quickCommands, .toggles, .clipboard, .notes: [.panel]
        case .layout: [.menuBar]
        case .notch: []
        }
    }
}

/// Edits the menu bar the way Settings → «Строка меню» does: the current profile gets every change too.
@MainActor
enum MenuBarEdit {
    static func store(_ config: MenuBarConfig, settings: AppSettings, modes: ModeStore) {
        settings.menuBarConfig = config
        modes.setMenuBar(config)
    }

    /// What switching a module's menu bar place on brings in.
    static func primaryKinds(_ kind: ModuleKind) -> [MenuBarElement.Kind] {
        switch kind {
        case .limits: [.session, .week]
        case .sessions: [.waiting]
        case .upcoming: [.deadline]
        case .projects: [.projectsAlert]
        case .resources: [.cpu, .memory]
        case .keepAwake: [.keepAwake]
        default: []
        }
    }
}

/// The «Где показывать» chips of one module.
struct ModulePlaces: View {
    let kind: ModuleKind

    @Environment(AppSettings.self) private var settings
    @Environment(ModeStore.self) private var modes

    var body: some View {
        HStack(spacing: 8) {
            ForEach(places, id: \.self) { place in
                PlaceChip(place: place, isOn: binding(place), help: help(place))
                    .disabled(!available(place))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// The island only while «Остров у чёлки» works.
    private var places: [ModulePlace] {
        ModulePlace.of(kind).filter { $0 != .island || modes.isOn(.notch) }
    }

    private func available(_ place: ModulePlace) -> Bool {
        guard place == .panel else { return true }
        guard let mode = modes.current else { return false }
        return !kind.isBuiltIn || mode.normalizedModules(hiddenBlocks: []).contains { $0.kind == kind }
    }

    private func help(_ place: ModulePlace) -> String {
        switch place {
        case .panel:
            modes.current == nil ? String(localized: "Нет профиля: панель показывает модули профиля")
                : available(place) ? String(localized: "Блок в панели текущего профиля «\(modes.current?.name ?? "")»")
                : ModuleSwitch.unavailableReason(kind)
        case .menuBar: String(localized: "Элементы модуля в строке меню; порядок и вид — «Строка меню»")
        case .island: String(localized: "Ушко у чёлки показывает модуль")
        case .notifications: String(localized: "Уведомления macOS от модуля; как часто — ниже, в «Как часто уведомлять»")
        case .telegram: String(localized: "Дублировать в Telegram; бот — «Основные» → Telegram")
        }
    }

    private func binding(_ place: ModulePlace) -> Binding<Bool> {
        switch place {
        case .panel:
            Binding(get: { modes.current?.shows(kind) ?? false }, set: { setPanel($0) })
        case .menuBar:
            if kind == .layout {
                Binding(get: { settings.layout.menuBarIcon }, set: { settings.layout.menuBarIcon = $0 })
            } else {
                Binding(get: { menuBarKinds.contains { settings.menuBarConfig.element($0).enabled } }, set: { setMenuBar($0) })
            }
        case .island:
            Binding(get: { [settings.notch.leftEar, settings.notch.rightEar].contains(where: ears.contains) }, set: { setIsland($0) })
        case .notifications:
            Binding(get: { notificationsOn }, set: { setNotifications($0) })
        case .telegram:
            Binding(get: { telegram?.wrappedValue ?? false }, set: { telegram?.wrappedValue = $0 })
        }
    }

    private func setPanel(_ shown: Bool) {
        guard var mode = modes.current else { return }
        var list = mode.normalizedModules(hiddenBlocks: [])
        if let index = list.firstIndex(where: { $0.kind == kind }) {
            list[index].shown = shown
        } else if shown, kind.isPanelBlock {
            list.append(ProfileModule(kind))
        }
        mode.modules = list
        modes.update(mode)
    }

    private var menuBarKinds: [MenuBarElement.Kind] { MenuBarElement.Kind.allCases.filter { $0.module == kind } }

    private func setMenuBar(_ on: Bool) {
        var config = settings.menuBarConfig
        for element in on ? MenuBarEdit.primaryKinds(kind) : menuBarKinds {
            config.set(element) { $0.enabled = on }
        }
        config.preset = .custom
        MenuBarEdit.store(config, settings: settings, modes: modes)
    }

    private var ears: [NotchEar] { kind == .limits ? [.sessionLimit, .weekLimit, .otherAI] : [.sessions, .background] }

    private func setIsland(_ on: Bool) {
        if on {
            if kind == .limits { settings.notch.leftEar = .sessionLimit } else { settings.notch.rightEar = .sessions }
        } else {
            if ears.contains(settings.notch.leftEar) { settings.notch.leftEar = .none }
            if ears.contains(settings.notch.rightEar) { settings.notch.rightEar = .none }
        }
    }

    private var notificationKinds: [NotificationKind] { NotificationKind.allCases.filter { $0.module == kind } }

    private var notificationsOn: Bool {
        if kind == .resources, !settings.resourceAlerts { return false }
        return notificationKinds.contains { settings.frequency($0) != .off }
    }

    private func setNotifications(_ on: Bool) {
        if kind == .resources { settings.resourceAlerts = on }
        for notification in notificationKinds {
            if on {
                if settings.frequency(notification) == .off { settings.notificationFrequencies[notification.rawValue] = nil }
            } else {
                settings.notificationFrequencies[notification.rawValue] = NotificationFrequency.off.rawValue
            }
        }
    }

    private var telegram: Binding<Bool>? {
        @Bindable var settings = settings
        return switch kind {
        case .limits: $settings.limitAlertsToTelegram
        case .sessions: $settings.telegramForBackground
        case .upcoming: $settings.calendarRemindersToTelegram
        case .projects: $settings.pullRequestAlertsToTelegram
        default: nil
        }
    }
}

/// One place: a capsule with its symbol, tinted while on.
private struct PlaceChip: View {
    let place: ModulePlace
    @Binding var isOn: Bool
    let help: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { isOn.toggle() } label: {
            Label(place.title, systemImage: isOn ? "checkmark" : place.symbol)
                .font(.system(size: 13, weight: isOn ? .medium : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isOn ? Color.accentColor : .primary)
                .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)))
                .overlay(Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25), lineWidth: 0.5))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityValue(isOn ? String(localized: "включено") : String(localized: "выключено"))
    }
}

// MARK: - Module page

/// Settings → one module (SPEC-settings §2): the header above carries its main switch; here the places and every
/// setting of the module.
struct ModulePage: View {
    let kind: ModuleKind

    @Environment(AppSettings.self) private var settings
    @Environment(ModeStore.self) private var modes

    var body: some View {
        Form {
            if let note {
                Section {
                    Label(note, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                    if kind.isBeta, !settings.betaUpdates {
                        Button("Включить бета-версии") { settings.betaUpdates = true }
                    }
                }
            }
            if !ModulePlace.of(kind).isEmpty {
                Section {
                    ModulePlaces(kind: kind)
                } header: {
                    Text("Где показывать")
                }
            }
            sections
            if !NotificationKind.of(kind).isEmpty {
                NotificationFrequencySection(kinds: NotificationKind.of(kind))
            }
            if kind.isPanelBlock, !modes.modes.isEmpty {
                Section {
                    LabeledContent("В профилях", value: profiles)
                } footer: {
                    Footnote(text: String(localized: "Порядок блоков — «Панель»; что показывает модуль в каждом профиле — «Профили»."))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var note: String? {
        if kind.isBeta, !settings.betaUpdates {
            return String(localized: "На испытании: работает только с «Бета-версиями».")
        }
        if kind.isBuiltIn, !modes.installedModules.contains(kind) { return ModuleSwitch.unavailableReason(kind) }
        if !modes.isOn(kind), modes.installedModules.contains(kind) {
            return String(localized: "Модуль выключен: не работает в фоне, не виден в панели и строке меню, не присылает уведомлений. Настройки и место в профилях сохранены.")
        }
        return nil
    }

    @ViewBuilder private var sections: some View {
        switch kind {
        case .limits:
            LimitSection()
            HubSection()
        case .sessions:
            SessionSection()
            TelegramApprovalsSection()
        case .upcoming: ReminderSection()
        case .projects: PullRequestAlertSection()
        case .reports:
            Section {
                Text("Команды _daily-report: отчёт, быстрая сводка, очистка сборок. Папка _daily-report — у профиля.")
                    .foregroundStyle(.secondary)
            }
        case .resources: ResourceSection()
        case .keepAwake: KeepAwakeSection()
        case .quickCommands: QuickCommandsSection()
        case .toggles: QuickTogglesSection()
        case .clipboard: ClipboardSection()
        case .notes: NotesSection()
        case .notch: NotchSection()
        case .layout: LayoutSection()
        }
    }

    private var profiles: String {
        let names = modes.modes.filter { $0.shows(kind) }.map(\.name)
        return names.isEmpty ? String(localized: "нет") : names.joined(separator: ", ")
    }
}

/// How often each of a module's notifications may come (it was one list in «Основные»).
private struct NotificationFrequencySection: View {
    let kinds: [NotificationKind]

    @Environment(AppSettings.self) private var settings

    var body: some View {
        Section {
            ForEach(kinds) { kind in
                Picker(kind.title, systemImage: kind.symbol, selection: Binding(
                    get: { settings.frequency(kind) },
                    set: { settings.notificationFrequencies[kind.rawValue] = $0.rawValue }
                )) {
                    ForEach(NotificationFrequency.allCases) { Text($0.title).tag($0) }
                }
            }
        } header: {
            Text("Как часто уведомлять")
        } footer: {
            Footnote(text: String(localized: "«Не чаще…» считается для одного и того же события: та же сессия, тот же порог, тот же PR. Разные события приходят как обычно. Telegram настраивается отдельно, у каждого модуля."))
        }
    }
}

extension NotificationKind {
    var symbol: String {
        switch self {
        case .waiting: "hand.raised"
        case .context: "gauge.with.needle"
        case .background: "moon.zzz"
        case .limits: "gauge.with.dots.needle.67percent"
        case .pullRequests: "arrow.triangle.pull"
        case .calendar: "calendar"
        case .resources: "cpu"
        case .commands: "terminal"
        }
    }
}

// MARK: - «Модули»: tiles

/// Settings → «Модули» (SPEC-settings §3): ready-made sets on top, then a tile per module by section.
struct ModuleCatalog: View {
    let open: (ModuleKind) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(ModeStore.self) private var modes

    /// A set switches its modules on and the rest off; modules without a switch are left alone.
    enum Preset: CaseIterable {
        case ai, layout, mac, everything

        var title: String {
            switch self {
            case .ai: String(localized: "Только AI")
            case .layout: String(localized: "Только раскладка")
            case .mac: String(localized: "Утилиты Mac")
            case .everything: String(localized: "Всё")
            }
        }

        var symbol: String {
            switch self {
            case .ai: "sparkles"
            case .layout: "keyboard"
            case .mac: "laptopcomputer"
            case .everything: "square.grid.3x3.fill"
            }
        }

        func includes(_ kind: ModuleKind) -> Bool {
            switch self {
            case .ai: kind.group == .ai
            case .layout: kind == .layout
            case .mac: kind.group == .mac
            case .everything: true
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 196, maximum: 320), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { preset in
                        Button { apply(preset) } label: {
                            Label(preset.title, systemImage: preset.symbol)
                                .padding(.horizontal, 4)
                        }
                        .controlSize(.large)
                        .help(String(localized: "Включить модули набора и выключить остальные"))
                    }
                    Spacer(minLength: 0)
                    Text("Включено: \(onCount) из \(listed.count)")
                        .foregroundStyle(.secondary)
                }
                ForEach(ModuleGroup.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 3).fill(group.tint.gradient).frame(width: 11, height: 11)
                            Text(group.title).font(.system(size: 15, weight: .semibold))
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(group.modules.filter { listed.contains($0) }, id: \.self) { kind in
                                ModuleTile(kind: kind, open: { open(kind) })
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }

    private var listed: [ModuleKind] { ModuleKind.allCases.filter { !$0.isBeta || settings.betaUpdates } }
    private var onCount: Int { listed.filter(modes.isOn).count }
    private var presets: [Preset] { Preset.allCases.filter { $0 != .layout || settings.betaUpdates } }

    private func apply(_ preset: Preset) {
        for kind in listed where ModuleSwitch.canSwitch(kind, modes: modes) || !kind.isBuiltIn {
            let on = preset.includes(kind)
            if modes.isOn(kind) != on { modes.setOn(kind, on) }
        }
    }
}

/// A module's tile: icon, name, one line and its main switch; a click opens the module's page.
private struct ModuleTile: View {
    let kind: ModuleKind
    let open: () -> Void

    @Environment(ModeStore.self) private var modes
    @State private var hovering = false

    var body: some View {
        let on = modes.isOn(kind)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                PaneIcon(pane: .module(kind), size: 34)
                Spacer()
                if ModuleSwitch.canSwitch(kind, modes: modes) {
                    Toggle(kind.title, isOn: Binding(get: { on }, set: { modes.setOn(kind, $0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                Text(kind.title).font(.system(size: 14, weight: .semibold))
                if kind.isBeta { BetaBadge() }
            }
            Text(ModuleSwitch.canSwitch(kind, modes: modes) || !kind.isBuiltIn ? kind.tagline : String(localized: "Нужен в профиле"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, maxHeight: 118, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2), lineWidth: hovering ? 1 : 0.5))
        .opacity(on ? 1 : 0.6)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .help(kind.summary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Открыть настройки модуля"), open)
    }
}

// MARK: - «Панель»: builder

/// Settings → «Панель» (SPEC-settings §4): the current profile's modules top to bottom, dragged into order, with a
/// sketch of the panel beside them.
struct PanelBuilder: View {
    /// Which profile «Панель» edits; «Профили» → profile → «Изменить в «Панели»» points it there.
    static let profileKey = "settingsPanelProfile"

    @Environment(ModeStore.self) private var modes
    @AppStorage(PanelBuilder.profileKey) private var profileID = ""

    @State private var targeted: ModuleKind?

    /// The chosen profile, else the current one.
    private var chosen: Mode? { modes.modes.first { $0.id == profileID } ?? modes.current }

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
                            kind.isPanelBlock && !kind.isBuiltIn && !mode.normalizedModules(hiddenBlocks: []).contains { $0.kind == kind }
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
                        .frame(width: 250)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
        } else {
            ContentUnavailableView("Нет профиля", systemImage: "rectangle.stack",
                                   description: Text("Панель показывает модули профиля. Создайте профиль на странице «Профили»."))
        }
    }

    private func visible(_ mode: Mode) -> [ProfileModule] {
        mode.normalizedModules(hiddenBlocks: []).filter { $0.kind.isPanelBlock && modes.isOn($0.kind) }
    }

    /// `kind` takes `target`'s place; modules switched off keep their places in the full list.
    private func move(_ mode: Mode, _ kind: ModuleKind, onto target: ModuleKind) {
        var list = mode.normalizedModules(hiddenBlocks: [])
        guard kind != target, let from = list.firstIndex(where: { $0.kind == kind }),
              let to = list.firstIndex(where: { $0.kind == target }) else { return }
        list.insert(list.remove(at: from), at: to)
        var changed = mode
        changed.modules = list
        modes.update(changed)
    }
}

private struct PanelBuilderRow: View {
    let module: ProfileModule
    let mode: Mode
    let canMoveUp: Bool
    let canMoveDown: Bool
    /// -1 up, +1 down: the buttons, the context menu and VoiceOver, for whoever doesn't drag.
    let onMove: (Int) -> Void

    @Environment(ModeStore.self) private var modes

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            PaneIcon(pane: .module(module.kind), size: 26)
            Text(module.kind.title)
                .font(.system(size: 14))
            Spacer()
            ProfileModuleOptions(module: module) { new in
                set { $0 = new }
            }
            Toggle(module.kind.title, isOn: Binding(get: { module.shown }, set: { shown in set { $0.shown = shown } }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            HStack(spacing: 2) {
                Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(!canMoveUp)
                    .help("Выше")
                Button { onMove(1) } label: { Image(systemName: "chevron.down") }
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
        var list = mode.normalizedModules(hiddenBlocks: [])
        guard let index = list.firstIndex(where: { $0.kind == module.kind }) else { return }
        change(&list[index])
        changed.modules = list
        modes.update(changed)
    }
}

/// A sketch of the panel: one card per shown block, in order — what goes where, not live data.
private struct PanelSketch: View {
    let modules: [ModuleKind]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Схема панели").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(modules, id: \.self) { kind in
                    HStack(spacing: 8) {
                        Image(systemName: kind.symbol)
                            .foregroundStyle(kind.group.tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kind.title).font(.system(size: 12, weight: .semibold))
                            Text(kind.tagline).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
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
}

// MARK: - A profile's choices inside a module

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
