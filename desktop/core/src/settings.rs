//! `settings.json` (docs/specs/SPEC-windows.md §6). Reading is tolerant like the Mac's `NotchSettings`: unknown keys from
//! newer versions are ignored, missing or broken ones take their defaults, so a file never stops the app.

use serde::{Deserialize, Serialize};
use std::io;
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    /// An interface language code (`i18n::LANGUAGES`); None — as in the system.
    pub language: Option<String>,
    /// The person has seen the hint about pinning the tray icon (Windows 11 hides new icons under «^»).
    pub tray_hint_seen: bool,
    /// Where Claude's commands run: `terminal` or `background`; None — ask each time (the Mac's «Спрашивать»).
    pub launch_mode: Option<String>,
    /// A background run is stopped after this many minutes.
    pub background_time_limit_minutes: u32,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            language: None,
            tray_hint_seen: false,
            launch_mode: None,
            background_time_limit_minutes: crate::runs::DEFAULT_TIME_LIMIT_MINUTES,
        }
    }
}

pub const LAUNCH_MODES: [&str; 2] = ["terminal", "background"];

impl Settings {
    pub fn from_json(json: &str) -> Self {
        // Field by field, so one bad value keeps the others.
        let value: serde_json::Value = serde_json::from_str(json).unwrap_or_default();
        let defaults = Settings::default();
        Settings {
            language: value.get("language").and_then(|v| v.as_str()).map(str::to_owned).or(defaults.language),
            tray_hint_seen: value.get("tray_hint_seen").and_then(|v| v.as_bool()).unwrap_or(defaults.tray_hint_seen),
            launch_mode: value.get("launch_mode").and_then(|v| v.as_str()).filter(|m| LAUNCH_MODES.contains(m)).map(str::to_owned),
            background_time_limit_minutes: value
                .get("background_time_limit_minutes")
                .and_then(|v| v.as_u64())
                .and_then(|v| u32::try_from(v).ok())
                .filter(|v| (5..=24 * 60).contains(v))
                .unwrap_or(defaults.background_time_limit_minutes),
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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tolerant_reading() {
        assert_eq!(Settings::from_json("{}"), Settings::default());
        assert_eq!(Settings::from_json("garbage"), Settings::default());
        let read = Settings::from_json(r#"{"language": "de", "tray_hint_seen": "yes", "from_the_future": 1, "launch_mode": "window", "background_time_limit_minutes": 2}"#);
        assert_eq!(read.language.as_deref(), Some("de"));
        assert!(!read.tray_hint_seen, "a bad value takes the default, the rest stays");
        assert_eq!((read.launch_mode, read.background_time_limit_minutes), (None, 90));
        let read = Settings::from_json(r#"{"launch_mode": "background", "background_time_limit_minutes": 120}"#);
        assert_eq!((read.launch_mode.as_deref(), read.background_time_limit_minutes), (Some("background"), 120));
    }

    #[test]
    fn round_trip() {
        let dir = std::env::temp_dir().join(format!("claudepult-settings-{}", std::process::id()));
        let path = dir.join("settings.json");
        let settings = Settings { language: Some("uk".into()), tray_hint_seen: true, launch_mode: Some("terminal".into()), background_time_limit_minutes: 60 };
        settings.save(&path).unwrap();
        assert_eq!(Settings::load(&path), settings);
        assert!(!path.with_extension("json.tmp").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
