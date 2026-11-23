//! The search field in the panel (the Mac's `PanelSearchField` / `PanelSearchResults`).

use claudepult_core::search::{self, Item, Kind, SavedPrompt};
use serde::Serialize;
use tauri::{AppHandle, Manager};

use crate::{save, strings, AppState};

/// «Свои промпты»: the kept list, or the two examples until it is edited.
fn prompts(app: &AppHandle) -> Vec<SavedPrompt> {
    let kept = app.state::<AppState>().settings.lock().unwrap().saved_prompts.clone();
    kept.unwrap_or_else(|| SavedPrompt::examples(&strings(app)))
}

#[tauri::command]
pub fn saved_prompts_view(app: AppHandle) -> Vec<SavedPrompt> {
    prompts(&app)
}

/// Settings → «Свои промпты»: the whole list as it is on the page.
#[tauri::command]
pub fn set_saved_prompts(app: AppHandle, prompts: Vec<SavedPrompt>) -> Vec<SavedPrompt> {
    let list = search::saved_prompts(serde_json::to_value(prompts).ok().as_ref()).unwrap_or_default();
    save(&app, |settings| settings.saved_prompts = Some(list));
    self::prompts(&app)
}

/// «Добавить промпт».
#[tauri::command]
pub fn add_saved_prompt(app: AppHandle) -> Vec<SavedPrompt> {
    let mut list = prompts(&app);
    list.push(SavedPrompt { id: claudepult_core::runs::new_id(), title: strings(&app).t("Новый промпт").to_owned(), text: String::new() });
    save(&app, |settings| settings.saved_prompts = Some(list));
    prompts(&app)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PromptProject {
    id: String,
    name: String,
    detail: String,
    /// «Запустить в shop».
    hint: String,
}

/// Step two of a saved prompt: the projects it can start in.
#[tauri::command]
pub fn prompt_projects(app: AppHandle, query: String, projects: Vec<Item>) -> Vec<PromptProject> {
    let texts = strings(&app);
    search::prompt_projects(&query, &projects).into_iter().map(|project| PromptProject { hint: texts.format("Запустить в %@", &[&project.name]), id: project.id, name: project.name, detail: project.detail }).collect()
}

/// The prompt's text for this project. {файл} stays empty: there is no selected file to ask Explorer for.
#[tauri::command]
pub fn fill_saved_prompt(app: AppHandle, id: String, project: String, branch: Option<String>) -> Result<String, String> {
    let prompt = prompts(&app).into_iter().find(|prompt| prompt.id == id).ok_or("no such prompt")?;
    eprintln!("saved prompt «{}» for {project}", prompt.title);
    Ok(prompt.filled(&project, branch.as_deref().filter(|b| !b.is_empty()), None))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FoundRow {
    kind: Kind,
    id: String,
    title: String,
    detail: String,
    /// What Enter or a click does.
    hint: String,
    /// A saved prompt: «Проект для «Ревью ветки»…» for the field of its second step.
    placeholder: Option<String>,
}

/// What the panel shows now — its sessions, projects and quick commands — searched by the typed text.
#[tauri::command]
pub fn panel_search(app: AppHandle, query: String, sessions: Vec<Item>, projects: Vec<Item>, quick_commands: Vec<Item>, with_prompts: bool) -> Vec<FoundRow> {
    let texts = strings(&app);
    // Prompts start in a git project: not offered where the profile's projects are folders.
    let prompts: Vec<Item> = if with_prompts { prompts(&app).into_iter().map(|p| Item { id: p.id, name: p.title, detail: p.text }).collect() } else { Vec::new() };
    search::results(&query, &sessions, &prompts, &projects, &quick_commands)
        .into_iter()
        .map(|found| FoundRow {
            hint: match found.kind {
                Kind::Session => texts.t("Показать сессию").to_owned(),
                Kind::Prompt => texts.t("Выбрать проект и запустить").to_owned(),
                Kind::Project => texts.t("Раскрыть проект в панели").to_owned(),
                Kind::QuickCommand => texts.t("Запустить").to_owned(),
            },
            placeholder: (found.kind == Kind::Prompt).then(|| texts.format("Проект для «%@»…", &[&found.title])),
            detail: match found.kind {
                Kind::QuickCommand => texts.t("быстрая команда").to_owned(),
                Kind::Prompt => texts.t("свой промпт").to_owned(),
                _ => found.detail,
            },
            kind: found.kind,
            id: found.id,
            title: found.title,
        })
        .collect()
}
