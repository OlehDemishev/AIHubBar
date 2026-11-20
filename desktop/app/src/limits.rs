//! Stage 2 «Лимиты» (docs/specs/SPEC-windows.md §4.2): the session and week limits on a background thread — every 2 minutes
//! while the session grows, else every 5, a pause after 429 — with the forecast, notifications at 50 / 80 / 95 %,
//! `usage.json` for `report.py`, and the tray icon drawn from the first two limits in the chosen style, with the summary in its hint.

use crate::strings;
use chrono::{DateTime, Duration, Utc};
use claudepult_core::texts;
use claudepult_core::token_usage;
use claudepult_core::tray_icon;
use claudepult_core::usage::{self, UsageError, UsageForecast, UsagePoint, UsageSnapshot};
use claudepult_core::{i18n::Strings, paths};
use serde::Serialize;
use std::collections::BTreeSet;
use std::sync::{Arc, Condvar, Mutex};
use tauri::image::Image;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

/// «Уведомлять на, %» from Settings; 50 / 80 / 95 until the person sets their own.
pub(crate) fn thresholds(app: &AppHandle) -> Vec<u32> {
    app.state::<crate::AppState>().settings.lock().unwrap().limit_thresholds()
}
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
    /// The last try to renew Claude Code's sign-in.
    last_renewal: Option<DateTime<Utc>>,
    /// «Расход по проектам»: the journals' records and when they were last read.
    spend: Option<(Vec<token_usage::TokenRecord>, DateTime<Utc>)>,
}

#[derive(Clone)]
pub struct Limits {
    state: Arc<Mutex<State>>,
    scanner: Arc<Mutex<token_usage::Scanner>>,
    wake: Arc<(Mutex<bool>, Condvar)>,
}

fn notified_file() -> std::path::PathBuf {
    paths::data_dir().join("usage-notified.json")
}

/// The session's readings for the forecast, kept across restarts (the Mac's file and format).
fn history_file() -> std::path::PathBuf {
    paths::data_dir().join("usage-history.json")
}

impl Limits {
    pub fn new() -> Self {
        let notified = std::fs::read_to_string(notified_file())
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default();
        let history = std::fs::read_to_string(history_file()).map(|text| usage::parse_history(&text, Utc::now())).unwrap_or_default();
        Limits { state: Arc::new(Mutex::new(State { notified, history, ..State::default() })), scanner: Arc::default(), wake: Arc::default() }
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
        let read = || {
            usage::read_credentials(&paths::claude_dir(), now)
                .and_then(|credentials| usage::fetch(&credentials, now))
                .and_then(|body| UsageSnapshot::decode(&body, now).ok_or(UsageError::BadResponse))
        };
        let mut result = read();
        // The sign-in is out of date (`claude` has not run lately): renew it through `claude` and ask once more.
        if result == Err(UsageError::Expired) && app.state::<crate::AppState>().settings.lock().unwrap().renew_claude_login {
            let last = self.state.lock().unwrap().last_renewal;
            if usage::should_renew(last, now) {
                self.state.lock().unwrap().last_renewal = Some(now);
                let renewed = claudepult_core::launch::find_claude().is_some_and(|claude| usage::renew_sign_in(&claude));
                eprintln!("Claude Code sign-in renewal: {}", if renewed { "done" } else { "failed" });
                if renewed {
                    result = read();
                }
            }
        }
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
                        state.history.retain(|p| now - p.date < Duration::hours(usage::HISTORY_HOURS));
                        if let Err(error) = std::fs::write(history_file(), usage::history_json(&state.history)) {
                            eprintln!("usage history not saved: {error}");
                        }
                    }
                    let previous = state.snapshot.take();
                    let mut notified = std::mem::take(&mut state.notified);
                    let alerts = usage::evaluate_alerts(previous.as_ref(), &snapshot, &thresholds(app), &mut notified);
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
                crate::telegram::notify(app, "lim", claudepult_core::telegram::alert_html(&title, &body));
                let _ = app.notification().builder().title(title).body(body).show();
            }
        }
        self.update_tray(app);
        let _ = app.emit("limits-changed", ());
    }

    /// Claude has limits to show (signed in and answered): «Главный сервис» goes to it by default.
    pub fn has_limits(&self) -> bool {
        self.state.lock().unwrap().snapshot.as_ref().is_some_and(|s| s.session().is_some() || s.week().is_some())
    }

    /// The main service's first two limits (Claude's session and week by default) drawn in the chosen style, and the
    /// summary in the hint; the app's own icon until the first answer.
    pub fn update_tray(&self, app: &AppHandle) {
        // Read before this store's lock: the main service asks it whether Claude has limits.
        let lead = app.state::<crate::hub::Hub>().lead_percents(app);
        let style = tray_icon::Style::saved(&app.state::<crate::AppState>().settings.lock().unwrap().tray_style);
        // An orange dot while a session waits for an answer (stage 3); else a red one while a project needs attention.
        let waiting = app.state::<crate::sessions::Sessions>().attention.load(std::sync::atomic::Ordering::Relaxed);
        let (count, red) = app.state::<crate::projects::Projects>().counts();
        let dot = if waiting { Some(tray_icon::ORANGE) } else if red > 0 { Some(tray_icon::RED) } else { None };
        let (session, tooltip) = {
            let state = self.state.lock().unwrap();
            let texts = strings(app);
            let session = lead.or_else(|| {
                let snapshot = state.snapshot.as_ref()?;
                Some((snapshot.session()?.utilization, snapshot.week().map(|w| w.utilization)))
            });
            let mut tooltip = texts::tray_tooltip(&texts, state.snapshot.as_ref(), state.error.as_ref(), Utc::now());
            if count > 0 {
                tooltip += "\n";
                tooltip += &texts.format("Проектов: %lld · с проблемами: %lld", &[&count.to_string(), &red.to_string()]);
            }
            if let Some(line) = app.state::<crate::hub::Hub>().tray_line() {
                tooltip += "\n";
                tooltip += &line;
            }
            if let Some(line) = app.state::<crate::resources::Resources>().tray_line(&texts) {
                tooltip += "\n";
                tooltip += &line;
            }
            if let Some(line) = app.state::<crate::keep_awake::KeepAwake>().tray_line(app) {
                tooltip += "\n";
                tooltip += &line;
            }
            (session, if cfg!(windows) { texts::fit_tooltip(&tooltip, 127) } else { tooltip })
        };
        let app_for_tray = app.clone();
        let _ = app.run_on_main_thread(move || {
            let Some(tray) = app_for_tray.tray_by_id(crate::TRAY_ID) else { return };
            let _ = tray.set_tooltip(Some(tooltip));
            if let Some((first, second)) = session {
                let pixels = tray_icon::draw(style, ICON_SIZE, first, second, dot);
                let _ = tray.set_icon(Some(Image::new_owned(pixels, ICON_SIZE, ICON_SIZE)));
            }
        });
    }

    /// «Расход по проектам» for the panel: reads what is new in Claude Code's journals when the last read is older
    /// than a minute, and counts the session, today and the week.
    pub fn spend(&self, projects_dir: &std::path::Path, texts: &Strings) -> SpendView {
        let now = Utc::now();
        let fresh = self.state.lock().unwrap().spend.as_ref().is_some_and(|(_, at)| now - *at < Duration::minutes(1));
        if !fresh {
            let records = self.scanner.lock().unwrap().scan(&paths::claude_dir().join("projects"), 8, now - Duration::days(8), now);
            self.state.lock().unwrap().spend = Some((records, now));
        }
        let state = self.state.lock().unwrap();
        let records = state.spend.as_ref().map(|(records, _)| records.as_slice()).unwrap_or(&[]);
        let snapshot = state.snapshot.as_ref();
        let midnight = chrono::Local::now().date_naive().and_hms_opt(0, 0, 0).and_then(|t| t.and_local_timezone(chrono::Local).earliest()).map(|t| t.with_timezone(&Utc)).unwrap_or(now - Duration::hours(24));
        let starts = [
            ("session", texts.t("Сессия"), snapshot.and_then(|s| s.session()).and_then(|w| w.resets_at).map(|at| at - Duration::hours(5)).unwrap_or(now - Duration::hours(5))),
            ("today", texts.t("Сегодня"), midnight),
            ("week", texts.t("Неделя"), snapshot.and_then(|s| s.week()).and_then(|w| w.resets_at).map(|at| at - Duration::days(7)).unwrap_or(now - Duration::days(7))),
        ];
        let other = texts.t("Другое");
        SpendView {
            periods: starts
                .into_iter()
                .map(|(id, title, since)| {
                    let breakdown = token_usage::Breakdown::make(records, since, projects_dir, other);
                    let percent = |share: f64| (share * 100.0).round() as i64;
                    SpendPeriod {
                        id,
                        title: title.to_owned(),
                        rows: breakdown.projects.iter().take(6).map(|row| SpendRow { name: row.name.clone(), tokens: token_usage::tokens_text(row.tokens, texts), percent: format!("{} %", percent(row.share)) }).collect(),
                        top: breakdown.top_session.as_ref().map(|top| texts.format("Самая затратная сессия: %@ — %lld %% (%@ токенов)", &[&top.name, &percent(top.share).to_string(), &token_usage::tokens_text(top.tokens, texts)])),
                    }
                })
                .collect(),
        }
    }

    /// Claude's session (percent, «сброс через …») and week, for the Telegram bot's 🏠.
    pub fn brief(&self, texts: &Strings) -> (Option<(f64, Option<String>)>, Option<f64>) {
        let state = self.state.lock().unwrap();
        let snapshot = state.snapshot.as_ref();
        let session = snapshot.and_then(|s| s.session()).map(|w| (w.utilization, texts::reset_text(texts, w.resets_at, Utc::now())));
        (session, snapshot.and_then(|s| s.week()).map(|w| w.utilization))
    }

    /// Claude's limits for the Telegram bot's ⏳: the session, the week, the models' weeks.
    pub fn telegram_service(&self, texts: &Strings) -> claudepult_core::telegram::LimitService {
        use claudepult_core::telegram::{LimitService, LimitWindow};
        let state = self.state.lock().unwrap();
        let now = Utc::now();
        let window = |w: &usage::UsageWindow| LimitWindow { title: texts::window_title(texts, w), percent: Some(w.utilization), reset: texts::reset_text(texts, w.resets_at, now), ..LimitWindow::default() };
        let windows = match state.snapshot.as_ref() {
            Some(snapshot) => snapshot.session().into_iter().chain(snapshot.week()).chain(snapshot.shown_other_windows()).map(window).collect(),
            None => Vec::new(),
        };
        LimitService { title: "Claude".to_owned(), windows, error: None }
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

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpendRow {
    name: String,
    /// «12,3 млн».
    tokens: String,
    percent: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpendPeriod {
    id: &'static str,
    title: String,
    rows: Vec<SpendRow>,
    top: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpendView {
    periods: Vec<SpendPeriod>,
}

/// «Расход по проектам»: counted off the panel's thread — the first read goes through a week of journals.
#[tauri::command]
pub async fn spend_view(app: AppHandle) -> Result<SpendView, String> {
    let limits = app.state::<Limits>().inner().clone();
    let texts = strings(&app);
    let root = crate::profiles::projects_root(&app);
    tauri::async_runtime::spawn_blocking(move || limits.spend(&root, &texts)).await.map_err(|e| e.to_string())
}

/// «Продлевать вход Claude Code сам».
#[tauri::command]
pub fn renew_claude_login(app: AppHandle) -> bool {
    app.state::<crate::AppState>().settings.lock().unwrap().renew_claude_login
}

#[tauri::command]
pub fn set_renew_claude_login(app: AppHandle, enabled: bool) {
    crate::save(&app, |settings| settings.renew_claude_login = enabled);
    if enabled {
        app.state::<Limits>().refresh_now();
    }
}

/// «Уведомлять на, %» as text: «50, 80, 95».
#[tauri::command]
pub fn limit_thresholds(app: AppHandle) -> String {
    thresholds(&app).iter().map(u32::to_string).collect::<Vec<_>>().join(", ")
}

/// Saves what is valid in `text` (whole percents 1–100) and answers with the thresholds now in force; text with
/// nothing valid keeps the old ones.
#[tauri::command]
pub fn set_limit_thresholds(app: AppHandle, text: String) -> String {
    let values = claudepult_core::settings::parse_thresholds(&text);
    if !values.is_empty() {
        crate::save(&app, |settings| settings.set_limit_thresholds(&values));
        eprintln!("limit thresholds: {values:?}");
    }
    limit_thresholds(app)
}

#[tauri::command]
pub fn limits_view(app: AppHandle) -> LimitsView {
    app.state::<Limits>().view(&strings(&app))
}

#[tauri::command]
pub fn refresh_limits(app: AppHandle) {
    app.state::<Limits>().refresh_now();
}

/// A style of the tray icon for Settings: its name and a sample drawn with the same pixels as the icon.
#[derive(Serialize)]
pub struct TrayStyleView {
    id: &'static str,
    title: String,
    /// `size`×`size` RGBA of 62 % and 31 %.
    pixels: Vec<u8>,
}

#[derive(Serialize)]
pub struct TrayStyles {
    current: &'static str,
    size: u32,
    styles: Vec<TrayStyleView>,
}

fn style_title(texts: &Strings, style: tray_icon::Style) -> String {
    let title = match style {
        tray_icon::Style::Ring => texts.t("Одно кольцо"),
        tray_icon::Style::Rings => texts.t("Кольцо в кольце"),
        tray_icon::Style::Columns => texts.t("Два столбика"),
        tray_icon::Style::Rows => texts.t("Две полоски"),
        tray_icon::Style::Number => texts.t("Число и полоска"),
        tray_icon::Style::Pie => texts.t("Кольцо и сектор"),
        tray_icon::Style::Arcs => texts.t("Две дуги"),
    };
    title.to_owned()
}

/// Settings → «Сервисы AI» → «Значок в трее»: the styles with their samples, and the chosen one.
#[tauri::command]
pub fn tray_styles(app: AppHandle) -> TrayStyles {
    let texts = strings(&app);
    let current = tray_icon::Style::saved(&app.state::<crate::AppState>().settings.lock().unwrap().tray_style);
    let styles = tray_icon::Style::ALL
        .into_iter()
        .map(|style| TrayStyleView { id: style.id(), title: style_title(&texts, style), pixels: tray_icon::draw(style, ICON_SIZE, 62.0, Some(31.0), None) })
        .collect();
    TrayStyles { current: current.id(), size: ICON_SIZE, styles }
}

/// The icon is redrawn at once.
#[tauri::command]
pub fn set_tray_style(app: AppHandle, style: String) -> TrayStyles {
    if let Some(style) = tray_icon::Style::parse(&style) {
        crate::save(&app, |settings| settings.tray_style = style.id().to_owned());
        app.state::<Limits>().update_tray(&app);
    }
    tray_styles(app)
}
