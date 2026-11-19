//! «Быстрый запрос» (docs/specs/SPEC-quick-prompt.md), the Mac's `QuickPrompt` and `QuickPromptHotKey`: a hot key in
//! any program opens a small window — the task, the project, the agent — and the task goes to the background or a
//! terminal. The project in front is guessed from the front window's title (Windows gives it without asking); else
//! the last one, else the most recently active.

use chrono::{DateTime, Utc};

/// The Mac's choices, with Ctrl for ⌃ and Alt for ⌥. Ctrl+Alt is AltGr on many layouts: Ctrl+Alt+A takes «ą» from
/// Polish keyboards, so it is only one of the choices.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HotKey {
    Off,
    ControlOptionP,
    ControlOptionA,
    ControlShiftSpace,
}

pub const HOT_KEYS: [HotKey; 4] = [HotKey::Off, HotKey::ControlOptionP, HotKey::ControlOptionA, HotKey::ControlShiftSpace];

impl HotKey {
    /// The Mac's `QuickPromptHotKey` raw value, kept in `settings.json`.
    pub fn id(self) -> &'static str {
        match self {
            HotKey::Off => "off",
            HotKey::ControlOptionP => "controlOptionP",
            HotKey::ControlOptionA => "controlOptionA",
            HotKey::ControlShiftSpace => "controlShiftSpace",
        }
    }

    pub fn parse(id: &str) -> Option<HotKey> {
        HOT_KEYS.into_iter().find(|k| k.id() == id)
    }

    /// As the global shortcut plugin reads it; None — off.
    pub fn accelerator(self) -> Option<&'static str> {
        match self {
            HotKey::Off => None,
            HotKey::ControlOptionP => Some("Ctrl+Alt+P"),
            HotKey::ControlOptionA => Some("Ctrl+Alt+A"),
            HotKey::ControlShiftSpace => Some("Ctrl+Shift+Space"),
        }
    }
}

/// Ctrl+Alt+P, as on the Mac (⌃⌥P).
pub const DEFAULT_HOT_KEY: HotKey = HotKey::ControlOptionP;

#[derive(Debug, Clone, PartialEq)]
pub struct Candidate {
    pub name: String,
    pub path: String,
    pub last_activity: Option<DateTime<Utc>>,
}

/// The project chosen when the window opens: the one in front, the last one, the most recently active one.
pub fn default_project(projects: &[Candidate], front_title: Option<&str>, last: Option<&str>) -> Option<String> {
    if let Some(path) = front_title.and_then(|title| front_project(projects, title)) {
        return Some(path);
    }
    if let Some(last) = last.filter(|l| projects.iter().any(|p| p.path == *l)) {
        return Some(last.to_owned());
    }
    projects.iter().filter(|p| p.last_activity.is_some()).max_by_key(|p| p.last_activity).or(projects.first()).map(|p| p.path.clone())
}

/// A project's name in the front window's title as a whole word; the longest name wins («Cantero-l5» before «Cantero»).
pub fn front_project(projects: &[Candidate], title: &str) -> Option<String> {
    projects.iter().filter(|p| !p.name.is_empty() && contains_word(&p.name, title)).max_by_key(|p| p.name.chars().count()).map(|p| p.path.clone())
}

fn is_name_part(c: Option<char>) -> bool {
    c.is_some_and(|c| c.is_alphanumeric() || c == '-' || c == '_')
}

/// `name` in `text` with no letter, digit, «-» or «_» right before or after it, ignoring case.
pub fn contains_word(name: &str, text: &str) -> bool {
    let name: Vec<char> = name.to_lowercase().chars().collect();
    let text: Vec<char> = text.to_lowercase().chars().collect();
    if name.is_empty() || name.len() > text.len() {
        return false;
    }
    (0..=text.len() - name.len()).any(|at| {
        text[at..at + name.len()] == name[..] && !is_name_part(at.checked_sub(1).map(|i| text[i])) && !is_name_part(text.get(at + name.len()).copied())
    })
}

/// Claude Code and Codex run in the background (`claude -p`, `codex exec`); the others open in a terminal until their
/// unattended modes are checked live.
pub fn modes(agent: &str) -> &'static [&'static str] {
    if agent == "claude-code" || agent == "codex" { &["background", "terminal"] } else { &["terminal"] }
}

/// The mode the window starts with for an agent: the last one if the agent can, else the profile's, else the first.
pub fn mode(agent: &str, last: Option<&str>, preferred: Option<&str>) -> &'static str {
    let allowed = modes(agent);
    [last, preferred].into_iter().flatten().find_map(|m| allowed.iter().find(|a| **a == m).copied()).unwrap_or(allowed[0])
}

pub fn can_send(text: &str, project: Option<&str>) -> bool {
    project.is_some() && !text.trim().is_empty()
}

/// The front window's title, read when the hot key is pressed (before this app's window comes up).
#[cfg(windows)]
pub fn front_title() -> Option<String> {
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowTextW};
    let mut buffer = [0u16; 512];
    let length = unsafe { GetWindowTextW(GetForegroundWindow(), buffer.as_mut_ptr(), buffer.len() as i32) };
    (length > 0).then(|| String::from_utf16_lossy(&buffer[..length as usize]))
}

#[cfg(not(windows))]
pub fn front_title() -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(name: &str, days_ago: Option<i64>) -> Candidate {
        Candidate { name: name.into(), path: format!("C:/P/{name}"), last_activity: days_ago.map(|d| Utc::now() - chrono::Duration::days(d)) }
    }

    #[test]
    fn the_project_in_front() {
        let projects = [candidate("Cantero", Some(3)), candidate("Cantero-l5", Some(5)), candidate("Shop", Some(1))];
        assert_eq!(front_project(&projects, "main.rs - Cantero-l5 - Visual Studio Code").as_deref(), Some("C:/P/Cantero-l5"), "the longest name wins");
        assert_eq!(front_project(&projects, "cantero — README"), Some("C:/P/Cantero".into()), "ignoring case");
        assert_eq!(front_project(&projects, "Shopping list"), None, "a whole word only");
        assert_eq!(default_project(&projects, Some("Notepad"), Some("C:/P/Cantero")).as_deref(), Some("C:/P/Cantero"), "the last one");
        assert_eq!(default_project(&projects, None, Some("C:/gone")).as_deref(), Some("C:/P/Shop"), "the most recently active");
        assert_eq!(default_project(&[], None, None), None);
        assert!(contains_word("Shop", "Shop") && contains_word("Shop", "(Shop)") && !contains_word("Shop", "Shop_2"));
    }

    #[test]
    fn agents_modes_and_keys() {
        assert_eq!(modes("codex"), ["background", "terminal"]);
        assert_eq!(modes("gemini"), ["terminal"]);
        assert_eq!(mode("gemini", Some("background"), None), "terminal");
        assert_eq!(mode("claude-code", None, Some("terminal")), "terminal");
        assert_eq!(mode("claude-code", Some("background"), Some("terminal")), "background", "the last one first");
        assert_eq!(mode("codex", None, None), "background");
        assert!(can_send(" x ", Some("p")) && !can_send("  ", Some("p")) && !can_send("x", None));
        assert_eq!(HotKey::parse("controlShiftSpace").and_then(HotKey::accelerator), Some("Ctrl+Shift+Space"));
        assert_eq!(HotKey::Off.accelerator(), None);
        assert_eq!(DEFAULT_HOT_KEY.id(), "controlOptionP");
    }
}
