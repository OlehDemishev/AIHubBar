//! Stage 5: the commands of a folder project (the Mac's `CommandEngine` and `ProjectCommandsView`), run by Claude
//! Code — in the background with the profile's permissions («Только файлы», «Файлы + поиск в интернете»), or in a
//! terminal window when the profile says so. The result is always a new file in the project folder. Models by API and
//! «Сравнить» come with «Сервисы AI».

use crate::projects::Projects;
use crate::runs::Runs;
use crate::{language, strings, AppState};
use claudepult_core::commands::{self, Command, Context};
use claudepult_core::i18n::Strings;
use claudepult_core::launch;
use claudepult_core::profiles::Profile;
use claudepult_core::runs::{NewRun, Run, RunState};
use claudepult_core::paths;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};

#[derive(Clone)]
enum JobState {
    Background(String),
    Terminal,
    Failed(String),
}

#[derive(Clone)]
struct Job {
    id: String,
    project: PathBuf,
    title: String,
    result_file: PathBuf,
    state: JobState,
}

/// What was started from the panel since the app started, newest first.
#[derive(Default)]
pub struct Jobs(Mutex<Vec<Job>>);

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
pub struct JobRow {
    id: String,
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
        JobState::Terminal => ("terminal", Some(texts.t("Открыто в Терминале").to_owned()), None),
        JobState::Failed(message) => ("failed", Some(message.clone()), None),
        JobState::Background(id) => match runs.iter().find(|r| &r.id == id) {
            Some(run) if run.is_running() => ("running", None, None),
            Some(run) if run.state == RunState::Succeeded && job.result_file.is_file() => ("done", None, file_name),
            Some(run) => ("failed", Some(crate::runs::outcome_text(texts, run)), None),
            None => ("failed", None, None),
        },
    };
    JobRow { id: job.id.clone(), title: job.title.clone(), state, message, result }
}

fn is_finished(job: &Job, runs: &[Run]) -> bool {
    match &job.state {
        JobState::Background(id) => !runs.iter().any(|r| &r.id == id && r.is_running()),
        _ => true,
    }
}

/// A command button (or its field's «Запустить»): the result's name is chosen now, so it is never an existing file.
#[tauri::command]
pub fn run_folder_command(app: AppHandle, path: String, command: String, text: Option<String>) -> Result<(), String> {
    let texts = strings(&app);
    let language = language(&app);
    let folder = PathBuf::from(&path);
    let project = app.state::<Projects>().folder_project(&folder).ok_or("unknown project")?;
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let profile = settings.current().filter(|p| p.source().is_folders()).ok_or("no folder profile")?.clone();
    let template = all(&profile, &texts).into_iter().find(|c| c.id == command).ok_or("unknown command")?;
    let context = Context::new(&template, &project, &profile, text.as_deref(), chrono::Local::now());
    let name = commands::unique_name(&commands::output_name(&template.output, &context, language), |n| folder.join(n).exists());
    let result_file = folder.join(&name);
    let task = commands::fill(&template.task, &context, language);
    let title = commands::run_title(&template.title, context.text.as_deref());
    eprintln!("command «{}» in {} → {name}", template.title, folder.display());

    let state = match launch::find_claude() {
        None => JobState::Failed(texts.t("Claude Code не установлен").to_owned()),
        Some(claude) if profile.launch_mode.as_deref() == Some("terminal") => {
            let prompt = launch::one_line(&commands::agent_prompt(&task, &context, &name, None, language));
            match launch::open_in_terminal(&folder, &claude, &[&prompt]) {
                Ok(()) => JobState::Terminal,
                Err(error) => JobState::Failed(texts.format("Не удалось открыть Терминал: %@", &[&error])),
            }
        }
        Some(claude) => {
            // With no shell an `.rtf` would be read as markup: its text goes into the prompt instead.
            let inline = context.file.as_deref().and_then(|f| commands::inline_text(&folder.join(f)));
            let prompt = commands::agent_prompt(&task, &context, &name, inline.as_deref(), language);
            let permissions = profile.other.get("permissions").and_then(|v| v.as_str()).unwrap_or("filesOnly").to_owned();
            let new = NewRun {
                project: &project.name,
                project_path: &folder,
                folder: &folder,
                worktree_branch: None,
                command_title: &template.title,
                task: &title,
                prompt: &prompt,
                time_limit_minutes: settings.background_time_limit_minutes,
                permissions: &permissions,
                result_file: Some(&result_file),
            };
            match claudepult_core::runs::start(&paths::runs_dir(), &claude, &new) {
                Ok((run, child)) => {
                    let id = run.id.clone();
                    eprintln!("run {id} started: «{title}» ({permissions})");
                    app.state::<Runs>().add(&app, run, child);
                    JobState::Background(id)
                }
                Err(error) => JobState::Failed(error.to_string()),
            }
        }
    };
    // A failure shows in the job's row, as on the Mac.
    let job = Job { id: claudepult_core::runs::new_id(), project: folder, title, result_file, state };
    app.state::<Jobs>().0.lock().unwrap().insert(0, job);
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
