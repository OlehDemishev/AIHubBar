//! Stage 3 «Сессии» (docs/specs/SPEC-windows.md §4.3): the sessions the hook records, read every few seconds; the panel's
//! list, the tray icon's dot while one waits for an answer, and installing the hook into Claude Code's settings.

use crate::limits::Limits;
use crate::strings;
use chrono::{Local, Utc};
use claudepult_core::hooks::{self, HookCommand, HookStatus};
use claudepult_core::paths;
use claudepult_core::sessions::{self, State};
use serde::Serialize;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};

/// What the panel last showed: (id, state, updated) per session.
type Seen = Vec<(String, State, i64)>;

#[derive(Clone, Default)]
pub struct Sessions {
    seen: Arc<Mutex<Seen>>,
    /// Some session waits for an answer: the tray icon gets its dot.
    pub attention: Arc<AtomicBool>,
}

impl Sessions {
    pub fn start(&self, app: AppHandle) {
        let this = self.clone();
        std::thread::spawn(move || loop {
            let shown = sessions::load(&paths::sessions_dir(), Utc::now(), |_| None);
            let seen: Seen = shown.iter().map(|(s, state)| (s.id.clone(), *state, s.updated_at.timestamp())).collect();
            let changed = *this.seen.lock().unwrap() != seen;
            if changed {
                *this.seen.lock().unwrap() = seen;
                let waiting = shown.iter().any(|(_, state)| *state == State::Waiting);
                if this.attention.swap(waiting, Ordering::Relaxed) != waiting {
                    app.state::<Limits>().update_tray(&app);
                }
                let _ = app.emit("sessions-changed", ());
            }
            std::thread::sleep(std::time::Duration::from_secs(3));
        });
    }
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
    let rows = sessions::load(&paths::sessions_dir(), Utc::now(), |_| None)
        .into_iter()
        .map(|(session, state)| SessionRow {
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

// MARK: - Hooks

/// `claudepult-hook(.exe)` next to the app: the installer puts it there.
fn hook_program() -> Option<PathBuf> {
    let name = if cfg!(windows) { "claudepult-hook.exe" } else { "claudepult-hook" };
    Some(std::env::current_exe().ok()?.with_file_name(name))
}

fn command() -> Option<HookCommand> {
    let projects = dirs_home().join("Projects");
    Some(HookCommand::new(&hook_program()?, &projects))
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
}

fn hooks_view(app: &AppHandle, error: Option<String>) -> HooksView {
    let texts = strings(app);
    let status = hook_status();
    let title = match status {
        HookStatus::Installed => texts.t("установлены"),
        HookStatus::NotInstalled => texts.t("не установлены"),
        HookStatus::Outdated => texts.t("нужно обновить"),
    };
    HooksView {
        status: status_key(status),
        title: title.to_owned(),
        may_install: may_install(),
        settings_path: settings_path().to_string_lossy().into_owned(),
        error,
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
