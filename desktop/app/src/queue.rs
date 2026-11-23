//! Background runs for later (the Mac's queue in `LaunchController`): «На ночь» and «После сброса» put a run into
//! `queue.json`; once a half-minute the due ones start in the background, those that would only hit the limit wait
//! for its reset, and the night's batch gets one summary when it is done.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, Local, TimeZone, Utc};
use claudepult_core::launch::ClaudeCommand;
use claudepult_core::queue::{self, Queued, Target};
use claudepult_core::runs::RunState;
use claudepult_core::{agents, paths};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

use crate::limits::Limits;
use crate::projects::Projects;
use crate::runs::Runs;
use crate::{save, strings, AppState};

const CHECK_EVERY: Duration = Duration::from_secs(30);

#[derive(Clone, Default)]
pub struct Queue {
    items: Arc<Mutex<Vec<Queued>>>,
    /// Runs the person resumed by hand: the guard leaves them alone until they finish.
    exempt: Arc<Mutex<HashSet<String>>>,
}

fn file() -> PathBuf {
    paths::data_dir().join("queue.json")
}

fn clock(at: DateTime<Utc>) -> String {
    at.with_timezone(&Local).format("%H:%M").to_string()
}

fn keep(items: &[Queued]) {
    if let Err(error) = queue::save(&file(), items) {
        eprintln!("queue not saved: {error}");
    }
}

impl Queue {
    pub fn start(&self, app: AppHandle) {
        *self.items.lock().unwrap() = queue::load(&file());
        let this = self.clone();
        std::thread::spawn(move || loop {
            std::thread::sleep(CHECK_EVERY);
            this.tick(&app);
        });
    }

    fn add(&self, app: &AppHandle, item: Queued) {
        let mut items = self.items.lock().unwrap();
        items.push(item);
        keep(&items);
        drop(items);
        let _ = app.emit("sessions-changed", ());
    }

    /// One pass: the summary of a finished night, due runs moved past a full limit, the others started.
    fn tick(&self, app: &AppHandle) {
        let now = Utc::now();
        summarize_night(app, now);
        let snapshot = app.state::<Limits>().snapshot();
        let threshold = app.state::<AppState>().settings.lock().unwrap().run_guard_percent;
        let mut hold = queue::hold(snapshot.as_ref(), threshold, now);
        // For a look at the pause without a used-up limit, in a build made for development only.
        if cfg!(debug_assertions) && std::env::var_os("CLAUDEPULT_TEST_HOLD").is_some() {
            hold = Some(queue::Hold { key: "five_hour".into(), utilization: 99.0, resets_at: Some(now + chrono::Duration::hours(1)) });
        }
        self.guard_runs(app, hold);
        let (due, moved) = {
            let mut items = self.items.lock().unwrap();
            let moved = queue::postpone_held(&mut items, snapshot.as_ref(), threshold, now);
            let due = queue::due_now(&items, &HashSet::new(), now);
            let started: HashSet<&str> = due.iter().map(|item| item.id.as_str()).collect();
            items.retain(|item| !started.contains(item.id.as_str()));
            if moved || !due.is_empty() {
                keep(&items);
            }
            (due, moved)
        };
        if moved {
            eprintln!("queue: due runs wait for the limit to reset");
        }
        if due.iter().any(|item| item.night) && app.state::<AppState>().settings.lock().unwrap().night_batch_start.is_none() {
            save(app, |settings| settings.night_batch_start = Some(now.timestamp()));
        }
        for item in &due {
            let (command, task) = item.command.parts();
            eprintln!("queue: starting «{command}» for {}", item.target.name);
            let result = crate::projects::launch_now(app, Path::new(&item.target.path), command, task.map(str::to_owned), false, Some("background".to_owned()), false, item.codex_path.is_some(), true);
            // A folder that is busy with a command that can't move to a worktree, a project that is gone: said, not
            // dropped in silence.
            let problem = match result {
                Ok(reply) if reply.confirm => Some(reply.message),
                Ok(_) => None,
                Err(error) => Some(error),
            };
            if let Some(problem) = problem {
                eprintln!("queue: «{command}» for {} not started: {problem}", item.target.name);
                let _ = app.notification().builder().title(format!("❌ {}: {}", item.target.name, title(&strings(app), &item.command))).body(problem).show();
            }
        }
        if moved || !due.is_empty() {
            let _ = app.emit("sessions-changed", ());
        }
    }
}

impl Queue {
    /// Pauses Claude's running background runs near the limit and resumes them after the reset; one notification
    /// each way. Codex's runs are left alone: its limits are not Claude's.
    fn guard_runs(&self, app: &AppHandle, hold: Option<queue::Hold>) {
        let runs = app.state::<Runs>();
        let texts = strings(app);
        let mine: Vec<_> = runs.list().into_iter().filter(|run| run.is_running() && !run.is_codex()).collect();
        let lines = |list: &[&claudepult_core::runs::Run]| list.iter().map(|run| format!("{}: {}", run.project, run.command_title)).collect::<Vec<_>>().join("\n");
        let (icon, headline, body) = if let Some(hold) = hold {
            let exempt = self.exempt.lock().unwrap().clone();
            let paused: Vec<_> = mine.iter().filter(|run| !run.is_paused() && !exempt.contains(&run.id) && runs.pause(&run.id)).collect();
            if paused.is_empty() {
                return;
            }
            let window = claudepult_core::texts::window_title(&texts, &claudepult_core::usage::UsageWindow { key: hold.key.clone(), utilization: hold.utilization, resets_at: hold.resets_at, model: None });
            let until = hold.resets_at.map(|at| texts.format(" Продолжу после сброса в %@.", &[&clock(at)])).unwrap_or_default();
            ("⏸", texts.format("Фоновые задачи на паузе: %@ %@", &[&window, &claudepult_core::texts::percent(hold.utilization)]), lines(&paused) + &until)
        } else {
            let resumed: Vec<_> = mine.iter().filter(|run| run.is_paused() && runs.resume(&run.id)).collect();
            if resumed.is_empty() {
                return;
            }
            ("▶️", texts.t("Лимит сбросился: фоновые задачи продолжают работу").to_owned(), lines(&resumed))
        };
        let _ = app.notification().builder().title(&headline).body(&body).show();
        crate::telegram::notify(app, "bg", format!("{icon} <b>{}</b>\n{}", claudepult_core::telegram::escape(&headline), claudepult_core::telegram::escape(&body)));
        let _ = app.emit("sessions-changed", ());
    }
}

/// «Продолжить сейчас» on a paused run: it goes on, and the guard leaves it alone until it finishes.
#[tauri::command]
pub fn resume_run_now(app: AppHandle, id: String) {
    app.state::<Queue>().exempt.lock().unwrap().insert(id.clone());
    app.state::<Runs>().resume(&id);
    let _ = app.emit("sessions-changed", ());
}

#[derive(Serialize)]
pub struct RunGuardView {
    percent: u32,
    choices: Vec<(u32, String)>,
}

/// «Ставить фоновые задачи на паузу».
#[tauri::command]
pub fn run_guard(app: AppHandle) -> RunGuardView {
    let texts = strings(&app);
    let percent = app.state::<AppState>().settings.lock().unwrap().run_guard_percent;
    RunGuardView { percent, choices: queue::GUARD_CHOICES.into_iter().map(|value| (value, if value == 0 { texts.t("никогда").to_owned() } else { texts.format("с %lld %%", &[&value.to_string()]) })).collect() }
}

#[tauri::command]
pub fn set_run_guard(app: AppHandle, percent: u32) {
    if queue::GUARD_CHOICES.contains(&percent) {
        save(&app, |settings| settings.run_guard_percent = percent);
    }
}

fn title(texts: &claudepult_core::i18n::Strings, command: &queue::Command) -> String {
    match command {
        queue::Command::NextStep {} => texts.t("Следующий шаг"),
        queue::Command::CustomTask { .. } => texts.t("Своя задача"),
        queue::Command::FinishSession {} => texts.t("Завершить сессию"),
    }
    .to_owned()
}

/// When the night's runs are all finished: one notification (and Telegram, like other background results).
fn summarize_night(app: &AppHandle, now: DateTime<Utc>) {
    let Some(stamp) = app.state::<AppState>().settings.lock().unwrap().night_batch_start else { return };
    let runs = app.state::<Runs>().list();
    let Some(start) = Utc.timestamp_opt(stamp, 0).single() else { return };
    if runs.iter().any(|run| run.is_running()) || (now - start).num_seconds() <= 60 {
        return;
    }
    save(app, |settings| settings.night_batch_start = None);
    let batch: Vec<_> = runs.iter().filter(|run| run.started_at >= start - chrono::Duration::seconds(5) && !run.is_running()).collect();
    if batch.is_empty() {
        return;
    }
    let texts = strings(app);
    let done = batch.iter().filter(|run| run.state == RunState::Succeeded).count();
    let headline = texts.format("Ночью: %lld задач — ✅ %lld, ❌ %lld", &[&batch.len().to_string(), &done.to_string(), &(batch.len() - done).to_string()]);
    let icon = |run: &claudepult_core::runs::Run| if run.state == RunState::Succeeded { "✅" } else { "❌" };
    let body = batch.iter().map(|run| format!("{} {}: {}", icon(run), crate::runs::project_label(run), crate::runs::task_start(&run.task))).collect::<Vec<_>>().join("\n");
    let _ = app.notification().builder().title(&headline).body(body).show();
    let lines = batch
        .iter()
        .map(|run| claudepult_core::telegram::run_html(run.state == RunState::Succeeded, &crate::runs::project_label(run), &crate::runs::task_start(&run.task), &crate::runs::outcome_text(&texts, run), run.pull_request_url.as_deref()))
        .collect::<Vec<_>>()
        .join("\n");
    crate::telegram::notify(app, "bg", format!("🌙 <b>{}</b>\n{lines}", claudepult_core::telegram::escape(&headline)));
    eprintln!("night summary: {} runs", batch.len());
}

/// «На ночь» (`when` is `night`) and «После сброса» (`reset`): the run waits in the queue. Returns what to say.
#[tauri::command]
pub async fn queue_launch(app: AppHandle, path: String, command: String, task: Option<String>, when: String, agent: Option<String>) -> Result<String, String> {
    let texts = strings(&app);
    let (base_ref, next_items) = app.state::<Projects>().launch_target(Path::new(&path)).ok_or("unknown project")?;
    let command = match (command.as_str(), task.as_deref().map(str::trim)) {
        ("next", _) => ClaudeCommand::NextStep,
        ("finish", _) => ClaudeCommand::FinishSession,
        ("custom", Some(task)) if !task.is_empty() => ClaudeCommand::CustomTask(task.to_owned()),
        _ => return Err("unknown command".into()),
    };
    let codex_path = match agent.as_deref() {
        Some("codex") => {
            let kind = agents::kind("codex").expect("listed");
            Some(agents::detect(kind).ok_or_else(|| texts.format("%@ не установлен", &[kind.title]))?.to_string_lossy().into_owned())
        }
        _ => None,
    };
    let now = Utc::now();
    let night = when == "night";
    let launch_at = if night {
        let hour = app.state::<AppState>().settings.lock().unwrap().night_start_hour;
        let local = queue::next_start(hour, Local::now().naive_local());
        Local.from_local_datetime(&local).earliest().map_or(now, |at| at.with_timezone(&Utc))
    } else {
        // Codex's run waits an hour: its own limits are not read for the queue.
        let reset = if codex_path.is_some() { None } else { app.state::<Limits>().snapshot().and_then(|s| s.session().and_then(|w| w.resets_at)) };
        queue::after_reset(reset, now)
    };
    let command = queue::Command::from(&command);
    let name = Path::new(&path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let what = title(&texts, &command);
    eprintln!("queued «{what}» for {name} {} at {}", if night { "for the night" } else { "after the reset" }, launch_at.to_rfc3339());
    app.state::<Queue>().add(&app, Queued { id: claudepult_core::runs::new_id(), command, target: Target { path, name, next_items, base_ref }, launch_at, night, after_reset: !night, codex_path });
    Ok(if night {
        texts.format("«%@» запустится ночью в %@. Утром придёт сводка.", &[&what, &clock(launch_at)])
    } else {
        texts.format("«%@» запустится в фоне в %@, после сброса лимита.", &[&what, &clock(launch_at)])
    })
}

#[derive(Serialize)]
pub struct QueuedRow {
    id: String,
    text: String,
}

/// The waiting runs for the sessions block: «Shop: Следующий шаг — запуск в 01:00».
#[tauri::command]
pub fn queued_view(app: AppHandle) -> Vec<QueuedRow> {
    let texts = strings(&app);
    let items = app.state::<Queue>().items.lock().unwrap().clone();
    items
        .into_iter()
        .map(|item| {
            let name = if item.codex_path.is_some() { format!("{} · Codex", item.target.name) } else { item.target.name.clone() };
            QueuedRow { text: texts.format("%@: %@ — запуск в %@", &[&name, &title(&texts, &item.command), &clock(item.launch_at)]), id: item.id }
        })
        .collect()
}

/// «Отменить» on a waiting run.
#[tauri::command]
pub fn cancel_queued(app: AppHandle, id: String) {
    let state = app.state::<Queue>();
    let mut items = state.items.lock().unwrap();
    items.retain(|item| item.id != id);
    keep(&items);
    drop(items);
    let _ = app.emit("sessions-changed", ());
}

#[derive(Serialize)]
pub struct NightHour {
    hour: u32,
    hours: Vec<(u32, String)>,
}

/// «Ночные задачи начинаются в».
#[tauri::command]
pub fn night_hour(app: AppHandle) -> NightHour {
    let hour = app.state::<AppState>().settings.lock().unwrap().night_start_hour;
    NightHour { hour, hours: queue::HOURS.into_iter().map(|hour| (hour, format!("{hour:02}:00"))).collect() }
}

#[tauri::command]
pub fn set_night_hour(app: AppHandle, hour: u32) {
    if queue::HOURS.contains(&hour) {
        save(&app, |settings| settings.night_start_hour = hour);
    }
}
