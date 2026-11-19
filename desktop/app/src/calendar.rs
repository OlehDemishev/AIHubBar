//! Stage 5 «Ближайшее» (the Mac's `CalendarStore` and `UpcomingView`): the dates of every profile whose calendar is
//! on, read at start, every 5 minutes, when the panel opens on a list older than a minute and after a card changes;
//! the next 7 days in the panel, and a reminder before each date (Settings: «Напоминать»).

use crate::{language, strings, AppState};
use claudepult_core::calendar::{self, Entry};
use claudepult_core::paths;
use serde::Serialize;
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

const EVERY: Duration = Duration::from_secs(5 * 60);
const STALE_AFTER: Duration = Duration::from_secs(60);

#[derive(Default)]
struct State {
    entries: Vec<Entry>,
    updated: Option<Instant>,
}

#[derive(Clone, Default)]
pub struct Calendar {
    state: Arc<Mutex<State>>,
    wake: Arc<(Mutex<bool>, Condvar)>,
}

fn reminded_path() -> PathBuf {
    paths::data_dir().join("calendar-reminded.json")
}

impl Calendar {
    pub fn start(&self, app: AppHandle) {
        let this = self.clone();
        std::thread::spawn(move || loop {
            this.refresh(&app);
            let (lock, signal) = &*this.wake;
            let asked = lock.lock().unwrap();
            let (mut asked, _) = signal.wait_timeout_while(asked, EVERY, |asked| !*asked).unwrap();
            *asked = false;
        });
    }

    /// Read again now, on the calendar's thread.
    pub fn ask(&self) {
        let (lock, signal) = &*self.wake;
        *lock.lock().unwrap() = true;
        signal.notify_one();
    }

    fn refresh_if_stale(&self) {
        if self.state.lock().unwrap().updated.is_none_or(|at| at.elapsed() >= STALE_AFTER) {
            self.ask();
        }
    }

    fn refresh(&self, app: &AppHandle) {
        let settings = app.state::<AppState>().settings.lock().unwrap().clone();
        let home = dirs::home_dir().unwrap_or_default();
        let texts = strings(app);
        let entries = calendar::all(&settings.profiles, &home, language(app), &texts);
        if !entries.is_empty() || self.state.lock().unwrap().updated.is_none() {
            eprintln!("calendar: {} dates", entries.len());
        }
        *self.state.lock().unwrap() = State { entries: entries.clone(), updated: Some(Instant::now()) };
        let _ = app.emit("calendar-changed", ());
        self.remind(app, &entries, &settings.calendar_reminder_hours);
    }

    /// Each date once per reminder offset, when that moment has come and the date is still ahead.
    fn remind(&self, app: &AppHandle, entries: &[Entry], hours: &[i64]) {
        let mut reminded: HashSet<String> = std::fs::read_to_string(reminded_path()).ok().and_then(|t| serde_json::from_str::<Vec<String>>(&t).ok()).unwrap_or_default().into_iter().collect();
        let now = chrono::Local::now().naive_local();
        let due = calendar::due(entries, hours, &reminded, now);
        if due.is_empty() {
            return;
        }
        let texts = strings(app);
        for (entry, key) in due {
            reminded.insert(key);
            let when = calendar::relative(entry.date, entry.has_time, now, &texts);
            let body = [Some(when), entry.detail.clone(), Some(entry.profile.clone())].into_iter().flatten().filter(|t| !t.is_empty()).collect::<Vec<_>>().join(" · ");
            eprintln!("calendar reminder: {} {}", entry.kind.key(), entry.title);
            let _ = app.notification().builder().title(format!("{}: {}", entry.kind.title(&texts), entry.title)).body(body).show();
        }
        let mut keys: Vec<String> = reminded.into_iter().collect();
        keys.sort();
        let keep = keys.len().saturating_sub(2000);
        if let Ok(text) = serde_json::to_string(&keys[keep..]) {
            let _ = std::fs::create_dir_all(paths::data_dir());
            let _ = std::fs::write(reminded_path(), text);
        }
    }

    /// Whether any profile has its calendar on: the panel shows «Ближайшее» then.
    fn is_active(app: &AppHandle) -> bool {
        app.state::<AppState>().settings.lock().unwrap().profiles.iter().any(|p| p.calendar() != "off" && p.source().is_folders())
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpcomingRow {
    id: String,
    /// `deadline`, `publish` or `plan`.
    kind: &'static str,
    title: String,
    detail: Option<String>,
    when: String,
    overdue: bool,
    /// «Дедлайн · Видео — открыть».
    hint: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpcomingView {
    active: bool,
    rows: Vec<UpcomingRow>,
    /// «и ещё 3…».
    more: Option<String>,
}

const SHOWN: usize = 8;

#[tauri::command]
pub fn upcoming_view(app: AppHandle) -> UpcomingView {
    let calendar = app.state::<Calendar>();
    calendar.refresh_if_stale();
    let texts = strings(&app);
    let now = chrono::Local::now().naive_local();
    let entries = calendar::upcoming(&calendar.state.lock().unwrap().entries, 7, now);
    let rows = entries
        .iter()
        .take(SHOWN)
        .map(|entry| UpcomingRow {
            id: entry.id(),
            kind: entry.kind.key(),
            title: entry.title.clone(),
            detail: entry.detail.clone().filter(|d| !d.is_empty()),
            when: calendar::relative(entry.date, entry.has_time, now, &texts),
            overdue: entry.is_overdue(now),
            hint: format!("{} · {}", entry.kind.title(&texts), entry.profile),
        })
        .collect();
    let more = (entries.len() > SHOWN).then(|| texts.format("и ещё %lld…", &[&(entries.len() - SHOWN).to_string()]));
    UpcomingView { active: Calendar::is_active(&app), rows, more }
}

/// A row of «Ближайшее»: its project folder, the plan row's file or the plan — only what the calendar read.
#[tauri::command]
pub fn open_upcoming(app: AppHandle, id: String) -> Result<(), String> {
    let path = app.state::<Calendar>().state.lock().unwrap().entries.iter().find(|e| e.id() == id).map(|e| e.open_path.clone()).ok_or("unknown date")?;
    crate::projects::open_with_system(path.as_os_str())
}

/// «Напоминать»: the hours before a date (none — «не напоминать»), as the Mac offers them.
#[tauri::command]
pub fn reminder_hours(app: AppHandle) -> Vec<i64> {
    app.state::<AppState>().settings.lock().unwrap().calendar_reminder_hours.clone()
}

#[tauri::command]
pub fn set_reminder_hours(app: AppHandle, hours: Vec<i64>) {
    crate::save(&app, |settings| settings.calendar_reminder_hours = hours.into_iter().filter(|h| (1..=24 * 14).contains(h)).collect());
}

/// The current profile's calendar: `off`, `dates`, `contentPlan`.
#[tauri::command]
pub fn set_profile_calendar(app: AppHandle, mode: String) {
    crate::save(&app, |settings| {
        if let Some(id) = settings.current().map(|p| p.id.clone()) {
            if let Some(profile) = settings.profiles.iter_mut().find(|p| p.id == id) {
                profile.set_calendar(&mode);
            }
        }
    });
    app.state::<Calendar>().ask();
    let _ = app.emit("profiles-changed", ());
}

// MARK: - The «Календарь» window

/// Opens (or brings forward) the month view.
#[tauri::command]
pub fn open_calendar(app: AppHandle) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
    if let Some(window) = app.get_webview_window("calendar") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    let title = format!("{} — {}", claudepult_core::APP_NAME, strings(&app).t("Календарь"));
    // Windows' file drop handler would take the page's own drag and drop away: dates are dragged between days here.
    crate::off_main_thread(move || {
        let _ = tauri::WebviewWindowBuilder::new(&app, "calendar", tauri::WebviewUrl::App("calendar.html".into()))
            .title(title)
            .inner_size(900.0, 640.0)
            .min_inner_size(700.0, 480.0)
            .disable_drag_drop_handler()
            .center()
            .build();
    });
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarEntryRow {
    id: String,
    /// `2026-11-20`.
    day: String,
    /// `18:00` when the date has a time.
    time: Option<String>,
    kind: &'static str,
    title: String,
    /// «Дедлайн · Ролик · YouTube · Видео».
    hint: String,
    overdue: bool,
    /// The profile's place among the profiles: its colour.
    color: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectChoice {
    path: String,
    name: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarProfile {
    id: String,
    name: String,
    /// Its calendar has a content plan: «Запись контент-плана» can be added.
    plan: bool,
    projects: Vec<ProjectChoice>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarWindowView {
    active: bool,
    entries: Vec<CalendarEntryRow>,
    profiles: Vec<CalendarProfile>,
    current_profile: Option<String>,
}

/// Every date (or the current profile's), for the page to lay out by month or week.
#[tauri::command]
pub fn calendar_view(app: AppHandle, current_only: bool) -> CalendarWindowView {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let texts = strings(&app);
    let now = chrono::Local::now().naive_local();
    let current = settings.current().map(|p| p.id.clone());
    let calendar = app.state::<Calendar>();
    let entries = calendar.state.lock().unwrap().entries.clone();
    let color = |id: &str| settings.profiles.iter().position(|p| p.id == id).unwrap_or(0);
    let rows = entries
        .iter()
        .filter(|e| !current_only || Some(&e.profile_id) == current.as_ref())
        .map(|e| CalendarEntryRow {
            id: e.id(),
            day: e.date.format("%Y-%m-%d").to_string(),
            time: e.has_time.then(|| e.date.format("%H:%M").to_string()),
            kind: e.kind.key(),
            title: e.title.clone(),
            hint: [Some(e.kind.title(&texts)), Some(e.title.clone()), e.detail.clone(), Some(e.profile.clone())].into_iter().flatten().filter(|t| !t.is_empty()).collect::<Vec<_>>().join(" · "),
            overdue: e.is_overdue(now) && e.kind == calendar::Kind::Deadline,
            color: color(&e.profile_id),
        })
        .collect();
    let home = dirs::home_dir().unwrap_or_default();
    let profiles = settings
        .profiles
        .iter()
        .filter(|p| p.calendar() != "off" && p.source().is_folders())
        .map(|p| CalendarProfile {
            id: p.id.clone(),
            name: p.name.clone(),
            plan: p.calendar() == "contentPlan",
            projects: claudepult_core::folders::scan(&p.source(), &home, &[], language(&app))
                .into_iter()
                .map(|f| ProjectChoice { path: f.path.to_string_lossy().into_owned(), name: f.name })
                .collect(),
        })
        .collect();
    CalendarWindowView { active: Calendar::is_active(&app), entries: rows, profiles, current_profile: current }
}

/// «Перечитать файлы».
#[tauri::command]
pub async fn reread_calendar(app: AppHandle) {
    let handle = app.clone();
    let _ = tauri::async_runtime::spawn_blocking(move || handle.state::<Calendar>().refresh(&handle)).await;
}

fn day(text: &str) -> Result<chrono::NaiveDate, String> {
    chrono::NaiveDate::parse_from_str(text, "%Y-%m-%d").map_err(|e| e.to_string())
}

/// A date dragged to another day: written into its card or plan row, then everything is read again.
#[tauri::command]
pub async fn move_calendar_entry(app: AppHandle, id: String, to: String) -> Result<(), String> {
    let to = day(&to)?;
    let entry = app.state::<Calendar>().state.lock().unwrap().entries.iter().find(|e| e.id() == id).cloned().ok_or("unknown date")?;
    let moved = calendar::move_entry(&entry, to, language(&app), &strings(&app));
    let handle = app.clone();
    let _ = tauri::async_runtime::spawn_blocking(move || handle.state::<Calendar>().refresh(&handle)).await;
    let date = moved?;
    eprintln!("calendar: «{}» moved to {}", entry.title, calendar::date_text(date, entry.has_time));
    app.state::<crate::projects::Projects>().ask(false);
    Ok(())
}

/// A double click on a day: a plan row in the profile's own plan, or a project's deadline or publication.
#[tauri::command]
pub async fn add_calendar_date(app: AppHandle, profile: String, kind: String, day_text: String, time: String, platform: String, topic: String, project: String) -> Result<(), String> {
    let on = day(&day_text)?;
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let profile = settings.profiles.iter().find(|p| p.id == profile && p.calendar() != "off" && p.source().is_folders()).ok_or("unknown profile")?;
    let (texts, language) = (strings(&app), language(&app));
    let home = dirs::home_dir().unwrap_or_default();
    let clock = time.trim();
    match kind.as_str() {
        "plan" if profile.calendar() == "contentPlan" && !topic.trim().is_empty() => calendar::add_plan_row(profile, &home, on, clock, &platform, &topic, language, &texts)?,
        "deadline" | "publish" => {
            let folder = PathBuf::from(&project);
            let known = claudepult_core::folders::scan(&profile.source(), &home, &[], language).iter().any(|p| p.path == folder);
            if !known {
                return Err("unknown project".into());
            }
            let date = claudepult_core::folders::date(&format!("{day_text} {clock}")).filter(|_| !clock.is_empty()).unwrap_or_else(|| on.and_hms_opt(0, 0, 0).expect("midnight"));
            let key = if kind == "deadline" { claudepult_core::folders::Key::Deadline } else { claudepult_core::folders::Key::Publish };
            calendar::set_project_date(&folder, key, date, !clock.is_empty(), language, &texts)?;
        }
        _ => return Err("nothing to add".into()),
    }
    eprintln!("calendar: {kind} added on {day_text}");
    let handle = app.clone();
    let _ = tauri::async_runtime::spawn_blocking(move || handle.state::<Calendar>().refresh(&handle)).await;
    app.state::<crate::projects::Projects>().ask(false);
    Ok(())
}
