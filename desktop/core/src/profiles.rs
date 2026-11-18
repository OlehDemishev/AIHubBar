//! Profiles (docs/specs/SPEC-profiles.md, docs/specs/SPEC-windows.md §6, §9 stage 5): the Mac's `Profile` as it is
//! written in its JSON, so a `.claudepult` file moves between the Mac and Windows. This version reads what it uses —
//! the name, the projects source, the launch mode — and keeps every other field (modules, menu bar, card, commands…)
//! untouched for the way back. Paths are written with `~` for the home folder and `/` between parts.

use serde::Serialize;
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    pub id: String,
    pub name: String,
    /// An SF Symbol name on the Mac; kept, not shown here.
    pub icon: String,
    /// The template it started from (`developer`, `video`, …), `custom` for a hand-made one.
    pub template: String,
    /// The Mac's `ProjectSource` as written: `{"gitBuiltin": {"projects": "~/Projects"}}`, `{"folders": {"_0": …}}`…
    pub source: Value,
    /// `terminal` or `background`; None — ask each time.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub launch_mode: Option<String>,
    /// Everything this version doesn't use yet, written back as it came.
    #[serde(flatten)]
    pub other: Map<String, Value>,
}

/// Where a profile's projects come from (the Mac's `ProjectSource`).
#[derive(Debug, Clone, PartialEq)]
pub enum Source {
    /// Git repositories listed by `_daily-report/report.py` on the Mac; scanned by the app itself here.
    GitReport(String),
    GitBuiltin(String),
    /// Every subfolder is a project — not in this version yet.
    Folders(String),
    Inbox(String),
    None,
}

impl Source {
    pub fn parse(value: &Value) -> Source {
        let Some((kind, body)) = value.as_object().and_then(|o| o.iter().next()) else { return Source::None };
        let text = |key: &str| body.get(key).and_then(Value::as_str).map(str::to_owned);
        match (kind.as_str(), text("projects"), text("_0")) {
            ("gitReport", Some(projects), _) => Source::GitReport(projects),
            ("gitBuiltin", Some(projects), _) => Source::GitBuiltin(projects),
            ("folders", _, Some(path)) => Source::Folders(path),
            ("inbox", _, Some(path)) => Source::Inbox(path),
            _ => Source::None,
        }
    }

    /// The folder of git projects, `~`-form.
    pub fn git_folder(&self) -> Option<&str> {
        match self {
            Source::GitReport(path) | Source::GitBuiltin(path) => Some(path),
            _ => None,
        }
    }
}

impl Profile {
    /// Tolerant like the Mac's decoder: missing or broken fields take their defaults; None only for a non-object.
    pub fn from_value(value: &Value) -> Option<Profile> {
        let mut other = value.as_object()?.clone();
        let mut text = |key: &str| other.remove(key).and_then(|v| v.as_str().map(str::to_owned));
        let id = text("id").filter(|id| !id.is_empty()).unwrap_or_else(crate::runs::new_id);
        let name = text("name").unwrap_or_else(|| "Профиль".to_owned());
        let icon = text("icon").unwrap_or_else(|| "sparkle".to_owned());
        let template = text("template").unwrap_or_else(|| "custom".to_owned());
        let launch_mode = text("launchMode").filter(|m| crate::settings::LAUNCH_MODES.contains(&m.as_str()));
        let source = other.remove("source").unwrap_or(Value::Null);
        Some(Profile { id, name, icon, template, source, launch_mode, other })
    }

    pub fn source(&self) -> Source {
        Source::parse(&self.source)
    }

    /// The git projects folder, expanded; None for a profile without git projects.
    pub fn projects_dir(&self, home: &Path) -> Option<PathBuf> {
        self.source().git_folder().map(|folder| expand(folder, home))
    }

    /// A new projects folder (`~`-form) for a git profile; others are left alone. True when it changed.
    pub fn set_git_folder(&mut self, folder: &str) -> bool {
        let kind = match self.source() {
            Source::GitReport(_) => "gitReport",
            Source::GitBuiltin(_) => "gitBuiltin",
            _ => return false,
        };
        let Some(body) = self.source.get_mut(kind).and_then(Value::as_object_mut) else { return false };
        let changed = body.get("projects").and_then(Value::as_str) != Some(folder);
        body.insert("projects".to_owned(), json!(folder));
        changed
    }
}

// MARK: - Templates

fn templates() -> &'static Value {
    static TABLE: OnceLock<Value> = OnceLock::new();
    TABLE.get_or_init(|| serde_json::from_str(include_str!("../../ui/i18n/templates.json")).unwrap_or_default())
}

/// A new profile from a Mac template (`ui/i18n/templates.json`) in the content language, English when it has none.
pub fn from_template(template: &str, language: &str) -> Option<Profile> {
    let modes = templates().get(template)?;
    let mode = modes.get(language).or_else(|| modes.get("en"))?;
    let mut profile = Profile::from_value(mode)?;
    profile.id = crate::runs::new_id();
    Some(profile)
}

/// `name`, or `name 2`, `name 3`… when another profile already has it (the Mac's `uniqueName`).
pub fn unique_name(base: &str, taken: &[&str]) -> String {
    let mut name = base.to_owned();
    let mut counter = 2;
    while taken.contains(&name.as_str()) {
        name = format!("{base} {counter}");
        counter += 1;
    }
    name
}

// MARK: - Paths in files

/// `~/…` for a path inside the home folder, `/` between parts, so the file reads on the Mac and Windows alike.
pub fn tilde(path: &Path, home: &Path) -> String {
    match path.strip_prefix(home) {
        Ok(rest) => std::iter::once("~".to_owned())
            .chain(rest.components().map(|c| c.as_os_str().to_string_lossy().into_owned()))
            .collect::<Vec<_>>()
            .join("/"),
        Err(_) => path.to_string_lossy().replace('\\', "/"),
    }
}

/// The path for this system: `~` is the home folder, `/` the system's separator.
pub fn expand(text: &str, home: &Path) -> PathBuf {
    let rest = if text == "~" { Some("") } else { text.strip_prefix("~/").or_else(|| text.strip_prefix("~\\")) };
    match rest {
        Some(rest) => rest.split(['/', '\\']).filter(|part| !part.is_empty()).fold(home.to_path_buf(), |path, part| path.join(part)),
        None if cfg!(windows) => PathBuf::from(text.replace('/', "\\")),
        None => PathBuf::from(text),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mac_profile_round_trip() {
        // A profile file as the Mac writes it: the fields this version doesn't know come back unchanged.
        let mac = json!({
            "id": "aae3b197", "name": "Developer", "icon": "chevron.left.forwardslash.chevron.right", "template": "developer-report",
            "source": {"gitReport": {"dailyReport": "~/Projects/_daily-report", "projects": "~/Projects"}},
            "card": "statusMD", "metrics": ["branch", "dirty"], "modules": [{"kind": "projects"}], "menuBar": {"items": []},
            "wordsPerMinute": 150
        });
        let profile = Profile::from_value(&mac).unwrap();
        assert_eq!(profile.source(), Source::GitReport("~/Projects".into()));
        assert_eq!(profile.launch_mode, None);
        assert_eq!(serde_json::to_value(&profile).unwrap(), mac);
    }

    #[test]
    fn tolerant_reading() {
        assert!(Profile::from_value(&json!("text")).is_none());
        let profile = Profile::from_value(&json!({"name": 5, "launchMode": "window", "source": null})).unwrap();
        assert_eq!((profile.name.as_str(), profile.template.as_str(), profile.launch_mode.as_deref()), ("Профиль", "custom", None));
        assert!(!profile.id.is_empty());
        assert_eq!(profile.source(), Source::None);
        let folders = Profile::from_value(&json!({"source": {"folders": {"_0": "~/Documents/Видео"}}, "launchMode": "background"})).unwrap();
        assert_eq!(folders.source(), Source::Folders("~/Documents/Видео".into()));
        assert_eq!(folders.launch_mode.as_deref(), Some("background"));
        assert_eq!(folders.source().git_folder(), None);
    }

    #[test]
    fn git_folder_changes_in_place() {
        let mut profile = Profile::from_value(&json!({"source": {"gitReport": {"dailyReport": "~/r", "projects": "~/Projects"}}})).unwrap();
        assert!(profile.set_git_folder("D:/Работа"));
        assert!(!profile.set_git_folder("D:/Работа"));
        assert_eq!(profile.source, json!({"gitReport": {"dailyReport": "~/r", "projects": "D:/Работа"}}));
        let mut none = Profile::from_value(&json!({})).unwrap();
        assert!(!none.set_git_folder("~/x"));
    }

    #[test]
    fn templates_in_languages() {
        let ru = from_template("developer", "ru").unwrap();
        assert_eq!(ru.name, "Разработчик (GitHub)");
        assert_eq!(ru.source(), Source::GitBuiltin("~/Projects".into()));
        assert_eq!(ru.template, "developer");
        assert_eq!(from_template("developer", "en").unwrap().name, "Developer (GitHub)");
        assert_eq!(from_template("developer", "xx").unwrap().name, "Developer (GitHub)", "English when there is none");
        assert_ne!(from_template("developer", "ru").unwrap().id, from_template("developer", "ru").unwrap().id);
        assert!(from_template("video", "ru").is_none(), "folder projects come later");
    }

    #[test]
    fn names() {
        assert_eq!(unique_name("Dev", &[]), "Dev");
        assert_eq!(unique_name("Dev", &["Dev", "Dev 2"]), "Dev 3");
    }

    #[test]
    fn paths() {
        let home = PathBuf::from("/home/oleh");
        assert_eq!(tilde(&home.join("Projects").join("Мой"), &home), "~/Projects/Мой");
        assert_eq!(tilde(&home, &home), "~");
        assert_eq!(expand("~/Projects/Мой", &home), home.join("Projects").join("Мой"));
        assert_eq!(expand("~", &home), home);
        if cfg!(windows) {
            let home = PathBuf::from(r"C:\Users\Олег");
            assert_eq!(tilde(&home.join("Projects"), &home), "~/Projects");
            assert_eq!(tilde(Path::new(r"D:\Работа\Проекты"), &home), "D:/Работа/Проекты");
            assert_eq!(expand("D:/Работа/Проекты", &home), PathBuf::from(r"D:\Работа\Проекты"));
            assert_eq!(expand("~/Projects", &home), PathBuf::from(r"C:\Users\Олег\Projects"));
        } else {
            assert_eq!(tilde(Path::new("/srv/work"), &home), "/srv/work");
            assert_eq!(expand("/srv/work", &home), PathBuf::from("/srv/work"));
        }
    }
}
