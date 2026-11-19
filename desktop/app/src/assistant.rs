//! Stage 5: the profile assistant (the Mac's `AssistantView`, docs/specs/SPEC-modes.md §5) — one choice per screen:
//! a template or «С нуля», the projects folder (what it holds suggests git repositories or folders), stages, the
//! row's metrics, the calendar and reminders, the service, where Claude runs and what it may do, the name. The draft
//! is the Mac's profile JSON, kept by the page; «Готово» adds it and makes it current. The Mac's steps for modules,
//! the menu bar and SF Symbol icons have nothing to set here and are left out.

use crate::{language, strings, AppState};
use claudepult_core::assistant::{self, Analysis};
use claudepult_core::profiles::{self, Profile};
use serde::Serialize;
use serde_json::Value;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};
use tauri_plugin_dialog::DialogExt;

#[tauri::command]
pub fn open_assistant(app: AppHandle) {
    if let Some(window) = app.get_webview_window("assistant") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    let title = format!("{} — {}", claudepult_core::APP_NAME, strings(&app).t("Помощник…").trim_end_matches('…'));
    crate::off_main_thread(move || {
        let _ = tauri::WebviewWindowBuilder::new(&app, "assistant", tauri::WebviewUrl::App("assistant.html".into()))
            .title(title)
            .inner_size(640.0, 620.0)
            .min_inner_size(520.0, 480.0)
            .center()
            .build();
    });
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TemplateChoice {
    id: &'static str,
    title: String,
    description: String,
    folder_hint: String,
    mode: Value,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantStart {
    templates: Vec<TemplateChoice>,
    /// «С нуля».
    blank: Value,
    /// Who can run commands now: Claude Code first.
    services: Vec<crate::commands::ServiceChoice>,
    reminder_hours: Vec<i64>,
}

#[tauri::command]
pub fn assistant_start(app: AppHandle) -> AssistantStart {
    let texts = strings(&app);
    let language = language(&app);
    let templates = profiles::template_entries(language)
        .into_iter()
        .map(|(id, entry)| TemplateChoice {
            id,
            title: entry["title"].as_str().unwrap_or(id).to_owned(),
            description: entry["description"].as_str().unwrap_or_default().to_owned(),
            folder_hint: entry["folderHint"].as_str().unwrap_or_default().to_owned(),
            mode: entry["mode"].clone(),
        })
        .collect();
    AssistantStart {
        templates,
        blank: serde_json::to_value(assistant::blank(&texts)).unwrap_or_default(),
        services: crate::commands::choices(&app),
        reminder_hours: app.state::<AppState>().settings.lock().unwrap().calendar_reminder_hours.clone(),
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderLook {
    /// The folder as this system writes it.
    path: String,
    exists: bool,
    /// «Внутри git-репозиториев: 3, …», when it exists.
    text: Option<String>,
    suggests_git: bool,
}

fn look(app: &AppHandle, path: &std::path::Path) -> (FolderLook, Option<Analysis>) {
    let exists = path.is_dir();
    let analysis = exists.then(|| Analysis::of(path));
    let view = FolderLook {
        path: path.to_string_lossy().into_owned(),
        exists,
        text: analysis.map(|a| a.text(&strings(app))),
        suggests_git: analysis.is_some_and(|a| a.suggests_git()),
    };
    (view, analysis)
}

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_default()
}

/// What the draft's folder holds now.
#[tauri::command]
pub fn assistant_look(app: AppHandle, folder: String) -> FolderLook {
    look(&app, &profiles::expand(&folder, &home())).0
}

#[derive(Serialize)]
pub struct Chosen {
    draft: Value,
    look: FolderLook,
}

/// «Выбрать…»: the system's folder picker; the draft gets the folder and the source it suggests.
#[tauri::command]
pub async fn assistant_choose_folder(app: AppHandle, draft: Value) -> Option<Chosen> {
    let current = Profile::from_value(&draft).and_then(|p| p.projects_dir(&home())).unwrap_or_else(|| home().join("Documents"));
    let start = current.ancestors().find(|dir| dir.is_dir()).map(std::path::Path::to_path_buf);
    let mut dialog = app.dialog().file();
    if let Some(start) = start {
        dialog = dialog.set_directory(start);
    }
    if let Some(window) = app.get_webview_window("assistant") {
        dialog = dialog.set_parent(&window);
    }
    let folder = dialog.blocking_pick_folder()?.into_path().ok()?;
    let (view, analysis) = look(&app, &folder);
    let mut draft = draft;
    assistant::set_folder(&mut draft, &folder, analysis.as_ref(), &home());
    Some(Chosen { draft, look: view })
}

/// A template chosen after a folder keeps that folder (the Mac's `choose`): the draft gets it and the source it
/// suggests.
#[tauri::command]
pub fn assistant_apply_folder(app: AppHandle, draft: Value, folder: String) -> Chosen {
    let path = profiles::expand(&folder, &home());
    let (view, analysis) = look(&app, &path);
    let mut draft = draft;
    assistant::set_folder(&mut draft, &path, analysis.as_ref(), &home());
    Chosen { draft, look: view }
}

/// «Готово»: the folder is made if it isn't there, the profile added under a name no other has and made current,
/// the reminders kept; the window closes.
#[tauri::command]
pub fn assistant_finish(app: AppHandle, draft: Value, reminder_hours: Vec<i64>) -> Result<(), String> {
    let texts = strings(&app);
    let mut profile = Profile::from_value(&draft).ok_or("not a profile")?;
    profile.id = claudepult_core::runs::new_id();
    if profile.name.trim().is_empty() {
        profile.name = texts.t("Новый профиль").to_owned();
    }
    let stages: Vec<Value> = profile.stages().into_iter().map(|s| Value::String(s.trim().to_owned())).filter(|s| s.as_str() != Some("")).collect();
    profile.other.insert("stages".into(), Value::Array(stages));
    if let Some(folder) = profile.projects_dir(&home()).filter(|f| !f.exists()) {
        std::fs::create_dir_all(&folder).map_err(|e| format!("{}: {e}", texts.t("Не удалось создать папку")))?;
    }
    eprintln!("assistant: profile «{}» ({})", profile.name, profile.template);
    let hours: Vec<i64> = reminder_hours.into_iter().filter(|h| (1..=24 * 14).contains(h)).collect();
    crate::profiles::change(&app, |settings| {
        settings.add_profile(profile);
        settings.calendar_reminder_hours = hours;
    });
    if let Some(window) = app.get_webview_window("assistant") {
        let _ = window.close();
    }
    Ok(())
}
