//! Stage 4 «Фоновые задачи» (docs/specs/SPEC-windows.md §4.6): background `claude -p` runs (`core/runs.rs`) watched
//! every few seconds — the end of the process, the time limit, a stop from the panel — and a notification with the
//! result, as the Mac's `RunStore`. Runs started before the app quit are picked up again from `runs/`.

use crate::strings;
use chrono::{DateTime, Utc};
use claudepult_core::i18n::Strings;
use claudepult_core::runs::{self, FinishTexts, Run, RunState};
use claudepult_core::{paths, process};
use serde::Serialize;
use std::collections::HashMap;
use std::process::Child;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

const CHECK_EVERY: Duration = Duration::from_secs(5);
/// A run that ended long before the app noticed (it wasn't running) is not announced.
const ANNOUNCE_WITHIN: chrono::Duration = chrono::Duration::hours(1);

#[derive(Default)]
struct State {
    runs: Vec<Run>,
    children: HashMap<String, Child>,
    /// Why a run was stopped, applied when its process is gone.
    stopping: HashMap<String, RunState>,
}

#[derive(Clone, Default)]
pub struct Runs {
    state: Arc<Mutex<State>>,
}

fn started(run: &Run) -> std::time::SystemTime {
    std::time::UNIX_EPOCH + Duration::from_secs(u64::try_from(run.started_at.timestamp()).unwrap_or(0))
}

impl Runs {
    pub fn start(&self, app: AppHandle) {
        self.state.lock().unwrap().runs = runs::load(&paths::runs_dir(), Utc::now());
        let this = self.clone();
        std::thread::spawn(move || loop {
            if this.check(&app) {
                let _ = app.emit("sessions-changed", ());
                // A folder project's command shows its state in the project's row.
                let _ = app.emit("projects-changed", ());
            }
            std::thread::sleep(CHECK_EVERY);
        });
    }

    pub fn add(&self, app: &AppHandle, run: Run, child: Child) {
        let mut state = self.state.lock().unwrap();
        state.children.insert(run.id.clone(), child);
        state.runs.insert(0, run);
        drop(state);
        let _ = app.emit("sessions-changed", ());
    }

    pub fn list(&self) -> Vec<Run> {
        self.state.lock().unwrap().runs.clone()
    }

    /// One pass: ended processes are finished, overdue ones stopped. True when something changed.
    fn check(&self, app: &AppHandle) -> bool {
        let now = Utc::now();
        let mut ended = Vec::new();
        let mut overdue = Vec::new();
        {
            let mut state = self.state.lock().unwrap();
            let State { runs, children, stopping } = &mut *state;
            for run in runs.iter().filter(|r| r.is_running()) {
                let gone = match children.get_mut(&run.id) {
                    Some(child) => !matches!(child.try_wait(), Ok(None)),
                    // Started before the app's restart: only the pid is left.
                    None => !run.pid.is_some_and(|pid| process::is_same_process(pid, started(run))),
                };
                if gone {
                    ended.push(run.id.clone());
                } else if now >= run.deadline() && !stopping.contains_key(&run.id) {
                    overdue.push(run.id.clone());
                }
            }
        }
        for id in &overdue {
            self.stop(id, RunState::TimedOut);
        }
        for id in &ended {
            self.finish(app, id, now);
        }
        !ended.is_empty() || !overdue.is_empty()
    }

    /// Ends the process (and the tools it started); the run is finished once it is gone.
    pub fn stop(&self, id: &str, reason: RunState) {
        let mut state = self.state.lock().unwrap();
        let Some(run) = state.runs.iter().find(|r| r.id == id && r.is_running()).cloned() else { return };
        let Some(pid) = run.pid else { return };
        let ours = state.children.contains_key(id) || process::is_same_process(pid, started(&run));
        state.stopping.insert(id.to_owned(), reason);
        drop(state);
        if !ours {
            return;
        }
        eprintln!("run {id}: stopping ({reason:?})");
        runs::kill(pid, false);
        // Claude runs its SessionEnd hooks on SIGTERM; then make sure it is gone (Windows ends it at once).
        if cfg!(unix) {
            let started = started(&run);
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_secs(10));
                if process::is_same_process(pid, started) {
                    runs::kill(pid, true);
                }
            });
        }
    }

    fn finish(&self, app: &AppHandle, id: &str, now: DateTime<Utc>) {
        let texts = strings(app);
        let dir = paths::runs_dir();
        let mut state = self.state.lock().unwrap();
        state.children.remove(id);
        let reason = state.stopping.remove(id);
        let Some(run) = state.runs.iter_mut().find(|r| r.id == id && r.is_running()) else { return };
        let log = std::fs::read_to_string(run.log_path(&dir)).unwrap_or_default();
        let denied = texts.t("Отклонено правилами фона: %@").to_owned();
        let finish_texts = FinishTexts {
            no_result: texts.t("Claude завершился без результата — см. журнал").to_owned(),
            denied: Box::new(move |list| claudepult_core::i18n::fill(&denied, &[list])),
            no_result_file: {
                let text = texts.t("Файл результата не появился: %@").to_owned();
                Box::new(move |name| claudepult_core::i18n::fill(&text, &[name]))
            },
        };
        runs::finish(run, &log, reason, &finish_texts, now);
        eprintln!("run {id} finished: {:?}", run.state);
        let last_write = std::fs::metadata(run.log_path(&dir)).and_then(|m| m.modified()).ok().map(DateTime::<Utc>::from).unwrap_or(now);
        let announce = !run.notified && now - last_write < ANNOUNCE_WITHIN;
        run.notified = true;
        let run = run.clone();
        drop(state);
        if let Err(error) = runs::save(&dir, &run) {
            eprintln!("run {id} not saved: {error}");
        }
        if announce {
            let _ = app.notification().builder().title(notification_title(&run)).body(notification_body(&texts, &run)).show();
            let html = claudepult_core::telegram::run_html(run.state == RunState::Succeeded, &project_label(&run), &task_start(&run.task), &outcome_text(&texts, &run), run.pull_request_url.as_deref());
            crate::telegram::notify(app, "bg", html);
        }
        if run.result_file.is_some() {
            // A command wrote into a folder project: its files, words and main file are read again.
            app.state::<crate::projects::Projects>().ask(false);
        }
    }
}

// MARK: - Words

/// The task's start, flattened, at most 60 characters (the Mac's `RunMessage.taskStart`).
pub(crate) fn task_start(task: &str) -> String {
    let flat = task.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() > 60 { flat.chars().take(59).collect::<String>() + "…" } else { flat }
}

pub fn outcome_text(texts: &Strings, run: &Run) -> String {
    match run.state {
        RunState::TimedOut => texts.format("остановлено по лимиту времени (%lld мин)", &[&run.time_limit_minutes.to_string()]),
        RunState::Stopped => texts.t("остановлено вручную").to_owned(),
        RunState::Running => texts.t("выполняется").to_owned(),
        RunState::Succeeded => run.summary.clone().unwrap_or_else(|| texts.t("готово").to_owned()),
        RunState::Failed => run.summary.clone().unwrap_or_else(|| texts.t("завершилось с ошибкой").to_owned()),
    }
}

fn notification_title(run: &Run) -> String {
    let icon = if run.state == RunState::Succeeded { "✅" } else { "❌" };
    format!("{icon} {}: {}", project_label(run), task_start(&run.task))
}

/// «Shop», or «Shop · Codex» for a run Codex does.
pub fn project_label(run: &Run) -> String {
    if run.is_codex() { format!("{} · Codex", run.project) } else { run.project.clone() }
}

fn notification_body(texts: &Strings, run: &Run) -> String {
    [Some(outcome_text(texts, run)), run.pull_request_url.clone()].into_iter().flatten().collect::<Vec<_>>().join("\n")
}

// MARK: - Commands

/// «Остановить» on a running background task.
#[tauri::command]
pub fn stop_run(app: AppHandle, id: String) {
    app.state::<Runs>().stop(&id, RunState::Stopped);
}

#[derive(Serialize)]
pub struct LogEntry {
    kind: &'static str,
    text: String,
}

/// The run's log as readable lines: what Claude said, the tools it used, the result (the last 60).
#[tauri::command]
pub fn run_log(app: AppHandle, id: String) -> Result<Vec<LogEntry>, String> {
    let run = app.state::<Runs>().list().into_iter().find(|r| r.id == id).ok_or("unknown run")?;
    let log = std::fs::read_to_string(run.log_path(&paths::runs_dir())).map_err(|e| e.to_string())?;
    let entries = runs::entries(&log);
    let skip = entries.len().saturating_sub(60);
    Ok(entries
        .into_iter()
        .skip(skip)
        .map(|(kind, text)| LogEntry {
            kind: match kind {
                runs::EntryKind::Text => "text",
                runs::EntryKind::Tool => "tool",
                runs::EntryKind::Result => "result",
                runs::EntryKind::Error => "error",
            },
            text,
        })
        .collect())
}
