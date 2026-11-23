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
                } else if now >= run.deadline(now) && !stopping.contains_key(&run.id) {
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
        // A frozen process only gets the signal once it runs again.
        if cfg!(unix) && run.is_paused() {
            process::resume_tree(pid);
        }
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

    /// The limit guard: freezes the run's processes where they are, so the work isn't lost to a hit limit.
    pub fn pause(&self, id: &str) -> bool {
        self.set_paused(id, true)
    }

    pub fn resume(&self, id: &str) -> bool {
        self.set_paused(id, false)
    }

    fn set_paused(&self, id: &str, pause: bool) -> bool {
        let now = Utc::now();
        let mut state = self.state.lock().unwrap();
        let ours = |run: &Run, pid: u32| state.children.contains_key(&run.id) || process::is_same_process(pid, started(run));
        let Some(run) = state.runs.iter().find(|r| r.id == id && r.is_running() && r.is_paused() != pause).cloned() else { return false };
        // The process is gone or not ours: a pause that can't be made is not written; one that is over is cleared.
        match (run.pid.filter(|pid| ours(&run, *pid)), pause) {
            (Some(pid), true) => {
                if !process::suspend_tree(pid) {
                    eprintln!("run {id}: could not be paused");
                    process::resume_tree(pid);
                    return false;
                }
            }
            (Some(pid), false) => {
                process::resume_tree(pid);
            }
            (None, true) => return false,
            (None, false) => {}
        }
        let Some(run) = state.runs.iter_mut().find(|r| r.id == id) else { return false };
        if pause { run.mark_paused(now) } else { run.mark_resumed(now) }
        let run = run.clone();
        drop(state);
        eprintln!("run {id}: {}", if pause { "paused by the limit guard" } else { "resumed" });
        if let Err(error) = runs::save(&paths::runs_dir(), &run) {
            eprintln!("run {id} not saved: {error}");
        }
        true
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
        RunState::Running if run.is_paused() => texts.t("на паузе до сброса лимита").to_owned(),
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

/// Another background run in the folder of `run`: the same project, worktree and branch.
fn start_beside(app: &AppHandle, run: &Run, program: &std::path::Path, command_title: &str, task: &str, prompt: &str, codex: bool, review: bool) -> Result<(), String> {
    let folder = std::path::Path::new(&run.folder);
    // The folder may be gone (a removed worktree): the system's own words say so.
    std::fs::read_dir(folder).map_err(|error| format!("{}: {error}", run.folder))?;
    let time_limit_minutes = app.state::<crate::AppState>().settings.lock().unwrap().background_time_limit_minutes;
    let new = runs::NewRun {
        project: &run.project,
        project_path: std::path::Path::new(&run.project_path),
        folder,
        worktree_branch: run.worktree_branch.as_deref(),
        command_title,
        task,
        prompt,
        time_limit_minutes,
        permissions: if review { runs::REVIEW } else { "code" },
        result_file: None,
        codex,
        review_of: review.then_some(run.id.as_str()),
    };
    let (started, child) = runs::start(&paths::runs_dir(), program, &new).map_err(|error| error.to_string())?;
    eprintln!("run {} started beside {}: «{command_title}»{}", started.id, run.id, if codex { " (Codex)" } else { "" });
    app.state::<Runs>().add(app, started, child);
    Ok(())
}

fn codex_program(app: &AppHandle) -> Result<std::path::PathBuf, String> {
    let kind = claudepult_core::agents::kind("codex").expect("listed");
    claudepult_core::agents::detect(kind).ok_or_else(|| strings(app).format("%@ не установлен", &[kind.title]))
}

/// «Передать Codex» on a Claude run that is paused by the limit or ended badly: the run stops and Codex goes on in
/// the same folder (the worktree included) with the same task and a word about the work already there.
#[tauri::command]
pub async fn hand_over_run(app: AppHandle, id: String) -> Result<(), String> {
    let runs = app.state::<Runs>();
    let run = runs.list().into_iter().find(|run| run.id == id && run.can_hand_over()).ok_or("this run can't be handed over")?;
    let codex = codex_program(&app)?;
    if run.is_running() {
        runs.stop(&id, RunState::Stopped);
    }
    let prompt = runs::handover_prompt(run.prompt.as_deref().unwrap_or_default(), run.agent_title());
    start_beside(&app, &run, &codex, &run.command_title, &run.task, &prompt, true, false)
}

/// «Проверить в Codex / Claude Code» on a finished run: the other service reads the changes in the run's folder and
/// changes nothing.
#[tauri::command]
pub async fn review_run(app: AppHandle, id: String) -> Result<(), String> {
    let texts = strings(&app);
    let all = app.state::<Runs>().list();
    let run = all.iter().find(|run| run.id == id && run.can_review(&all)).ok_or("this run can't be reviewed")?;
    let codex = run.reviewer_is_codex();
    let program = if codex { codex_program(&app)? } else { claudepult_core::launch::find_claude().ok_or_else(|| texts.t("Claude Code не установлен").to_owned())? };
    let prompt = runs::review_prompt(run.prompt.as_deref().unwrap_or_default(), run.agent_title());
    start_beside(&app, run, &program, texts.t("Проверка"), &texts.format("Проверка: %@", &[&run.task]), &prompt, codex, true)
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
