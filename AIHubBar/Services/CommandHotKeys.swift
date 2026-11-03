import AppKit
import Carbon.HIToolbox
import Observation

/// A key with modifiers, as Carbon registers it: works in any app, no Accessibility permission.
struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    /// Carbon flags: `cmdKey`, `shiftKey`, `optionKey`, `controlKey`.
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.known
    }

    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), modifiers: Self.carbon(event.modifierFlags))
    }

    private static let known = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    private static let functionKeys: [Int] = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                              kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    var isFunctionKey: Bool { Self.functionKeys.contains(Int(keyCode)) }

    /// ⌘, ⌃ or ⌥ — or an F key alone: a letter with only ⇧ would take that letter from typing everywhere.
    var isValid: Bool {
        guard keyCode != UInt32(kVK_Escape) else { return false }
        return modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 || isFunctionKey
    }

    /// «⌃⌥⇧⌘K», in the order macOS menus use.
    var title: String {
        modifierSymbols.map(\.symbol).joined() + keyName
    }

    /// For VoiceOver: «Control Option K».
    var spoken: String {
        (modifierSymbols.map(\.name) + [Self.spokenKeys[Int(keyCode)] ?? keyName]).joined(separator: " ")
    }

    private var modifierSymbols: [(symbol: String, name: String)] {
        [(controlKey, "⌃", "Control"), (optionKey, "⌥", "Option"), (shiftKey, "⇧", "Shift"), (cmdKey, "⌘", "Command")]
            .filter { modifiers & UInt32($0.0) != 0 }
            .map { ($0.1, $0.2) }
    }

    /// The key as printed on a US keyboard, the way the Carbon key code means it whatever the layout.
    var keyName: String {
        if let index = Self.functionKeys.firstIndex(of: Int(keyCode)) { return "F\(index + 1)" }
        return Self.names[Int(keyCode)] ?? "#\(keyCode)"
    }

    private static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G",
        kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N",
        kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U",
        kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6",
        kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        kVK_ANSI_Keypad0: "Num0", kVK_ANSI_Keypad1: "Num1", kVK_ANSI_Keypad2: "Num2", kVK_ANSI_Keypad3: "Num3", kVK_ANSI_Keypad4: "Num4",
        kVK_ANSI_Keypad5: "Num5", kVK_ANSI_Keypad6: "Num6", kVK_ANSI_Keypad7: "Num7", kVK_ANSI_Keypad8: "Num8", kVK_ANSI_Keypad9: "Num9",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
    ]

    private static let spokenKeys: [Int: String] = [
        kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_ForwardDelete: "Forward Delete", kVK_Escape: "Escape",
        kVK_LeftArrow: "Left Arrow", kVK_RightArrow: "Right Arrow", kVK_UpArrow: "Up Arrow", kVK_DownArrow: "Down Arrow",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down", kVK_ANSI_KeypadEnter: "Enter",
    ]
}

/// Why a quick command's shortcut doesn't work, or may not work as expected.
enum HotKeyProblem: Equatable, Sendable {
    /// AI Hub Bar's own key (search, the island's ⌃⌥Y / ⌃⌥N): it wins, the command's isn't registered.
    case app(String)
    /// An earlier command in the library has it: only that one gets it.
    case command(String)
    /// macOS or another app refused it.
    case taken
    /// macOS uses it itself: registered, but may never arrive.
    case system(String)
    /// ⌘ (and ⇧) with a key: registered, and it replaces that shortcut in every app.
    case appShortcut

    /// Not registered at all (the others are warnings).
    var blocks: Bool {
        switch self {
        case .app, .command, .taken: true
        case .system, .appShortcut: false
        }
    }

    var text: String {
        switch self {
        case let .app(name): String(localized: "Уже занято в AI Hub Bar: \(name). У команды оно не сработает.")
        case let .command(title): String(localized: "Уже у команды «\(title)» — сработает только у неё.")
        case .taken: String(localized: "macOS не дала занять это сочетание: похоже, оно у другого приложения.")
        case let .system(name): String(localized: "Это сочетание macOS (\(name)) — может не сработать.")
        case .appShortcut: String(localized: "Сочетание только с ⌘ заменит его во всех приложениях.")
        }
    }
}

/// The quick command shortcuts (SPEC-profiles §4.3): registered while «Быстрые команды» is installed and on, one
/// per command; a press runs the command the way its panel button does.
@MainActor
@Observable
final class CommandHotKeys {
    struct Plan: Equatable {
        var keys: [Key]
        var problems: [String: HotKeyProblem]
    }

    struct Key: Equatable {
        var command: String
        var combo: KeyCombo
    }

    /// Registered now, by command id: what the panel shows next to the button.
    private(set) var registered: [String: KeyCombo] = [:]
    private(set) var problems: [String: HotKeyProblem] = [:]
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let isInstalled: () -> Bool
    @ObservationIgnored private let register: ([(command: String, combo: KeyCombo)]) -> Set<String>
    @ObservationIgnored private var last: [Key]?
    @ObservationIgnored private var failed: Set<String> = []

    init(settings: AppSettings, isInstalled: @escaping () -> Bool,
         register: @escaping ([(command: String, combo: KeyCombo)]) -> Set<String> = { GlobalHotKey.registerCommands($0) }) {
        self.settings = settings
        self.isInstalled = isInstalled
        self.register = register
    }

    /// Registers now and again whenever the library, the module or the app's own keys change.
    func start(run: @escaping (QuickCommand) -> Void) {
        GlobalHotKey.commandAction = { [weak self] id in
            guard let command = self?.settings.quickCommands.first(where: { $0.id == id }) else { return }
            AppLog.info("Quick command «\(command.title)» from its hot key")
            run(command)
        }
        follow()
    }

    private func follow() {
        withObservationTracking { refresh() } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    /// Reads everything the keys depend on, so `follow()` sees each change; registers again only when the keys change.
    func refresh() {
        let plan = Self.plan(commands: isInstalled() ? settings.quickCommands : [], reserved: Self.reserved(settings))
        if plan.keys != last {
            failed = register(plan.keys.map { ($0.command, $0.combo) })
            last = plan.keys
            registered = Dictionary(plan.keys.filter { !failed.contains($0.command) }.map { ($0.command, $0.combo) }) { first, _ in first }
        }
        var problems = plan.problems
        for id in failed { problems[id] = .taken }
        self.problems = problems
    }

    /// The problem the editor shows under the command's shortcut.
    func problem(for command: QuickCommand) -> HotKeyProblem? {
        guard let combo = command.hotKey else { return nil }
        if let problem = problems[command.id], problem.blocks { return problem }
        return Self.warning(for: combo)
    }

    /// AI Hub Bar's own keys, by what they do.
    static func reserved(_ settings: AppSettings) -> [KeyCombo: String] {
        var keys: [KeyCombo: String] = [:]
        if settings.panelHotKey != .off {
            keys[KeyCombo(keyCode: settings.panelHotKey.keyCode, modifiers: settings.panelHotKey.modifiers)] = String(localized: "поиск AI Hub Bar")
        }
        if settings.notch.hotKeys {
            let modifiers = UInt32(controlKey | optionKey)
            keys[KeyCombo(keyCode: UInt32(kVK_ANSI_Y), modifiers: modifiers)] = String(localized: "остров — разрешить запрос")
            keys[KeyCombo(keyCode: UInt32(kVK_ANSI_N), modifiers: modifiers)] = String(localized: "остров — отклонить запрос")
        }
        return keys
    }

    /// Which commands get their keys: the app's own keys win, then the first command in the library.
    static func plan(commands: [QuickCommand], reserved: [KeyCombo: String]) -> Plan {
        var keys: [Key] = []
        var owners: [KeyCombo: String] = [:]
        var problems: [String: HotKeyProblem] = [:]
        for command in commands {
            guard let combo = command.hotKey, combo.isValid else { continue }
            if let name = reserved[combo] {
                problems[command.id] = .app(name)
            } else if let owner = owners[combo] {
                problems[command.id] = .command(owner)
            } else {
                owners[combo] = command.title
                keys.append(Key(command: command.id, combo: combo))
            }
        }
        return Plan(keys: keys, problems: problems)
    }

    /// The keys macOS keeps for itself, and ⌘-only keys that belong to every app's menus.
    static func warning(for combo: KeyCombo) -> HotKeyProblem? {
        let command = UInt32(cmdKey), shift = UInt32(shiftKey), option = UInt32(optionKey), control = UInt32(controlKey)
        let system: [KeyCombo: String] = [
            KeyCombo(keyCode: UInt32(kVK_Space), modifiers: command): "Spotlight",
            KeyCombo(keyCode: UInt32(kVK_Space), modifiers: control): String(localized: "смена раскладки"),
            KeyCombo(keyCode: UInt32(kVK_Space), modifiers: control | option): String(localized: "смена раскладки"),
            KeyCombo(keyCode: UInt32(kVK_Tab), modifiers: command): String(localized: "переключение приложений"),
            KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: command | shift): String(localized: "снимок экрана"),
            KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: command | shift): String(localized: "снимок экрана"),
            KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: command | shift): String(localized: "снимок экрана"),
            KeyCombo(keyCode: UInt32(kVK_ANSI_Q), modifiers: command | control): String(localized: "блокировка экрана"),
            KeyCombo(keyCode: UInt32(kVK_Escape), modifiers: command | option): String(localized: "принудительное завершение"),
            KeyCombo(keyCode: UInt32(kVK_UpArrow), modifiers: control): "Mission Control",
            KeyCombo(keyCode: UInt32(kVK_DownArrow), modifiers: control): "Mission Control",
            KeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: control): String(localized: "рабочие столы"),
            KeyCombo(keyCode: UInt32(kVK_RightArrow), modifiers: control): String(localized: "рабочие столы"),
        ]
        if let name = system[combo] { return .system(name) }
        if combo.modifiers & (option | control) == 0, combo.modifiers & command != 0, !combo.isFunctionKey { return .appShortcut }
        return nil
    }
}
