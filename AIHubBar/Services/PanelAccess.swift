import AppKit
import Carbon.HIToolbox

/// The global shortcut that opens the panel. A Carbon hot key: works in any app and needs no Accessibility permission.
enum PanelHotKey: String, CaseIterable, Sendable {
    case off, controlOptionC, controlOptionSpace, optionCommandK

    var title: String {
        switch self {
        case .off: String(localized: "Выключено")
        case .controlOptionC: "⌃⌥C"
        case .controlOptionSpace: String(localized: "⌃⌥Пробел")
        case .optionCommandK: "⌥⌘K"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .off: 0
        case .controlOptionC: UInt32(kVK_ANSI_C)
        case .controlOptionSpace: UInt32(kVK_Space)
        case .optionCommandK: UInt32(kVK_ANSI_K)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .off: 0
        case .controlOptionC, .controlOptionSpace: UInt32(controlKey | optionKey)
        case .optionCommandK: UInt32(optionKey | cmdKey)
        }
    }
}

@MainActor
enum GlobalHotKey {
    private static var reference: EventHotKeyRef?
    private static var islandReferences: [EventHotKeyRef] = []
    private static var handler: EventHandlerRef?
    static var action: (() -> Void)?
    /// ⌃⌥Y / ⌃⌥N for the permission request in the notch island (SPEC-notch §4): true = allow.
    static var islandAction: ((Bool) -> Void)?
    private static var quickPromptReference: EventHotKeyRef?
    /// «Быстрый запрос» (SPEC-quick-prompt): opens its window.
    static var quickPromptAction: (() -> Void)?

    private static let signature: OSType = 0x4350_5554
    private enum ID: UInt32 { case panel = 1, allow, deny, quickPrompt }

    static func register(_ key: PanelHotKey) {
        if let reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
        guard key != .off else { return }
        installHandler()
        if let new = add(key.keyCode, key.modifiers, .panel) {
            reference = new
            AppLog.info("Hot key \(key.rawValue) registered")
        } else {
            AppLog.error("Hot key \(key.rawValue) not registered (another app may use it)")
        }
    }

    /// ⌃⌥Y and ⌃⌥N while the person has them on; off unregisters both.
    static func registerIsland(_ on: Bool) {
        for reference in islandReferences { UnregisterEventHotKey(reference) }
        islandReferences = []
        guard on else { return }
        installHandler()
        let modifiers = UInt32(controlKey | optionKey)
        islandReferences = [add(UInt32(kVK_ANSI_Y), modifiers, .allow), add(UInt32(kVK_ANSI_N), modifiers, .deny)].compactMap { $0 }
        AppLog.info(islandReferences.count == 2 ? "Island hot keys ⌃⌥Y / ⌃⌥N registered" : "Island hot keys not registered (another app may use them)")
    }

    /// «Быстрый запрос»'s key while its module is on; `.off` unregisters it.
    static func registerQuickPrompt(_ key: QuickPromptHotKey) {
        if let quickPromptReference {
            UnregisterEventHotKey(quickPromptReference)
            self.quickPromptReference = nil
        }
        guard key != .off else { return }
        installHandler()
        quickPromptReference = add(key.keyCode, key.modifiers, .quickPrompt)
        AppLog.info(quickPromptReference != nil ? "Quick prompt hot key \(key.rawValue) registered" : "Quick prompt hot key \(key.rawValue) not registered (another app may use it)")
    }

    private static func add(_ keyCode: UInt32, _ modifiers: UInt32, _ id: ID) -> EventHotKeyRef? {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: signature, id: id.rawValue),
                                         GetApplicationEventTarget(), 0, &reference)
        if status == noErr { combos[id.rawValue] = KeyCombo(keyCode: keyCode, modifiers: modifiers) }
        return status == noErr ? reference : nil
    }

    // MARK: Quick command shortcuts (SPEC-profiles §4.3)

    private static var commandReferences: [EventHotKeyRef] = []
    /// Hot key id → quick command id; the ids start far above `ID` so the fixed keys never collide.
    private static var commandIDs: [UInt32: String] = [:]
    private static let firstCommandID: UInt32 = 1000
    /// The keys registered under each id, for the recorder below.
    private static var combos: [UInt32: KeyCombo] = [:]
    static var commandAction: ((String) -> Void)?
    /// While a shortcut is being recorded, a registered key goes here instead of running: Carbon takes registered
    /// keys before the recorder can see them.
    static var recorder: ((KeyCombo) -> Void)?

    /// Replaces the quick command shortcuts with these; returns the command ids that didn't register (taken).
    @discardableResult
    static func registerCommands(_ keys: [(command: String, combo: KeyCombo)]) -> Set<String> {
        for reference in commandReferences { UnregisterEventHotKey(reference) }
        commandReferences = []
        for id in commandIDs.keys { combos[id] = nil }
        commandIDs = [:]
        guard !keys.isEmpty else { return [] }
        installHandler()
        var failed: Set<String> = []
        for (index, key) in keys.enumerated() {
            let id = firstCommandID + UInt32(index)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(key.combo.keyCode, key.combo.modifiers, EventHotKeyID(signature: signature, id: id),
                                             GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                commandReferences.append(reference)
                commandIDs[id] = key.command
                combos[id] = key.combo
            } else {
                failed.insert(key.command)
            }
        }
        AppLog.info("Quick command hot keys: \(commandReferences.count) registered, \(failed.count) not")
        return failed
    }

    /// A quick command's key, or any key while recording; false leaves the press to the fixed keys.
    private static func handleCommand(_ id: UInt32) -> Bool {
        if let recorder, let combo = combos[id] {
            recorder(combo)
            return true
        }
        guard let command = commandIDs[id] else { return false }
        commandAction?(command)
        return true
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if GlobalHotKey.handleCommand(id) { return }
                    switch ID(rawValue: id) {
                    case .allow: GlobalHotKey.islandAction?(true)
                    case .deny: GlobalHotKey.islandAction?(false)
                    case .quickPrompt: GlobalHotKey.quickPromptAction?()
                    default: GlobalHotKey.action?()
                    }
                }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// The hot key and the Shortcuts action open a small search window in the middle of the screen. The menu bar
/// panel itself can't be opened from code: `MenuBarExtra` ignores synthetic clicks on its item (tried
/// `performClick`, its action and mouse events, 2026-10-30).
@MainActor
enum QuickSearch {
    static var open: (() -> Void)?

    static func show() {
        AppLog.info("Quick search opened")
        NSApp.activate()
        open?()
    }
}
