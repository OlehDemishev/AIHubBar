//! Stage 5 «Профили» (docs/specs/SPEC-windows.md §9, docs/specs/SPEC-profiles.md): the profiles in Settings and the
//! switcher in the panel. The current profile decides the projects folder and where Claude runs, as the Mac's
//! `ProfileStore.apply`; switching reads the new folder at once and shows the hooks anew (they name a session's
//! project by that folder).

use crate::projects::Projects;
use crate::{language, save, strings, AppState};
use claudepult_core::{paths, profiles};
use serde::Serialize;
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_dialog::DialogExt;

/// The current profile's git projects folder; None when it has none (folder projects come later).
pub fn projects_dir(app: &AppHandle) -> Option<PathBuf> {
    app.state::<AppState>().settings.lock().unwrap().projects_dir()
}

/// The folder the hooks get with `--projects-dir` and the prompts' rules file is looked for in: the profile's, else
/// `~/Projects`.
pub fn projects_root(app: &AppHandle) -> PathBuf {
    projects_dir(app).unwrap_or_else(paths::default_projects_dir)
}

/// Saves a change to the profiles and follows it: another folder is read at once and the hooks shown anew; both
/// windows hear `profiles-changed`.
fn change(app: &AppHandle, edit: impl FnOnce(&mut claudepult_core::settings::Settings)) {
    let before = projects_dir(app);
    save(app, edit);
    let after = projects_dir(app);
    if after != before {
        eprintln!("projects folder: {}", after.as_deref().map(|p| p.display().to_string()).unwrap_or_else(|| "none".into()));
        app.state::<Projects>().folder_changed(app);
        let _ = app.emit("sessions-changed", ());
    }
    let _ = app.emit("profiles-changed", ());
}

// MARK: - Profiles

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileRow {
    id: String,
    name: String,
    current: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfilesView {
    rows: Vec<ProfileRow>,
    /// The last profile can't be deleted.
    may_delete: bool,
}

#[tauri::command]
pub fn profiles_view(app: AppHandle) -> ProfilesView {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let current = settings.current().map(|p| p.id.clone());
    ProfilesView {
        rows: settings
            .profiles
            .iter()
            .map(|p| ProfileRow { id: p.id.clone(), name: p.name.clone(), current: Some(&p.id) == current.as_ref() })
            .collect(),
        may_delete: settings.profiles.len() > 1,
    }
}

#[tauri::command]
pub fn select_profile(app: AppHandle, id: String) -> ProfilesView {
    change(&app, |settings| {
        if settings.select_profile(&id) {
            eprintln!("profile: {}", settings.current().map(|p| p.name.as_str()).unwrap_or_default());
        }
    });
    profiles_view(app)
}

/// «Добавить профиль»: the Mac's «Разработчик (GitHub)» template in the interface language, made current. Other
/// templates come with folder projects.
#[tauri::command]
pub fn add_profile(app: AppHandle) -> Result<ProfilesView, String> {
    let profile = profiles::from_template("developer", language(&app)).ok_or("no template")?;
    change(&app, |settings| settings.add_profile(profile));
    Ok(profiles_view(app))
}

#[tauri::command]
pub fn rename_profile(app: AppHandle, id: String, name: String) -> ProfilesView {
    save(&app, |settings| {
        settings.rename_profile(&id, &name);
    });
    let _ = app.emit("profiles-changed", ());
    profiles_view(app)
}

#[tauri::command]
pub fn delete_profile(app: AppHandle, id: String) -> ProfilesView {
    change(&app, |settings| {
        settings.delete_profile(&id);
    });
    profiles_view(app)
}

// MARK: - The projects folder

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectsFolder {
    /// The current profile's name: the folder is its own.
    profile: String,
    /// None — the profile has no git projects folder.
    path: Option<String>,
    /// Another folder than `~/Projects`: «По умолчанию» brings that back.
    custom: bool,
    /// «Папки нет: …» when the folder is gone, or why there is no folder.
    note: Option<String>,
}

fn folder_view(app: &AppHandle) -> ProjectsFolder {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let texts = strings(app);
    let path = settings.projects_dir();
    let note = match &path {
        None => Some(texts.t("У этого профиля нет папки проектов").to_owned()),
        Some(path) if !path.is_dir() => Some(texts.format("Папки нет: %@", &[&path.to_string_lossy()])),
        Some(_) => None,
    };
    ProjectsFolder {
        profile: settings.current().map(|p| p.name.clone()).unwrap_or_default(),
        path: path.map(|p| p.to_string_lossy().into_owned()),
        custom: settings.has_custom_projects_dir(),
        note,
    }
}

#[tauri::command]
pub fn projects_folder(app: AppHandle) -> ProjectsFolder {
    folder_view(&app)
}

/// «Выбрать…»: the system's folder picker, opened at the current folder (or the nearest one that exists).
#[tauri::command]
pub async fn choose_projects_folder(app: AppHandle) -> ProjectsFolder {
    let Some(current) = projects_dir(&app) else { return folder_view(&app) };
    let start = current.ancestors().find(|dir| dir.is_dir()).map(Path::to_path_buf);
    let mut dialog = app.dialog().file().set_title(strings(&app).t("Папка проектов"));
    if let Some(start) = start {
        dialog = dialog.set_directory(start);
    }
    if let Some(window) = app.get_webview_window("settings") {
        dialog = dialog.set_parent(&window);
    }
    if let Some(folder) = dialog.blocking_pick_folder().and_then(|f| f.into_path().ok()) {
        change(&app, |settings| {
            settings.set_projects_dir(&folder);
        });
    }
    folder_view(&app)
}

#[tauri::command]
pub fn reset_projects_folder(app: AppHandle) -> ProjectsFolder {
    change(&app, |settings| {
        settings.set_projects_dir(&paths::default_projects_dir());
    });
    folder_view(&app)
}
