//! Batch tasks (the Mac's `BatchRunner`, SPEC-content §5): «Выбрать» in the folder projects, a command of the profile
//! and when — «Сейчас», «На ночь», «После сброса лимита». One background run per project, one after another over all
//! batches; near Claude's limit a Claude batch waits as single runs do; one summary at the end, in a notification and
//! in Telegram. The list is kept in `batches.json`.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, Local, TimeZone, Utc};
use claudepult_core::ai::Service;
use claudepult_core::batch::{self, Batch, Item, State, When};
use claudepult_core::commands::Command;
use claudepult_core::{folders, paths, queue};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

use crate::limits::Limits;
use crate::{language, strings, AppState};

const CHECK_EVERY: Duration = Duration::from_secs(5);

#[derive(Clone, Default)]
pub struct Batches(Arc<Mutex<Vec<Batch>>>);

fn file() -> PathBuf {
    paths::data_dir().join("batches.json")
}

fn clock(at: DateTime<Utc>) -> String {
    at.with_timezone(&Local).format("%H:%M").to_string()
}

/// A batch in the projects block: «Редактура · 3 из 10» and what can be done with it.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BatchRow {
    id: String,
    text: String,
    /// `done`, `failed` (finished with failures), `running`, `waiting`.
    state: &'static str,
    /// The projects' names, or the failed ones with why.
    hint: String,
    can_cancel: bool,
}

impl Batches {
    pub fn start(&self, app: AppHandle) {
        *self.0.lock().unwrap() = batch::load(&file(), Utc::now());
        let this = self.clone();
        std::thread::spawn(move || loop {
            this.tick(&app);
            std::thread::sleep(CHECK_EVERY);
        });
    }

    fn save(list: &[Batch]) {
        if let Err(error) = batch::save(&file(), list) {
            eprintln!("batches not saved: {error}");
        }
    }

    fn change(&self, app: &AppHandle, change: impl FnOnce(&mut Vec<Batch>)) {
        let mut list = self.0.lock().unwrap();
        change(&mut list);
        Self::save(&list);
        drop(list);
        let _ = app.emit("projects-changed", ());
    }

    pub fn rows(&self, texts: &claudepult_core::i18n::Strings) -> Vec<BatchRow> {
        let now = Utc::now();
        self.0
            .lock()
            .unwrap()
            .iter()
            .map(|b| {
                let failed: Vec<&Item> = b.items.iter().filter(|i| i.state == State::Failed).collect();
                BatchRow {
                    id: b.id.clone(),
                    text: format!("{} · {}", b.title(), b.status(texts, now, clock)),
                    state: if b.is_finished() {
                        if failed.is_empty() { "done" } else { "failed" }
                    } else if b.running_index().is_some() {
                        "running"
                    } else {
                        "waiting"
                    },
                    hint: if failed.is_empty() {
                        b.items.iter().map(|i| i.name.as_str()).collect::<Vec<_>>().join(", ")
                    } else {
                        failed.iter().map(|i| format!("{}: {}", i.name, i.note.as_deref().unwrap_or(""))).collect::<Vec<_>>().join("\n")
                    },
                    // Nothing waits (the last project runs, or the rest was cancelled): there is nothing left to cancel.
                    can_cancel: !b.is_finished() && b.items.iter().any(|i| i.state == State::Waiting),
                }
            })
            .collect()
    }

    /// One step: looks at what is running, then starts the next project — one at a time over all batches.
    fn tick(&self, app: &AppHandle) {
        let texts = strings(app);
        let now = Utc::now();
        let interrupted = texts.t("прервано: приложение было закрыто").to_owned();
        let mut list = self.0.lock().unwrap();
        let before = list.clone();
        for b in list.iter_mut() {
            b.settle(|item| crate::commands::outcome(app, item.job_id.as_deref(), item.result_file.as_deref().unwrap_or_default()), &interrupted);
        }
        let held = list.iter().any(|b| !b.is_finished() && b.waits_for_limit()) && is_held(app, now);
        if let Some(index) = batch::next_to_start(&list, now, held) {
            start_next(app, &mut list[index], &texts);
        }
        let mut finished = Vec::new();
        for b in list.iter_mut().filter(|b| b.is_finished() && !b.announced) {
            b.announced = true;
            finished.push(b.clone());
        }
        let changed = *list != before;
        if changed {
            Self::save(&list);
        }
        drop(list);
        for b in finished {
            eprintln!("batch «{}» finished: {} of {}", b.title(), b.done_count(), b.items.len());
            let (title, body) = b.summary(&texts);
            let _ = app.notification().builder().title(&title).body(&body).show();
            let html = format!("<b>{}</b>\n{}", claudepult_core::telegram::escape(&title), claudepult_core::telegram::escape(&body));
            crate::telegram::notify(app, "bg", html);
        }
        if changed {
            let _ = app.emit("projects-changed", ());
        }
    }

    /// «Сейчас», «На ночь», «После сброса лимита» for the checked projects of the current profile.
    fn add(&self, app: &AppHandle, projects: Vec<String>, command: &str, service: &str, text: Option<String>, when: When) -> Result<(), String> {
        let profile = app.state::<AppState>().settings.lock().unwrap().current().filter(|p| p.source().is_folders()).cloned().ok_or("no folder profile")?;
        let template = profile.other.get("commands").and_then(|v| v.as_array()).into_iter().flatten().find(|c| c.get("id").and_then(|v| v.as_str()) == Some(command)).cloned().ok_or("unknown command")?;
        if !crate::commands::batch_choices(app, &profile).iter().any(|c| crate::commands::choice_id(c) == service) || projects.is_empty() {
            return Err("cannot run".into());
        }
        let now = Utc::now();
        let start_at = match when {
            When::Now => now,
            When::Night => {
                let hour = app.state::<AppState>().settings.lock().unwrap().night_start_hour;
                let local = queue::next_start(hour, Local::now().naive_local());
                Local.from_local_datetime(&local).earliest().map_or(now, |at| at.with_timezone(&Utc))
            }
            // Two minutes after the reset, as single runs; in an hour when the reset is not known.
            When::AfterReset => queue::after_reset(app.state::<Limits>().snapshot().and_then(|s| s.session().and_then(|w| w.resets_at)), now),
        };
        let items = projects
            .iter()
            .map(|path| Item::new(path, &Path::new(path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()))
            .collect::<Vec<_>>();
        let text = text.map(|t| t.trim().to_owned()).filter(|t| !t.is_empty());
        let b = Batch { id: claudepult_core::runs::new_id(), template, profile_id: profile.id.clone(), service_id: service.into(), text, when, start_at, items, announced: false };
        eprintln!("batch «{}»: {} projects, {when:?}, starts {}", b.title(), b.items.len(), start_at.to_rfc3339());
        self.change(app, |list| list.push(b));
        let this = self.clone();
        let app = app.clone();
        std::thread::spawn(move || this.tick(&app));
        Ok(())
    }
}

/// Claude's limit holds background work right now (the queue's rule and threshold).
fn is_held(app: &AppHandle, now: DateTime<Utc>) -> bool {
    let snapshot = app.state::<Limits>().snapshot();
    let threshold = app.state::<AppState>().settings.lock().unwrap().run_guard_percent;
    queue::hold(snapshot.as_ref(), threshold, now).is_some()
}

fn start_next(app: &AppHandle, b: &mut Batch, texts: &claudepult_core::i18n::Strings) {
    let Some(index) = b.next_index() else { return };
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let profile = settings.profiles.iter().find(|p| p.id == b.profile_id).cloned();
    let service = Service::parse(&b.service_id);
    let usable = profile.as_ref().is_some_and(|p| crate::commands::batch_choices(app, p).iter().any(|c| crate::commands::choice_id(c) == b.service_id));
    let (Some(profile), Some(service), true, Some(template)) = (profile, service, usable, Command::from_value(&b.template)) else {
        b.fail(index, texts.t("профиля или сервиса больше нет"));
        return;
    };
    let folder = PathBuf::from(&b.items[index].project_path);
    if !folder.is_dir() {
        b.fail(index, texts.t("папки больше нет"));
        return;
    }
    // Read now, not when the batch was made: at night the main file may be another one.
    let project = folders::project(&folder, &profile.result_patterns(), language(app));
    let (job, result) = crate::commands::start_quietly(app, project, profile, template, b.text.as_deref(), &service);
    let item = &mut b.items[index];
    item.job_id = Some(job);
    item.result_file = Some(result.to_string_lossy().into_owned());
    item.state = State::Running;
    eprintln!("batch «{}»: {} of {} started — {}", b.title(), index + 1, b.items.len(), b.items[index].name);
}

#[tauri::command]
pub fn batch_start(app: AppHandle, projects: Vec<String>, command: String, service: String, text: Option<String>, when: String) -> Result<(), String> {
    let when = When::parse(&when).ok_or("unknown time")?;
    app.state::<Batches>().add(&app, projects, &command, &service, text, when)
}

#[tauri::command]
pub fn batch_cancel(app: AppHandle, id: String) {
    app.state::<Batches>().change(&app, |list| batch::cancel(list, &id));
}

#[tauri::command]
pub fn batch_dismiss(app: AppHandle, id: String) {
    app.state::<Batches>().change(&app, |list| batch::dismiss(list, &id));
}
