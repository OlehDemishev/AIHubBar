import AppKit
import Carbon.HIToolbox

/// The system's keyboard layouts, read through Text Input Sources.
@MainActor
enum KeyboardLayouts {
    static func enabled() -> [(source: TISInputSource, layout: KeyLayout)] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap { source in
            guard string(source, kTISPropertyInputSourceType) == kTISTypeKeyboardLayout as String,
                  let id = string(source, kTISPropertyInputSourceID),
                  let language = language(source), LayoutWords.languages.contains(language),
                  let data = property(source, kTISPropertyUnicodeKeyLayoutData).map({ $0 as! CFData as Data }) else { return nil }
            let (keys, dead) = translate(data)
            return (source, KeyLayout(id: id, language: language, name: string(source, kTISPropertyLocalizedName) ?? id, keys: keys, deadKeys: dead))
        }
    }

    static func currentID() -> String? {
        TISCopyCurrentKeyboardInputSource().map { string($0.takeRetainedValue(), kTISPropertyInputSourceID) } ?? nil
    }

    static func currentName() -> String? {
        TISCopyCurrentKeyboardInputSource().map { string($0.takeRetainedValue(), kTISPropertyLocalizedName) } ?? nil
    }

    static func currentLanguage() -> String? {
        TISCopyCurrentKeyboardInputSource().map { language($0.takeRetainedValue()) } ?? nil
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        TISGetInputSourceProperty(source, key).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? { property(source, key) as? String }

    /// The layout's first language, two letters («pt» for pt-BR).
    private static func language(_ source: TISInputSource) -> String? {
        (property(source, kTISPropertyInputSourceLanguages) as? [String])?.first.map { String($0.prefix { $0.isLetter }).lowercased() }
    }

    /// What each key types with and without Shift and Caps Lock. The keypad and keys that type nothing are left out.
    private static func translate(_ data: Data) -> (keys: [KeyStroke: String], dead: Set<KeyStroke>) {
        let keypad: Set<Int> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        var keys: [KeyStroke: String] = [:]
        var dead: Set<KeyStroke> = []
        let keyboardType = UInt32(LMGetKbdType())
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in 0..<128 where !keypad.contains(code) && code != kVK_Space {
                for (shift, caps) in [(false, false), (true, false), (false, true), (true, true)] {
                    let stroke = KeyStroke(keyCode: UInt16(code), shift: shift, caps: caps)
                    var modifiers = 0
                    if shift { modifiers |= shiftKey }
                    if caps { modifiers |= alphaLock }
                    var state: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    guard UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), UInt32(modifiers >> 8) & 0xFF, keyboardType,
                                         OptionBits(kUCKeyTranslateNoDeadKeysMask), &state, chars.count, &length, &chars) == noErr,
                          length > 0 else { continue }
                    let text = String(utf16CodeUnits: chars, count: length)
                    guard let scalar = text.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F,
                          !text.contains(where: \.isWhitespace) else { continue }
                    keys[stroke] = text
                    var deadState: UInt32 = 0
                    _ = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), UInt32(modifiers >> 8) & 0xFF, keyboardType,
                                       0, &deadState, chars.count, &length, &chars)
                    if deadState != 0 { dead.insert(stroke) }
                }
            }
        }
        return (keys, dead)
    }
}
