//! Stage 3 «Сессии» (docs/specs/SPEC-windows.md §4.3): the sessions the hook records, read every few seconds; the panel's
//! list, the tray icon's dot while one waits for an answer, installing the hook into Claude Code's settings, and
//! «Разрешить» / «Отклонить» for the permission requests the hook leaves in `approvals/` (the Mac's protocol).

use crate::limits::Limits;
use crate::strings;
use chrono::{Local, Utc};
use claudepult_core::agent_hooks;
use claudepult_core::approvals::{self, Request};
use claudepult_core::hooks::{self, HookCommand, HookStatus};
use claudepult_core::sessions::{self, Session, State};
use claudepult_core::{paths, process};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

/// What the panel last showed: (id, state, updated, open request) per session.
type Seen = Vec<(String, State, i64, Option<String>)>;

#[derive(Clone, Default)]
pub struct Sessions {
    seen: Arc<Mutex<Seen>>,
    /// Some session waits for an answer: the tray icon gets its dot.
    pub attention: Arc<AtomicBool>,
    /// Requests already announced by a notification.
    notified: Arc<Mutex<HashSet<String>>>,
}

/// The sessions to show; a process that is gone ends its session.
fn shown() -> Vec<(Session, State)> {
    sessions::load(&paths::sessions_dir(), Utc::now(), process::is_alive)
}

/// The newest open request of each session that still waits: answered in Claude, it is over.
fn open_requests(shown: &[(Session, State)]) -> HashMap<String, Request> {
    let now = Utc::now().timestamp_millis() as f64 / 1000.0;
    let mut open = approvals::by_session(approvals::requests(&paths::approvals_dir(), now, process::is_alive));
    open.retain(|session_id, _| shown.iter().any(|(s, state)| &s.id == session_id && *state == State::Waiting));
    open
}

impl Sessions {
    pub fn start(&self, app: AppHandle) {
        let this = self.clone();
        std::thread::spawn(move || loop {
            // The hooks wait for an answer only while this is fresh.
            approvals::touch_alive(&paths::approvals_dir());
            let shown = shown();
            let open = open_requests(&shown);
            let seen: Seen = shown
                .iter()
                .map(|(s, state)| (s.id.clone(), *state, s.updated_at.timestamp(), open.get(&s.id).map(|r| r.id.clone())))
                .collect();
            let changed = *this.seen.lock().unwrap() != seen;
            if changed {
                *this.seen.lock().unwrap() = seen;
                let waiting = shown.iter().any(|(_, state)| *state == State::Waiting);
                if this.attention.swap(waiting, Ordering::Relaxed) != waiting {
                    app.state::<Limits>().update_tray(&app);
                }
                this.announce(&app, &open);
                let _ = app.emit("sessions-changed", ());
            }
            std::thread::sleep(std::time::Duration::from_secs(3));
        });
    }

    /// One notification per new request; the answer is in the panel (buttons in the notification itself are not
    /// checked on Windows yet, SPEC-windows §11.4).
    fn announce(&self, app: &AppHandle, open: &HashMap<String, Request>) {
        let mut notified = self.notified.lock().unwrap();
        let texts = strings(app);
        for request in open.values() {
            if notified.insert(request.id.clone()) {
                let title = request.asks_title(&texts);
                let body = match &request.project {
                    Some(project) if !project.is_empty() => format!("{project} · {}", request.text()),
                    _ => request.text(),
                };
                let _ = app.notification().builder().title(title).body(body).show();
            }
        }
        notified.retain(|id| open.values().any(|r| &r.id == id));
    }
}

/// On quit: the waiting hooks give up at once and Claude's own dialog is the only one.
pub fn stop() {
    approvals::stop_alive(&paths::approvals_dir());
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestRow {
    id: String,
    title: String,
    text: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRow {
    id: String,
    project: String,
    state: &'static str,
    state_title: String,
    detail: Option<String>,
    progress: Option<String>,
    /// A permission request to answer from the panel.
    request: Option<RequestRow>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionsView {
    rows: Vec<SessionRow>,
    hooks: &'static str,
}

#[tauri::command]
pub fn sessions_view(app: AppHandle) -> SessionsView {
    let texts = strings(&app);
    let shown = shown();
    let mut open = open_requests(&shown);
    let rows = shown
        .into_iter()
        .map(|(session, state)| SessionRow {
            request: open.remove(&session.id).map(|r| RequestRow { title: r.asks_title(&texts), text: r.text(), id: r.id }),
            id: session.id.clone(),
            project: session.display_project(),
            state: match state {
                State::Waiting => "waiting",
                State::Running => "running",
                State::Error => "error",
                State::Done => "done",
                State::Ended => "ended",
                State::Unknown => "unknown",
            },
            state_title: state.title(&texts),
            // While it waits, what it waits for; while it works, what it does now.
            detail: match state {
                State::Waiting => session.message.clone(),
                State::Running => session.action_text(&texts),
                _ => None,
            },
            progress: session.progress.map(|(done, total)| format!("{done}/{total}")),
        })
        .collect();
    SessionsView { rows, hooks: status_key(hook_status()) }
}

/// «Разрешить» / «Отклонить» from the panel. An error leaves the request open: answer again or in Claude.
#[tauri::command]
pub fn decide_request(app: AppHandle, id: String, allow: bool) -> Result<(), String> {
    approvals::decide(&paths::approvals_dir(), &id, allow).map_err(|e| e.to_string())?;
    let _ = app.emit("sessions-changed", ());
    Ok(())
}

// MARK: - Hooks

/// `claudepult-hook(.exe)` next to the app: the installer puts it there.
fn hook_program() -> Option<PathBuf> {
    let name = if cfg!(windows) { "claudepult-hook.exe" } else { "claudepult-hook" };
    Some(std::env::current_exe().ok()?.with_file_name(name))
}

fn projects_dir() -> PathBuf {
    dirs_home().join("Projects")
}

fn command() -> Option<HookCommand> {
    Some(HookCommand::new(&hook_program()?, &projects_dir()))
}

fn dirs_home() -> PathBuf {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from).unwrap_or_default()
}

fn settings_path() -> PathBuf {
    paths::claude_dir().join("settings.json")
}

/// On a Mac this build is for development only: the real Mac app owns `~/.claude/settings.json` there, so the
/// hooks are installed only into another `CLAUDE_CONFIG_DIR`.
fn may_install() -> bool {
    !cfg!(target_os = "macos") || std::env::var_os("CLAUDE_CONFIG_DIR").is_some()
}

fn hook_status() -> HookStatus {
    let Some(command) = command() else { return HookStatus::NotInstalled };
    match hooks::read_settings(&settings_path()) {
        Ok(Some(settings)) => hooks::status(&settings, &command),
        _ => HookStatus::NotInstalled,
    }
}

fn status_key(status: HookStatus) -> &'static str {
    match status {
        HookStatus::Installed => "installed",
        HookStatus::NotInstalled => "notInstalled",
        HookStatus::Outdated => "outdated",
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HooksView {
    status: &'static str,
    title: String,
    may_install: bool,
    settings_path: String,
    error: Option<String>,
    /// What to do next, e.g. trusting the hooks in Codex.
    note: Option<String>,
}

fn status_title(app: &AppHandle, status: HookStatus) -> String {
    let texts = strings(app);
    match status {
        HookStatus::Installed => texts.t("установлены"),
        HookStatus::NotInstalled => texts.t("не установлены"),
        HookStatus::Outdated => texts.t("нужно обновить"),
    }
    .to_owned()
}

fn hooks_view(app: &AppHandle, error: Option<String>) -> HooksView {
    let status = hook_status();
    HooksView {
        status: status_key(status),
        title: status_title(app, status),
        may_install: may_install(),
        settings_path: settings_path().to_string_lossy().into_owned(),
        error,
        note: None,
    }
}

#[tauri::command]
pub fn hooks_state(app: AppHandle) -> HooksView {
    hooks_view(&app, None)
}

#[tauri::command]
pub fn install_hooks(app: AppHandle) -> HooksView {
    let stamp = Local::now().format("%Y%m%d-%H%M%S").to_string();
    let result = match (may_install(), command()) {
        (true, Some(command)) => hooks::install(&settings_path(), &command, &stamp).map(|_| ()),
        _ => Err(std::io::Error::other("not here")),
    };
    let _ = app.emit("sessions-changed", ());
    hooks_view(&app, result.err().map(|e| e.to_string()))
}

#[tauri::command]
pub fn uninstall_hooks(app: AppHandle) -> HooksView {
    let stamp = Local::now().format("%Y%m%d-%H%M%S").to_string();
    let result = if may_install() { hooks::uninstall(&settings_path(), &stamp).map(|_| ()) } else { Err(std::io::Error::other("not here")) };
    let _ = app.emit("sessions-changed", ());
    hooks_view(&app, result.err().map(|e| e.to_string()))
}

// MARK: - Codex and Copilot

#[derive(Clone, Copy, PartialEq)]
enum Agent {
    Codex,
    Copilot,
}

impl Agent {
    fn parse(name: &str) -> Result<Agent, String> {
        match name {
            "codex" => Ok(Agent::Codex),
            "copilot" => Ok(Agent::Copilot),
            _ => Err(format!("unknown agent {name}")),
        }
    }

    fn path(self) -> PathBuf {
        match self {
            Agent::Codex => paths::codex_dir().join("hooks.json"),
            Agent::Copilot => paths::copilot_dir().join("hooks").join("aihubbar.json"),
        }
    }

    /// On a Mac the real Mac app owns these files: only another `CODEX_HOME` / `COPILOT_HOME` (as for Claude).
    fn may_install(self) -> bool {
        !cfg!(target_os = "macos")
            || std::env::var_os(match self {
                Agent::Codex => "CODEX_HOME",
                Agent::Copilot => "COPILOT_HOME",
            })
            .is_some()
    }

    fn status(self) -> HookStatus {
        let Some(program) = hook_program() else { return HookStatus::NotInstalled };
        match self {
            Agent::Codex => agent_hooks::codex_status(&self.path(), &program, &projects_dir()),
            Agent::Copilot => agent_hooks::copilot_status(&self.path(), &program, &projects_dir()),
        }
    }
}

fn agent_view(app: &AppHandle, agent: Agent, error: Option<String>, note: Option<String>) -> HooksView {
    let status = agent.status();
    HooksView {
        status: status_key(status),
        title: status_title(app, status),
        may_install: agent.may_install(),
        settings_path: agent.path().to_string_lossy().into_owned(),
        error,
        note,
    }
}

#[tauri::command]
pub fn agent_hooks_state(app: AppHandle, agent: String) -> Result<HooksView, String> {
    let agent = Agent::parse(&agent)?;
    // Until trusted in `/hooks`, Codex skips them: say so while they are there.
    let note = (agent == Agent::Codex && agent.status() == HookStatus::Installed)
        .then(|| strings(&app).t("Готово. Теперь в codex введите /hooks и доверьте hooks AI Hub Bar — до этого Codex их пропускает.").to_owned());
    Ok(agent_view(&app, agent, None, note))
}

#[tauri::command]
pub fn install_agent_hooks(app: AppHandle, agent: String) -> Result<HooksView, String> {
    let agent = Agent::parse(&agent)?;
    let stamp = Local::now().format("%Y%m%d-%H%M%S").to_string();
    let result = match (agent.may_install(), hook_program()) {
        (true, Some(program)) => match agent {
            Agent::Codex => agent_hooks::codex_install(&agent.path(), &program, &projects_dir(), &stamp).map(|_| ()),
            Agent::Copilot => agent_hooks::copilot_install(&agent.path(), &program, &projects_dir()),
        },
        _ => Err(std::io::Error::other("not here")),
    };
    let error = result.err().map(|e| e.to_string());
    let note = (agent == Agent::Codex && error.is_none())
        .then(|| strings(&app).t("Готово. Теперь в codex введите /hooks и доверьте hooks AI Hub Bar — до этого Codex их пропускает.").to_owned());
    Ok(agent_view(&app, agent, error, note))
}

#[tauri::command]
pub fn uninstall_agent_hooks(app: AppHandle, agent: String) -> Result<HooksView, String> {
    let agent = Agent::parse(&agent)?;
    let stamp = Local::now().format("%Y%m%d-%H%M%S").to_string();
    let result = if !agent.may_install() {
        Err(std::io::Error::other("not here"))
    } else {
        match agent {
            Agent::Codex => agent_hooks::codex_uninstall(&agent.path(), &stamp).map(|_| ()),
            Agent::Copilot => agent_hooks::copilot_uninstall(&agent.path()),
        }
    };
    Ok(agent_view(&app, agent, result.err().map(|e| e.to_string()), None))
}
