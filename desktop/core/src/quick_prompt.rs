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

    /// The same key as a command's shortcut would name it, so a command can't take it.
    pub fn combo(self) -> Option<crate::hot_keys::KeyCombo> {
        use crate::hot_keys::{KeyCombo, CONTROL, OPTION, SHIFT};
        match self {
            HotKey::Off => None,
            HotKey::ControlOptionP => Some(KeyCombo::new(35, CONTROL | OPTION)),
            HotKey::ControlOptionA => Some(KeyCombo::new(0, CONTROL | OPTION)),
            HotKey::ControlShiftSpace => Some(KeyCombo::new(49, CONTROL | SHIFT)),
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

/// How many files one request takes.
pub const MAX_FILES: usize = 8;

/// Files dropped on the window, joined to the ones already there: existing files only, each once, at most
/// `MAX_FILES` (the Mac's `QuickPrompt.adding`).
pub fn adding_files(dropped: &[String], files: &[String]) -> Vec<String> {
    let mut result: Vec<String> = files.to_vec();
    for path in dropped {
        if std::path::Path::new(path).is_file() && !result.iter().any(|known| known.eq_ignore_ascii_case(path)) {
            result.push(path.clone());
        }
    }
    result.truncate(MAX_FILES);
    result
}

/// The task with its files: their paths after the text, one per line, for the agent to open. The heading is English
/// on purpose — it is read by the agent, in whatever language the task is (the Mac's `QuickPrompt.task`).
pub fn task_with_files(text: &str, files: &[String]) -> String {
    if files.is_empty() {
        return text.to_owned();
    }
    format!("{}\n\nFiles:\n{}", text.trim(), files.join("\n"))
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
        let dir = std::env::temp_dir().join(format!("claudepult-qp-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = |name: &str| {
            let path = dir.join(name);
            std::fs::write(&path, "x").unwrap();
            path.to_string_lossy().into_owned()
        };
        let (a, b) = (file("a.png"), file("b.txt"));
        let folder = dir.to_string_lossy().into_owned();
        let files = adding_files(&[a.clone(), folder, a.clone(), "C:/nowhere/x.txt".into()], &[]);
        assert_eq!(files, [a.clone()], "files only, each once, existing");
        let many: Vec<String> = (0..12).map(|i| file(&format!("f{i}.txt"))).collect();
        assert_eq!(adding_files(&many, &[b.clone()]).len(), MAX_FILES);
        assert_eq!(task_with_files("  Fix it \n", &[a.clone(), b.clone()]), format!("Fix it\n\nFiles:\n{a}\n{b}"));
        assert_eq!(task_with_files("Fix it", &[]), "Fix it");
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(HotKey::parse("controlShiftSpace").and_then(HotKey::accelerator), Some("Ctrl+Shift+Space"));
        assert_eq!(HotKey::Off.accelerator(), None);
        for key in HOT_KEYS {
            assert_eq!(key.combo().map(|c| c.title()).as_deref(), key.accelerator(), "one key under both names");
        }
        assert_eq!(DEFAULT_HOT_KEY.id(), "controlOptionP");
    }
}
