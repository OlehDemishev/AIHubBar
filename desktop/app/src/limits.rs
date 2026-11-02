//! Stage 2 «Лимиты» (docs/SPEC-windows.md §4.2): the session and week limits on a background thread — every 2 minutes
//! while the session grows, else every 5, a pause after 429 — with the forecast, notifications at 50 / 80 / 95 %,
//! `usage.json` for `report.py`, and the tray icon drawn as a ring with the summary in its hint.

use crate::strings;
use chrono::{DateTime, Duration, Utc};
use claudepult_core::texts;
use claudepult_core::tray_icon;
use claudepult_core::usage::{self, UsageError, UsageForecast, UsagePoint, UsageSnapshot};
use claudepult_core::{i18n::Strings, paths};
use serde::Serialize;
use std::collections::BTreeSet;
use std::sync::{Arc, Condvar, Mutex};
use tauri::image::Image;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

/// The thresholds the Mac app starts with (Settings → «Лимиты» there; a setting here comes later).
const THRESHOLDS: [u32; 3] = [50, 80, 95];
const ICON_SIZE: u32 = 32;

#[derive(Default)]
struct State {
    snapshot: Option<UsageSnapshot>,
    error: Option<UsageError>,
    history: Vec<UsagePoint>,
    strikes: u32,
    paused_until: Option<DateTime<Utc>>,
    notified: BTreeSet<String>,
    last_growth: Option<DateTime<Utc>>,
}

#[derive(Clone)]
pub struct Limits {
    state: Arc<Mutex<State>>,
    wake: Arc<(Mutex<bool>, Condvar)>,
}

fn notified_file() -> std::path::PathBuf {
    paths::data_dir().join("usage-notified.json")
}

impl Limits {
    pub fn new() -> Self {
        let notified = std::fs::read_to_string(notified_file())
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default();
        Limits { state: Arc::new(Mutex::new(State { notified, ..State::default() })), wake: Arc::default() }
    }

    /// Starts the background thread; the first request goes out at once.
    pub fn start(&self, app: AppHandle) {
        let limits = self.clone();
        std::thread::spawn(move || loop {
            limits.refresh(&app);
            let wait = {
                let state = limits.state.lock().unwrap();
                let grew = state.last_growth.is_some_and(|at| Utc::now() - at < Duration::minutes(10));
                usage::poll_seconds(grew)
            };
            let (lock, condvar) = &*limits.wake;
            let woken = lock.lock().unwrap();
            let (mut woken, _) = condvar.wait_timeout_while(woken, std::time::Duration::from_secs(wait), |w| !*w).unwrap();
            *woken = false;
        });
    }

    /// «Обновить» in the panel: the next request now (still not during a 429 pause).
    pub fn refresh_now(&self) {
        let (lock, condvar) = &*self.wake;
        *lock.lock().unwrap() = true;
        condvar.notify_one();
    }

    fn refresh(&self, app: &AppHandle) {
        let now = Utc::now();
        if self.state.lock().unwrap().paused_until.is_some_and(|until| until > now) {
            return;
        }
        let result = usage::read_credentials(&paths::claude_dir(), now)
            .and_then(|credentials| usage::fetch(&credentials, now))
            .and_then(|body| UsageSnapshot::decode(&body, now).ok_or(UsageError::BadResponse));
        let alerts = {
            let mut state = self.state.lock().unwrap();
            match result {
                Ok(snapshot) => {
                    state.strikes = 0;
                    state.paused_until = None;
                    state.error = None;
                    let before = state.snapshot.as_ref().and_then(|s| s.session()).map(|w| w.utilization);
                    if let (Some(before), Some(now_value)) = (before, snapshot.session().map(|w| w.utilization)) {
                        if now_value > before {
                            state.last_growth = Some(now);
                        }
                    }
                    if let Some(session) = snapshot.session() {
                        state.history.push(UsagePoint { date: now, session: session.utilization, session_resets_at: session.resets_at });
                        state.history.retain(|p| now - p.date < Duration::hours(2));
                    }
                    let previous = state.snapshot.take();
                    let mut notified = std::mem::take(&mut state.notified);
                    let alerts = usage::evaluate_alerts(previous.as_ref(), &snapshot, &THRESHOLDS, &mut notified);
                    state.notified = notified;
                    if !alerts.is_empty() {
                        let _ = std::fs::write(notified_file(), serde_json::to_string(&state.notified).unwrap_or_default());
                    }
                    write_usage_file(&snapshot);
                    state.snapshot = Some(snapshot);
                    alerts
                }
                Err(UsageError::RateLimited(retry_after)) => {
                    state.strikes += 1;
                    let pause = usage::backoff_seconds(state.strikes, retry_after);
                    state.paused_until = Some(now + Duration::seconds(pause as i64));
                    eprintln!("usage: HTTP 429, pause {} min", pause / 60);
                    state.error = Some(UsageError::RateLimited(retry_after));
                    Vec::new()
                }
                Err(error) => {
                    state.error = Some(error);
                    Vec::new()
                }
            }
        };
        let texts = strings(app);
        if let Some(snapshot) = self.state.lock().unwrap().snapshot.clone() {
            for alert in &alerts {
                let (title, body) = texts::alert_text(&texts, alert, &snapshot, now);
                let _ = app.notification().builder().title(title).body(body).show();
            }
        }
        self.update_tray(app);
        let _ = app.emit("limits-changed", ());
    }

    /// The ring of the session limit and the summary in the hint; the app's own icon until the first answer.
    pub fn update_tray(&self, app: &AppHandle) {
        let (session, tooltip) = {
            let state = self.state.lock().unwrap();
            let texts = strings(app);
            let session = state.snapshot.as_ref().and_then(|s| s.session()).map(|w| w.utilization);
            (session, texts::tray_tooltip(&texts, state.snapshot.as_ref(), state.error.as_ref(), Utc::now()))
        };
        let app_for_tray = app.clone();
        let _ = app.run_on_main_thread(move || {
            let Some(tray) = app_for_tray.tray_by_id(crate::TRAY_ID) else { return };
            let _ = tray.set_tooltip(Some(tooltip));
            if let Some(percent) = session {
                let pixels = tray_icon::ring(ICON_SIZE, percent, false);
                let _ = tray.set_icon(Some(Image::new_owned(pixels, ICON_SIZE, ICON_SIZE)));
            }
        });
    }

    pub fn view(&self, texts: &Strings) -> LimitsView {
        let state = self.state.lock().unwrap();
        let now = Utc::now();
        let ring = |window: &usage::UsageWindow| {
            let [r, g, b] = tray_icon::level_color(usage::UsageLevel::of(window.utilization));
            RingView {
                title: texts::window_title(texts, window),
                percent: texts::percent(window.utilization),
                fraction: (window.utilization / 100.0).clamp(0.0, 1.0),
                color: format!("#{r:02x}{g:02x}{b:02x}"),
                reset: texts::reset_text(texts, window.resets_at, now),
            }
        };
        let snapshot = state.snapshot.as_ref();
        LimitsView {
            session: snapshot.and_then(|s| s.session()).map(ring),
            week: snapshot.and_then(|s| s.week()).map(ring),
            others: snapshot.map(|s| s.shown_other_windows().into_iter().map(ring).collect()).unwrap_or_default(),
            forecast: texts::forecast_text(
                texts,
                &UsageForecast::make(&state.history, snapshot.and_then(|s| s.session()), now),
            ),
            error: state.error.as_ref().map(|e| texts::error_text(texts, e)),
        }
    }
}

fn write_usage_file(snapshot: &UsageSnapshot) {
    let path = paths::data_dir().join("usage.json");
    let _ = std::fs::create_dir_all(paths::data_dir());
    let tmp = path.with_extension("json.tmp");
    let text = serde_json::to_string_pretty(&usage::usage_file_json(snapshot)).unwrap_or_default();
    if std::fs::write(&tmp, text).is_ok() {
        let _ = std::fs::rename(&tmp, &path);
    }
}

#[derive(Serialize)]
pub struct RingView {
    title: String,
    percent: String,
    fraction: f64,
    color: String,
    reset: Option<String>,
}

#[derive(Serialize)]
pub struct LimitsView {
    session: Option<RingView>,
    week: Option<RingView>,
    others: Vec<RingView>,
    forecast: Option<String>,
    error: Option<String>,
}

#[tauri::command]
pub fn limits_view(app: AppHandle) -> LimitsView {
    app.state::<Limits>().view(&strings(&app))
}

#[tauri::command]
pub fn refresh_limits(app: AppHandle) {
    app.state::<Limits>().refresh_now();
}
