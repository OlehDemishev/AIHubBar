import Foundation

/// Everything about one module that isn't a screen (docs/specs/SPEC-refactor.md §3): one value per module, each in its own
/// file in `Modules/`. Adding a module means a new case in `ModuleKind`, a file here, and the compiler pointing at
/// the few places that still switch over kinds (the panel card, `MenuBarData.without`, the assistant).
struct ModuleDefinition: Sendable {
    let kind: ModuleKind
    let group: ModuleGroup
    let symbol: String
    let title: String
    /// What the module does, for its page and the tiles' help.
    let summary: String
    /// One line for its tile in Settings → «Модули».
    let tagline: String
    /// Built in: a profile has it when its settings call for it (SPEC-profiles §3); the rest are installed by hand.
    var isBuiltIn = false
    /// Still in beta testing: offered and working only with Settings → General → «Бета-версии» on (docs/RELEASE.md).
    var isBeta = false
    /// Shown as a block of the panel; «Остров у чёлки» and «Раскладка» live elsewhere (SPEC-notch §6, SPEC-layout §4).
    var isPanelBlock = true
    /// «Где показывать» on its page (SPEC-settings §1).
    var places: [ModulePlace] = [.panel]
    /// The menu bar elements that show its data.
    var menuBarKinds: [MenuBarElement.Kind] = []
    /// What switching its menu bar place on brings in.
    var primaryMenuBarKinds: [MenuBarElement.Kind] = []
    /// Its menu bar place is an item of its own rather than elements of the main one («Раскладка»'s language).
    var ownMenuBarItem = false
    /// Notifications whose frequency its page sets. A kind listed by one module only is that module's: switched off,
    /// the module sends none of it (`NotificationKind.module`).
    var notifications: [NotificationKind] = []
    /// A switch of its own that turns its notifications on and off, besides their frequency.
    var notificationSwitch: NotificationSwitch?
    /// The notch island's ears that show it, and the side switching the island place on uses.
    var island: IslandSlot?
    /// The setting that sends its notifications to Telegram too.
    var telegram: TelegramToggle?
    /// For a built-in module a profile doesn't have yet: what brings it in.
    var bringIn: BringIn?
    /// Words the Settings search finds its page by, besides its title.
    var keywords: [String] = []
}

/// The island ears a module can take (SPEC-notch §3).
struct IslandSlot: Sendable {
    let ears: [NotchEar]
    /// Switching the place on puts the first ear on the left of the notch, else on the right.
    let left: Bool
}

/// Settings that send a module's notifications to Telegram.
enum TelegramToggle: Sendable {
    case limitAlerts, backgroundResults, calendarReminders, pullRequests
}

/// A module's own on/off switch for its notifications.
enum NotificationSwitch: Sendable {
    case resourceAlerts, pullRequestAlerts, calendarReminders
}

/// How a built-in module gets into the current profile (SPEC-settings §3).
enum BringIn: Sendable {
    /// Switch the profile's calendar on.
    case calendar
    /// Switch the profile's `_daily-report` commands on (when this Mac has it).
    case dailyReport
    /// Needs a choice in the profile (a projects folder): open it.
    case profilePage

    var unavailableReason: String {
        switch self {
        case .calendar: String(localized: "Появится, когда у профиля включён календарь — «Профили» → профиль.")
        case .profilePage: String(localized: "Появится, когда у профиля есть источник проектов — «Профили» → профиль.")
        case .dailyReport: String(localized: "Появится, когда у профиля команды _daily-report — «Профили» → профиль.")
        }
    }
}

extension ModuleDefinition {
    /// Every module, in Settings sidebar order within its section.
    static let all: [ModuleDefinition] = [
        .limits, .sessions, .quickPrompt, .telegram,
        .upcoming, .projects, .reports, .quickCommands, .notes, .clipboard,
        .resources, .keepAwake, .toggles, .layout, .notch,
    ]

    static func of(_ kind: ModuleKind) -> ModuleDefinition {
        switch kind {
        case .limits: .limits
        case .sessions: .sessions
        case .upcoming: .upcoming
        case .projects: .projects
        case .reports: .reports
        case .resources: .resources
        case .keepAwake: .keepAwake
        case .quickCommands: .quickCommands
        case .toggles: .toggles
        case .clipboard: .clipboard
        case .notes: .notes
        case .notch: .notch
        case .layout: .layout
        case .quickPrompt: .quickPrompt
        case .telegram: .telegram
        }
    }
}

extension ModuleKind {
    var definition: ModuleDefinition { .of(self) }

    var title: String { definition.title }
    var summary: String { definition.summary }
    var tagline: String { definition.tagline }
    var symbol: String { definition.symbol }
    var group: ModuleGroup { definition.group }
    var isBuiltIn: Bool { definition.isBuiltIn }
    var isBeta: Bool { definition.isBeta }
    var isPanelBlock: Bool { definition.isPanelBlock }
    var keywords: [String] { definition.keywords }
}

extension ModuleGroup {
    /// Its modules in sidebar order.
    var modules: [ModuleKind] { ModuleDefinition.all.filter { $0.group == self }.map(\.kind) }
}

extension MenuBarElement.Kind {
    /// The module whose data the element shows; nil for the icon, the free space and the profile.
    var module: ModuleKind? { ModuleDefinition.all.first { $0.menuBarKinds.contains(self) }?.kind }
}

extension NotificationKind {
    /// The notifications a module's page sets the frequency of.
    static func of(_ module: ModuleKind) -> [NotificationKind] { module.definition.notifications }

    /// The module these notifications belong to: switched off, it sends none (SPEC-settings §1). Nil when no module
    /// or several list it (command results: «Отчёты» and «Быстрые команды»).
    var module: ModuleKind? {
        let owners = ModuleDefinition.all.filter { $0.notifications.contains(self) }
        return owners.count == 1 ? owners[0].kind : nil
    }
}
