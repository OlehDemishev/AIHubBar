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

    private static let signature: OSType = 0x4350_5554
    private enum ID: UInt32 { case panel = 1, allow, deny }

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

    private static func add(_ keyCode: UInt32, _ modifiers: UInt32, _ id: ID) -> EventHotKeyRef? {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: signature, id: id.rawValue),
                                         GetApplicationEventTarget(), 0, &reference)
        return status == noErr ? reference : nil
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
                    switch ID(rawValue: id) {
                    case .allow: GlobalHotKey.islandAction?(true)
                    case .deny: GlobalHotKey.islandAction?(false)
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
