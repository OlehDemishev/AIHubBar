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
    /// The `whats_new::VERSION` whose card was closed.
    pub whats_new_seen: Option<String>,
    /// «Ставить фоновые задачи на паузу» (`queue::GUARD_CHOICES`).
    pub run_guard_percent: u32,
    /// «Ночные задачи начинаются в» (`queue::HOURS`).
    pub night_start_hour: u32,
    /// When the night's first run started, in seconds: the batch that gets one summary once it is done.
    pub night_batch_start: Option<i64>,
    /// A background run is stopped after this many minutes.
    pub background_time_limit_minutes: u32,
    /// Notify when a PR's CI fails or is fixed and when a PR closes (on by default, as on the Mac).
    pub pull_request_alerts: bool,
    /// In the order shown.
    pub profiles: Vec<Profile>,
    pub current_profile: Option<String>,
    /// Calendar reminders, hours before a date (the Mac's `calendarReminderHours`); empty — «не напоминать».
    pub calendar_reminder_hours: Vec<i64>,
    /// The Mac's settings from the last imported `.claudepult` file (`profiles::MAC_KEYS`: appearance, AI services,
    /// Telegram, modules…): nothing here uses them, an export writes them back.
    pub mac_settings: Map<String, Value>,
    /// «Не спать»: the rules (this computer's own, as on the Mac) and a manual hold (−1 — until switched off, else
    /// its end in seconds since 1970), kept across restarts.
    pub keep_awake: crate::keep_awake::Rules,
    pub keep_awake_manual: Option<f64>,
    /// «Ресурсы компьютера»: notify about load, memory, space and charge (on by default, as on the Mac), and below
    /// how many GB free the disk counts as nearly full.
    pub resource_alerts: bool,
    /// Look for a new version once a day (Windows; on by default, as the Mac's «Проверять раз в день»).
    pub updates_daily: bool,
    /// «Продлевать вход Claude Code сам» (the Mac's `renewClaudeLogin`, on by default there too).
    pub renew_claude_login: bool,
    /// «Подписка, $ в месяц» of «История расхода» (the Mac's `claudePlanPrice`); 0 — not said.
    pub claude_plan_price: f64,
    /// The chat the Telegram bot writes to (the Mac's `telegramChatID`); the token is among the API keys.
    pub telegram_chat: Option<String>,
    /// Events that don't go to Telegram (`telegram::EVENTS`); all go by default.
    pub telegram_off: Vec<String>,
    /// «Этот компьютер отвечает боту»: it reads the bot's messages (one reader per bot — off until switched on).
    pub telegram_answers: bool,
    /// «Запросы разрешений в этот бот» (the Mac's `telegramApprovals`).
    pub telegram_requests: bool,
    /// «Заметки»: the folder of the notes (None — `notes::default_folder`) and the note shown last.
    pub notes_folder: Option<String>,
    /// «История буфера»: how many copies are kept, and whether they outlive a restart (in `clipboard.json`).
    pub clipboard_limit: u32,
    pub clipboard_remember: bool,
    pub notes_selected: Option<String>,
    pub resource_disk_below_gb: u64,
    /// «Быстрые команды»: the library (the Mac's `[QuickCommand]`); None — the starting examples, until edited.
    pub quick_commands: Option<Vec<crate::quick_commands::QuickCommand>>,
    /// «Свои промпты» (the Mac's `savedPrompts`); None — the two examples, until edited.
    pub saved_prompts: Option<Vec<crate::search::SavedPrompt>>,
    /// «Быстрые переключатели» shown (the Mac's `quickToggles`); None — every one this system has.
    pub quick_toggles: Option<Vec<String>>,
    /// Other AI services' limits (the Mac's `hubDisabled`, `hubGeminiQuota`, `hubGeminiDailyLimit`): each source is on
    /// once found unless switched off; Gemini's exact quota only with consent; its plan's requests a day.
    pub hub_disabled: Vec<String>,
    pub hub_gemini_quota: bool,
    pub hub_gemini_daily_limit: u64,
    /// Whose limits lead the panel and the tray icon (the Mac's `mainService`): `""` automatic, `claude` or a source.
    pub main_service: String,
    /// How the tray icon draws the limits (`tray_icon::Style`'s id); `""` is the default style.
    pub tray_style: String,
    /// «Быстрый запрос» (the Mac's `QuickPromptSettings`): the hot key, and the project and mode used last.
    pub quick_prompt_hot_key: String,
    /// «Открывать поиск с клавиатуры» (`search::SEARCH_KEYS`); «off» until chosen — no global key is taken unasked.
    pub search_hot_key: String,
    pub quick_prompt_last_project: Option<String>,
    pub quick_prompt_last_mode: Option<String>,
    /// `projects_dir` and `launch_mode` of a file from before profiles, for the first profile.
    #[serde(skip)]
    pub before_profiles: (Option<String>, Option<String>),
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            language: None,
            tray_hint_seen: false,
            whats_new_seen: None,
            run_guard_percent: crate::queue::GUARD_PERCENT,
            night_start_hour: crate::queue::DEFAULT_HOUR,
            night_batch_start: None,
            background_time_limit_minutes: crate::runs::DEFAULT_TIME_LIMIT_MINUTES,
            pull_request_alerts: true,
            profiles: Vec::new(),
            current_profile: None,
            calendar_reminder_hours: vec![24],
            mac_settings: Map::new(),
            keep_awake: crate::keep_awake::Rules::default(),
            keep_awake_manual: None,
            resource_alerts: true,
            updates_daily: true,
            renew_claude_login: true,
            claude_plan_price: 0.0,
            telegram_chat: None,
            telegram_off: Vec::new(),
            telegram_answers: false,
            telegram_requests: false,
            notes_folder: None,
            clipboard_limit: crate::clipboard::DEFAULT_LIMIT,
            clipboard_remember: false,
            notes_selected: None,
            resource_disk_below_gb: 20,
            quick_commands: None,
            saved_prompts: None,
            quick_toggles: None,
            hub_disabled: Vec::new(),
            hub_gemini_quota: false,
            hub_gemini_daily_limit: 1000,
            main_service: String::new(),
            tray_style: String::new(),
            quick_prompt_hot_key: crate::quick_prompt::DEFAULT_HOT_KEY.id().to_owned(),
            search_hot_key: "off".into(),
            quick_prompt_last_project: None,
            quick_prompt_last_mode: None,
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
            whats_new_seen: value.get("whats_new_seen").and_then(Value::as_str).map(str::to_owned),
            night_start_hour: value.get("night_start_hour").and_then(Value::as_u64).map(|hour| hour as u32).filter(|hour| crate::queue::HOURS.contains(hour)).unwrap_or(defaults.night_start_hour),
            night_batch_start: value.get("night_batch_start").and_then(Value::as_i64),
            run_guard_percent: value.get("run_guard_percent").and_then(Value::as_u64).map(|percent| percent as u32).filter(|percent| crate::queue::GUARD_CHOICES.contains(percent)).unwrap_or(defaults.run_guard_percent),
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
            calendar_reminder_hours: value
                .get("calendar_reminder_hours")
                .and_then(Value::as_array)
                .map(|list| list.iter().filter_map(Value::as_i64).filter(|h| *h > 0).collect())
                .unwrap_or(defaults.calendar_reminder_hours),
            mac_settings: value
                .get("mac_settings")
                .and_then(Value::as_object)
                .map(|map| map.iter().filter(|(key, _)| profiles::MAC_KEYS.contains(&key.as_str())).map(|(k, v)| (k.clone(), v.clone())).collect())
                .unwrap_or_default(),
            keep_awake: crate::keep_awake::Rules::from_value(value.get("keep_awake")),
            keep_awake_manual: value.get("keep_awake_manual").and_then(Value::as_f64),
            resource_alerts: value.get("resource_alerts").and_then(Value::as_bool).unwrap_or(defaults.resource_alerts),
            updates_daily: value.get("updates_daily").and_then(Value::as_bool).unwrap_or(defaults.updates_daily),
            claude_plan_price: value.get("claude_plan_price").and_then(Value::as_f64).filter(|price| price.is_finite() && *price > 0.0).unwrap_or(0.0),
            renew_claude_login: value.get("renew_claude_login").and_then(Value::as_bool).unwrap_or(defaults.renew_claude_login),
            telegram_answers: value.get("telegram_answers").and_then(Value::as_bool).unwrap_or(false),
            telegram_requests: value.get("telegram_requests").and_then(Value::as_bool).unwrap_or(false),
            clipboard_limit: value.get("clipboard_limit").and_then(Value::as_u64).map(|n| n as u32).filter(|n| crate::clipboard::LIMITS.contains(n)).unwrap_or(crate::clipboard::DEFAULT_LIMIT),
            clipboard_remember: value.get("clipboard_remember").and_then(Value::as_bool).unwrap_or(false),
            notes_folder: value.get("notes_folder").and_then(Value::as_str).map(str::to_owned).filter(|f| !f.trim().is_empty()),
            notes_selected: value.get("notes_selected").and_then(Value::as_str).map(str::to_owned),
            telegram_chat: value.get("telegram_chat").and_then(Value::as_str).map(str::to_owned).filter(|c| !c.is_empty()),
            telegram_off: value.get("telegram_off").and_then(Value::as_array).map(|list| list.iter().filter_map(Value::as_str).filter(|e| crate::telegram::EVENTS.contains(e)).map(str::to_owned).collect()).unwrap_or_default(),
            quick_commands: crate::quick_commands::library(value.get("quick_commands")),
            saved_prompts: crate::search::saved_prompts(value.get("saved_prompts")),
            hub_disabled: value.get("hub_disabled").and_then(Value::as_array).map(|l| l.iter().filter_map(Value::as_str).map(str::to_owned).collect()).unwrap_or_default(),
            hub_gemini_quota: value.get("hub_gemini_quota").and_then(Value::as_bool).unwrap_or(false),
            main_service: value.get("main_service").and_then(Value::as_str).unwrap_or_default().to_owned(),
            tray_style: value.get("tray_style").and_then(Value::as_str).unwrap_or_default().to_owned(),
            quick_prompt_hot_key: text("quick_prompt_hot_key").filter(|k| crate::quick_prompt::HotKey::parse(k).is_some()).unwrap_or(defaults.quick_prompt_hot_key),
            search_hot_key: text("search_hot_key").filter(|k| crate::search::SEARCH_KEYS.iter().any(|(id, _, _)| id == k)).unwrap_or_else(|| "off".into()),
            quick_prompt_last_project: text("quick_prompt_last_project"),
            quick_prompt_last_mode: text("quick_prompt_last_mode").filter(|m| LAUNCH_MODES.contains(&m.as_str())),
            hub_gemini_daily_limit: value.get("hub_gemini_daily_limit").and_then(Value::as_u64).filter(|n| *n > 0).unwrap_or(1000),
            quick_toggles: value
                .get("quick_toggles")
                .and_then(Value::as_array)
                .map(|list| list.iter().filter_map(Value::as_str).filter(|t| crate::toggles::TOGGLES.contains(t)).map(str::to_owned).collect()),
            resource_disk_below_gb: value.get("resource_disk_below_gb").and_then(Value::as_u64).filter(|gb| *gb > 0).unwrap_or(defaults.resource_disk_below_gb),
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

    /// A field of the current profile edited in Settings (`Profile::set_field`). True when it was taken.
    pub fn set_profile_field(&mut self, field: &str, value: &serde_json::Value) -> bool {
        self.current_mut().is_some_and(|profile| profile.set_field(field, value))
    }

    /// No profile yet (a first start, or a file from before profiles): the Mac's «Разработчик (GitHub)» template in
    /// `language`, with the old file's folder and launch mode. True when one was made.
    /// At start: a file from before profiles with its own folder or launch mode keeps them in «Разработчик (GitHub)»;
    /// otherwise there is no profile and the assistant makes the first one (the Mac's empty start, SPEC-profiles §2).
    pub fn migrate_profile(&mut self, language: &str) -> bool {
        self.profiles.is_empty() && (self.before_profiles.0.is_some() || self.before_profiles.1.is_some()) && self.ensure_profile(language)
    }

    pub fn ensure_profile(&mut self, language: &str) -> bool {
        if !self.profiles.is_empty() {
            return false;
        }
        let Some(mut profile) = profiles::from_template("developer", language) else { return false };
        let (folder, launch_mode) = std::mem::take(&mut self.before_profiles);
        if let Some(folder) = folder {
            profile.set_folder(&profiles::tilde(Path::new(&folder), &home()));
        }
        profile.launch_mode = launch_mode;
        self.current_profile = Some(profile.id.clone());
        self.profiles.push(profile);
        true
    }

    /// The current profile's projects folder (git repositories or folder projects); None when it has none.
    pub fn projects_dir(&self) -> Option<PathBuf> {
        self.current()?.projects_dir(&home())
    }

    /// The current profile's folder isn't the one its template starts with (`~/Projects` for git repositories):
    /// «По умолчанию» brings that back.
    pub fn has_custom_projects_dir(&self) -> bool {
        match (self.projects_dir(), self.default_projects_dir()) {
            (Some(dir), Some(default)) => dir != default,
            _ => false,
        }
    }

    /// Where «По умолчанию» goes: `~/Projects` for git repositories, the template's folder for folder projects.
    pub fn default_projects_dir(&self) -> Option<PathBuf> {
        let profile = self.current()?;
        if !profile.source().is_folders() {
            return profile.source().folder().map(|_| crate::paths::default_projects_dir());
        }
        let template = profiles::from_template(&profile.template, crate::i18n::resolve(self.language.as_deref()))?;
        template.projects_dir(&home()).filter(|_| template.source().is_folders())
    }

    /// A new projects folder for the current profile. True when it changed.
    pub fn set_projects_dir(&mut self, folder: &Path) -> bool {
        let text = profiles::tilde(folder, &home());
        self.current_mut().is_some_and(|p| p.set_folder(&text))
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

// MARK: - Modules: the Mac's `installed` and `off` lists, so `.claudepult` files carry them both ways

pub const THEMES: [&str; 3] = ["system", "light", "dark"];
/// The Mac's panel is 380, 420 or 500 points wide; this one has been 380 since its first version, so that stays
/// «Обычная» and the others stand as far from it.
pub const PANEL_WIDTHS: [(&str, f64); 3] = [("narrow", 340.0), ("normal", 380.0), ("wide", 460.0)];
pub const PANEL_DENSITIES: [(&str, f64); 3] = [("compact", 0.5), ("normal", 1.0), ("spacious", 1.5)];
pub const TEXT_SIZES: [(&str, f64); 4] = [("small", 0.9), ("normal", 1.0), ("large", 1.15), ("extraLarge", 1.3)];

/// The stage 6 modules this version has, as the Mac's `ModuleKind` names them.
pub const MODULES: [&str; 7] = ["resources", "keepAwake", "quickCommands", "toggles", "quickPrompt", "notes", "clipboard"];

impl Settings {
    fn kinds(&self, key: &str) -> Vec<String> {
        self.mac_settings.get(key).and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(str::to_owned).collect()
    }

    /// Installed and not switched off (the Mac's `ProfileStore.isOn`).
    pub fn module_on(&self, kind: &str) -> bool {
        self.kinds("installed").iter().any(|k| k == kind) && !self.kinds("off").iter().any(|k| k == kind)
    }

    /// On: installed, not off, and added (shown) to every profile that lists its modules — a profile from a Mac
    /// lists them, one made here doesn't and shows every module that is on. Off: in `off`, as the Mac switches one off.
    pub fn set_module(&mut self, kind: &str, on: bool) {
        let mut installed = self.kinds("installed");
        let mut off = self.kinds("off");
        off.retain(|k| k != kind);
        if on {
            if !installed.iter().any(|k| k == kind) {
                installed.push(kind.to_owned());
            }
            for profile in &mut self.profiles {
                if let Some(modules) = profile.other.get_mut("modules").and_then(Value::as_array_mut) {
                    if !modules.iter().any(|m| m["kind"] == kind) {
                        modules.push(serde_json::json!({"kind": kind, "shown": true}));
                    }
                }
            }
        } else if installed.iter().any(|k| k == kind) {
            off.push(kind.to_owned());
        }
        self.mac_settings.insert("installed".into(), serde_json::json!(installed));
        self.mac_settings.insert("off".into(), serde_json::json!(off));
    }

    /// The current profile shows the module: it lists it as shown, or lists no modules at all.
    pub fn shows_module(&self, kind: &str) -> bool {
        self.module_on(kind)
            && self.current().is_none_or(|p| match p.other.get("modules").and_then(Value::as_array) {
                Some(modules) => modules.iter().any(|m| m["kind"] == kind && m["shown"].as_bool() != Some(false)),
                None => true,
            })
    }
}

// MARK: - «Сервисы AI»: the Mac's `AIServicesConfig`, kept with its other settings

impl Settings {
    /// The models chosen, the compatible server, prices and budget (`ai.rs`); Null when nothing is set.
    pub fn services(&self) -> Value {
        self.mac_settings.get("services").cloned().unwrap_or(Value::Null)
    }

    pub fn services_mut(&mut self) -> &mut Value {
        self.mac_settings.entry("services").or_insert_with(|| Value::Object(Map::new()))
    }
}

// MARK: - `.claudepult` files (the Mac's `ProfileStore` export and import)

/// The limit alerts' thresholds until the person sets their own (the Mac's `defaultLimitThresholds`).
pub const DEFAULT_LIMIT_THRESHOLDS: [u32; 3] = [50, 80, 95];

/// «50, 80, 95» → [50, 80, 95]: whole percents from 1 to 100, each once, in order; anything else is dropped.
pub fn parse_thresholds(text: &str) -> Vec<u32> {
    let mut values: Vec<u32> = text.split(|c: char| !c.is_ascii_digit()).filter_map(|part| part.parse().ok()).filter(|value| (1..=100).contains(value)).collect();
    values.sort_unstable();
    values.dedup();
    values
}

impl Settings {
    /// «Уведомлять на, %»: kept where the Mac keeps it (`general.limitThresholds`), so a settings file carries it
    /// both ways.
    pub fn limit_thresholds(&self) -> Vec<u32> {
        let saved: Vec<u32> = self
            .mac_settings
            .get("general")
            .and_then(|general| general.get("limitThresholds"))
            .and_then(Value::as_array)
            .map(|list| list.iter().filter_map(Value::as_u64).filter(|value| (1..=100).contains(value)).map(|value| value as u32).collect())
            .unwrap_or_default();
        let mut values = saved;
        values.sort_unstable();
        values.dedup();
        if values.is_empty() { DEFAULT_LIMIT_THRESHOLDS.to_vec() } else { values }
    }

    /// «Тема»: «system», «light» or «dark» (the Mac's `PanelTheme`, kept where its profiles keep it).
    pub fn theme(&self) -> &'static str {
        let saved = self.mac_settings.get("appearance").and_then(|a| a.get("theme")).and_then(Value::as_str);
        THEMES.into_iter().find(|theme| Some(*theme) == saved).unwrap_or(THEMES[0])
    }

    /// «Размер текста»: the Mac's `PanelTextSize` and its scale.
    pub fn text_size(&self) -> (&'static str, f64) {
        let saved = self.mac_settings.get("appearance").and_then(|a| a.get("textSize")).and_then(Value::as_str);
        TEXT_SIZES.into_iter().find(|(size, _)| Some(*size) == saved).unwrap_or(TEXT_SIZES[1])
    }

    /// «Ширина»: the Mac's `PanelWidth` and the panel's width here, before «Размер текста» widens it.
    pub fn panel_width(&self) -> (&'static str, f64) {
        let saved = self.mac_settings.get("appearance").and_then(|a| a.get("width")).and_then(Value::as_str);
        PANEL_WIDTHS.into_iter().find(|(width, _)| Some(*width) == saved).unwrap_or(PANEL_WIDTHS[1])
    }

    /// «Плотность строк»: the Mac's `PanelDensity` and its multiplier of the rows' spacing.
    pub fn panel_density(&self) -> (&'static str, f64) {
        let saved = self.mac_settings.get("appearance").and_then(|a| a.get("density")).and_then(Value::as_str);
        PANEL_DENSITIES.into_iter().find(|(density, _)| Some(*density) == saved).unwrap_or(PANEL_DENSITIES[1])
    }

    /// Values that are not a width or a density change nothing.
    pub fn set_panel_shape(&mut self, width: &str, density: &str) {
        let appearance = self.mac_settings.entry("appearance").or_insert_with(|| Value::Object(Map::new()));
        if let Some(appearance) = appearance.as_object_mut() {
            if PANEL_WIDTHS.iter().any(|(id, _)| *id == width) {
                appearance.insert("width".into(), Value::String(width.to_owned()));
            }
            if PANEL_DENSITIES.iter().any(|(id, _)| *id == density) {
                appearance.insert("density".into(), Value::String(density.to_owned()));
            }
        }
    }

    /// Values that are not a theme or a size change nothing.
    pub fn set_appearance(&mut self, theme: &str, text_size: &str) {
        let appearance = self.mac_settings.entry("appearance").or_insert_with(|| Value::Object(Map::new()));
        if let Some(appearance) = appearance.as_object_mut() {
            if THEMES.contains(&theme) {
                appearance.insert("theme".into(), Value::String(theme.to_owned()));
            }
            if TEXT_SIZES.iter().any(|(size, _)| *size == text_size) {
                appearance.insert("textSize".into(), Value::String(text_size.to_owned()));
            }
        }
    }

    /// Nothing valid in `values` keeps what was there.
    pub fn set_limit_thresholds(&mut self, values: &[u32]) {
        let values = parse_thresholds(&values.iter().map(u32::to_string).collect::<Vec<_>>().join(","));
        if values.is_empty() {
            return;
        }
        let general = self.mac_settings.entry("general").or_insert_with(|| Value::Object(Map::new()));
        if let Some(general) = general.as_object_mut() {
            general.insert("limitThresholds".into(), serde_json::json!(values));
        }
    }

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
        assert_eq!(read.calendar_reminder_hours, [24], "the Mac's default");
        assert_eq!(Settings::from_json(r#"{"calendar_reminder_hours": []}"#).calendar_reminder_hours, Vec::<i64>::new(), "«не напоминать» stays");
        assert_eq!(Settings::from_json(r#"{"calendar_reminder_hours": [72, "x", -1, 24]}"#).calendar_reminder_hours, [72, 24]);
    }

    #[test]
    fn first_profile_from_a_file_before_profiles() {
        let mut empty = Settings::from_json(r#"{"language": "ru"}"#);
        assert!(!empty.migrate_profile("ru"), "an empty start: the assistant makes the first profile");
        assert!(empty.profiles.is_empty() && empty.current().is_none() && empty.projects_dir().is_none());
        let mut settings = Settings::from_json(r#"{"projects_dir": "/srv/Проекты", "launch_mode": "background"}"#);
        assert_eq!(settings.projects_dir(), None);
        assert!(settings.migrate_profile("ru"));
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
    fn modules_and_keep_awake() {
        let mut settings = Settings::from_json(r#"{"mac_settings": {"installed": ["limits", "keepAwake"], "off": ["keepAwake"]}, "keep_awake": {"whileOnPower": true}, "keep_awake_manual": -1}"#);
        assert!(!settings.module_on("keepAwake"), "installed but switched off on the Mac");
        assert_eq!((settings.keep_awake.while_on_power, settings.keep_awake.while_claude_works, settings.keep_awake_manual), (true, true, Some(-1.0)));
        settings.ensure_profile("ru");
        let mut mac = settings.profiles[0].clone();
        mac.id = "mac".into();
        mac.other.insert("modules".into(), serde_json::json!([{"kind": "limits", "shown": true}]));
        settings.profiles.push(mac);
        assert!(!settings.shows_module("keepAwake"));
        settings.set_module("keepAwake", true);
        assert!(settings.module_on("keepAwake") && settings.shows_module("keepAwake"));
        assert_eq!(settings.mac_settings["off"], serde_json::json!([]));
        assert_eq!(settings.profiles[1].other["modules"][1], serde_json::json!({"kind": "keepAwake", "shown": true}), "a Mac profile lists it now");
        assert!(settings.profiles[0].other.get("modules").is_none(), "a profile made here shows every module that is on");
        settings.set_module("keepAwake", false);
        assert!(!settings.module_on("keepAwake"));
        assert_eq!(settings.mac_settings["installed"], serde_json::json!(["limits", "keepAwake"]));
        let saved = Settings::from_json(&serde_json::to_string(&settings).unwrap());
        assert_eq!((saved.keep_awake.clone(), saved.keep_awake_manual, saved.module_on("keepAwake")), (settings.keep_awake.clone(), Some(-1.0), false));
        assert!(!Settings::default().module_on("keepAwake"), "off until switched on");
        let resources = Settings::from_json(r#"{"resource_alerts": false, "resource_disk_below_gb": 0}"#);
        assert_eq!((resources.resource_alerts, resources.resource_disk_below_gb), (false, 20));
        assert_eq!(parse_thresholds("95, 50;80 % 80, 0, 101, x"), [50, 80, 95]);
        assert!(parse_thresholds("ноль").is_empty());
        let mut look = Settings::default();
        assert_eq!((look.theme(), look.text_size()), ("system", ("normal", 1.0)));
        look.set_appearance("dark", "extraLarge");
        assert_eq!((look.theme(), look.text_size()), ("dark", ("extraLarge", 1.3)));
        look.set_appearance("pink", "huge");
        assert_eq!((look.theme(), look.text_size().0), ("dark", "extraLarge"), "not a theme, not a size");
        let from_mac = Settings::from_json(r#"{"mac_settings": {"appearance": {"theme": "light", "textSize": "small", "width": "wide"}}}"#);
        assert_eq!((from_mac.theme(), from_mac.text_size()), ("light", ("small", 0.9)));
        let mut kept = from_mac.clone();
        kept.set_appearance("system", "large");
        assert_eq!(kept.mac_settings["appearance"]["width"], "wide", "the Mac's other appearance settings stay");
        assert_eq!((kept.panel_width(), kept.panel_density()), (("wide", 460.0), ("normal", 1.0)));
        let mut shaped = Settings::default();
        assert_eq!(shaped.panel_width(), ("normal", 380.0));
        shaped.set_panel_shape("narrow", "spacious");
        shaped.set_panel_shape("huge", "loose");
        assert_eq!((shaped.panel_width().0, shaped.panel_density()), ("narrow", ("spacious", 1.5)), "what is not a choice changes nothing");
        let mut thresholds = Settings::default();
        assert_eq!(thresholds.limit_thresholds(), DEFAULT_LIMIT_THRESHOLDS);
        thresholds.set_limit_thresholds(&[90, 70, 70, 300]);
        assert_eq!(thresholds.limit_thresholds(), [70, 90]);
        thresholds.set_limit_thresholds(&[]);
        assert_eq!(thresholds.limit_thresholds(), [70, 90], "nothing valid keeps the old ones");
        let from_mac = Settings::from_json(r#"{"mac_settings": {"general": {"limitThresholds": [95, 80]}}}"#);
        assert_eq!(from_mac.limit_thresholds(), [80, 95]);
        assert!(resources.renew_claude_login && !Settings::from_json(r#"{"renew_claude_login": false}"#).renew_claude_login);
        assert!(resources.updates_daily && !Settings::from_json(r#"{"updates_daily": false}"#).updates_daily);
        let telegram = Settings::from_json(r#"{"telegram_chat": "42", "telegram_off": ["pr", "nonsense"]}"#);
        assert_eq!((telegram.telegram_chat.as_deref(), telegram.telegram_off), (Some("42"), vec!["pr".to_owned()]));
        assert!(resources.telegram_chat.is_none() && resources.telegram_off.is_empty());
        assert!(!resources.telegram_answers && !resources.telegram_requests, "nothing reads a bot or sends requests until asked");
        let reader = Settings::from_json(r#"{"telegram_answers": true, "telegram_requests": true}"#);
        assert!(reader.telegram_answers && reader.telegram_requests);
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
        assert_eq!(replaced.projects_dir(), Some(home().join("Documents").join("Видео")), "folder projects have a folder too");
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
