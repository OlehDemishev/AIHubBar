//! Stage 4 «Проекты» (docs/specs/SPEC-windows.md §4.7): the git repositories of the projects folder in the panel, kept
//! fresh like the Mac's `ProjectStore` — with notifications when a PR's CI fails or is fixed and when a PR closes — at start, every 5 minutes, with `git fetch` every 30, and when the panel opens
//! on a list older than a minute. A row opens into STATUS.md, the attention items, PRs, worktrees and «Терминал» /
//! «Папка» / GitHub, and the Mac's three Claude commands, started in a terminal window (`core/launch.rs`).

use crate::profiles::{projects_dir, projects_root};
use crate::{language, strings};
use chrono::{DateTime, Utc};
use claudepult_core::i18n::Strings;
use claudepult_core::folders::{self, FolderProject};
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
    /// The profile has no git projects folder.
    NoSource,
}

#[derive(Default)]
struct State {
    projects: Vec<Project>,
    /// A profile with folder projects (the Mac's `FolderProjectStore`): these instead of git repositories.
    folders: Vec<FolderProject>,
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
        let profile = app.state::<crate::AppState>().settings.lock().unwrap().current().cloned();
        if let Some(profile) = profile.filter(|p| p.source().is_folders()) {
            let found = match &root {
                Some(root) if root.is_dir() => {
                    let home = dirs::home_dir().unwrap_or_default();
                    (folders::scan(&profile.source(), &home, &profile.result_patterns(), language(app)), None)
                }
                _ => (Vec::new(), Some(Problem::NoFolder)),
            };
            eprintln!("folder projects: {} in {:.1} s", found.0.len(), started.elapsed().as_secs_f64());
            app.state::<crate::calendar::Calendar>().ask();
            *self.state.lock().unwrap() = State { folders: found.0, root, updated: Some(Instant::now()), problem: found.1, ..State::default() };
            let _ = app.emit("projects-changed", ());
            app.state::<crate::limits::Limits>().update_tray(app);
            return;
        }
        let (projects, problem) = match (Tools::find(), &root) {
            (_, None) => (Vec::new(), Some(Problem::NoSource)),
            (_, Some(root)) if !root.is_dir() => (Vec::new(), Some(Problem::NoFolder)),
            (None, _) => (Vec::new(), Some(Problem::NoGit)),
            (Some(tools), Some(root)) => (projects::scan(root, &tools, fetch, &words, Utc::now()), None),
        };
        eprintln!("projects: {} in {:.1} s{}", projects.len(), started.elapsed().as_secs_f64(), if fetch { " (fetch)" } else { "" });
        let (old, old_root) = {
            let mut state = self.state.lock().unwrap();
            (std::mem::take(&mut state.projects), state.root.take())
        };
        // A failed scan (no folder, no git) keeps quiet: an empty list isn't «every PR closed»; nor is another folder.
        let same_folder = old_root.is_some() && old_root == root;
        let changes = if problem.is_none() && same_folder { projects::pull_request_changes(&old, &projects) } else { Vec::new() };
        *self.state.lock().unwrap() = State { projects, root, updated: Some(Instant::now()), problem, ..State::default() };
        let _ = app.emit("projects-changed", ());
        app.state::<crate::limits::Limits>().update_tray(app);
        let alerts = app.state::<crate::AppState>().settings.lock().unwrap().pull_request_alerts;
        if alerts && !changes.is_empty() {
            eprintln!("pull request changes: {}", changes.len());
            let mut html = Vec::new();
            for change in &changes {
                let (title, body) = projects::pr_change_text(&texts, change);
                html.push(claudepult_core::telegram::pull_request_html(&title, &body, change.url.as_deref()));
                let _ = app.notification().builder().title(title).body(body).show();
            }
            crate::telegram::notify(app, "pr", html.join("\n\n"));
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
        (state.projects.len() + state.folders.len(), state.projects.iter().filter(|p| p.health == Health::Red).count())
    }

    fn knows_path(&self, path: &Path) -> bool {
        let state = self.state.lock().unwrap();
        state.projects.iter().any(|p| p.path == path || p.worktrees.iter().any(|w| Path::new(&w.path) == path)) || state.folders.iter().any(|p| p.path == path)
    }

    /// Every project of the profile's folder, git or folder: name and path.
    pub(crate) fn names(&self) -> Vec<(String, PathBuf)> {
        let state = self.state.lock().unwrap();
        state.projects.iter().map(|p| (p.name.clone(), p.path.clone())).chain(state.folders.iter().map(|p| (p.name.clone(), p.path.clone()))).collect()
    }

    pub(crate) fn folder_project(&self, path: &Path) -> Option<FolderProject> {
        self.state.lock().unwrap().folders.iter().find(|p| p.path == path).cloned()
    }

    /// One folder project read again after a change to its card.
    fn reread(&self, app: &AppHandle, path: &Path) {
        let Some(profile) = app.state::<crate::AppState>().settings.lock().unwrap().current().cloned() else { return };
        let fresh = folders::project(path, &profile.result_patterns(), language(app));
        if let Some(slot) = self.state.lock().unwrap().folders.iter_mut().find(|p| p.path == path) {
            *slot = fresh;
        }
        // A stage decides whether a date is still to do.
        app.state::<crate::calendar::Calendar>().ask();
        let _ = app.emit("projects-changed", ());
    }

    /// The base branch and the Next items of a scanned project.
    /// The git projects for «Быстрый запрос»: name, folder, last change.
    pub(crate) fn candidates(&self) -> Vec<claudepult_core::quick_prompt::Candidate> {
        let state = self.state.lock().unwrap();
        state
            .projects
            .iter()
            .map(|p| claudepult_core::quick_prompt::Candidate { name: p.name.clone(), path: p.path.to_string_lossy().into_owned(), last_activity: p.last_activity.map(|d| d.with_timezone(&Utc)) })
            .collect()
    }

    pub(crate) fn launch_target(&self, path: &Path) -> Option<(String, Vec<String>)> {
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
    /// The other agents for «Открыть в…» in a git project.
    agents: Vec<crate::commands::ServiceChoice>,
    /// A profile with folder projects: these rows instead of `rows`.
    folders: Option<FolderView>,
    /// Why the list is empty, when it is.
    message: Option<String>,
    refreshing: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderView {
    rows: Vec<FolderRow>,
    /// The profile's stages, in order: the chips to switch between.
    stages: Vec<String>,
    /// «Новый проект»: only for a folder of projects, not an inbox.
    can_create: bool,
    /// Who can run the commands: Claude Code and the API models with a key.
    services: Vec<crate::commands::ServiceChoice>,
    /// The profile's service, preselected.
    default_service: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderRow {
    path: String,
    name: String,
    stage: Option<String>,
    /// Its place among the profile's stages: the chip's colour from start (blue) to done (green).
    stage_index: Option<usize>,
    /// The profile's metrics joined: «1 240 сл. · 8:16 · до 05.12».
    metrics: String,
    /// «просрочено 2 дн».
    overdue: Option<String>,
    /// «Формат» or «Площадка» from the card.
    format: Option<String>,
    main_file: Option<String>,
    /// The card's file name when there is one; otherwise «Создать проект.md» is offered.
    card_file: Option<String>,
    create_card: String,
    /// The profile's commands and «Своя задача».
    commands: Vec<crate::commands::CommandButton>,
    /// What was started here: running, done (its file), failed.
    jobs: Vec<crate::commands::JobRow>,
    /// «В папке нет текстового файла — команды получат только папку.»
    no_text: bool,
}

fn folder_view(app: &AppHandle, state: &State, texts: &Strings) -> Option<FolderView> {
    let settings = app.state::<crate::AppState>().settings.lock().unwrap().clone();
    let profile = settings.current().filter(|p| p.source().is_folders())?;
    let language = language(app);
    let stages = profile.stages();
    let metrics = profile.metrics();
    let done = profile.done_stage();
    let now = chrono::Local::now();
    let rows = state
        .folders
        .iter()
        .map(|project| {
            let card = folders::card_path(&project.path, language);
            FolderRow {
                path: project.path.to_string_lossy().into_owned(),
                name: project.name.clone(),
                stage: project.card.stage().map(str::to_owned),
                stage_index: project.card.stage().and_then(|stage| stages.iter().position(|s| s == stage)),
                metrics: metrics
                    .iter()
                    .filter_map(|metric| folders::metric_text(metric, project, profile.words_per_minute(), texts, language, now))
                    .collect::<Vec<_>>()
                    .join(" · "),
                overdue: folders::overdue(project, done.as_deref(), texts, now.date_naive()),
                format: project.card.get(folders::Key::Format).or(project.card.get(folders::Key::Platform)).map(str::to_owned),
                main_file: project.main_file.clone(),
                card_file: project.has_card_file.then(|| card.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()),
                create_card: texts.format("Создать %@", &[&folders::card_file_name(language)]),
                commands: crate::commands::buttons(profile, texts),
                jobs: crate::commands::rows(app, &project.path, texts),
                no_text: project.main_file.is_none() && crate::commands::needs_main_file(profile),
            }
        })
        .collect();
    let default_service = crate::commands::default_service(profile);
    Some(FolderView { rows, stages, can_create: matches!(profile.source(), claudepult_core::profiles::Source::Folders(_)), services: crate::commands::choices(app), default_service })
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
    let folder_rows = folder_view(&app, &state, &texts);
    let message = match state.problem {
        Some(Problem::NoFolder) => Some(texts.format("Папки нет: %@", &[&projects_root(&app).to_string_lossy()])),
        None if folder_rows.as_ref().is_some_and(|f| f.rows.is_empty()) && state.updated.is_some() => Some(if folder_rows.as_ref().is_some_and(|f| f.can_create) {
            let root = claudepult_core::profiles::tilde(&projects_root(&app), &dirs::home_dir().unwrap_or_default());
            texts.format("Проектов пока нет: каждая папка внутри «%@» — проект.", &[&root])
        } else {
            texts.t("Папка пуста.").to_owned()
        }),
        Some(Problem::NoSource) => Some(texts.t("Проектов нет: у профиля нет папки с git-проектами.").to_owned()),
        Some(Problem::NoGit) => Some(texts.t("Не удалось прочитать репозитории").to_owned()),
        None if state.updated.is_some() && state.projects.is_empty() => Some(texts.t("В папке проектов не найдено git-репозиториев.").to_owned()),
        None => None,
    };
    let agents = crate::commands::agent_choices(&app);
    ProjectsView { rows: state.projects.iter().map(|p| row(p, &words, now)).collect(), agents, folders: folder_rows, message, refreshing: state.refreshing }
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

// MARK: - Folder projects

/// A stage chip in an opened folder project: «Этап:» in its card (the card is made when there is none).
#[tauri::command]
pub fn set_project_stage(app: AppHandle, path: String, stage: String) -> Result<(), String> {
    let path = PathBuf::from(path);
    let projects = app.state::<Projects>();
    projects.folder_project(&path).ok_or("unknown project")?;
    let texts = strings(&app);
    folders::set_stage(&path, &stage, language(&app)).map_err(|error| {
        let card = folders::card_file_name(language(&app));
        texts.format("Не удалось записать %@: %@", &[&card, &error.to_string()])
    })?;
    projects.reread(&app, &path);
    Ok(())
}

/// «Создать проект.md» for a project without a card, at the profile's first stage.
#[tauri::command]
pub fn create_project_card(app: AppHandle, path: String) -> Result<(), String> {
    let path = PathBuf::from(path);
    let projects = app.state::<Projects>();
    projects.folder_project(&path).ok_or("unknown project")?;
    let first = app.state::<crate::AppState>().settings.lock().unwrap().current().and_then(|p| p.stages().into_iter().next());
    folders::create_card(&path, first.as_deref(), language(&app)).map_err(|e| e.to_string())?;
    projects.reread(&app, &path);
    Ok(())
}

/// «Новый проект»: a folder with a card in the profile's projects folder. Returns its path, to open it.
#[tauri::command]
pub fn create_folder_project(app: AppHandle, name: String) -> Result<String, String> {
    let texts = strings(&app);
    let settings = app.state::<crate::AppState>().settings.lock().unwrap().clone();
    let profile = settings.current().filter(|p| matches!(p.source(), claudepult_core::profiles::Source::Folders(_)));
    let (Some(profile), Some(root)) = (profile, settings.projects_dir()) else {
        return Err(texts.t("У этого профиля нет папки проектов").to_owned());
    };
    let first = profile.stages().into_iter().next();
    let folder = folders::create_project(&root, &name, first.as_deref(), language(&app)).map_err(|error| match error {
        folders::CreateError::BadName => texts.t("Название не подходит для папки").to_owned(),
        folders::CreateError::Exists => texts.t("Такая папка уже есть").to_owned(),
        folders::CreateError::Io(error) => error,
    })?;
    eprintln!("folder project created: {}", folder.display());
    app.state::<Projects>().ask(false);
    Ok(folder.to_string_lossy().into_owned())
}

/// A file of a folder project — its main file or its card — opened in its app. Only inside a scanned project.
#[tauri::command]
pub fn open_project_file(app: AppHandle, path: String, file: String) -> Result<(), String> {
    let folder = PathBuf::from(path);
    app.state::<Projects>().folder_project(&folder).ok_or("unknown project")?;
    let target = folder.join(&file);
    let inside = target.canonicalize().ok().zip(folder.canonicalize().ok()).is_some_and(|(t, f)| t.starts_with(&f) && t != f);
    if !inside || !target.is_file() {
        return Err("not a file of this project".into());
    }
    open_with_system(target.as_os_str())
}

/// «Открыть в…»: another installed agent in a terminal window, in a scanned project's folder (the Mac's
/// `ClaudeActionsView.otherAgents`).
#[tauri::command]
pub fn open_agent(app: AppHandle, path: String, agent: String) -> Result<(), String> {
    let path = PathBuf::from(path);
    if !app.state::<Projects>().knows_path(&path) {
        return Err("unknown project".into());
    }
    let found = app.state::<crate::services::Agents>().found().into_iter().find(|f| f.id == agent).ok_or("not installed")?;
    eprintln!("opening {} in {}", found.id, path.display());
    launch::open_in_terminal(&path, &found.path, &[]).map_err(|e| strings(&app).format("Не удалось открыть Терминал: %@", &[&e]))
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
    pub(crate) message: String,
    /// The folder is busy and the command can't move to a worktree: «Запустить всё равно» asks again.
    pub(crate) confirm: bool,
    /// No mode chosen yet: «Где запустить «…»?» with «Терминал» / «Фон».
    pub(crate) choose: Option<String>,
    /// The session is nearly used up: «Запустить после сброса» / «Запустить сейчас».
    pub(crate) limit: bool,
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
    agent: Option<String>,
    skip_limit: bool,
) -> Result<LaunchReply, String> {
    let codex = agent.as_deref() == Some("codex");
    tauri::async_runtime::spawn_blocking(move || launch_now(&app, Path::new(&path), &command, task, allow_busy, mode, remember, codex, skip_limit))
        .await
        .map_err(|e| e.to_string())?
}

pub(crate) fn launch_now(
    app: &AppHandle,
    path: &Path,
    command: &str,
    task: Option<String>,
    allow_busy: bool,
    mode: Option<String>,
    remember: bool,
    codex: bool,
    skip_limit: bool,
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
    // Codex goes to the background only (`codex exec`), as from the Mac's «Быстрый запрос»; a terminal is «Открыть в…».
    let mode = if codex { Some("background".to_owned()) } else { mode.filter(|m| LAUNCH_MODES.contains(&m.as_str())) };
    if remember && mode.is_some() && !codex {
        crate::save(app, |s| s.set_launch_mode(mode.clone()));
        let _ = app.emit("profiles-changed", ());
    }
    let Some(mode) = mode.or(settings.launch_mode()) else {
        return Ok(LaunchReply { choose: Some(texts.format("Где запустить «%@»?", &[&title])), ..LaunchReply::default() });
    };
    let background = mode == "background";
    // Near the session's limit a background run of Claude asks first (the Mac's limit guard).
    if background && !codex && !skip_limit {
        let session = app.state::<crate::limits::Limits>().snapshot().and_then(|snapshot| snapshot.session().cloned());
        if let Some(session) = session.filter(|session| session.utilization > claudepult_core::queue::LAUNCH_WARNING) {
            let reset = session.resets_at.map(|at| texts.format(", сброс в %@", &[&at.with_timezone(&chrono::Local).format("%H:%M").to_string()])).unwrap_or_default();
            let message = texts.format("Сессия использована на %@%@. Фоновая задача может упереться в лимит.", &[&claudepult_core::texts::percent(session.utilization), &reset]);
            return Ok(LaunchReply { message, limit: true, ..LaunchReply::default() });
        }
    }
    let program = if codex {
        let kind = claudepult_core::agents::kind("codex").expect("listed");
        claudepult_core::agents::detect(kind).ok_or_else(|| texts.format("%@ не установлен", &[kind.title]))?
    } else {
        launch::find_claude().ok_or_else(|| texts.t("Claude Code не установлен").to_owned())?
    };
    let claude = program.clone();

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
            return Ok(LaunchReply { message, confirm: true, ..LaunchReply::default() });
        }
    }

    let prompt = launch::one_line(&command.prompt(&Style::for_projects(&projects_root(app)), language(app)));
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
            permissions: "code",
            result_file: None,
            codex,
            review_of: None,
            pair: None,
        };
        let (run, child) = claudepult_core::runs::start(&paths::runs_dir(), &program, &new).map_err(|e| e.to_string())?;
        eprintln!("run {} started: «{title}» in {}{}", run.id, folder.display(), if codex { " (Codex)" } else { "" });
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

/// «И в Codex — сравнить» (the Mac's `launchBoth`): the same task goes to Claude and to Codex in the background,
/// each in its own new worktree, so their changes do not meet. One notification comes when both have finished.
#[tauri::command]
pub async fn launch_both(app: AppHandle, path: String, task: String) -> Result<LaunchReply, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let texts = strings(&app);
        let project = Path::new(&path);
        let task = task.trim().to_owned();
        if task.is_empty() {
            return Err("unknown command".to_owned());
        }
        let (base, _) = app.state::<Projects>().launch_target(project).ok_or("unknown project")?;
        let kind = claudepult_core::agents::kind("codex").expect("listed");
        let codex = claudepult_core::agents::detect(kind).ok_or_else(|| texts.format("%@ не установлен", &[kind.title]))?;
        let claude = launch::find_claude().ok_or_else(|| texts.t("Claude Code не установлен").to_owned())?;
        let tools = Tools::find().ok_or("git not found")?;
        let settings = app.state::<crate::AppState>().settings.lock().unwrap().clone();
        let command = ClaudeCommand::CustomTask(task.clone());
        let prompt = launch::one_line(&command.prompt(&Style::for_projects(&projects_root(&app)), language(&app)));
        let title = texts.t("Своя задача").to_owned();
        let name = project.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let pair = claudepult_core::runs::new_id();
        let mut branches = Vec::new();
        for (program, by_codex) in [(&claude, false), (&codex, true)] {
            let plan = launch::create_worktree(&tools, project, &claudepult_core::runs::pair_name_source(&task, by_codex), &base)?;
            let new = NewRun {
                project: &name,
                project_path: project,
                folder: &plan.path,
                worktree_branch: Some(plan.branch.as_str()),
                command_title: &title,
                task: &task,
                prompt: &prompt,
                time_limit_minutes: settings.background_time_limit_minutes,
                permissions: "code",
                result_file: None,
                codex: by_codex,
                review_of: None,
                pair: Some(&pair),
            };
            let (run, child) = claudepult_core::runs::start(&paths::runs_dir(), program, &new).map_err(|e| e.to_string())?;
            eprintln!("run {} started: pair {pair} in {}{}", run.id, plan.path.display(), if by_codex { " (Codex)" } else { "" });
            app.state::<Runs>().add(&app, run, child);
            branches.push(plan.branch);
        }
        app.state::<Projects>().ask(false);
        let message = texts.format("«%@» запущен в фоне у Claude и Codex, каждый в своём worktree: %@. Итог придёт, когда закончат оба.", &[&title, &branches.join(", ")]);
        Ok(LaunchReply { message, ..LaunchReply::default() })
    })
    .await
    .map_err(|e| e.to_string())?
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
pub(crate) fn open_with_system(target: &std::ffi::OsStr) -> Result<(), String> {
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
