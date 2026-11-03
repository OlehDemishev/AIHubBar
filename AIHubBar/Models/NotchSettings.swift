import AppKit

/// What one «ear» beside the notch shows (SPEC-notch §3.1).
enum NotchEar: String, Codable, CaseIterable, Sendable {
    case sessionLimit, weekLimit, otherAI, sessions, background, none

    var title: String {
        switch self {
        case .sessionLimit: String(localized: "Лимит сессии")
        case .weekLimit: String(localized: "Лимит недели")
        case .otherAI: String(localized: "Другие AI")
        case .sessions: String(localized: "Сессии Claude Code")
        case .background: String(localized: "Фоновые задачи")
        case .none: String(localized: "Ничего")
        }
    }
}

/// Where the summary — limits and sessions — is shown when the island is on screen (SPEC-notch §6, Oleh 2026-11-02).
enum NotchSummary: String, Codable, CaseIterable, Sendable {
    /// The menu bar as configured and the island's ears.
    case both
    /// The ears; the menu bar keeps only its icon and the projects' red dot.
    case island
    /// The menu bar; the island has no ears and shows only events.
    case menuBar

    var title: String {
        switch self {
        case .both: String(localized: "в строке меню и в острове")
        case .island: String(localized: "только в острове")
        case .menuBar: String(localized: "только в строке меню")
        }
    }
}

/// Which screen the island lives on (SPEC-notch §5).
enum NotchScreen: String, Codable, CaseIterable, Sendable {
    /// The screen with a notch; without one, the main screen's pill.
    case notch
    /// The main screen (the one with the menu bar in focus): its notch, or the pill.
    case main
    /// Every screen: its notch, or the pill where the pill is on.
    case all

    var title: String {
        switch self {
        case .notch: String(localized: "экран с чёлкой")
        case .main: String(localized: "главный экран")
        case .all: String(localized: "все экраны")
        }
    }
}

/// Settings → «Модули» → «Остров у чёлки» (SPEC-notch §6). Unknown keys from newer versions are ignored.
struct NotchSettings: Codable, Equatable, Sendable {
    var leftEar: NotchEar = .sessionLimit
    var rightEar: NotchEar = .sessions
    /// Open the card when the pointer rests on the notch; off = only on a click.
    var openOnHover = true
    /// Which events get a banner (SPEC-notch §3.2).
    var events: [NotchEventKind] = NotchEventKind.defaultOn
    /// «Только остров»: no system notification about a request or a wait while the island is on screen (SPEC-notch §4).
    var replaceNotifications = false
    var summary: NotchSummary = .both
    var screen: NotchScreen = .notch
    /// The pill on a screen without a notch (SPEC-notch §5); nil — on a Mac that has no notch screen at all.
    var pill: Bool?
    /// «Скрыть остров» (SPEC-notch §5): nothing on screen, notifications as usual.
    var hidden = false
    /// ⌃⌥Y / ⌃⌥N answer the request in the island (SPEC-notch §4); off by default — easy to allow without reading.
    var hotKeys = false
    /// The first-setup window (SPEC-notch §6.1) was answered or closed.
    var setupDone = false
    /// «Ход работы Claude в ушке сессий» (SPEC-notch §3.4): the task list's progress in the ear, its steps in the
    /// card, progress and files in «Готово».
    var liveActivity = true
    /// A file or folder dragged onto the island opens the profile's AI commands for it (SPEC-notch §9, stage 5).
    var fileDrop = true

    init() {}

    /// Whether the pill is shown: the choice, or by default only on a Mac without a notch screen.
    func showsPill(macHasNotch: Bool) -> Bool { pill ?? !macHasNotch }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NotchSettings()
        leftEar = (try? c.decodeIfPresent(NotchEar.self, forKey: .leftEar)) ?? defaults.leftEar
        rightEar = (try? c.decodeIfPresent(NotchEar.self, forKey: .rightEar)) ?? defaults.rightEar
        openOnHover = (try? c.decodeIfPresent(Bool.self, forKey: .openOnHover)) ?? defaults.openOnHover
        // Kinds from a newer version are skipped rather than dropping the whole list.
        events = (try? c.decodeIfPresent([String].self, forKey: .events))?.compactMap(NotchEventKind.init(rawValue:)) ?? defaults.events
        replaceNotifications = (try? c.decodeIfPresent(Bool.self, forKey: .replaceNotifications)) ?? defaults.replaceNotifications
        summary = (try? c.decodeIfPresent(NotchSummary.self, forKey: .summary)) ?? defaults.summary
        screen = (try? c.decodeIfPresent(NotchScreen.self, forKey: .screen)) ?? defaults.screen
        pill = (try? c.decodeIfPresent(Bool.self, forKey: .pill)) ?? nil
        hidden = (try? c.decodeIfPresent(Bool.self, forKey: .hidden)) ?? defaults.hidden
        hotKeys = (try? c.decodeIfPresent(Bool.self, forKey: .hotKeys)) ?? defaults.hotKeys
        setupDone = (try? c.decodeIfPresent(Bool.self, forKey: .setupDone)) ?? defaults.setupDone
        liveActivity = (try? c.decodeIfPresent(Bool.self, forKey: .liveActivity)) ?? defaults.liveActivity
        fileDrop = (try? c.decodeIfPresent(Bool.self, forKey: .fileDrop)) ?? defaults.fileDrop
    }
}

/// One screen's island: where it is and whether a full-screen app fills that screen (SPEC-notch §5).
struct NotchPlace: Equatable, Sendable {
    var geometry: NotchGeometry
    /// No ears there, only requests and waits.
    var isFullScreen = false
}
