//! Stage 4 «Проекты» (docs/specs/SPEC-windows.md §4.7): the git repositories of the projects folder in the panel, kept
//! fresh like the Mac's `ProjectStore` — at start, every 5 minutes, with `git fetch` every 30, and when the panel opens
//! on a list older than a minute. A row opens into STATUS.md, the attention items, PRs, worktrees and «Терминал» /
//! «Папка» / GitHub.

use crate::{language, strings};
use chrono::{DateTime, Utc};
use claudepult_core::i18n::Strings;
use claudepult_core::projects::{self, Ci, Health, Project, Tools, Words};
use claudepult_core::{command, paths};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

const STALE_AFTER: Duration = Duration::from_secs(60);
const BACKGROUND_INTERVAL: Duration = Duration::from_secs(5 * 60);
const FETCH_INTERVAL: Duration = Duration::from_secs(30 * 60);

#[derive(Clone, Copy, PartialEq)]
enum Problem {
    NoFolder,
    NoGit,
}

#[derive(Default)]
struct State {
    projects: Vec<Project>,
    updated: Option<Instant>,
    refreshing: bool,
    problem: Option<Problem>,
}

#[derive(Clone, Default)]
pub struct Projects {
    state: Arc<Mutex<State>>,
    /// A refresh asked for out of turn; `true` — with `git fetch`.
    wake: Arc<(Mutex<Option<bool>>, Condvar)>,
}

impl Projects {
    pub fn start(&self, app: AppHandle) {
        let this = self.clone();
        std::thread::spawn(move || {
            let mut last_fetch = Instant::now();
            this.refresh(&app, false);
            loop {
                let asked = {
                    let (lock, signal) = &*this.wake;
                    let guard = lock.lock().unwrap();
                    let (mut guard, _) = signal.wait_timeout_while(guard, BACKGROUND_INTERVAL, |asked| asked.is_none()).unwrap();
                    guard.take()
                };
                let fetch = asked.unwrap_or_else(|| last_fetch.elapsed() + Duration::from_secs(10) >= FETCH_INTERVAL);
                if fetch {
                    last_fetch = Instant::now();
                }
                this.refresh(&app, fetch);
            }
        });
    }

    /// A refresh now, on the background thread (also after a language change: the attention texts are made there).
    pub fn ask(&self, fetch: bool) {
        let (lock, signal) = &*self.wake;
        let mut asked = lock.lock().unwrap();
        *asked = Some(asked.unwrap_or(false) || fetch);
        signal.notify_one();
    }

    fn refresh(&self, app: &AppHandle, fetch: bool) {
        self.state.lock().unwrap().refreshing = true;
        let _ = app.emit("projects-changed", ());
        let root = paths::projects_dir();
        let texts = strings(app);
        let words = Words { strings: &texts, language: language(app) };
        let started = Instant::now();
        let (projects, problem) = match Tools::find() {
            _ if !root.is_dir() => (Vec::new(), Some(Problem::NoFolder)),
            None => (Vec::new(), Some(Problem::NoGit)),
            Some(tools) => (projects::scan(&root, &tools, fetch, &words, Utc::now()), None),
        };
        eprintln!("projects: {} in {:.1} s{}", projects.len(), started.elapsed().as_secs_f64(), if fetch { " (fetch)" } else { "" });
        *self.state.lock().unwrap() = State { projects, updated: Some(Instant::now()), refreshing: false, problem };
        let _ = app.emit("projects-changed", ());
    }

    /// The panel opened: a list older than a minute is read again.
    fn refresh_if_stale(&self) {
        let state = self.state.lock().unwrap();
        if !state.refreshing && state.updated.is_none_or(|at| at.elapsed() >= STALE_AFTER) {
            drop(state);
            self.ask(false);
        }
    }

    fn knows_path(&self, path: &Path) -> bool {
        self.state.lock().unwrap().projects.iter().any(|p| p.path == path || p.worktrees.iter().any(|w| Path::new(&w.path) == path))
    }

    fn knows_link(&self, url: &str) -> bool {
        self.state.lock().unwrap().projects.iter().any(|p| {
            p.remote.as_deref().and_then(projects::web_url).as_deref() == Some(url)
                || p.open_prs.iter().flatten().any(|pr| pr.url.as_deref() == Some(url))
        })
    }
}

// MARK: - The panel's view

#[derive(Serialize)]
pub struct AttentionRow {
    level: &'static str,
    text: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestRow {
    number: u64,
    title: String,
    url: Option<String>,
    draft: bool,
    ci: &'static str,
    ci_title: String,
}

#[derive(Serialize)]
pub struct WorktreeRow {
    path: String,
    name: String,
    detail: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectRow {
    path: String,
    name: String,
    health: &'static str,
    health_title: String,
    /// Shown when it isn't main or master.
    branch: Option<String>,
    dirty: Option<String>,
    dirty_title: String,
    prs: Option<String>,
    prs_ci: &'static str,
    prs_title: String,
    ago: Option<String>,
    github: Option<String>,
    stage: Option<String>,
    now: Vec<String>,
    next: Vec<String>,
    needs: Vec<String>,
    /// «Нет docs/STATUS.md» or «В STATUS.md нет шапки».
    status_note: Option<String>,
    attention: Vec<AttentionRow>,
    pull_requests: Vec<PullRequestRow>,
    worktrees: Vec<WorktreeRow>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectsView {
    rows: Vec<ProjectRow>,
    /// Why the list is empty, when it is.
    message: Option<String>,
    refreshing: bool,
}

fn health_key(health: Health) -> &'static str {
    match health {
        Health::Red => "red",
        Health::Yellow => "yellow",
        Health::Green => "green",
    }
}

fn health_title(texts: &Strings, health: Health) -> String {
    match health {
        Health::Red => texts.t("Требует внимания"),
        Health::Yellow => texts.t("Есть что проверить"),
        Health::Green => texts.t("Всё в порядке"),
    }
    .to_owned()
}

fn ci_key(ci: Ci) -> &'static str {
    match ci {
        Ci::Ok => "ok",
        Ci::Fail => "fail",
        Ci::Pending => "pending",
        Ci::None => "none",
    }
}

fn ci_title(texts: &Strings, ci: Ci) -> String {
    match ci {
        Ci::Ok => texts.t("пройдено"),
        Ci::Fail => texts.t("упало"),
        Ci::Pending => texts.t("идёт"),
        Ci::None => texts.t("нет проверок"),
    }
    .to_owned()
}

fn row(project: &Project, words: &Words, now: DateTime<Utc>) -> ProjectRow {
    let texts = words.strings;
    let summary = project.status.as_ref().and_then(|s| s.summary.clone()).unwrap_or_default();
    let prs = project.open_prs.as_deref().unwrap_or(&[]);
    ProjectRow {
        path: project.path.to_string_lossy().into_owned(),
        name: project.name.clone(),
        health: health_key(project.health),
        health_title: health_title(texts, project.health),
        branch: Some(project.branch.clone()).filter(|b| b != "main" && b != "master"),
        dirty: (project.dirty > 0).then(|| format!("{} {}", project.dirty, projects::files_word(words, project.dirty))),
        dirty_title: texts.format("Незакоммиченных файлов: %lld", &[&project.dirty.to_string()]),
        prs: (!prs.is_empty()).then(|| format!("{} PR", prs.len())),
        prs_ci: ci_key(project.pull_requests_ci()),
        prs_title: texts.format("Открытых PR: %lld, CI: %@", &[&prs.len().to_string(), &ci_title(texts, project.pull_requests_ci())]),
        ago: project.last_activity.map(|at| projects::ago(texts, at.with_timezone(&Utc), now)),
        github: project.remote.as_deref().and_then(projects::web_url),
        stage: Some(summary.stage.clone()).filter(|s| !s.is_empty()),
        status_note: match &project.status {
            None => Some(texts.t("Нет docs/STATUS.md").to_owned()),
            Some(status) if status.summary.is_none() => Some(texts.t("В STATUS.md нет шапки").to_owned()),
            Some(_) => None,
        },
        now: summary.now,
        next: summary.next,
        needs: summary.needs,
        attention: project
            .attention_not_in_status()
            .into_iter()
            .map(|a| AttentionRow {
                level: match a.level {
                    projects::Level::High => "high",
                    projects::Level::Mid => "mid",
                    projects::Level::Low => "low",
                },
                text: a.text.clone(),
            })
            .collect(),
        pull_requests: prs
            .iter()
            .map(|pr| PullRequestRow {
                number: pr.number,
                title: pr.title.clone(),
                url: pr.url.clone(),
                draft: pr.is_draft,
                ci: ci_key(pr.ci),
                ci_title: ci_title(texts, pr.ci),
            })
            .collect(),
        worktrees: project
            .worktrees
            .iter()
            .map(|w| WorktreeRow {
                path: w.path.clone(),
                name: Path::new(&w.path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
                detail: if w.dirty > 0 {
                    format!("{} · {}", w.branch, texts.format("изменено файлов: %lld", &[&w.dirty.to_string()]))
                } else {
                    w.branch.clone()
                },
            })
            .collect(),
    }
}

#[tauri::command]
pub fn projects_view(app: AppHandle) -> ProjectsView {
    let texts = strings(&app);
    let words = Words { strings: &texts, language: language(&app) };
    let projects = app.state::<Projects>();
    let state = projects.state.lock().unwrap();
    let now = Utc::now();
    let message = match state.problem {
        Some(Problem::NoFolder) => Some(texts.format("Папки нет: %@", &[&paths::projects_dir().to_string_lossy()])),
        Some(Problem::NoGit) => Some(texts.t("Не удалось прочитать репозитории").to_owned()),
        None if state.updated.is_some() && state.projects.is_empty() => Some(texts.t("В папке проектов не найдено git-репозиториев.").to_owned()),
        None => None,
    };
    ProjectsView { rows: state.projects.iter().map(|p| row(p, &words, now)).collect(), message, refreshing: state.refreshing }
}

#[tauri::command]
pub fn refresh_projects(app: AppHandle) {
    app.state::<Projects>().ask(false);
}

#[tauri::command]
pub fn projects_panel_opened(app: AppHandle) {
    app.state::<Projects>().refresh_if_stale();
}

/// «Терминал» and «Папка» for a project or one of its worktrees — only folders the scan found.
#[tauri::command]
pub fn open_project(app: AppHandle, path: String, target: String) -> Result<(), String> {
    let path = PathBuf::from(path);
    if !app.state::<Projects>().knows_path(&path) {
        return Err("unknown project".into());
    }
    match target.as_str() {
        "terminal" => open_terminal(&path),
        "folder" => open_with_system(path.as_os_str()),
        _ => Err("unknown target".into()),
    }
}

/// A project's page or a PR — only links the scan found.
#[tauri::command]
pub fn open_link(app: AppHandle, url: String) -> Result<(), String> {
    if !url.starts_with("https://") || !app.state::<Projects>().knows_link(&url) {
        return Err("unknown link".into());
    }
    open_with_system(url.as_ref())
}

// MARK: - Opening

fn spawn(mut command: std::process::Command) -> Result<(), String> {
    let mut child = command.spawn().map_err(|e| e.to_string())?;
    // Reaped in the background, so no zombie stays on Linux.
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

/// A folder in the file manager, a link in the browser.
fn open_with_system(target: &std::ffi::OsStr) -> Result<(), String> {
    let mut command = if cfg!(windows) {
        if Path::new(target).is_dir() {
            let mut command = std::process::Command::new("explorer.exe");
            command.arg(target);
            command
        } else {
            // No shell between: `&` in a link stays a character.
            let mut command = std::process::Command::new("rundll32.exe");
            command.arg("url.dll,FileProtocolHandler").arg(target);
            command
        }
    } else if cfg!(target_os = "macos") {
        let mut command = std::process::Command::new("open");
        command.arg(target);
        command
    } else {
        let mut command = std::process::Command::new("xdg-open");
        command.arg(target);
        command
    };
    command::hide_window(&mut command);
    spawn(command)
}

/// A terminal in the folder: Windows Terminal when it is there, else PowerShell in a console of its own; on Linux the
/// first terminal found; Terminal.app on a Mac (development only).
fn open_terminal(folder: &Path) -> Result<(), String> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        if let Some(wt) = command::find("wt") {
            let mut command = command::command(&wt);
            command.arg("-d").arg(folder);
            return spawn(command);
        }
        const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;
        let mut command = std::process::Command::new("powershell.exe");
        command.arg("-NoExit").current_dir(folder).creation_flags(CREATE_NEW_CONSOLE);
        spawn(command)
    }
    #[cfg(target_os = "macos")]
    {
        let mut command = std::process::Command::new("open");
        command.args(["-a", "Terminal"]).arg(folder);
        spawn(command)
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let terminal = ["x-terminal-emulator", "gnome-terminal", "konsole", "xfce4-terminal", "kitty", "alacritty", "xterm"]
            .iter()
            .find_map(|name| command::find(name))
            .ok_or("no terminal found")?;
        let mut command = std::process::Command::new(terminal);
        command.current_dir(folder);
        spawn(command)
    }
}
