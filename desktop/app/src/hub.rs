//! Limits of other AI services (the Mac's `HubLimitsStore`): read 8 s after start, then every 5 minutes and on
//! «Обновить»; the same thresholds as Claude's (50 / 80 / 95 %), once per window and reset; their fullest limits in
//! the tray's hint. Settings → «Сервисы AI» → «Другие AI» switches each source and keeps the keys in the key store.

use crate::{save, strings, AppState};
use chrono::{Local, Utc};
use claudepult_core::hub::{self, History, Limit, Main, Options, Source, SOURCES};
use claudepult_core::{keys, texts};
use serde::Serialize;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

const THRESHOLDS: [u32; 3] = [50, 80, 95];

#[derive(Default)]
struct State {
    limits: Vec<Limit>,
    available: HashSet<Source>,
    history: History,
    notified: HashSet<String>,
}

#[derive(Clone, Default)]
pub struct Hub {
    state: Arc<Mutex<State>>,
    refreshing: Arc<AtomicBool>,
}

impl Hub {
    pub fn start(&self, app: AppHandle) {
        let this = self.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(8));
            loop {
                this.refresh(&app);
                std::thread::sleep(Duration::from_secs(5 * 60));
            }
        });
    }

    /// Reads every source that is found and on, one after another (a few seconds each at most).
    pub fn refresh(&self, app: &AppHandle) {
        if self.refreshing.swap(true, Ordering::SeqCst) {
            return;
        }
        let settings = app.state::<AppState>().settings.lock().unwrap().clone();
        let texts = strings(app);
        let home = dirs::home_dir().unwrap_or_default();
        let now = Utc::now();
        let mut available = HashSet::new();
        let mut limits = Vec::new();
        for source in SOURCES {
            let key = source.key_account().and_then(keys::read);
            if !hub::present(source, &home, key.is_some()) {
                continue;
            }
            available.insert(source);
            if settings.hub_disabled.iter().any(|d| d == source.id()) {
                continue;
            }
            let options = Options { gemini_quota: settings.hub_gemini_quota, gemini_daily_limit: settings.hub_gemini_daily_limit, key };
            limits.push(hub::read(source, &options, &home, now, &texts));
        }
        let mut alerts = Vec::new();
        {
            let mut state = self.state.lock().unwrap();
            let State { history, notified, .. } = &mut *state;
            for limit in &mut limits {
                history.apply(limit, now);
                alerts.extend(hub::alerts(limit, &THRESHOLDS, notified, &texts, now));
            }
            state.limits = limits;
            state.available = available;
        }
        eprintln!("other AI limits: {} read", self.state.lock().unwrap().limits.len());
        for (title, body) in alerts {
            crate::telegram::notify(app, "lim", claudepult_core::telegram::alert_html(&title, &body));
            let _ = app.notification().builder().title(title).body(body).show();
        }
        self.refreshing.store(false, Ordering::SeqCst);
        let _ = app.emit("hub-changed", ());
        app.state::<crate::limits::Limits>().update_tray(app);
    }

    /// Whose limits lead: the setting, Claude's limits and the others' (the Mac's `MainService.current`).
    pub fn main(&self, app: &AppHandle) -> Option<Main> {
        let choice = app.state::<AppState>().settings.lock().unwrap().main_service.clone();
        let claude = app.state::<crate::limits::Limits>().has_limits();
        let limits = self.state.lock().unwrap().limits.clone();
        hub::pick(&choice, claude, &limits)
    }

    /// The tray icon's percents while another service than Claude leads: its first limit, and the second if it has one.
    pub fn lead_percents(&self, app: &AppHandle) -> Option<(f64, Option<f64>)> {
        let Some(Main::Hub(source)) = self.main(app) else { return None };
        let state = self.state.lock().unwrap();
        let mut percents = state.limits.iter().find(|l| l.source == source)?.windows.iter().filter_map(|w| w.percent);
        Some((percents.next()?, percents.next()))
    }

    /// «Codex 42 % · Copilot 75 %» for the tray's hint.
    pub fn tray_line(&self) -> Option<String> {
        let state = self.state.lock().unwrap();
        let parts: Vec<String> = state.limits.iter().filter_map(|l| l.fullest().map(|p| format!("{} {}", l.source.short_title(), texts::percent(p)))).collect();
        (!parts.is_empty()).then(|| parts.join(" · "))
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowView {
    title: String,
    percent: Option<f64>,
    /// «42 %».
    value: Option<String>,
    color: Option<String>,
    detail: Option<String>,
    reset: Option<String>,
    /// «при текущем темпе хватит до ~14:30».
    forecast: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceView {
    id: &'static str,
    title: String,
    windows: Vec<WindowView>,
    error: Option<String>,
}

fn color(percent: f64) -> String {
    let [r, g, b] = claudepult_core::tray_icon::level_color(claudepult_core::usage::UsageLevel::of(percent));
    format!("#{r:02x}{g:02x}{b:02x}")
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HubView {
    /// `claude` or the leading source's id: the panel draws its limits first and Claude among «Другие AI».
    main: &'static str,
    services: Vec<ServiceView>,
}

/// The panel's «Другие AI» rows and who leads.
#[tauri::command]
pub fn hub_view(app: AppHandle) -> HubView {
    let texts = strings(&app);
    let now = Utc::now();
    let hub = app.state::<Hub>().inner().clone();
    let main = match hub.main(&app) {
        Some(Main::Hub(source)) => source.id(),
        _ => hub::CLAUDE,
    };
    let state = hub.state.lock().unwrap().limits.clone();
    let services = state
        .into_iter()
        .map(|limit| ServiceView {
            id: limit.source.id(),
            title: limit.source.title(&texts),
            error: limit.error.clone(),
            windows: limit
                .windows
                .iter()
                .map(|w| WindowView {
                    title: w.title.clone(),
                    percent: w.percent,
                    value: w.percent.map(texts::percent),
                    color: w.percent.map(color),
                    detail: w.detail.clone(),
                    reset: texts::reset_text(&texts, w.resets_at, now),
                    forecast: w.runs_out_at.map(|at| texts.format("при текущем темпе хватит до ~%@", &[&if (at - now).num_hours() < 20 { at.with_timezone(&Local).format("%H:%M").to_string() } else { texts.weekday_time(&at.with_timezone(&Local)) }])),
                })
                .collect(),
        })
        .collect();
    HubView { main, services }
}

/// «Обновить» in the panel.
#[tauri::command]
pub async fn refresh_hub(app: AppHandle) {
    let hub = app.state::<Hub>().inner().clone();
    let _ = tauri::async_runtime::spawn_blocking(move || hub.refresh(&app)).await;
}

// MARK: - Settings → «Сервисы AI» → «Другие AI»

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceRow {
    id: &'static str,
    title: String,
    requirement: String,
    enabled: bool,
    /// Its windows or its error, else «найден» / «нет ключа» / «не найден».
    status: String,
    found: bool,
    /// Read with a key: whether one is saved, and where to get one.
    needs_key: bool,
    has_key: bool,
    key_page: Option<&'static str>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HubSettings {
    keys_available: bool,
    sources: Vec<SourceRow>,
    gemini_quota: bool,
    gemini_daily_limit: u64,
}

fn status(limit: Option<&Limit>, found: bool, needs_key: bool, s: &claudepult_core::i18n::Strings) -> String {
    if let Some(limit) = limit {
        if let Some(error) = &limit.error {
            return error.clone();
        }
        return limit
            .windows
            .iter()
            .map(|w| match w.percent {
                Some(p) => format!("{} {}", w.title, texts::percent(p)),
                None => [Some(w.title.clone()), w.detail.clone()].into_iter().flatten().collect::<Vec<_>>().join(" "),
            })
            .collect::<Vec<_>>()
            .join(" · ");
    }
    if found {
        s.t("найден")
    } else if needs_key {
        s.t("нет ключа")
    } else {
        s.t("не найден")
    }
    .to_owned()
}

fn settings_view(app: &AppHandle) -> HubSettings {
    let texts = strings(app);
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let hub = app.state::<Hub>().inner().clone();
    let (limits, available) = {
        let state = hub.state.lock().unwrap();
        (state.limits.clone(), state.available.clone())
    };
    let sources = SOURCES
        .into_iter()
        .map(|source| {
            let found = available.contains(&source);
            let needs_key = source.key_account().is_some();
            SourceRow {
                id: source.id(),
                title: source.title(&texts),
                requirement: texts.format("Нужно: %@", &[&source.requirement(&texts)]),
                enabled: !settings.hub_disabled.iter().any(|d| d == source.id()),
                status: status(limits.iter().find(|l| l.source == source), found, needs_key, &texts),
                found,
                needs_key,
                has_key: source.key_account().is_some_and(|a| keys::read(a).is_some()),
                key_page: source.key_page(),
            }
        })
        .collect();
    HubSettings { keys_available: keys::available(), sources, gemini_quota: settings.hub_gemini_quota, gemini_daily_limit: settings.hub_gemini_daily_limit }
}

#[tauri::command]
pub fn hub_settings(app: AppHandle) -> HubSettings {
    settings_view(&app)
}

fn source(id: &str) -> Result<Source, String> {
    Source::parse(id).ok_or_else(|| format!("{id}: no such source"))
}

/// A setting changed: written, then everything read again.
async fn after_change(app: AppHandle) -> HubSettings {
    refresh_hub(app.clone()).await;
    settings_view(&app)
}

#[tauri::command]
pub async fn set_hub_enabled(app: AppHandle, id: String, on: bool) -> Result<HubSettings, String> {
    let source = source(&id)?;
    save(&app, |settings| {
        settings.hub_disabled.retain(|d| d != source.id());
        if !on {
            settings.hub_disabled.push(source.id().to_owned());
        }
    });
    Ok(after_change(app).await)
}

#[tauri::command]
pub async fn save_hub_key(app: AppHandle, id: String, key: String) -> Result<HubSettings, String> {
    let account = source(&id)?.key_account().ok_or("no key for this source")?;
    keys::save(account, key.trim()).map_err(|e| e.to_string())?;
    eprintln!("hub key saved: {account}");
    Ok(after_change(app).await)
}

#[tauri::command]
pub async fn delete_hub_key(app: AppHandle, id: String) -> Result<HubSettings, String> {
    let account = source(&id)?.key_account().ok_or("no key for this source")?;
    keys::delete(account).map_err(|e| e.to_string())?;
    Ok(after_change(app).await)
}

#[tauri::command]
pub async fn set_gemini_options(app: AppHandle, quota: bool, daily_limit: u64) -> HubSettings {
    save(&app, |settings| {
        settings.hub_gemini_quota = quota;
        if [250, 1000, 1500, 2000].contains(&daily_limit) {
            settings.hub_gemini_daily_limit = daily_limit;
        }
    });
    after_change(app).await
}

#[derive(Serialize)]
pub struct Choice {
    id: String,
    title: String,
}

#[derive(Serialize)]
pub struct MainChoice {
    /// `""` automatic, `claude` or a source's id.
    choice: String,
    /// The services with limits now, and the saved one.
    choices: Vec<Choice>,
}

#[tauri::command]
pub fn main_service(app: AppHandle) -> MainChoice {
    let texts = strings(&app);
    let choice = app.state::<AppState>().settings.lock().unwrap().main_service.clone();
    let limits = app.state::<Hub>().inner().state.lock().unwrap().limits.clone();
    let choices = hub::choices(&choice, &limits).into_iter().map(|s| Choice { id: s.id().to_owned(), title: s.title(&texts) }).collect();
    MainChoice { choice, choices }
}

/// «Главный сервис»: the panel and the tray icon follow at once.
#[tauri::command]
pub fn set_main_service(app: AppHandle, choice: String) -> MainChoice {
    let valid = choice == hub::AUTO || choice == hub::CLAUDE || Source::parse(&choice).is_some();
    if valid {
        save(&app, |settings| settings.main_service = choice);
    }
    let _ = app.emit("hub-changed", ());
    app.state::<crate::limits::Limits>().update_tray(&app);
    main_service(app)
}

#[tauri::command]
pub fn open_hub_key_page(id: String) -> Result<(), String> {
    let page = source(&id)?.key_page().ok_or("no page")?;
    crate::projects::open_with_system(page.as_ref())
}
