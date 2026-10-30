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
    private static var handler: EventHandlerRef?
    static var action: (() -> Void)?

    static func register(_ key: PanelHotKey) {
        if let reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
        guard key != .off else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.action?() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        var newReference: EventHotKeyRef?
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, EventHotKeyID(signature: 0x4350_5554, id: 1),
                                         GetApplicationEventTarget(), 0, &newReference)
        if status == noErr {
            reference = newReference
            AppLog.info("Hot key \(key.rawValue) registered")
        } else {
            AppLog.error("Hot key \(key.rawValue) not registered: \(status) (another app may use it)")
        }
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
