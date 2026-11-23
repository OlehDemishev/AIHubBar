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

    /// The projects folder of any kind, `~`-form: git repositories, folders, or the inbox folder itself.
    pub fn folder(&self) -> Option<&str> {
        match self {
            Source::GitReport(path) | Source::GitBuiltin(path) | Source::Folders(path) | Source::Inbox(path) => Some(path),
            Source::None => None,
        }
    }

    pub fn is_folders(&self) -> bool {
        matches!(self, Source::Folders(_) | Source::Inbox(_))
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

    /// The projects folder of any kind, expanded; None for a profile without projects.
    pub fn projects_dir(&self, home: &Path) -> Option<PathBuf> {
        self.source().folder().map(|folder| expand(folder, home))
    }

    /// A new projects folder (`~`-form), kept in the source's own shape; a profile without projects is left alone.
    /// True when it changed.
    pub fn set_folder(&mut self, folder: &str) -> bool {
        let (kind, key) = match self.source() {
            Source::GitReport(_) => ("gitReport", "projects"),
            Source::GitBuiltin(_) => ("gitBuiltin", "projects"),
            Source::Folders(_) => ("folders", "_0"),
            Source::Inbox(_) => ("inbox", "_0"),
            Source::None => return false,
        };
        let Some(body) = self.source.get_mut(kind).and_then(Value::as_object_mut) else { return false };
        let changed = body.get(key).and_then(Value::as_str) != Some(folder);
        body.insert(key.to_owned(), json!(folder));
        changed
    }

    /// The folder projects' stages, in order, without blank ones.
    pub fn stages(&self) -> Vec<String> {
        self.strings("stages").into_iter().filter(|s| !s.trim().is_empty()).collect()
    }

    /// The metrics a folder project's row shows (`words`, `duration`, `deadline`…).
    pub fn metrics(&self) -> Vec<String> {
        self.strings("metrics")
    }

    /// Speech pace for «Хронометраж».
    pub fn words_per_minute(&self) -> u64 {
        self.other.get("wordsPerMinute").and_then(Value::as_u64).filter(|&n| n > 0).unwrap_or(150)
    }

    /// «Цель по словам»: words a day in the projects' main files; 0 — none (the Mac's `wordGoal`).
    pub fn word_goal(&self) -> usize {
        self.other.get("wordGoal").and_then(Value::as_u64).map_or(0, |n| n.min(20_000) as usize)
    }

    /// `off`, `dates` (the cards' deadlines and publications) or `contentPlan` (also `контент-план.md`).
    pub fn calendar(&self) -> &str {
        self.other.get("calendar").and_then(Value::as_str).filter(|c| ["off", "dates", "contentPlan"].contains(c)).unwrap_or("off")
    }

    pub fn set_calendar(&mut self, mode: &str) {
        if ["off", "dates", "contentPlan"].contains(&mode) {
            self.other.insert("calendar".into(), json!(mode));
        }
    }

    /// The stage that means the work is finished: the last one, when there are two or more.
    pub fn done_stage(&self) -> Option<String> {
        let stages = self.stages();
        if stages.len() > 1 { stages.last().cloned() } else { None }
    }

    /// What the profile's commands write from the main file: such files never become the main file themselves (the
    /// Mac's `Profile.resultPatterns`), plus «Своя задача»'s result.
    pub fn result_patterns(&self) -> Vec<String> {
        let commands = self.other.get("commands").and_then(Value::as_array).cloned().unwrap_or_default();
        commands
            .iter()
            .filter(|c| c.get("input").and_then(Value::as_str).is_none_or(|input| input == "mainFile"))
            .map(|c| c.get("output").and_then(Value::as_str).unwrap_or("результат-<время>.md").to_owned())
            .chain(std::iter::once("результат-<время>.md".to_owned()))
            .collect()
    }

    /// `code`, `filesOnly` or `filesAndWeb`: what Claude may do in the background.
    pub fn permissions(&self) -> &str {
        self.other.get("permissions").and_then(Value::as_str).filter(|p| PERMISSIONS.contains(p)).unwrap_or("filesOnly")
    }

    /// One field edited in Settings → «Профили» (the Mac's `ProfileDetail`), checked like the Mac's decoder would read
    /// it. Stages stay as typed, blank ones too (`stages()` skips them); metrics keep the Mac's order; a command keeps
    /// only the Mac's `CommandTemplate` keys. False for a field this page doesn't edit or a value that doesn't fit.
    pub fn set_field(&mut self, field: &str, value: &Value) -> bool {
        let checked = match field {
            "stages" => value.as_array().map(|list| json!(list.iter().map(|s| s.as_str().unwrap_or_default()).collect::<Vec<_>>())),
            "metrics" => value.as_array().map(|list| json!(METRICS.iter().filter(|m| list.iter().any(|v| v == **m)).collect::<Vec<_>>())),
            "wordsPerMinute" => value.as_u64().map(|n| json!(n.clamp(80, 250))),
            "wordGoal" => value.as_u64().map(|n| json!(n.min(20_000))),
            "permissions" => value.as_str().filter(|p| PERMISSIONS.contains(p)).map(|p| json!(p)),
            "service" => match value {
                Value::Null => {
                    self.other.remove("service");
                    return true;
                }
                Value::String(id) if crate::ai::Service::parse(id).is_some() => Some(json!(id)),
                _ => None,
            },
            "commands" => value.as_array().map(|list| Value::Array(list.iter().filter_map(command_value).collect())),
            _ => None,
        };
        let Some(checked) = checked else { return false };
        self.other.insert(field.to_owned(), checked);
        true
    }

    fn strings(&self, key: &str) -> Vec<String> {
        self.other.get(key).and_then(Value::as_array).map(|list| list.iter().filter_map(Value::as_str).map(str::to_owned).collect()).unwrap_or_default()
    }
}

/// The Mac's `FolderMetric` in its order.
pub const METRICS: [&str; 8] = ["words", "duration", "readingTime", "pages", "sources", "deadline", "publishDate", "lastActivity"];

/// The Mac's `PermissionProfile`.
pub const PERMISSIONS: [&str; 3] = ["code", "filesOnly", "filesAndWeb"];

/// A command as the Mac's `CommandTemplate` writes it: a blank «Спросить» and «Сервис профиля» are left out.
fn command_value(value: &Value) -> Option<Value> {
    let object = value.as_object()?;
    let text = |key: &str| object.get(key).and_then(Value::as_str).unwrap_or_default();
    let id = Some(text("id")).filter(|id| !id.is_empty()).map(str::to_owned).unwrap_or_else(crate::runs::new_id);
    let mut command = json!({
        "id": id,
        "title": text("title"),
        "task": text("task"),
        "output": text("output"),
        "input": if text("input") == "project" { "project" } else { "mainFile" },
    });
    let asks = text("asks").trim();
    if !asks.is_empty() {
        command["asks"] = json!(asks);
    }
    let service = text("service");
    if crate::ai::Service::parse(service).is_some() {
        command["service"] = json!(service);
    }
    Some(command)
}

// MARK: - Templates

fn templates() -> &'static Value {
    static TABLE: OnceLock<Value> = OnceLock::new();
    TABLE.get_or_init(|| serde_json::from_str(include_str!("../../ui/i18n/templates.json")).unwrap_or_default())
}

/// The Mac's template ids in the assistant's order.
pub const TEMPLATE_IDS: [&str; 6] = ["developer", "video", "texts", "research", "social", "custom"];

fn template_entry(template: &str, language: &str) -> Option<&'static Value> {
    let modes = templates().get(template)?;
    modes.get(language).or_else(|| modes.get("en"))
}

/// A new profile from a Mac template (`ui/i18n/templates.json`) in the content language, English when it has none.
pub fn from_template(template: &str, language: &str) -> Option<Profile> {
    let mut profile = Profile::from_value(template_entry(template, language)?.get("mode")?)?;
    profile.id = crate::runs::new_id();
    Some(profile)
}

/// Every template's whole entry in the content language: `title`, `description`, `folderHint`, `mode`.
pub fn template_entries(language: &str) -> Vec<(&'static str, &'static Value)> {
    TEMPLATE_IDS.iter().filter_map(|id| Some((*id, template_entry(id, language)?))).collect()
}

/// (id, title) of every template, in the content language: «Разработчик (GitHub)», «Видео (YouTube, Shorts, Reels)»…
pub fn template_titles(language: &str) -> Vec<(&'static str, String)> {
    TEMPLATE_IDS
        .iter()
        .filter_map(|id| Some((*id, template_entry(id, language)?.get("title")?.as_str()?.to_owned())))
        .collect()
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

// MARK: - `.claudepult` files

/// The Mac's `SettingsBundle` formats: all settings and profiles, or one profile.
pub const SETTINGS_FORMAT: &str = "claudepult-settings";
pub const PROFILE_FORMAT: &str = "claudepult-mode";
pub const BUNDLE_VERSION: u64 = 2;
/// The Mac's settings this version has no place for (appearance, AI services, Telegram, modules…): kept from an
/// imported file and written back on export.
pub const MAC_KEYS: [&str; 5] = ["general", "appearance", "services", "installed", "off"];

/// A `.claudepult` file read and made safe.
#[derive(Debug, Clone, PartialEq)]
pub struct Bundle {
    pub format: String,
    pub profiles: Vec<Profile>,
    /// Which profiles the Mac shows in its switcher; ids of `profiles`.
    pub enabled: Option<Vec<String>>,
    pub current: Option<String>,
    /// `MAC_KEYS` as they were in the file.
    pub mac: Map<String, Value>,
}

impl Bundle {
    pub fn is_settings(&self) -> bool {
        self.format == SETTINGS_FORMAT
    }

    /// The file's background time limit, within what Settings allows here.
    pub fn time_limit_minutes(&self) -> Option<u32> {
        let minutes = self.mac.get("general")?.get("backgroundTimeLimitMinutes")?.as_u64()?;
        Some(u32::try_from(minutes.clamp(5, 24 * 60)).unwrap_or(90))
    }
}

/// None for anything but a `.claudepult` file with at least one profile. A file from someone else is not trusted, as
/// on the Mac (`ProfileStore.sanitized`): an id that isn't letters, digits and hyphens, or repeats, gets a fresh one.
pub fn read_bundle(text: &str) -> Option<Bundle> {
    let value: Value = serde_json::from_str(text.trim_start_matches('\u{feff}')).ok()?;
    let format = value.get("format")?.as_str()?.to_owned();
    if format != SETTINGS_FORMAT && format != PROFILE_FORMAT {
        return None;
    }
    let mut profiles: Vec<Profile> = value.get("modes")?.as_array()?.iter().filter_map(Profile::from_value).collect();
    if profiles.is_empty() {
        return None;
    }
    let safe = |id: &str| (1..=64).contains(&id.len()) && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
    let mut renamed = std::collections::HashMap::new();
    let mut seen = std::collections::HashSet::new();
    for profile in &mut profiles {
        let id = profile.id.clone();
        if !safe(&id) || !seen.insert(id.clone()) {
            let fresh = crate::runs::new_id();
            // A repeated id stays with the first profile that has it; «enabled» and «current» mean that one.
            if !safe(&id) {
                renamed.entry(id).or_insert_with(|| fresh.clone());
            }
            profile.id = fresh.clone();
            seen.insert(fresh);
        }
    }
    let rename = |id: &str| renamed.get(id).cloned().unwrap_or_else(|| id.to_owned());
    let ids = |key: &str| value.get(key).and_then(Value::as_array).map(|list| list.iter().filter_map(Value::as_str).map(rename).collect::<Vec<_>>());
    let enabled = ids("enabled");
    let current = value.get("current").and_then(Value::as_str).map(rename);
    let mac = MAC_KEYS.iter().filter_map(|key| value.get(*key).filter(|v| !v.is_null()).map(|v| ((*key).to_owned(), v.clone()))).collect();
    Some(Bundle { format, profiles, enabled, current, mac })
}

/// A file the Mac reads (`SettingsBundle`, version 2): `exportedAt` in whole seconds — the Mac's ISO 8601 decoder
/// refuses fractions — and keys sorted, as the Mac writes them.
pub fn write_bundle(format: &str, profiles: &[Profile], current: Option<&str>, mac: &Map<String, Value>, now: chrono::DateTime<chrono::Utc>) -> String {
    let mut file = Map::new();
    file.insert("format".into(), json!(format));
    file.insert("version".into(), json!(BUNDLE_VERSION));
    file.insert("exportedAt".into(), json!(now.format("%Y-%m-%dT%H:%M:%SZ").to_string()));
    file.insert("modes".into(), serde_json::to_value(profiles).unwrap_or_default());
    if format == SETTINGS_FORMAT {
        file.insert("enabled".into(), json!(profiles.iter().map(|p| &p.id).collect::<Vec<_>>()));
        if let Some(current) = current {
            file.insert("current".into(), json!(current));
        }
        for (key, value) in mac {
            file.insert(key.clone(), value.clone());
        }
    }
    serde_json::to_string_pretty(&sorted(Value::Object(file))).unwrap_or_default() + "\n"
}

/// Keys in order at every level, whether or not serde_json keeps insertion order in this build.
fn sorted(value: Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut entries: Vec<(String, Value)> = map.into_iter().collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            Value::Object(entries.into_iter().map(|(k, v)| (k, sorted(v))).collect())
        }
        Value::Array(list) => Value::Array(list.into_iter().map(sorted).collect()),
        other => other,
    }
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
    fn fields_edited_in_settings() {
        let mut profile = Profile::from_value(&json!({"name": "Видео", "source": {"folders": {"_0": "~/Видео"}}, "permissions": "code"})).unwrap();
        assert!(profile.set_field("stages", &json!(["идея", "", "готово"])));
        assert_eq!(profile.stages(), ["идея", "готово"]);
        assert_eq!(profile.other["stages"], json!(["идея", "", "готово"]), "a blank stage stays while typing");
        assert!(profile.set_field("metrics", &json!(["deadline", "words", "nonsense"])));
        assert_eq!(profile.metrics(), ["words", "deadline"]);
        assert!(profile.set_field("wordsPerMinute", &json!(400)));
        assert_eq!(profile.words_per_minute(), 250);
        assert!(!profile.set_field("permissions", &json!("everything")));
        assert!(profile.set_field("permissions", &json!("filesAndWeb")));
        assert_eq!(profile.permissions(), "filesAndWeb");
        assert!(profile.set_field("service", &json!("api:openai")));
        assert!(!profile.set_field("service", &json!("api:nowhere")));
        assert!(profile.set_field("service", &Value::Null));
        assert!(!profile.other.contains_key("service"));
        assert!(!profile.set_field("name", &json!("x")), "only this page's fields");

        let commands = json!([
            {"id": "a1", "title": "Хуки", "task": "Найди хуки в {файл}", "output": "хуки.md", "input": "mainFile", "asks": "  ", "service": null, "extra": 1},
            {"title": "Новая команда", "task": "", "output": "результат-<время>.md", "input": "project", "asks": "Тон", "service": "agent:codex"},
        ]);
        assert!(profile.set_field("commands", &commands));
        let saved = profile.other["commands"].as_array().unwrap();
        assert_eq!(saved[0], json!({"id": "a1", "title": "Хуки", "task": "Найди хуки в {файл}", "output": "хуки.md", "input": "mainFile"}));
        assert_eq!((saved[1]["input"].as_str(), saved[1]["asks"].as_str(), saved[1]["service"].as_str()), (Some("project"), Some("Тон"), Some("agent:codex")));
        assert!(!saved[1]["id"].as_str().unwrap().is_empty(), "a new command gets an id");
        assert_eq!(crate::commands::of_profile(&profile).len(), 2);
    }

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
        assert!(profile.set_folder("D:/Работа"));
        assert!(!profile.set_folder("D:/Работа"));
        assert_eq!(profile.source, json!({"gitReport": {"dailyReport": "~/r", "projects": "D:/Работа"}}));
        let mut folders = Profile::from_value(&json!({"source": {"folders": {"_0": "~/Documents/Видео"}}})).unwrap();
        assert!(folders.set_folder("~/Видео"));
        assert_eq!(folders.source, json!({"folders": {"_0": "~/Видео"}}));
        let mut none = Profile::from_value(&json!({})).unwrap();
        assert!(!none.set_folder("~/x"));
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
        let video = from_template("video", "ru").unwrap();
        assert_eq!(video.source(), Source::Folders("~/Documents/Видео".into()));
        assert!(video.source().is_folders());
        assert_eq!(video.stages().first().map(String::as_str), Some("идея"));
        assert_eq!(video.done_stage().as_deref(), Some("опубликовано"));
        assert_eq!(video.metrics(), ["words", "duration", "deadline", "publishDate"]);
        assert_eq!(video.words_per_minute(), 150);
        assert!(video.result_patterns().len() > 1 && video.result_patterns().contains(&"результат-<время>.md".to_owned()));
        let titles = template_titles("ru");
        assert_eq!(titles.len(), 6);
        assert_eq!(titles[1], ("video", "Видео (YouTube, Shorts, Reels)".to_owned()));
        assert!(from_template("utilities", "ru").is_none(), "Mac-only modules, no projects");
    }

    #[test]
    fn mac_bundle_read_and_written_back() {
        // A settings file as the Mac exports it (keys sorted, appearance and Telegram settings this version can't use).
        let mac = r#"{
  "appearance" : { "animations" : true, "density" : "normal", "menuBar" : "session", "showLimits" : true, "showSessions" : true, "textSize" : "normal", "theme" : "system", "width" : "normal" },
  "current" : "b-2",
  "enabled" : [ "../evil", "b-2" ],
  "exportedAt" : "2026-11-17T10:00:00Z",
  "format" : "claudepult-settings",
  "general" : { "backgroundTimeLimitMinutes" : 2000, "limitAlertsToTelegram" : false, "limitThresholds" : [ 80, 95 ], "telegramForBackground" : true },
  "installed" : [ "limits", "projects" ],
  "modes" : [
    { "id" : "../evil", "name" : "Dev", "source" : { "gitBuiltin" : { "projects" : "~/Projects" } }, "modules" : [ { "kind" : "projects" } ] },
    { "id" : "b-2", "name" : "Видео", "source" : { "folders" : { "_0" : "~/Documents/Видео" } }, "launchMode" : "terminal" },
    { "id" : "b-2", "name" : "Копия" }
  ],
  "version" : 2
}"#;
        let bundle = read_bundle(mac).unwrap();
        assert!(bundle.is_settings());
        assert_eq!(bundle.profiles.len(), 3);
        let ids: Vec<&str> = bundle.profiles.iter().map(|p| p.id.as_str()).collect();
        assert_ne!(ids[0], "../evil", "an unsafe id is replaced");
        assert_eq!(ids[1], "b-2");
        assert_ne!(ids[2], "b-2", "a repeated id is replaced, the first keeps it");
        assert_eq!(bundle.enabled.as_deref().unwrap()[0], ids[0], "«enabled» follows the new id");
        assert_eq!(bundle.current.as_deref(), Some("b-2"));
        assert_eq!(bundle.time_limit_minutes(), Some(1440));
        assert_eq!(bundle.mac.keys().collect::<Vec<_>>(), ["appearance", "general", "installed"]);

        let now = chrono::DateTime::parse_from_rfc3339("2026-11-18T12:34:56.789Z").unwrap().with_timezone(&chrono::Utc);
        let written = write_bundle(SETTINGS_FORMAT, &bundle.profiles, Some("b-2"), &bundle.mac, now);
        let value: Value = serde_json::from_str(&written).unwrap();
        assert_eq!(value["exportedAt"], "2026-11-18T12:34:56Z", "whole seconds for the Mac");
        assert_eq!(value["version"], 2);
        assert_eq!(value["general"]["limitThresholds"], json!([80, 95]), "the Mac's settings go back");
        assert_eq!(value["modes"][0]["modules"], json!([{"kind": "projects"}]));
        assert_eq!(value["enabled"].as_array().unwrap().len(), 3);
        let keys: Vec<&str> = value.as_object().unwrap().keys().map(String::as_str).collect();
        let mut sorted_keys = keys.clone();
        sorted_keys.sort_unstable();
        assert_eq!(keys, sorted_keys);
        assert_eq!(read_bundle(&written).unwrap().profiles, bundle.profiles, "its own file reads back the same");
    }

    #[test]
    fn profile_file_and_refusals() {
        let profile = from_template("developer", "en").unwrap();
        let written = write_bundle(PROFILE_FORMAT, std::slice::from_ref(&profile), Some(&profile.id), &Map::new(), chrono::Utc::now());
        let value: Value = serde_json::from_str(&written).unwrap();
        assert_eq!(value["format"], PROFILE_FORMAT);
        assert!(value.get("current").is_none() && value.get("enabled").is_none(), "one profile, no settings");
        let back = read_bundle(&format!("\u{feff}{written}")).unwrap();
        assert!(!back.is_settings());
        assert_eq!(back.profiles, vec![profile]);

        assert!(read_bundle("garbage").is_none());
        assert!(read_bundle(r#"{"format": "something-else", "modes": [{}]}"#).is_none());
        assert!(read_bundle(r#"{"format": "claudepult-settings", "modes": []}"#).is_none());
        assert!(read_bundle(r#"{"format": "claudepult-settings", "modes": [3]}"#).is_none());
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
