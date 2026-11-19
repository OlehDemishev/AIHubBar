//! Keyboard shortcuts of «Быстрые команды» (SPEC-profiles §4.3), the Mac's `KeyCombo` and `CommandHotKeys.plan`.
//!
//! A command's `hotKey` stays in the Mac's own shape — `{"keyCode": <Mac virtual key code>, "modifiers": <Carbon
//! mask>}` — so a library moves between the systems as it is. The modifiers map one to one, which is what survives a
//! round trip: ⌃ ↔ Ctrl, ⌥ ↔ Alt, ⇧ ↔ Shift, ⌘ ↔ Win. ⌘ is NOT Ctrl here: ⌃⌥K and ⌘⌥K are two shortcuts on a Mac and
//! must stay two. A key is the one printed on a US keyboard, as the Mac's key code means it. A combination with a
//! key this table doesn't know (a JIS key, «Help») is never registered and never rewritten.

use crate::i18n::Strings;
use crate::quick_commands::{Kind, QuickCommand};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

/// Carbon's `cmdKey`, `shiftKey`, `optionKey`, `controlKey`.
pub const COMMAND: u32 = 0x0100;
pub const SHIFT: u32 = 0x0200;
pub const OPTION: u32 = 0x0800;
pub const CONTROL: u32 = 0x1000;
const KNOWN: u32 = COMMAND | SHIFT | OPTION | CONTROL;

const ESCAPE: u32 = 53;

/// The Mac's key code, the key as the global shortcut plugin and a browser's `KeyboardEvent.code` name it, its
/// Windows virtual key (what a browser's `keyCode` and `RegisterHotKey` mean; 0 — none of its own), its title.
const KEYS: [(u32, &str, u32, &str); 94] = [
    (0, "KeyA", 0x41, "A"),
    (11, "KeyB", 0x42, "B"),
    (8, "KeyC", 0x43, "C"),
    (2, "KeyD", 0x44, "D"),
    (14, "KeyE", 0x45, "E"),
    (3, "KeyF", 0x46, "F"),
    (5, "KeyG", 0x47, "G"),
    (4, "KeyH", 0x48, "H"),
    (34, "KeyI", 0x49, "I"),
    (38, "KeyJ", 0x4A, "J"),
    (40, "KeyK", 0x4B, "K"),
    (37, "KeyL", 0x4C, "L"),
    (46, "KeyM", 0x4D, "M"),
    (45, "KeyN", 0x4E, "N"),
    (31, "KeyO", 0x4F, "O"),
    (35, "KeyP", 0x50, "P"),
    (12, "KeyQ", 0x51, "Q"),
    (15, "KeyR", 0x52, "R"),
    (1, "KeyS", 0x53, "S"),
    (17, "KeyT", 0x54, "T"),
    (32, "KeyU", 0x55, "U"),
    (9, "KeyV", 0x56, "V"),
    (13, "KeyW", 0x57, "W"),
    (7, "KeyX", 0x58, "X"),
    (16, "KeyY", 0x59, "Y"),
    (6, "KeyZ", 0x5A, "Z"),
    (29, "Digit0", 0x30, "0"),
    (18, "Digit1", 0x31, "1"),
    (19, "Digit2", 0x32, "2"),
    (20, "Digit3", 0x33, "3"),
    (21, "Digit4", 0x34, "4"),
    (23, "Digit5", 0x35, "5"),
    (22, "Digit6", 0x36, "6"),
    (26, "Digit7", 0x37, "7"),
    (28, "Digit8", 0x38, "8"),
    (25, "Digit9", 0x39, "9"),
    (27, "Minus", 0xBD, "-"),
    (24, "Equal", 0xBB, "="),
    (33, "BracketLeft", 0xDB, "["),
    (30, "BracketRight", 0xDD, "]"),
    (42, "Backslash", 0xDC, "\\"),
    (41, "Semicolon", 0xBA, ";"),
    (39, "Quote", 0xDE, "'"),
    (43, "Comma", 0xBC, ","),
    (47, "Period", 0xBE, "."),
    (44, "Slash", 0xBF, "/"),
    (50, "Backquote", 0xC0, "`"),
    (82, "Numpad0", 0x60, "Num0"),
    (83, "Numpad1", 0x61, "Num1"),
    (84, "Numpad2", 0x62, "Num2"),
    (85, "Numpad3", 0x63, "Num3"),
    (86, "Numpad4", 0x64, "Num4"),
    (87, "Numpad5", 0x65, "Num5"),
    (88, "Numpad6", 0x66, "Num6"),
    (89, "Numpad7", 0x67, "Num7"),
    (91, "Numpad8", 0x68, "Num8"),
    (92, "Numpad9", 0x69, "Num9"),
    (49, "Space", 0x20, "Space"),
    (36, "Enter", 0x0D, "Enter"),
    (48, "Tab", 0x09, "Tab"),
    (51, "Backspace", 0x08, "Backspace"),
    (117, "Delete", 0x2E, "Delete"),
    (ESCAPE, "Escape", 0x1B, "Esc"),
    (123, "ArrowLeft", 0x25, "←"),
    (124, "ArrowRight", 0x27, "→"),
    (126, "ArrowUp", 0x26, "↑"),
    (125, "ArrowDown", 0x28, "↓"),
    (115, "Home", 0x24, "Home"),
    (119, "End", 0x23, "End"),
    (116, "PageUp", 0x21, "PgUp"),
    (121, "PageDown", 0x22, "PgDn"),
    // Windows knows it only as Enter: found by its name alone.
    (76, "NumpadEnter", 0, "Num Enter"),
    (122, "F1", 0x70, "F1"),
    (120, "F2", 0x71, "F2"),
    (99, "F3", 0x72, "F3"),
    (118, "F4", 0x73, "F4"),
    (96, "F5", 0x74, "F5"),
    (97, "F6", 0x75, "F6"),
    (98, "F7", 0x76, "F7"),
    (100, "F8", 0x77, "F8"),
    (101, "F9", 0x78, "F9"),
    (109, "F10", 0x79, "F10"),
    (103, "F11", 0x7A, "F11"),
    (111, "F12", 0x7B, "F12"),
    (105, "F13", 0x7C, "F13"),
    (107, "F14", 0x7D, "F14"),
    (113, "F15", 0x7E, "F15"),
    (106, "F16", 0x7F, "F16"),
    (64, "F17", 0x80, "F17"),
    (79, "F18", 0x81, "F18"),
    (80, "F19", 0x82, "F19"),
    (90, "F20", 0x83, "F20"),
    // Not on a Mac's own keyboards, but they have key codes there.
    (114, "Insert", 0x2D, "Insert"),
    (71, "NumLock", 0x90, "NumLock"),
];

/// The Mac's `KeyCombo`: a key with modifiers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyCombo {
    pub key_code: u32,
    pub modifiers: u32,
}

impl KeyCombo {
    pub fn new(key_code: u32, modifiers: u32) -> KeyCombo {
        KeyCombo { key_code, modifiers: modifiers & KNOWN }
    }

    /// A command's `hotKey` as it lies in the file; bits the Mac doesn't know are left out, as its own `init` does.
    pub fn from_value(value: &Value) -> Option<KeyCombo> {
        serde_json::from_value::<KeyCombo>(value.clone()).ok().map(|k| KeyCombo::new(k.key_code, k.modifiers))
    }

    /// Keys pressed in the recorder: a browser's `keyCode` (the Windows virtual key) first, since that is what the
    /// system registers whatever the layout; else `code`, the key's name. None — a key that has no Mac key code.
    pub fn from_press(virtual_key: u32, code: &str, ctrl: bool, alt: bool, shift: bool, win: bool) -> Option<KeyCombo> {
        let found = KEYS.iter().find(|k| virtual_key != 0 && k.2 == virtual_key && code != "NumpadEnter").or_else(|| KEYS.iter().find(|k| k.1 == code))?;
        let modifiers = [(ctrl, CONTROL), (alt, OPTION), (shift, SHIFT), (win, COMMAND)].iter().filter(|m| m.0).fold(0, |all, m| all | m.1);
        Some(KeyCombo::new(found.0, modifiers))
    }

    fn key(self) -> Option<&'static (u32, &'static str, u32, &'static str)> {
        KEYS.iter().find(|k| k.0 == self.key_code)
    }

    pub fn has(self, modifier: u32) -> bool {
        self.modifiers & modifier != 0
    }

    pub fn is_function_key(self) -> bool {
        self.key().is_some_and(|k| k.1.starts_with('F') && k.1[1..].parse::<u8>().is_ok())
    }

    /// Ctrl, Alt or Win — or an F key alone: a letter with only Shift would take that letter from typing everywhere.
    pub fn is_valid(self) -> bool {
        self.key_code != ESCAPE && (self.modifiers & (COMMAND | OPTION | CONTROL) != 0 || self.is_function_key())
    }

    /// As the global shortcut plugin reads it («Ctrl+Alt+KeyK»); None — a key this table doesn't know.
    pub fn accelerator(self) -> Option<String> {
        Some(self.joined(["Super", "Ctrl", "Alt", "Shift"], self.key()?.1))
    }

    /// «Win+Ctrl+Alt+Shift+K», in the order Windows writes its own; «#114» for a key without a name, like the Mac.
    pub fn title(self) -> String {
        self.joined(["Win", "Ctrl", "Alt", "Shift"], &self.key().map_or_else(|| format!("#{}", self.key_code), |k| k.3.to_owned()))
    }

    fn joined(self, names: [&str; 4], key: &str) -> String {
        let held = [COMMAND, CONTROL, OPTION, SHIFT].into_iter().zip(names).filter(|(bit, _)| self.has(*bit)).map(|(_, name)| name);
        held.chain([key]).collect::<Vec<_>>().join("+")
    }

    fn virtual_key(self) -> Option<u32> {
        self.key().map(|k| k.2).filter(|vk| *vk != 0)
    }
}

/// Why a command's shortcut doesn't work, or may not work as expected (the Mac's `HotKeyProblem`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Problem {
    /// AI Hub Bar's own key («Быстрый запрос»): it wins, the command's isn't registered.
    App(String),
    /// An earlier command in the library has it: only that one gets it.
    Command(String),
    /// The system or another program refused it.
    Taken,
    /// A key that exists only on a Mac: kept in the file, not registered here.
    NotHere,
    /// Ctrl+Alt is AltGr, and with this key a keyboard layout of this computer types this character: registered, and
    /// the character can't be typed any more.
    AltGr(String),
    /// Only Ctrl or only Alt (and Shift) with a key: registered, and it replaces that shortcut in every program.
    AppShortcut,
}

impl Problem {
    /// Not registered at all (the others are warnings).
    pub fn blocks(&self) -> bool {
        matches!(self, Problem::App(_) | Problem::Command(_) | Problem::Taken | Problem::NotHere)
    }

    pub fn text(&self, s: &Strings) -> String {
        match self {
            Problem::App(name) => s.format("Уже занято в AI Hub Bar: %@. У команды оно не сработает.", &[name]),
            Problem::Command(title) => s.format("Уже у команды «%@» — сработает только у неё.", &[title]),
            Problem::Taken => s.t("Система не дала занять это сочетание: похоже, оно у другой программы.").to_owned(),
            Problem::NotHere => s.t("Такой клавиши здесь нет: сочетание записано на Mac и работает только там.").to_owned(),
            Problem::AltGr(character) => s.format("Ctrl+Alt — это AltGr: на вашей раскладке это сочетание заберёт символ «%@».", &[character]),
            Problem::AppShortcut => s.t("Сочетание только с Ctrl или Alt заменит его во всех программах.").to_owned(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Key {
    pub command: String,
    pub combo: KeyCombo,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Plan {
    pub keys: Vec<Key>,
    pub problems: HashMap<String, Problem>,
}

/// Which commands get their keys: the app's own keys win, then the first command in the library. A Mac shortcut
/// from «Команды» never runs here, so it takes no key either.
pub fn plan(commands: &[QuickCommand], reserved: &[(KeyCombo, String)]) -> Plan {
    let mut plan = Plan::default();
    let mut owners: Vec<(KeyCombo, &str)> = Vec::new();
    for command in commands.iter().filter(|c| c.kind != Kind::Shortcut) {
        let Some(combo) = command.combo().filter(|c| c.is_valid()) else { continue };
        if combo.accelerator().is_none() {
            plan.problems.insert(command.id.clone(), Problem::NotHere);
        } else if let Some((_, name)) = reserved.iter().find(|r| r.0 == combo) {
            plan.problems.insert(command.id.clone(), Problem::App(name.clone()));
        } else if let Some((_, owner)) = owners.iter().find(|o| o.0 == combo) {
            plan.problems.insert(command.id.clone(), Problem::Command((*owner).to_owned()));
        } else {
            owners.push((combo, &command.title));
            plan.keys.push(Key { command: command.id.clone(), combo });
        }
    }
    plan
}

/// A registered shortcut that still costs something: a character AltGr types, or a shortcut every program has.
/// `altgr` says which character a layout of this computer types with AltGr and this key ([`altgr_character`]).
pub fn warning(combo: KeyCombo, altgr: impl Fn(KeyCombo) -> Option<String>) -> Option<Problem> {
    let (ctrl, alt, win) = (combo.has(CONTROL), combo.has(OPTION), combo.has(COMMAND));
    if ctrl && alt && !win {
        return altgr(combo).map(Problem::AltGr);
    }
    // Ctrl+C, Alt+F4: unlike the Mac's F keys with ⌘, here they belong to programs too.
    (!win && (ctrl || alt)).then_some(Problem::AppShortcut)
}

/// The character typed by AltGr (which Windows sees as Ctrl+Alt) with this key, and Shift if the combination has
/// it, on any keyboard layout installed on this computer: «ą» for Ctrl+Alt+A with a Polish layout, «@» for
/// Ctrl+Alt+Q with a German one. A dead key counts too. None on other systems: there AltGr is a key of its own.
#[cfg(windows)]
pub fn altgr_character(combo: KeyCombo) -> Option<String> {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::GetKeyboardLayoutList;
    let count = unsafe { GetKeyboardLayoutList(0, std::ptr::null_mut()) };
    let mut layouts = vec![std::ptr::null_mut(); count.max(0) as usize];
    let filled = unsafe { GetKeyboardLayoutList(count, layouts.as_mut_ptr()) };
    layouts.truncate(filled.max(0) as usize);
    layouts.into_iter().find_map(|layout| altgr_character_on(combo, layout))
}

#[cfg(windows)]
pub fn altgr_character_on(combo: KeyCombo, layout: windows_sys::Win32::UI::Input::KeyboardAndMouse::HKL) -> Option<String> {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{MapVirtualKeyExW, ToUnicodeEx, MAPVK_VK_TO_VSC};
    let key = combo.virtual_key()?;
    let mut state = [0u8; 256];
    // Control, Alt, and the two AltGr is made of: left Control and right Alt.
    for held in [0x11, 0x12, 0xA2, 0xA5] {
        state[held] = 0x80;
    }
    if combo.has(SHIFT) {
        state[0x10] = 0x80;
    }
    let mut text = [0u16; 8];
    let scan = unsafe { MapVirtualKeyExW(key, MAPVK_VK_TO_VSC, layout) };
    // Flag 4: the layout's own state (a pending dead key) is left as it is.
    let length = unsafe { ToUnicodeEx(key, scan, state.as_ptr(), text.as_mut_ptr(), text.len() as i32, 4, layout) };
    let length = if length < 0 { 1 } else { length as usize };
    let typed: String = String::from_utf16_lossy(&text[..length.min(text.len())]).chars().filter(|c| !c.is_control()).collect();
    (!typed.trim().is_empty()).then_some(typed)
}

#[cfg(not(windows))]
pub fn altgr_character(_combo: KeyCombo) -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn command(id: &str, title: &str, hot_key: Option<Value>) -> QuickCommand {
        QuickCommand { id: id.into(), hot_key, ..QuickCommand::new(title, "bolt", Kind::Script, "exit 0") }
    }

    fn mac(key_code: u32, modifiers: u32) -> Option<Value> {
        Some(json!({"keyCode": key_code, "modifiers": modifiers}))
    }

    #[test]
    fn the_table_has_each_key_once() {
        for (index, key) in KEYS.iter().enumerate() {
            for other in &KEYS[index + 1..] {
                assert!(key.0 != other.0 && key.1 != other.1 && key.3 != other.3, "{key:?} and {other:?}");
                assert!(key.2 == 0 || key.2 != other.2, "{key:?} and {other:?}");
            }
        }
    }

    #[test]
    fn mac_modifiers_map_one_to_one() {
        // ⌃⌥K, as the Mac writes it.
        let combo = KeyCombo::from_value(&json!({"keyCode": 40, "modifiers": 6144})).unwrap();
        assert_eq!((combo.title(), combo.accelerator().as_deref()), ("Ctrl+Alt+K".into(), Some("Ctrl+Alt+KeyK")));
        // ⌘⇧B is Win+Shift+B, not Ctrl+Shift+B: ⌃⇧B is another shortcut on the Mac.
        let command = KeyCombo::new(11, COMMAND | SHIFT);
        assert_eq!((command.title(), command.accelerator().as_deref()), ("Win+Shift+B".into(), Some("Super+Shift+KeyB")));
        assert_ne!(command, KeyCombo::new(11, CONTROL | SHIFT));
        assert_eq!(KeyCombo::new(123, COMMAND | CONTROL | OPTION | SHIFT).title(), "Win+Ctrl+Alt+Shift+←");
        assert_eq!(KeyCombo::new(122, 0).title(), "F1");
        // Caps Lock's bit, which the Mac leaves out too.
        assert_eq!(KeyCombo::from_value(&json!({"keyCode": 40, "modifiers": 6144 | 0x0400})), Some(combo));
        assert_eq!(KeyCombo::from_value(&json!({"keyCode": "K"})), None);
    }

    #[test]
    fn a_press_becomes_the_macs_key_code_and_back() {
        // What the recorder sends: the virtual key, the key's name, Ctrl, Alt, Shift, Win.
        assert_eq!(KeyCombo::from_press(0x4B, "KeyK", true, true, false, false), Some(KeyCombo::new(40, CONTROL | OPTION)));
        assert_eq!(KeyCombo::from_press(0x70, "F1", false, false, false, false), Some(KeyCombo::new(122, 0)));
        assert_eq!(KeyCombo::from_press(0xBD, "Minus", false, true, true, true), Some(KeyCombo::new(27, OPTION | SHIFT | COMMAND)));
        // AZERTY: the key in Q's place types «a» and is the virtual key A, which is what Windows registers.
        assert_eq!(KeyCombo::from_press(0x41, "KeyQ", true, false, false, false).map(KeyCombo::title).as_deref(), Some("Ctrl+A"));
        // No virtual key (another system's web view): the name alone.
        assert_eq!(KeyCombo::from_press(0, "ArrowUp", true, false, false, false), Some(KeyCombo::new(126, CONTROL)));
        assert_eq!(KeyCombo::from_press(0x0D, "NumpadEnter", true, false, false, false), Some(KeyCombo::new(76, CONTROL)));
        assert_eq!(KeyCombo::from_press(0x2C, "PrintScreen", true, false, false, false), None, "no such key on a Mac");
        // Every key of the table: Mac → here → Mac.
        for key in KEYS {
            for modifiers in [0, CONTROL, CONTROL | OPTION, COMMAND | SHIFT, KNOWN] {
                let combo = KeyCombo::new(key.0, modifiers);
                let back = KeyCombo::from_press(key.2, key.1, combo.has(CONTROL), combo.has(OPTION), combo.has(SHIFT), combo.has(COMMAND));
                assert_eq!(back, Some(combo), "{}", combo.title());
                assert!(combo.accelerator().is_some_and(|a| a.ends_with(key.1)));
            }
        }
    }

    #[test]
    fn which_combinations_may_be_recorded() {
        assert!(KeyCombo::new(40, CONTROL).is_valid() && KeyCombo::new(40, OPTION).is_valid() && KeyCombo::new(40, COMMAND).is_valid());
        assert!(!KeyCombo::new(40, 0).is_valid(), "a bare letter");
        assert!(!KeyCombo::new(40, SHIFT).is_valid(), "Shift alone would take the capital letter");
        assert!(KeyCombo::new(122, 0).is_valid() && KeyCombo::new(90, SHIFT).is_valid(), "an F key alone");
        assert!(!KeyCombo::new(3, 0).is_valid(), "the letter F is not an F key");
        assert!(!KeyCombo::new(ESCAPE, CONTROL | OPTION).is_valid(), "Esc cancels");
    }

    #[test]
    fn who_gets_a_combination() {
        let quick_prompt = (KeyCombo::new(35, CONTROL | OPTION), "Быстрый запрос".to_owned());
        let commands = [
            command("a", "Сборка", mac(40, CONTROL | OPTION)),
            command("b", "Тесты", mac(40, CONTROL | OPTION)),
            command("c", "Запрос", mac(35, CONTROL | OPTION)),
            command("d", "Без клавиш", None),
            command("e", "Одна буква", mac(40, SHIFT)),
            command("f", "С Mac", mac(10, COMMAND)),
            QuickCommand { kind: Kind::Shortcut, ..command("g", "Ярлык", mac(0, CONTROL)) },
            command("h", "Другое", mac(40, CONTROL | OPTION | SHIFT)),
        ];
        let plan = plan(&commands, &[quick_prompt]);
        assert_eq!(plan.keys.iter().map(|k| k.command.as_str()).collect::<Vec<_>>(), ["a", "h"]);
        assert_eq!(plan.problems.get("b"), Some(&Problem::Command("Сборка".into())));
        assert_eq!(plan.problems.get("c"), Some(&Problem::App("Быстрый запрос".into())));
        assert_eq!(plan.problems.get("f"), Some(&Problem::NotHere), "the ISO key next to Z");
        assert_eq!(plan.problems.len(), 3, "nothing said about a command with no keys, an invalid one or a Mac shortcut");
        assert!(plan.problems.values().all(Problem::blocks));
        // «Быстрый запрос» off: its key is free again.
        assert_eq!(super::plan(&commands, &[]).keys.len(), 3);
        let s = Strings::from_json("{}");
        assert_eq!(Problem::Command("Сборка".into()).text(&s), "Уже у команды «Сборка» — сработает только у неё.");
    }

    #[test]
    fn what_a_registered_combination_costs() {
        let polish = |combo: KeyCombo| (combo.key_code == 0).then(|| "ą".to_owned());
        assert_eq!(warning(KeyCombo::new(0, CONTROL | OPTION), polish), Some(Problem::AltGr("ą".into())));
        assert_eq!(warning(KeyCombo::new(40, CONTROL | OPTION), polish), None, "AltGr+K types nothing there");
        assert_eq!(warning(KeyCombo::new(0, CONTROL | OPTION | COMMAND), polish), None, "with Win it isn't AltGr");
        assert_eq!(warning(KeyCombo::new(8, CONTROL), polish), Some(Problem::AppShortcut), "Ctrl+C");
        assert_eq!(warning(KeyCombo::new(118, OPTION), polish), Some(Problem::AppShortcut), "Alt+F4");
        assert_eq!(warning(KeyCombo::new(8, CONTROL | SHIFT), polish), Some(Problem::AppShortcut));
        assert_eq!(warning(KeyCombo::new(8, COMMAND | SHIFT), polish), None);
        assert_eq!(warning(KeyCombo::new(122, 0), polish), None, "an F key alone");
        assert!(!Problem::AltGr("ą".into()).blocks() && !Problem::AppShortcut.blocks() && Problem::Taken.blocks());
    }

    #[test]
    fn a_library_from_a_mac_goes_back_as_it_came() {
        // ⌘⇧B, a key this table doesn't know (JIS «英数», 102) and bits it doesn't know either.
        let file = json!([
            {"id": "a", "title": "Сборка", "symbol": "hammer", "kind": "script", "value": "make", "confirm": true, "hotKey": {"keyCode": 11, "modifiers": 768}},
            {"id": "b", "title": "Япония", "symbol": "bolt", "kind": "open", "value": "~/x", "confirm": false, "hotKey": {"keyCode": 102, "modifiers": 4096}},
            {"id": "c", "title": "Биты", "symbol": "bolt", "kind": "open", "value": "~/y", "confirm": false, "hotKey": {"keyCode": 40, "modifiers": 7168}}
        ]);
        let library = crate::quick_commands::library(Some(&file)).unwrap();
        assert_eq!(library[0].combo().map(KeyCombo::title).as_deref(), Some("Win+Shift+B"));
        assert_eq!(library[1].combo().and_then(KeyCombo::accelerator), None);
        assert_eq!(library[1].combo().map(KeyCombo::title).as_deref(), Some("Ctrl+#102"));
        assert_eq!(library[2].combo(), Some(KeyCombo::new(40, CONTROL | OPTION)));
        assert_eq!(serde_json::to_value(&library).unwrap(), file);
        // Recorded here, read there: the Mac's own two fields and nothing else.
        let recorded = KeyCombo::from_press(0x4B, "KeyK", true, true, false, false).unwrap();
        assert_eq!(serde_json::to_value(recorded).unwrap(), json!({"keyCode": 40, "modifiers": 6144}));
    }

    /// Ctrl+Alt+A on a Polish keyboard is «ą», Ctrl+Alt+Q on a German one «@». Loads the two layouts for a moment
    /// (they are not added to the language bar) — run by hand: `cargo test -p claudepult-core altgr -- --ignored`.
    #[cfg(windows)]
    #[test]
    #[ignore = "loads keyboard layouts"]
    fn altgr_on_polish_and_german_layouts() {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetKeyboardLayoutList, LoadKeyboardLayoutW, UnloadKeyboardLayout, KLF_NOTELLSHELL};
        let installed = || {
            let mut layouts = vec![std::ptr::null_mut(); 64];
            let count = unsafe { GetKeyboardLayoutList(64, layouts.as_mut_ptr()) };
            layouts.truncate(count.max(0) as usize);
            layouts
        };
        let before = installed();
        let check = |name: &str, combo: KeyCombo, typed: Option<&str>| {
            let wide: Vec<u16> = name.encode_utf16().chain([0]).collect();
            let layout = unsafe { LoadKeyboardLayoutW(wide.as_ptr(), KLF_NOTELLSHELL) };
            assert!(!layout.is_null(), "{name} loads");
            let found = altgr_character_on(combo, layout);
            if !before.contains(&layout) {
                unsafe { UnloadKeyboardLayout(layout) };
            }
            assert_eq!(found.as_deref(), typed, "{name}: {}", combo.title());
        };
        check("00000415", KeyCombo::new(0, CONTROL | OPTION), Some("ą"));
        check("00000415", KeyCombo::new(0, CONTROL | OPTION | SHIFT), Some("Ą"));
        check("00000415", KeyCombo::new(40, CONTROL | OPTION), None);
        check("00000407", KeyCombo::new(12, CONTROL | OPTION), Some("@"));
        check("00000409", KeyCombo::new(0, CONTROL | OPTION), None);
        assert_eq!(installed().len(), before.len(), "the layouts of this computer are as they were");
    }
}
