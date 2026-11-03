import SwiftUI

/// Which modules have a main switch in Settings (SPEC-settings §1).
@MainActor
enum ModuleSwitch {
    /// A built-in module comes with the profile settings that call for it («Ближайшее» with a calendar…), so until a
    /// profile has it there is nothing to switch; «Раскладка» needs beta builds.
    static func canSwitch(_ kind: ModuleKind, modes: ProfileStore) -> Bool {
        if kind.isBeta, !modes.isBetaAllowed { return false }
        return !kind.isBuiltIn || modes.installedModules.contains(kind)
    }

    /// What brings a built-in module into the current profile: a calendar, the `_daily-report` commands, or (for
    /// projects, which need a folder) the profile's page. Nil when there is no profile.
    static func enableAction(_ kind: ModuleKind, modes: ProfileStore) -> (title: String, run: () -> Void)? {
        guard let bringIn = kind.definition.bringIn, !modes.installedModules.contains(kind), let mode = modes.current else { return nil }
        switch bringIn {
        case .calendar:
            return (String(localized: "Включить календарь в профиле «\(mode.name)»"), {
                var changed = mode
                changed.calendar = .dates
                modes.update(changed)
            })
        case .dailyReport where modes.hasDailyReport:
            return (String(localized: "Включить команды _daily-report в профиле «\(mode.name)»"), {
                var changed = mode
                changed.commonCommands = .dailyReport
                changed.showCommonCommands = true
                modes.update(changed)
            })
        case .dailyReport, .profilePage:
            return (String(localized: "Открыть профиль «\(mode.name)»…"), {
                SettingsRoute.open(.modes)
            })
        }
    }

    /// Why a built-in module has no switch yet.
    static func unavailableReason(_ kind: ModuleKind) -> String {
        kind.definition.bringIn?.unavailableReason ?? String(localized: "Появится вместе с первым профилем.")
    }
}

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
    static func of(_ kind: ModuleKind) -> [ModulePlace] { kind.definition.places }
}

/// Menu bar helpers for a module's page; changes go through `ProfileStore.setMenuBar`.
@MainActor
enum MenuBarEdit {
    /// What switching a module's menu bar place on brings in.
    static func primaryKinds(_ kind: ModuleKind) -> [MenuBarElement.Kind] { kind.definition.primaryMenuBarKinds }
}

/// The «Где показывать» chips of one module.
struct ModulePlaces: View {
    let kind: ModuleKind

    @Environment(AppSettings.self) private var settings
    @Environment(ProfileStore.self) private var modes

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
        return !kind.isBuiltIn || mode.moduleList.contains { $0.kind == kind }
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
        case .telegram:
            kind.definition.telegram == .backgroundResults
                ? String(localized: "Итоги фоновых задач в Telegram; ответы на запросы разрешений — ниже, «Ответы из Telegram»")
                : String(localized: "Дублировать в Telegram; бот — модуль «Telegram»")
        }
    }

    private func binding(_ place: ModulePlace) -> Binding<Bool> {
        switch place {
        case .panel:
            Binding(get: { modes.current?.shows(kind) ?? false }, set: { setPanel($0) })
        case .menuBar:
            if kind.definition.ownMenuBarItem {
                // «Раскладка»'s language is an item of its own, not an element of the main one.
                Binding(get: { settings.layout.menuBarIcon }, set: { settings.layout.menuBarIcon = $0 })
            } else {
                Binding(get: { menuBarKinds.contains { modes.menuBar.element($0).enabled } }, set: { setMenuBar($0) })
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
        var list = mode.moduleList
        if let index = list.firstIndex(where: { $0.kind == kind }) {
            list[index].shown = shown
        } else if shown, kind.isPanelBlock {
            list.append(ProfileModule(kind))
        }
        mode.modules = list
        modes.update(mode)
    }

    private var menuBarKinds: [MenuBarElement.Kind] { kind.definition.menuBarKinds }

    private func setMenuBar(_ on: Bool) {
        var config = modes.menuBar
        for element in on ? MenuBarEdit.primaryKinds(kind) : menuBarKinds {
            config.set(element) { $0.enabled = on }
        }
        config.preset = .custom
        modes.setMenuBar(config)
    }

    private var ears: [NotchEar] { kind.definition.island?.ears ?? [] }

    private func setIsland(_ on: Bool) {
        if on {
            guard let slot = kind.definition.island, let ear = slot.ears.first else { return }
            if slot.left { settings.notch.leftEar = ear } else { settings.notch.rightEar = ear }
        } else {
            if ears.contains(settings.notch.leftEar) { settings.notch.leftEar = .none }
            if ears.contains(settings.notch.rightEar) { settings.notch.rightEar = .none }
        }
    }

    /// The notifications that are this module's alone (command results belong to two modules: not here).
    private var notificationKinds: [NotificationKind] { kind.definition.notifications.filter { $0.module == kind } }

    private var notificationsOn: Bool {
        if let toggle = kind.definition.notificationSwitch, !settings.isOn(toggle) { return false }
        return notificationKinds.contains { settings.frequency($0) != .off }
    }

    private func setNotifications(_ on: Bool) {
        if let toggle = kind.definition.notificationSwitch { settings.set(toggle, on) }
        for notification in notificationKinds {
            if on {
                if settings.frequency(notification) == .off { settings.notificationFrequencies[notification.rawValue] = nil }
            } else {
                settings.notificationFrequencies[notification.rawValue] = NotificationFrequency.off.rawValue
            }
        }
    }

    private var telegram: Binding<Bool>? {
        kind.definition.telegram.map { toggle in Binding(get: { settings.isOn(toggle) }, set: { settings.set(toggle, $0) }) }
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

/// Settings → one module (SPEC-settings §2): the header above carries its main switch; here the places and every
/// setting of the module.
struct ModulePage: View {
    let kind: ModuleKind

    @Environment(AppSettings.self) private var settings
    @Environment(ProfileStore.self) private var modes

    var body: some View {
        Form {
            if let note {
                Section {
                    Label(note, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                    if kind.isBeta, !settings.betaUpdates {
                        Button("Включить бета-версии") { settings.betaUpdates = true }
                    }
                    if let action = ModuleSwitch.enableAction(kind, modes: modes) {
                        Button(action.title, action: action.run)
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
                    IconRow("В профилях", systemImage: "square.stack.3d.up", value: profiles)
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
        if let settings = ModuleUI.of(kind).settings { settings() }
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
