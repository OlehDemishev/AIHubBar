//! Stage 4 «Проекты» (docs/specs/SPEC-windows.md §4.7): the git repositories of the projects folder in the panel, kept
//! fresh like the Mac's `ProjectStore` — with notifications when a PR's CI fails or is fixed and when a PR closes — at start, every 5 minutes, with `git fetch` every 30, and when the panel opens
//! on a list older than a minute. A row opens into STATUS.md, the attention items, PRs, worktrees and «Терминал» /
//! «Папка» / GitHub, and the Mac's three Claude commands, started in a terminal window (`core/launch.rs`).

use crate::{language, projects_dir, strings};
use chrono::{DateTime, Utc};
use claudepult_core::i18n::Strings;
use claudepult_core::projects::{self, Ci, Health, Project, Tools, Words};
use crate::runs::Runs;
use claudepult_core::launch::{self, ClaudeCommand, Style};
use claudepult_core::runs::NewRun;
use claudepult_core::settings::LAUNCH_MODES;
use claudepult_core::sessions::{self, State as SessionState};
use claudepult_core::{command, paths, process};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

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
    /// The folder `projects` came from: PR alerts compare two scans of the same folder only.
    root: Option<PathBuf>,
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
        let root = projects_dir(app);
        let texts = strings(app);
        let words = Words { strings: &texts, language: language(app) };
        let started = Instant::now();
        let (projects, problem) = match Tools::find() {
            _ if !root.is_dir() => (Vec::new(), Some(Problem::NoFolder)),
            None => (Vec::new(), Some(Problem::NoGit)),
            Some(tools) => (projects::scan(&root, &tools, fetch, &words, Utc::now()), None),
        };
        eprintln!("projects: {} in {:.1} s{}", projects.len(), started.elapsed().as_secs_f64(), if fetch { " (fetch)" } else { "" });
        let (old, old_root) = {
            let mut state = self.state.lock().unwrap();
            (std::mem::take(&mut state.projects), state.root.take())
        };
        // A failed scan (no folder, no git) keeps quiet: an empty list isn't «every PR closed»; nor is another folder.
        let same_folder = old_root.as_deref() == Some(root.as_path());
        let changes = if problem.is_none() && same_folder { projects::pull_request_changes(&old, &projects) } else { Vec::new() };
        *self.state.lock().unwrap() = State { projects, root: Some(root), updated: Some(Instant::now()), refreshing: false, problem };
        let _ = app.emit("projects-changed", ());
        app.state::<crate::limits::Limits>().update_tray(app);
        let alerts = app.state::<crate::AppState>().settings.lock().unwrap().pull_request_alerts;
        if alerts && !changes.is_empty() {
            eprintln!("pull request changes: {}", changes.len());
            for change in &changes {
                let (title, body) = projects::pr_change_text(&texts, change);
                let _ = app.notification().builder().title(title).body(body).show();
            }
        }
    }

    /// Another projects folder was chosen: the old list goes at once and the new folder is read.
    pub fn folder_changed(&self, app: &AppHandle) {
        *self.state.lock().unwrap() = State::default();
        let _ = app.emit("projects-changed", ());
        app.state::<crate::limits::Limits>().update_tray(app);
        self.ask(false);
    }

    /// The panel opened: a list older than a minute is read again.
    fn refresh_if_stale(&self) {
        let state = self.state.lock().unwrap();
        if !state.refreshing && state.updated.is_none_or(|at| at.elapsed() >= STALE_AFTER) {
            drop(state);
            self.ask(false);
        }
    }

    /// How many projects there are and how many need attention (red): the tray icon's dot and hint.
    pub fn counts(&self) -> (usize, usize) {
        let state = self.state.lock().unwrap();
        (state.projects.len(), state.projects.iter().filter(|p| p.health == Health::Red).count())
    }

    fn knows_path(&self, path: &Path) -> bool {
        self.state.lock().unwrap().projects.iter().any(|p| p.path == path || p.worktrees.iter().any(|w| Path::new(&w.path) == path))
    }

    /// The base branch and the Next items of a scanned project.
    fn launch_target(&self, path: &Path) -> Option<(String, Vec<String>)> {
        let state = self.state.lock().unwrap();
        let project = state.projects.iter().find(|p| p.path == path)?;
        let next = project.status.as_ref().and_then(|s| s.summary.as_ref()).map(|s| s.next.clone()).unwrap_or_default();
        Some((project.default_branch.clone(), next))
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
    /// «Следующий шаг»'s hint: the first Next item.
    next_hint: String,
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
        next_hint: match summary.next.first() {
            Some(first) => texts.format("Первый пункт Next: %@", &[first]),
            None => texts.t("Первый пункт Next из STATUS.md").to_owned(),
        },
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
        Some(Problem::NoFolder) => Some(texts.format("Папки нет: %@", &[&projects_dir(&app).to_string_lossy()])),
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
    let from_a_run = app.state::<Runs>().list().iter().any(|r| r.pull_request_url.as_deref() == Some(url.as_str()));
    if !url.starts_with("https://") || !(from_a_run || app.state::<Projects>().knows_link(&url)) {
        return Err("unknown link".into());
    }
    open_with_system(url.as_ref())
}

// MARK: - Claude

#[derive(Serialize, Default)]
pub struct LaunchReply {
    message: String,
    /// The folder is busy and the command can't move to a worktree: «Запустить всё равно» asks again.
    confirm: bool,
    /// No mode chosen yet: «Где запустить «…»?» with «Терминал» / «Фон».
    choose: Option<String>,
}

/// «Следующий шаг», «Своя задача», «Завершить», as the Mac's `LaunchController`: in a terminal window or in the
/// background (`mode`, else the remembered one, else the question); a busy project folder gives a new worktree, or a
/// question for «Завершить».
#[tauri::command]
#[allow(clippy::too_many_arguments)]
pub async fn launch_claude(
    app: AppHandle,
    path: String,
    command: String,
    task: Option<String>,
    allow_busy: bool,
    mode: Option<String>,
    remember: bool,
) -> Result<LaunchReply, String> {
    tauri::async_runtime::spawn_blocking(move || launch_now(&app, Path::new(&path), &command, task, allow_busy, mode, remember))
        .await
        .map_err(|e| e.to_string())?
}

fn launch_now(
    app: &AppHandle,
    path: &Path,
    command: &str,
    task: Option<String>,
    allow_busy: bool,
    mode: Option<String>,
    remember: bool,
) -> Result<LaunchReply, String> {
    let texts = strings(app);
    let projects = app.state::<Projects>();
    let (base, next) = projects.launch_target(path).ok_or("unknown project")?;
    let command = match (command, task.as_deref().map(str::trim)) {
        ("next", _) => ClaudeCommand::NextStep,
        ("finish", _) => ClaudeCommand::FinishSession,
        ("custom", Some(task)) if !task.is_empty() => ClaudeCommand::CustomTask(task.to_owned()),
        _ => return Err("unknown command".into()),
    };
    let title = match command {
        ClaudeCommand::NextStep => texts.t("Следующий шаг"),
        ClaudeCommand::CustomTask(_) => texts.t("Своя задача"),
        ClaudeCommand::FinishSession => texts.t("Завершить сессию"),
    }
    .to_owned();
    let settings = app.state::<crate::AppState>().settings.lock().unwrap().clone();
    let mode = mode.filter(|m| LAUNCH_MODES.contains(&m.as_str()));
    if remember && mode.is_some() {
        crate::save(app, |s| s.launch_mode = mode.clone());
    }
    let Some(mode) = mode.or(settings.launch_mode) else {
        return Ok(LaunchReply { choose: Some(texts.format("Где запустить «%@»?", &[&title])), ..LaunchReply::default() });
    };
    let background = mode == "background";
    let claude = launch::find_claude().ok_or_else(|| texts.t("Claude Code не установлен").to_owned())?;

    // Busy: a session of the hook that still works or waits in the project folder.
    let working: Vec<PathBuf> = sessions::load(&paths::sessions_dir(), Utc::now(), process::is_alive)
        .into_iter()
        .filter(|(_, state)| matches!(state, SessionState::Running | SessionState::Waiting))
        .map(|(session, _)| PathBuf::from(session.cwd))
        .collect();
    let mut folder = path.to_path_buf();
    let mut worktree = None;
    if launch::is_busy(path, &working) {
        if command.can_use_worktree() {
            let tools = Tools::find().ok_or("git not found")?;
            let plan = launch::create_worktree(&tools, path, &command.name_source(&next), &base)?;
            folder = plan.path.clone();
            worktree = Some(plan);
        } else if !allow_busy {
            let message = texts.t("В этой папке уже работает сессия Claude. Запустить ещё одну там же?").to_owned();
            return Ok(LaunchReply { message, confirm: true, choose: None });
        }
    }

    let prompt = launch::one_line(&command.prompt(&Style::for_projects(&projects_dir(app)), language(app)));
    let mut message = if background {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let task = match &command {
            ClaudeCommand::CustomTask(task) => task.trim().to_owned(),
            _ => title.clone(),
        };
        let new = NewRun {
            project: &name,
            project_path: path,
            folder: &folder,
            worktree_branch: worktree.as_ref().map(|w| w.branch.as_str()),
            command_title: &title,
            task: &task,
            prompt: &prompt,
            time_limit_minutes: settings.background_time_limit_minutes,
        };
        let (run, child) = claudepult_core::runs::start(&paths::runs_dir(), &claude, &new).map_err(|e| e.to_string())?;
        eprintln!("run {} started: «{title}» in {}", run.id, folder.display());
        app.state::<Runs>().add(app, run, child);
        texts.format("«%@» запущен в фоне (лимит %lld мин). Итог придёт уведомлением.", &[&title, &settings.background_time_limit_minutes.to_string()])
    } else {
        launch::open_in_terminal(&folder, &claude, &[&prompt]).map_err(|e| texts.format("Не удалось открыть Терминал: %@", &[&e]))?;
        eprintln!("launched «{title}» in a terminal: {}", folder.display());
        texts.format("«%@» запущен в новом окне Терминала.", &[&title])
    };
    if let Some(plan) = worktree {
        message = texts.format("В папке проекта уже работает Claude, поэтому запуск идёт в worktree cb-%@ (ветка %@). ", &[&plan.slug, &plan.branch]) + &message;
        projects.ask(false);
    }
    Ok(LaunchReply { message, ..LaunchReply::default() })
}

// MARK: - Worktrees

#[derive(Serialize)]
pub struct RemovalReply {
    /// `confirm` (safe: ask «Удалить?»), `blocked` (with the reason) or `removed`.
    state: &'static str,
    reason: Option<String>,
}

/// The trash button of a worktree, as on the Mac: first a check (nothing uncommitted, the branch merged or pushed),
/// then, on «Удалить?», `git worktree remove` without force. Only worktrees the scan found.
#[tauri::command]
pub async fn worktree_removal(app: AppHandle, path: String, worktree: String, remove: bool) -> Result<RemovalReply, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let texts = strings(&app);
        let projects = app.state::<Projects>();
        let (project, worktree) = (PathBuf::from(path), PathBuf::from(worktree));
        let known = projects.state.lock().unwrap().projects.iter().any(|p| p.path == project && p.worktrees.iter().any(|w| Path::new(&w.path) == worktree));
        if !known {
            return Err("unknown worktree".to_owned());
        }
        let (base, _) = projects.launch_target(&project).ok_or("unknown project")?;
        let tools = Tools::find().ok_or("git not found")?;
        if remove {
            launch::remove_worktree(&tools, &worktree, &project, &texts)?;
            eprintln!("removed worktree {}", worktree.display());
            projects.ask(false);
            return Ok(RemovalReply { state: "removed", reason: None });
        }
        Ok(match launch::removal_check(&tools, &worktree, &base, &texts) {
            launch::Removal::Allowed => RemovalReply { state: "confirm", reason: None },
            launch::Removal::Blocked(reason) => RemovalReply { state: "blocked", reason: Some(reason) },
        })
    })
    .await
    .map_err(|e| e.to_string())?
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
