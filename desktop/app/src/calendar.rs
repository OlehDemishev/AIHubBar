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
