import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation

/// «Раскладка» (docs/specs/SPEC-layout.md): a word typed in the wrong layout is retyped in the right one once it is finished,
/// double Shift converts the last word or takes a fix back, ⌥⇧ converts the selection, and the layout's language sits
/// in the menu bar. Reads keys through an event tap, so it needs Accessibility; nothing typed is written anywhere.
@MainActor
@Observable
final class LayoutSwitcher {
    @ObservationIgnored var isActive: () -> Bool = { false }
    @ObservationIgnored var openSettings: (() -> Void)?

    private(set) var trusted = AXIsProcessTrusted()
    /// The enabled layouts of the languages «Раскладка» knows, in the system's order.
    private(set) var layouts: [KeyLayout] = []
    private(set) var currentID: String?
    /// «ghbdtn → привет», for the menu and Settings; in memory only.
    private(set) var lastChange: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var sources: [String: TISInputSource] = [:]
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var tapSource: CFRunLoopSource?
    @ObservationIgnored private var statusItem: NSStatusItem?
    /// For `PanelOpener`, which must not take this item for the panel's.
    var statusWindow: NSWindow? { statusItem?.button?.window }
    @ObservationIgnored private let menuActions = LayoutMenuActions()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var blinking: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let eventSource = CGEventSource(stateID: .privateState)
    @ObservationIgnored private var spellLanguages: [String: String?] = [:]

    /// The word being typed, as presses.
    @ObservationIgnored private var word: [KeyStroke] = []
    /// The word just finished by a space, Return or Tab, while nothing else has been typed.
    @ObservationIgnored private var previous: Finished?
    @ObservationIgnored private var gestures = ModifierGestures()
    /// The key-up of a space or Return held back with its key-down, so the app doesn't get it alone.
    @ObservationIgnored private var heldKeyUp: UInt16?
    @ObservationIgnored private var converting = false

    /// Marks the events «Раскладка» types itself, so the tap lets them through.
    private static let marker: Int64 = 0x4C41_594F

    private struct Finished {
        var strokes: [KeyStroke]
        /// What is on screen now, without the space after it.
        var text: String
        var boundary: UInt16
        /// The layout `text` is in.
        var layoutID: String
        /// Set when «Раскладка» fixed this word itself: double Shift takes it back.
        var correction: LayoutCorrection?
    }

    init(settings: AppSettings) {
        self.settings = settings
        eventSource?.userData = Self.marker
        menuActions.build = { [weak self] menu in self?.fill(menu) }
    }

    var current: KeyLayout? { layouts.first { $0.id == currentID } }

    func start() {
        guard loop == nil else { return }
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutChanged() }
        })
        observers.append(center.addObserver(forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadLayouts() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget() }
        })
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                sync()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Installs or removes the tap and the menu bar item as the module, the permission and the settings change.
    func sync() {
        let on = isActive()
        if on, layouts.isEmpty { reloadLayouts() }
        // The tap itself is the test: `AXIsProcessTrusted` can say no while the list in System Settings says yes.
        if on { installTap() } else { removeTap() }
        let granted = tap != nil
        if granted != trusted {
            trusted = granted
            updateStatusItem()
        }
        if on, settings.layout.menuBarIcon { showStatusItem() } else { hideStatusItem() }
        if Self.shouldAskForAccess(isOn: on, granted: trusted, alreadyAsked: settings.layoutAccessAsked) {
            settings.layoutAccessAsked = true
            AppLog.info("Layout: no key access (Accessibility \(AXIsProcessTrusted()), input monitoring \(CGPreflightListenEventAccess()), posting \(CGPreflightPostEventAccess())), asking macOS")
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            CGRequestListenEventAccess()
        }
    }

    /// The system prompt comes up by itself once in the life of the app. Without access it would otherwise be back at
    /// every launch and after every update; from then on the panel and Settings offer `requestAccess`.
    nonisolated static func shouldAskForAccess(isOn: Bool, granted: Bool, alreadyAsked: Bool) -> Bool {
        isOn && !granted && !alreadyAsked
    }

    /// A click on «Дать доступ»: clears this app's old records, asks macOS again and opens the list in System Settings.
    /// A record from an earlier signature keeps its switch on while the app gets no access, and turning it off and on
    /// does nothing; only removing the record helps (seen 2026-11-08).
    func requestAccess() {
        settings.layoutAccessAsked = true
        Task {
            if let id = Bundle.main.bundleIdentifier {
                for service in ["Accessibility", "ListenEvent"] {
                    _ = try? await ProcessRunner.run("/usr/bin/tccutil", ["reset", service, id], timeout: .seconds(5))
                }
            }
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            CGRequestListenEventAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func forgetLearned(_ word: String) {
        settings.layout.learned.removeAll { $0 == word }
    }

    // MARK: - Layouts

    private func reloadLayouts() {
        let loaded = KeyboardLayouts.enabled()
        sources = Dictionary(loaded.map { ($0.layout.id, $0.source) }) { first, _ in first }
        layouts = loaded.map(\.layout)
        currentID = KeyboardLayouts.currentID()
        updateStatusItem()
    }

    /// The person switched the layout (or «Раскладка» did, which is already known): a word half typed in the old one
    /// can't be read in the new one.
    private func layoutChanged() {
        let id = KeyboardLayouts.currentID()
        guard id != currentID else { return }
        currentID = id
        forget()
        updateStatusItem()
    }

    private func select(_ layout: KeyLayout) {
        guard let source = sources[layout.id] else { return }
        TISSelectInputSource(source)
        currentID = layout.id
        updateStatusItem()
        blink()
    }

    private func isWord(_ word: String, _ language: String) -> Bool {
        let spell: String?
        if let cached = spellLanguages[language] {
            spell = cached
        } else {
            let available = NSSpellChecker.shared.availableLanguages
            spell = available.first { $0 == language } ?? available.first { $0.hasPrefix(language + "_") }
            spellLanguages[language] = spell
        }
        // Without a dictionary every word would pass.
        guard let spell else { return false }
        return NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: spell, wrap: false,
                                                   inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    // MARK: - Keys

    private func installTap() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, info in
                                              guard let info else { return Unmanaged.passUnretained(event) }
                                              let switcher = Unmanaged<LayoutSwitcher>.fromOpaque(info).takeUnretainedValue()
                                              nonisolated(unsafe) let event = event
                                              let swallow = MainActor.assumeIsolated { switcher.handle(type, event) }
                                              return swallow ? nil : Unmanaged.passUnretained(event)
                                          },
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            // Without access this fails on every check; logged once (`sync`).
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        tapSource = source
        AppLog.info("Layout: watching keys (\(layouts.map(\.language).joined(separator: ", ")))")
    }

    private func removeTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        self.tap = nil
        tapSource = nil
        forget()
        AppLog.info("Layout: stopped watching keys")
    }

    private func forget() {
        word = []
        previous = nil
        gestures.reset()
    }

    /// True: the event is held back.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return false }
        switch type {
        case .keyDown:
            return keyDown(event)
        case .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard code == heldKeyUp else { return false }
            heldKeyUp = nil
            return true
        case .flagsChanged:
            let flags = event.flags
            let gesture = gestures.flags(shift: flags.contains(.maskShift), option: flags.contains(.maskAlternate),
                                         other: !flags.isDisjoint(with: [.maskCommand, .maskControl, .maskSecondaryFn]),
                                         at: Double(event.timestamp) / 1_000_000_000)
            switch gesture {
            case .doubleShift where settings.layout.doubleShift: convertLastWord()
            case .optionShift where settings.layout.optionShift: convertSelection()
            default: break
            }
            return false
        default:
            forget()
            return false
        }
    }

    private func keyDown(_ event: CGEvent) -> Bool {
        gestures.reset()
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        // A shortcut. ⌘Z right after a fix: the person takes it back in the app, so the word is learned.
        if !flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]) {
            if flags.contains(.maskCommand), Int(code) == kVK_ANSI_Z, word.isEmpty, let correction = previous?.correction { learn(correction.typed) }
            forget()
            return false
        }
        if IsSecureEventInputEnabled() {
            forget()
            return false
        }
        switch Int(code) {
        case kVK_Delete:
            if !word.isEmpty {
                word.removeLast()
            } else if let last = previous, last.correction == nil, last.layoutID == currentID {
                // The space went: the word before it is being edited again.
                word = last.strokes
            }
            previous = nil
            return false
        case kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab:
            return finishWord(boundary: code, shift: flags.contains(.maskShift))
        default:
            let stroke = KeyStroke(keyCode: code, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift))
            guard let layout = current, layout.keys[stroke] != nil else {
                forget()
                return false
            }
            previous = nil
            word.append(stroke)
            if word.count > LayoutWords.maximumStrokes { word.removeFirst() }
            return false
        }
    }

    private func finishWord(boundary: UInt16, shift: Bool) -> Bool {
        let strokes = word
        word = []
        guard !strokes.isEmpty, let layout = current else {
            previous = nil
            return false
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let skipped = settings.layout.skipTerminals && front.map(LayoutSettings.terminals.contains) == true
        if settings.layout.auto, !skipped,
           let correction = LayoutWords.correction(for: strokes, in: layout, others: settings.layout.autoTargets(from: layout, among: layouts),
                                                   learned: Set(settings.layout.learned),
                                                   isWord: { isWord($0, $1) }),
           let target = layouts.first(where: { $0.id == correction.layoutID }) {
            erase(correction.typed.count)
            type(correction.text)
            press(boundary, flags: shift ? .maskShift : [])
            heldKeyUp = boundary
            select(target)
            previous = Finished(strokes: strokes, text: correction.text, boundary: boundary, layoutID: layout.id, correction: correction)
            lastChange = "\(correction.typed) → \(correction.text)"
            AppLog.info("Layout: fixed a word, \(layout.language) → \(target.language)")
            return true
        }
        previous = Finished(strokes: strokes, text: layout.text(strokes), boundary: boundary, layoutID: layout.id)
        return false
    }

    /// Double Shift: takes back the fix just made (and learns the word), or converts the word being typed or the one
    /// just finished by a space.
    private func convertLastWord() {
        guard let layout = current else { return }
        if word.isEmpty, let last = previous, let correction = last.correction, let original = layouts.first(where: { $0.id == last.layoutID }) {
            learn(correction.typed)
            // After Return the text has usually gone (a message sent): only the layout goes back.
            if [kVK_Space, kVK_Tab].contains(Int(last.boundary)) {
                erase(correction.text.count + 1)
                type(correction.typed)
                press(last.boundary)
            }
            select(original)
            previous = Finished(strokes: last.strokes, text: correction.typed, boundary: last.boundary, layoutID: original.id)
            lastChange = "\(correction.text) → \(correction.typed)"
            AppLog.info("Layout: a fix taken back, the word is learned")
            return
        }
        let strokes: [KeyStroke]
        let shown: String
        var boundary: UInt16?
        if !word.isEmpty {
            strokes = word
            shown = layout.text(word)
        } else if let last = previous, last.correction == nil, [kVK_Space, kVK_Tab].contains(Int(last.boundary)), last.layoutID == layout.id {
            strokes = last.strokes
            shown = last.text
            boundary = last.boundary
        } else {
            return
        }
        guard !strokes.contains(where: layout.deadKeys.contains),
              let target = LayoutWords.manualTarget(for: strokes, in: layout, among: layouts, isWord: { isWord($0, $1) }) else { return }
        let text = target.text(strokes)
        erase(shown.count + (boundary == nil ? 0 : 1))
        type(text)
        if let boundary {
            press(boundary)
            previous = Finished(strokes: strokes, text: text, boundary: boundary, layoutID: target.id)
        }
        select(target)
        lastChange = "\(shown) → \(text)"
    }

    /// ⌥⇧: copies the selection, pastes it converted, and puts the clipboard back as it was.
    private func convertSelection() {
        guard !converting, layouts.count > 1 else { return }
        converting = true
        forget()
        Task { [weak self] in
            guard let self else { return }
            defer { converting = false }
            let pasteboard = NSPasteboard.general
            let saved = PasteboardSnapshot(pasteboard)
            let before = pasteboard.changeCount
            ClipboardHistory.pause(seconds: 2)
            press(UInt16(kVK_ANSI_C), flags: .maskCommand)
            for _ in 0..<15 where pasteboard.changeCount == before {
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard pasteboard.changeCount != before else { return }
            guard let text = pasteboard.string(forType: .string), text.count <= 5000,
                  let result = LayoutWords.convert(text, among: layouts, current: currentID, exceptions: Set(settings.layout.learned),
                                                   isWord: { self.isWord($0, $1) }) else {
                saved.restore(to: pasteboard)
                return
            }
            pasteboard.clearContents()
            pasteboard.setString(result.text, forType: .string)
            pasteboard.setString("", forType: PasteboardSnapshot.transient)
            press(UInt16(kVK_ANSI_V), flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(300))
            saved.restore(to: pasteboard)
            if let target = layouts.first(where: { $0.id == result.layoutID }) { select(target) }
            lastChange = "\(text.prefix(30)) → \(result.text.prefix(30))"
            AppLog.info("Layout: converted the selection")
        }
    }

    private func learn(_ typed: String) {
        settings.layout.learned = LayoutWords.learning(typed, into: settings.layout.learned)
    }

    // MARK: - Typing

    private func press(_ key: UInt16, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func press(_ key: Int, flags: CGEventFlags = []) { press(UInt16(key), flags: flags) }

    private func erase(_ count: Int) {
        for _ in 0..<max(count, 0) { press(kVK_Delete) }
    }

    private func type(_ text: String) {
        for character in text {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                event.post(tap: .cgSessionEventTap)
            }
        }
    }

    // MARK: - Menu bar

    private func showStatusItem() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = menuActions
            item.menu = menu
            statusItem = item
        }
        updateStatusItem()
    }

    private func hideStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let badge = current?.badge ?? KeyboardLayouts.currentLanguage().map(LayoutWords.badge) ?? "—"
        button.attributedTitle = NSAttributedString(string: badge, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
        // Without Accessibility nothing is fixed: the language shows faded until access is given.
        button.appearsDisabled = !trusted
        button.toolTip = String(localized: "Раскладка: \(KeyboardLayouts.currentName() ?? badge)")
        button.setAccessibilityLabel(String(localized: "Раскладка: \(KeyboardLayouts.currentName() ?? badge)"))
    }

    /// The language blinks when «Раскладка» switches the layout.
    private func blink() {
        guard let button = statusItem?.button else { return }
        blinking?.cancel()
        blinking = Task {
            for step in 0..<6 {
                button.alphaValue = step.isMultiple(of: 2) ? 0.2 : 1
                try? await Task.sleep(for: .milliseconds(130))
                if Task.isCancelled { break }
            }
            button.alphaValue = 1
        }
    }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        let name = NSMenuItem(title: KeyboardLayouts.currentName() ?? "", action: nil, keyEquivalent: "")
        name.isEnabled = false
        menu.addItem(name)
        if let lastChange {
            let item = NSMenuItem(title: String(localized: "Последнее: \(lastChange)"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if !trusted {
            menu.addItem(menuActions.item(String(localized: "Дать доступ к клавиатуре…")) { [weak self] in self?.requestAccess() })
        } else if layouts.count < 2 {
            let item = NSMenuItem(title: String(localized: "Нужны две раскладки"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        let auto = menuActions.item(String(localized: "Исправлять раскладку сам")) { [weak self] in self?.settings.layout.auto.toggle() }
        auto.state = settings.layout.auto ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())
        let directions = LayoutWords.directions(among: layouts)
        if settings.layout.auto, !directions.isEmpty {
            menu.addItem(.sectionHeader(title: String(localized: "С какой раскладки на какую")))
            for direction in directions {
                let on = settings.layout.fixes(direction)
                let item = menuActions.item(direction.title) { [weak self] in self?.settings.layout.setFixes(direction, !on) }
                item.state = on ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(menuActions.item(String(localized: "Словарь исключений…")) { [weak self] in self?.openSettings?() })
        menu.addItem(menuActions.item(String(localized: "Настройки раскладки…")) { [weak self] in self?.openSettings?() })
    }
}

/// The menu bar item's menu, built when it opens.
@MainActor
private final class LayoutMenuActions: NSObject, NSMenuDelegate {
    var build: (NSMenu) -> Void = { _ in }

    private final class Action {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(activate(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Action(run)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) { build(menu) }

    @objc private func activate(_ sender: NSMenuItem) { (sender.representedObject as? Action)?.run() }
}

/// What was on the clipboard before ⌥⇧, put back afterwards.
@MainActor
private struct PasteboardSnapshot {
    /// nspasteboard.org: clipboard managers (and «История буфера») skip what is marked with it.
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        restored.first?.setString("", forType: Self.transient)
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
