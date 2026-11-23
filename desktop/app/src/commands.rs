//! Stage 5: the commands of a folder project (the Mac's `CommandEngine` and `ProjectCommandsView`). Claude Code works
//! in the background with the profile's permissions («Только файлы», «Файлы + поиск в интернете»), or in a terminal
//! window when the profile says so; another agent opens in a terminal with the task on the clipboard; a model by API
//! gets the main file's text and AI Hub Bar writes its answer. The
//! result is always a new file in the project folder. «Сравнить» runs one command with 2–3 services and puts their
//! results side by side: `хуки (Claude).md`, `хуки (OpenAI).md`.

use crate::projects::Projects;
use crate::runs::Runs;
use crate::{language, strings, AppState};
use claudepult_core::ai::{self, Service};
use claudepult_core::commands::{self, Command, Context};
use claudepult_core::folders::{self, FolderProject};
use claudepult_core::i18n::Strings;
use claudepult_core::profiles::Profile;
use claudepult_core::runs::{NewRun, Run, RunState};
use claudepult_core::{keys, launch, paths};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

#[derive(Clone)]
enum JobState {
    /// A request to a model by API is under way.
    Working,
    Background(String),
    /// Opened in a terminal window: what to do there.
    Terminal(String),
    Done,
    Failed(String),
}

#[derive(Clone)]
struct Job {
    id: String,
    project: PathBuf,
    title: String,
    /// «Claude», «OpenAI», the compatible server's name.
    service: String,
    result_file: PathBuf,
    state: JobState,
}

/// What was started from the panel since the app started, newest first.
#[derive(Default, Clone)]
pub struct Jobs(Arc<Mutex<Vec<Job>>>);

impl Jobs {
    fn set(&self, id: &str, state: JobState) {
        if let Some(job) = self.0.lock().unwrap().iter_mut().find(|j| j.id == id) {
            job.state = state;
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandButton {
    id: String,
    title: String,
    hint: String,
    /// The field to fill before it runs: «Язык», «Тон», «Задача».
    asks: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceChoice {
    id: String,
    name: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JobRow {
    id: String,
    /// «Хуки · OpenAI».
    title: String,
    /// `running`, `done`, `failed` or `terminal`.
    state: &'static str,
    /// Why it failed, or «Открыто в Терминале».
    message: Option<String>,
    /// The result's file name once it is there.
    result: Option<String>,
}

/// The profile's commands and «Своя задача», as buttons.
pub fn buttons(profile: &Profile, texts: &Strings) -> Vec<CommandButton> {
    all(profile, texts)
        .into_iter()
        .map(|c| CommandButton {
            hint: if c.id == commands::CUSTOM_TASK { texts.t("Напишите задачу своими словами — AI выполнит её над файлом").to_owned() } else { c.hint() },
            id: c.id,
            title: c.title,
            asks: c.asks,
        })
        .collect()
}

/// Who can run the commands now, for the project's «Каким сервисом выполнять» and «Сравнить».
pub fn choices(app: &AppHandle) -> Vec<ServiceChoice> {
    let services = app.state::<AppState>().settings.lock().unwrap().services();
    crate::services::available(app).into_iter().map(|s| ServiceChoice { id: s.id(), name: s.short_name(&services) }).collect()
}

/// The installed agents other than Claude Code, by name: «Открыть в…».
pub fn agent_choices(app: &AppHandle) -> Vec<ServiceChoice> {
    app.state::<crate::services::Agents>()
        .found()
        .into_iter()
        .filter_map(|f| claudepult_core::agents::kind(f.id).map(|k| ServiceChoice { id: f.id.to_owned(), name: k.title.to_owned() }))
        .collect()
}

/// The service a project's commands go to unless the person picks another: the profile's (`claude-code` by default).
pub fn default_service(profile: &Profile) -> String {
    profile.other.get("service").and_then(|v| v.as_str()).and_then(Service::parse).map(|s| s.id()).unwrap_or_else(|| "claude-code".into())
}

fn all(profile: &Profile, texts: &Strings) -> Vec<Command> {
    let mut list = commands::of_profile(profile);
    list.push(Command::custom_task(texts.t("Своя задача"), texts.t("Задача")));
    list
}

/// Whether a command of the profile works on the main file (the note «В папке нет текстового файла…» then).
pub fn needs_main_file(profile: &Profile) -> bool {
    commands::of_profile(profile).iter().any(|c| c.on_main_file)
}

/// The project's jobs, with the background ones' state taken from their runs.
pub fn rows(app: &AppHandle, project: &Path, texts: &Strings) -> Vec<JobRow> {
    let runs = app.state::<Runs>().list();
    let jobs = app.state::<Jobs>().0.lock().unwrap().clone();
    jobs.iter().filter(|j| j.project == project).map(|job| row(job, &runs, texts)).collect()
}

fn row(job: &Job, runs: &[Run], texts: &Strings) -> JobRow {
    let file_name = job.result_file.file_name().map(|n| n.to_string_lossy().into_owned());
    let (state, message, result) = match &job.state {
        JobState::Working => ("running", None, None),
        JobState::Done => ("done", None, file_name),
        JobState::Terminal(message) => ("terminal", Some(message.clone()), None),
        JobState::Failed(message) => ("failed", Some(message.clone()), None),
        JobState::Background(id) => match runs.iter().find(|r| &r.id == id) {
            Some(run) if run.is_running() => ("running", None, None),
            Some(run) if run.state == RunState::Succeeded && job.result_file.is_file() => ("done", None, file_name),
            Some(run) => ("failed", Some(crate::runs::outcome_text(texts, run)), None),
            None => ("failed", None, None),
        },
    };
    JobRow { id: job.id.clone(), title: format!("{} · {}", job.title, job.service), state, message, result }
}

fn is_finished(job: &Job, runs: &[Run]) -> bool {
    match &job.state {
        JobState::Working => false,
        JobState::Background(id) => !runs.iter().any(|r| &r.id == id && r.is_running()),
        _ => true,
    }
}

/// Everything one run needs, gathered once for a command or a comparison.
struct Request {
    project: FolderProject,
    profile: Profile,
    template: Command,
    context: Context,
    time_limit: u32,
}

/// Starts one command with one service; the result's name is chosen now, so it is never an existing file.
fn start(app: &AppHandle, request: &Request, service: &Service, suffix: Option<&str>) {
    let texts = strings(app);
    let language = language(app);
    let folder = &request.project.path;
    let context = &request.context;
    let services = app.state::<AppState>().settings.lock().unwrap().services();
    let name = commands::unique_name(&commands::output_name(&request.template.output, context, language, suffix), |n| folder.join(n).exists());
    let result_file = folder.join(&name);
    let task = commands::fill(&request.template.task, context, language);
    let title = commands::run_title(&request.template.title, context.text.as_deref());
    let id = claudepult_core::runs::new_id();
    eprintln!("command «{}» → {} in {} → {name}", request.template.title, service.id(), folder.display());
    let mut job = Job { id: id.clone(), project: folder.clone(), title: title.clone(), service: service.short_name(&services), result_file: result_file.clone(), state: JobState::Working };

    match service {
        Service::Api(provider) => {
            let file_text = context.file.as_deref().and_then(|f| folders::text_of(&folder.join(f)));
            let prompt = commands::api_prompt(&task, context, file_text.as_deref(), language);
            let (app, jobs, provider, project) = (app.clone(), app.state::<Jobs>().inner().clone(), *provider, request.project.name.clone());
            app.state::<Jobs>().0.lock().unwrap().insert(0, job);
            std::thread::spawn(move || {
                let texts = strings(&app);
                let key = keys::read(provider.id);
                let state = match ai::complete(provider, &services, key.as_deref(), &prompt, &texts) {
                    Ok((reply, model)) => match std::fs::write(&result_file, &reply.text) {
                        Ok(()) => {
                            let record = ai::SpendRecord { date: chrono::Utc::now(), provider: provider.id.into(), model, input_tokens: reply.input_tokens, output_tokens: reply.output_tokens };
                            if let Err(error) = ai::record_spend(&crate::services::spend_path(), record) {
                                eprintln!("API spend not saved: {error}");
                            }
                            crate::services::warn_about_budget(&app);
                            let _ = app.notification().builder().title(texts.format("Готово: %@", &[&title])).body(format!("{project} · {name}")).show();
                            JobState::Done
                        }
                        Err(error) => JobState::Failed(texts.format("Не удалось записать %@: %@", &[&name, &error.to_string()])),
                    },
                    Err(message) => JobState::Failed(message),
                };
                if let JobState::Failed(message) = &state {
                    eprintln!("command via {} failed: {message}", provider.id);
                }
                jobs.set(&id, state);
                let _ = app.emit("projects-changed", ());
                app.state::<Projects>().ask(false);
            });
            return;
        }
        // Other agents only in a terminal, as on the Mac (their «no actions» modes aren't checked live): the agent opens
        // in the folder and the task goes to the clipboard to paste.
        Service::Agent(id) => {
            let kind = claudepult_core::agents::kind(id);
            let found = app.state::<crate::services::Agents>().found().into_iter().find(|f| &f.id == id).map(|f| f.path);
            let title = kind.map(|k| k.title).unwrap_or(id);
            job.state = match (kind, found) {
                (Some(kind), Some(path)) => {
                    use tauri_plugin_clipboard_manager::ClipboardExt;
                    let prompt = commands::agent_prompt(&task, context, &name, None, language);
                    match app.clipboard().write_text(prompt).map_err(|e| e.to_string()).and_then(|()| launch::open_in_terminal(folder, &path, &[])) {
                        Ok(()) => JobState::Terminal(texts.format("%@ открыт в Терминале — задача скопирована, вставьте Ctrl+V", &[kind.title])),
                        Err(error) => JobState::Failed(texts.format("Не удалось открыть Терминал: %@", &[&error])),
                    }
                }
                _ => JobState::Failed(texts.format("%@ не установлен", &[title])),
            };
        }
        Service::ClaudeCode => {
            job.service = "Claude".into();
            job.state = match launch::find_claude() {
                None => JobState::Failed(texts.t("Claude Code не установлен").to_owned()),
                Some(claude) if request.profile.launch_mode.as_deref() == Some("terminal") => {
                    let prompt = launch::one_line(&commands::agent_prompt(&task, context, &name, None, language));
                    match launch::open_in_terminal(folder, &claude, &[&prompt]) {
                        Ok(()) => JobState::Terminal(texts.t("Открыто в Терминале").to_owned()),
                        Err(error) => JobState::Failed(texts.format("Не удалось открыть Терминал: %@", &[&error])),
                    }
                }
                Some(claude) => {
                    // With no shell an `.rtf` would be read as markup: its text goes into the prompt instead.
                    let inline = context.file.as_deref().and_then(|f| commands::inline_text(&folder.join(f)));
                    let prompt = commands::agent_prompt(&task, context, &name, inline.as_deref(), language);
                    let permissions = request.profile.other.get("permissions").and_then(|v| v.as_str()).unwrap_or("filesOnly").to_owned();
                    let new = NewRun {
                        project: &request.project.name,
                        project_path: folder,
                        folder,
                        worktree_branch: None,
                        command_title: &request.template.title,
                        task: &title,
                        prompt: &prompt,
                        time_limit_minutes: request.time_limit,
                        permissions: &permissions,
                        result_file: Some(&result_file),
                        codex: false,
                        review_of: None,
                    };
                    match claudepult_core::runs::start(&paths::runs_dir(), &claude, &new) {
                        Ok((run, child)) => {
                            let run_id = run.id.clone();
                            eprintln!("run {run_id} started: «{title}» ({permissions})");
                            app.state::<Runs>().add(app, run, child);
                            JobState::Background(run_id)
                        }
                        Err(error) => JobState::Failed(error.to_string()),
                    }
                }
            };
        }
    }
    app.state::<Jobs>().0.lock().unwrap().insert(0, job);
}

fn request(app: &AppHandle, path: &str, command: &str, text: Option<&str>) -> Result<Request, String> {
    let texts = strings(app);
    let folder = PathBuf::from(path);
    let project = app.state::<Projects>().folder_project(&folder).ok_or("unknown project")?;
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let profile = settings.current().filter(|p| p.source().is_folders()).ok_or("no folder profile")?.clone();
    let template = all(&profile, &texts).into_iter().find(|c| c.id == command).ok_or("unknown command")?;
    let context = Context::new(&template, &project, &profile, text, chrono::Local::now());
    Ok(Request { project, profile, template, context, time_limit: settings.background_time_limit_minutes })
}

/// A command button (or its field's «Запустить») with the service chosen for the project; the command's own service
/// wins, as on the Mac. A failure shows in the job's row.
#[tauri::command]
pub fn run_folder_command(app: AppHandle, path: String, command: String, text: Option<String>, service: Option<String>) -> Result<(), String> {
    let request = request(&app, &path, &command, text.as_deref())?;
    let chosen = request.template.service.clone().or(service).unwrap_or_else(|| default_service(&request.profile));
    let service = Service::parse(&chosen).unwrap_or(Service::ClaudeCode);
    start(&app, &request, &service, None);
    let _ = app.emit("projects-changed", ());
    Ok(())
}

/// «Сравнить»: the same command with 2–3 services, each result named after its service.
#[tauri::command]
pub fn compare_folder_command(app: AppHandle, path: String, command: String, text: Option<String>, services: Vec<String>) -> Result<(), String> {
    let request = request(&app, &path, &command, text.as_deref())?;
    let config = app.state::<AppState>().settings.lock().unwrap().services();
    let chosen: Vec<Service> = services.iter().filter_map(|id| Service::parse(id)).take(3).collect();
    if chosen.len() < 2 {
        return Err(strings(&app).t("Выберите 2–3 сервиса, затем команду.").to_owned());
    }
    for service in &chosen {
        start(&app, &request, service, Some(&service.short_name(&config)));
    }
    let _ = app.emit("projects-changed", ());
    Ok(())
}

/// «Убрать готовые»: what has ended goes from the project's list (running ones stay).
#[tauri::command]
pub fn clear_finished_jobs(app: AppHandle, path: String) {
    let runs = app.state::<Runs>().list();
    let folder = PathBuf::from(path);
    app.state::<Jobs>().0.lock().unwrap().retain(|job| job.project != folder || !is_finished(job, &runs));
    let _ = app.emit("projects-changed", ());
}
