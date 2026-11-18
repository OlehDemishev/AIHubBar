//! `settings.json` (docs/specs/SPEC-windows.md §6). Reading is tolerant like the Mac's `NotchSettings`: unknown keys from
//! newer versions are ignored, missing or broken ones take their defaults, so a file never stops the app.
//!
//! Profiles live here too (§6), in the Mac's own JSON (`profiles.rs`). The projects folder and where Claude runs are
//! the current profile's, as the Mac's `ProfileStore.apply` makes them; files from before profiles (2026-11-18) had
//! them at the top level, and the first profile takes them over (`ensure_profile`).

use crate::profiles::{self, Profile};
use serde::Serialize;
use serde_json::{Map, Value};
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Settings {
    /// An interface language code (`i18n::LANGUAGES`); None — as in the system.
    pub language: Option<String>,
    /// The person has seen the hint about pinning the tray icon (Windows 11 hides new icons under «^»).
    pub tray_hint_seen: bool,
    /// A background run is stopped after this many minutes.
    pub background_time_limit_minutes: u32,
    /// Notify when a PR's CI fails or is fixed and when a PR closes (on by default, as on the Mac).
    pub pull_request_alerts: bool,
    /// In the order shown.
    pub profiles: Vec<Profile>,
    pub current_profile: Option<String>,
    /// The Mac's settings from the last imported `.claudepult` file (`profiles::MAC_KEYS`: appearance, AI services,
    /// Telegram, modules…): nothing here uses them, an export writes them back.
    pub mac_settings: Map<String, Value>,
    /// `projects_dir` and `launch_mode` of a file from before profiles, for the first profile.
    #[serde(skip)]
    pub before_profiles: (Option<String>, Option<String>),
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            language: None,
            tray_hint_seen: false,
            background_time_limit_minutes: crate::runs::DEFAULT_TIME_LIMIT_MINUTES,
            pull_request_alerts: true,
            profiles: Vec::new(),
            current_profile: None,
            mac_settings: Map::new(),
            before_profiles: (None, None),
        }
    }
}

pub const LAUNCH_MODES: [&str; 2] = ["terminal", "background"];

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(std::env::temp_dir)
}

impl Settings {
    pub fn from_json(json: &str) -> Self {
        // Field by field, so one bad value keeps the others.
        let value: Value = serde_json::from_str(json).unwrap_or_default();
        let defaults = Settings::default();
        let text = |key: &str| value.get(key).and_then(Value::as_str).map(str::trim).filter(|v| !v.is_empty()).map(str::to_owned);
        let profiles: Vec<Profile> = value.get("profiles").and_then(Value::as_array).into_iter().flatten().filter_map(Profile::from_value).collect();
        let mut seen = std::collections::HashSet::new();
        let profiles = profiles.into_iter().filter(|p| seen.insert(p.id.clone())).collect();
        Settings {
            language: text("language").or(defaults.language),
            tray_hint_seen: value.get("tray_hint_seen").and_then(Value::as_bool).unwrap_or(defaults.tray_hint_seen),
            background_time_limit_minutes: value
                .get("background_time_limit_minutes")
                .and_then(Value::as_u64)
                .and_then(|v| u32::try_from(v).ok())
                .filter(|v| (5..=24 * 60).contains(v))
                .unwrap_or(defaults.background_time_limit_minutes),
            pull_request_alerts: value.get("pull_request_alerts").and_then(Value::as_bool).unwrap_or(defaults.pull_request_alerts),
            profiles,
            current_profile: text("current_profile"),
            mac_settings: value
                .get("mac_settings")
                .and_then(Value::as_object)
                .map(|map| map.iter().filter(|(key, _)| profiles::MAC_KEYS.contains(&key.as_str())).map(|(k, v)| (k.clone(), v.clone())).collect())
                .unwrap_or_default(),
            before_profiles: (text("projects_dir"), text("launch_mode").filter(|m| LAUNCH_MODES.contains(&m.as_str()))),
        }
    }

    pub fn load(path: &Path) -> Self {
        std::fs::read_to_string(path).map(|json| Self::from_json(&json)).unwrap_or_default()
    }

    /// Written to a temporary file next to it and renamed, so a crash never leaves half a file.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_string_pretty(self).map_err(io::Error::other)?)?;
        std::fs::rename(&tmp, path)
    }

    // MARK: - Profiles

    /// The chosen profile, or the first when the chosen one is gone.
    pub fn current(&self) -> Option<&Profile> {
        self.profiles.iter().find(|p| Some(&p.id) == self.current_profile.as_ref()).or(self.profiles.first())
    }

    fn current_mut(&mut self) -> Option<&mut Profile> {
        let id = self.current()?.id.clone();
        self.profiles.iter_mut().find(|p| p.id == id)
    }

    /// No profile yet (a first start, or a file from before profiles): the Mac's «Разработчик (GitHub)» template in
    /// `language`, with the old file's folder and launch mode. True when one was made.
    pub fn ensure_profile(&mut self, language: &str) -> bool {
        if !self.profiles.is_empty() {
            return false;
        }
        let Some(mut profile) = profiles::from_template("developer", language) else { return false };
        let (folder, launch_mode) = std::mem::take(&mut self.before_profiles);
        if let Some(folder) = folder {
            profile.set_git_folder(&profiles::tilde(Path::new(&folder), &home()));
        }
        profile.launch_mode = launch_mode;
        self.current_profile = Some(profile.id.clone());
        self.profiles.push(profile);
        true
    }

    /// The current profile's git projects folder; None when it has none (no profile, or folder projects).
    pub fn projects_dir(&self) -> Option<PathBuf> {
        self.current()?.projects_dir(&home())
    }

    /// The current profile has git projects but its folder isn't `~/Projects`: «По умолчанию» brings that back.
    pub fn has_custom_projects_dir(&self) -> bool {
        self.projects_dir().is_some_and(|dir| dir != crate::paths::default_projects_dir())
    }

    /// A new git projects folder for the current profile. True when it changed.
    pub fn set_projects_dir(&mut self, folder: &Path) -> bool {
        let text = profiles::tilde(folder, &home());
        self.current_mut().is_some_and(|p| p.set_git_folder(&text))
    }

    /// Where the current profile runs Claude; None — ask.
    pub fn launch_mode(&self) -> Option<String> {
        self.current()?.launch_mode.clone()
    }

    pub fn set_launch_mode(&mut self, mode: Option<String>) {
        if let Some(profile) = self.current_mut() {
            profile.launch_mode = mode.filter(|m| LAUNCH_MODES.contains(&m.as_str()));
        }
    }

    /// True when it is another profile than before.
    pub fn select_profile(&mut self, id: &str) -> bool {
        let before = self.current().map(|p| p.id.clone());
        if !self.profiles.iter().any(|p| p.id == id) || before.as_deref() == Some(id) {
            return false;
        }
        self.current_profile = Some(id.to_owned());
        true
    }

    /// Adds a profile under a name no other has, and makes it current.
    pub fn add_profile(&mut self, mut profile: Profile) {
        let taken: Vec<&str> = self.profiles.iter().map(|p| p.name.as_str()).collect();
        profile.name = profiles::unique_name(profile.name.trim(), &taken);
        self.current_profile = Some(profile.id.clone());
        self.profiles.push(profile);
    }

    /// A blank name is refused.
    pub fn rename_profile(&mut self, id: &str, name: &str) -> bool {
        let name = name.trim();
        match self.profiles.iter_mut().find(|p| p.id == id) {
            Some(profile) if !name.is_empty() => {
                profile.name = name.to_owned();
                true
            }
            _ => false,
        }
    }

    /// The last profile stays (no assistant here yet to make a new one). True when the current profile changed.
    pub fn delete_profile(&mut self, id: &str) -> bool {
        if self.profiles.len() < 2 || !self.profiles.iter().any(|p| p.id == id) {
            return false;
        }
        let was_current = self.current().is_some_and(|p| p.id == id);
        self.profiles.retain(|p| p.id != id);
        if was_current {
            self.current_profile = self.profiles.first().map(|p| p.id.clone());
        }
        was_current
    }
}

// MARK: - `.claudepult` files (the Mac's `ProfileStore` export and import)

impl Settings {
    /// «Экспорт настроек…»: every profile, the current one, and the Mac's settings kept from an import, with this
    /// computer's background time limit.
    pub fn export_settings(&self, now: chrono::DateTime<chrono::Utc>) -> String {
        let mut mac = self.mac_settings.clone();
        if let Some(general) = mac.get_mut("general").and_then(Value::as_object_mut) {
            general.insert("backgroundTimeLimitMinutes".into(), Value::from(self.background_time_limit_minutes));
        }
        let current = self.current().map(|p| p.id.as_str());
        profiles::write_bundle(profiles::SETTINGS_FORMAT, &self.profiles, current, &mac, now)
    }

    /// «Экспорт профиля…»: the current profile alone.
    pub fn export_profile(&self, now: chrono::DateTime<chrono::Utc>) -> Option<String> {
        let profile = self.current()?;
        Some(profiles::write_bundle(profiles::PROFILE_FORMAT, std::slice::from_ref(profile), None, &Map::new(), now))
    }

    /// «Заменить все настройки»: the file's profiles instead of these, its current one (if the Mac shows it), its
    /// time limit, and its Mac settings kept for the way back. A one-profile file only adds.
    pub fn import_replace(&mut self, bundle: profiles::Bundle) -> usize {
        if !bundle.is_settings() {
            return self.import_add(bundle);
        }
        let count = bundle.profiles.len();
        let shown = |id: &String| bundle.enabled.as_ref().is_none_or(|list| list.contains(id));
        let current = bundle.current.clone().filter(|id| bundle.profiles.iter().any(|p| &p.id == id) && shown(id));
        self.current_profile = current.or_else(|| bundle.profiles.iter().map(|p| p.id.clone()).find(shown)).or_else(|| bundle.profiles.first().map(|p| p.id.clone()));
        if let Some(minutes) = bundle.time_limit_minutes() {
            self.background_time_limit_minutes = minutes;
        }
        self.profiles = bundle.profiles;
        self.mac_settings = bundle.mac;
        count
    }

    /// «Добавить профили»: the file's profiles as new ones (fresh ids, names no other has); the current one stays.
    pub fn import_add(&mut self, bundle: profiles::Bundle) -> usize {
        let count = bundle.profiles.len();
        for mut profile in bundle.profiles {
            profile.id = crate::runs::new_id();
            let taken: Vec<&str> = self.profiles.iter().map(|p| p.name.as_str()).collect();
            profile.name = profiles::unique_name(&profile.name, &taken);
            self.profiles.push(profile);
        }
        count
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tolerant_reading() {
        assert_eq!(Settings::from_json("{}"), Settings::default());
        assert_eq!(Settings::from_json("garbage"), Settings::default());
        let read = Settings::from_json(r#"{"language": "de", "tray_hint_seen": "yes", "from_the_future": 1, "background_time_limit_minutes": 2, "profiles": [5, {"id": "a"}, {"id": "a"}]}"#);
        assert_eq!(read.language.as_deref(), Some("de"));
        assert!(!read.tray_hint_seen, "a bad value takes the default, the rest stays");
        assert_eq!((read.background_time_limit_minutes, read.pull_request_alerts), (90, true));
        assert_eq!(read.profiles.len(), 1, "not an object and a repeated id are dropped");
    }

    #[test]
    fn first_profile_from_a_file_before_profiles() {
        let mut settings = Settings::from_json(r#"{"projects_dir": "/srv/Проекты", "launch_mode": "background"}"#);
        assert_eq!(settings.projects_dir(), None);
        assert!(settings.ensure_profile("ru"));
        assert!(!settings.ensure_profile("ru"), "only once");
        let profile = settings.current().unwrap();
        assert_eq!(profile.name, "Разработчик (GitHub)");
        assert_eq!(settings.launch_mode().as_deref(), Some("background"));
        if cfg!(unix) {
            assert_eq!(settings.projects_dir(), Some(PathBuf::from("/srv/Проекты")));
        }
        let saved: Value = serde_json::from_str(&serde_json::to_string(&settings).unwrap()).unwrap();
        assert!(saved.get("projects_dir").is_none() && saved.get("launch_mode").is_none(), "only in the profile now");

        let mut fresh = Settings::default();
        assert!(fresh.ensure_profile("en"));
        assert_eq!(fresh.projects_dir(), Some(crate::paths::default_projects_dir()));
        assert!(!fresh.has_custom_projects_dir());
        assert_eq!(fresh.launch_mode(), None);
    }

    #[test]
    fn profiles_switch_and_keep_their_own_settings() {
        let mut settings = Settings::default();
        settings.ensure_profile("en");
        let first = settings.current().unwrap().id.clone();
        settings.set_launch_mode(Some("terminal".into()));
        let work = home().join("Работа");
        assert!(settings.set_projects_dir(&work));
        assert!(!settings.set_projects_dir(&work));

        settings.add_profile(profiles::from_template("developer", "en").unwrap());
        assert_eq!(settings.current().unwrap().name, "Developer (GitHub) 2");
        assert_eq!((settings.launch_mode(), settings.projects_dir()), (None, Some(crate::paths::default_projects_dir())));

        assert!(settings.select_profile(&first));
        assert!(!settings.select_profile(&first), "already current");
        assert!(!settings.select_profile("missing"));
        assert_eq!((settings.launch_mode().as_deref(), settings.projects_dir()), (Some("terminal"), Some(work)));
        assert!(settings.has_custom_projects_dir());

        assert!(settings.rename_profile(&first, "  Мой  "));
        assert!(!settings.rename_profile(&first, " "));
        assert_eq!(settings.current().unwrap().name, "Мой");

        assert!(settings.delete_profile(&first), "the current one went");
        assert_eq!(settings.current().unwrap().name, "Developer (GitHub) 2");
        let last = settings.current().unwrap().id.clone();
        assert!(!settings.delete_profile(&last), "the last one stays");
        assert_eq!(settings.profiles.len(), 1);
    }

    #[test]
    fn claudepult_files() {
        let now = chrono::Utc::now();
        let mut here = Settings::default();
        here.ensure_profile("ru");
        here.set_launch_mode(Some("terminal".into()));
        let own = here.current().unwrap().clone();

        // A Mac file: two profiles, the second current, appearance and Telegram settings.
        let mac = r#"{"format": "claudepult-settings", "version": 2, "exportedAt": "2026-11-17T10:00:00Z", "current": "v",
            "enabled": ["d", "v"], "general": {"backgroundTimeLimitMinutes": 120, "telegramForBackground": false, "limitThresholds": [90], "limitAlertsToTelegram": true},
            "appearance": {"theme": "dark"},
            "modes": [{"id": "d", "name": "Разработчик (GitHub)", "source": {"gitBuiltin": {"projects": "~/Projects"}}},
                      {"id": "v", "name": "Видео", "source": {"folders": {"_0": "~/Documents/Видео"}}}]}"#;

        let mut added = here.clone();
        assert_eq!(added.import_add(profiles::read_bundle(mac).unwrap()), 2);
        let names: Vec<&str> = added.profiles.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(names, ["Разработчик (GitHub)", "Разработчик (GitHub) 2", "Видео"]);
        assert_eq!(added.current().unwrap().id, own.id, "adding keeps the current profile");
        assert!(added.profiles[1..].iter().all(|p| p.id != "d" && p.id != "v"), "fresh ids");
        assert!(added.mac_settings.is_empty());

        let mut replaced = here.clone();
        assert_eq!(replaced.import_replace(profiles::read_bundle(mac).unwrap()), 2);
        assert_eq!(replaced.profiles.len(), 2);
        assert_eq!(replaced.current().unwrap().name, "Видео");
        assert_eq!(replaced.projects_dir(), None, "folder projects: no git folder");
        assert_eq!(replaced.background_time_limit_minutes, 120);
        assert_eq!(replaced.mac_settings["appearance"]["theme"], "dark");

        // Back to the Mac: its settings return, with this computer's time limit.
        replaced.background_time_limit_minutes = 45;
        let file: Value = serde_json::from_str(&replaced.export_settings(now)).unwrap();
        assert_eq!(file["general"]["telegramForBackground"], false);
        assert_eq!(file["general"]["backgroundTimeLimitMinutes"], 45);
        assert_eq!(file["current"], "v");
        assert_eq!(file["modes"].as_array().unwrap().len(), 2);

        // A file made here has no Mac settings to send; a profile file has the current profile alone.
        let file: Value = serde_json::from_str(&here.export_settings(now)).unwrap();
        assert!(file.get("general").is_none() && file.get("appearance").is_none());
        let one = profiles::read_bundle(&here.export_profile(now).unwrap()).unwrap();
        assert_eq!(one.profiles, vec![own.clone()]);
        let mut again = here.clone();
        assert_eq!(again.import_replace(one), 1, "a profile file only adds");
        assert_eq!(again.profiles.len(), 2);
        assert_eq!(again.current().unwrap().id, own.id);
    }

    #[test]
    fn round_trip() {
        let dir = std::env::temp_dir().join(format!("claudepult-settings-{}", std::process::id()));
        let path = dir.join("settings.json");
        let mut settings = Settings { language: Some("uk".into()), tray_hint_seen: true, background_time_limit_minutes: 60, pull_request_alerts: false, ..Settings::default() };
        settings.ensure_profile("uk");
        settings.set_launch_mode(Some("terminal".into()));
        settings.mac_settings.insert("appearance".into(), serde_json::json!({"theme": "dark"}));
        settings.save(&path).unwrap();
        assert_eq!(Settings::load(&path), settings);
        assert!(!path.with_extension("json.tmp").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
