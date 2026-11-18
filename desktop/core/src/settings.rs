//! `settings.json` (docs/specs/SPEC-windows.md §6). Reading is tolerant like the Mac's `NotchSettings`: unknown keys from
//! newer versions are ignored, missing or broken ones take their defaults, so a file never stops the app.
//!
//! Profiles live here too (§6), in the Mac's own JSON (`profiles.rs`). The projects folder and where Claude runs are
//! the current profile's, as the Mac's `ProfileStore.apply` makes them; files from before profiles (2026-11-18) had
//! them at the top level, and the first profile takes them over (`ensure_profile`).

use crate::profiles::{self, Profile};
use serde::Serialize;
use serde_json::Value;
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
    fn round_trip() {
        let dir = std::env::temp_dir().join(format!("claudepult-settings-{}", std::process::id()));
        let path = dir.join("settings.json");
        let mut settings = Settings { language: Some("uk".into()), tray_hint_seen: true, background_time_limit_minutes: 60, pull_request_alerts: false, ..Settings::default() };
        settings.ensure_profile("uk");
        settings.set_launch_mode(Some("terminal".into()));
        settings.save(&path).unwrap();
        assert_eq!(Settings::load(&path), settings);
        assert!(!path.with_extension("json.tmp").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
