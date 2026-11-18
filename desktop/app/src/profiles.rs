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

/// The current profile's projects folder (git repositories or folder projects); None when it has none.
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
    app.state::<crate::calendar::Calendar>().ask();
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

#[derive(Serialize)]
pub struct TemplateRow {
    id: &'static str,
    title: String,
}

/// The Mac's templates for «Добавить профиль из шаблона», titled in the interface language.
#[tauri::command]
pub fn profile_templates(app: AppHandle) -> Vec<TemplateRow> {
    profiles::template_titles(language(&app)).into_iter().map(|(id, title)| TemplateRow { id, title }).collect()
}

/// «Добавить профиль»: a Mac template in the interface language, made current.
#[tauri::command]
pub fn add_profile(app: AppHandle, template: String) -> Result<ProfilesView, String> {
    let profile = profiles::from_template(&template, language(&app)).ok_or("no template")?;
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
    /// None — the profile has no projects folder.
    path: Option<String>,
    /// Another folder than the template's own (`~/Projects` for git): «По умолчанию» brings that back.
    custom: bool,
    /// «Папки нет: …» when the folder is gone, or why there is no folder.
    note: Option<String>,
    /// A profile with folder projects: its calendar (`off`, `dates`, `contentPlan`).
    calendar: Option<String>,
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
        calendar: settings.current().filter(|p| p.source().is_folders()).map(|p| p.calendar().to_owned()),
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
        if let Some(default) = settings.default_projects_dir() {
            settings.set_projects_dir(&default);
        }
    });
    folder_view(&app)
}

// MARK: - `.claudepult` files

/// A file read by «Импорт…», waiting for «Заменить все настройки» / «Добавить профили» / «Отмена».
static PENDING: std::sync::Mutex<Option<(String, profiles::Bundle)>> = std::sync::Mutex::new(None);

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ImportView {
    /// «Импорт «file»» while a file waits.
    title: Option<String>,
    summary: Option<String>,
    /// A settings file may replace everything; a profile file only adds.
    may_replace: bool,
    message: Option<String>,
    error: bool,
}

fn pending_view(app: &AppHandle) -> ImportView {
    let texts = strings(app);
    let pending = PENDING.lock().unwrap();
    let Some((file, bundle)) = pending.as_ref() else { return ImportView::default() };
    let names = bundle.profiles.iter().map(|p| p.name.as_str()).collect::<Vec<_>>().join(", ");
    let what = if bundle.is_settings() { texts.t("Все настройки и профили") } else { texts.t("Профиль") };
    ImportView {
        title: Some(texts.format("Импорт «%@»", &[file])),
        summary: Some(format!("{what}: {names}.")),
        may_replace: bundle.is_settings(),
        ..ImportView::default()
    }
}

/// A file name from a profile's name: no characters Windows refuses.
fn file_name(name: &str) -> String {
    let clean: String = name.chars().map(|c| if "<>:\"/\\|?*".contains(c) || c.is_control() { '-' } else { c }).collect();
    let clean = clean.trim().trim_end_matches('.').to_owned();
    format!("{}.claudepult", if clean.is_empty() { "AI Hub Bar" } else { &clean })
}

/// The system's save dialog, then the file in UTF-8 without BOM. Some(error text) when writing failed.
fn save_file(app: &AppHandle, suggested: &str, text: String) -> Option<String> {
    let mut dialog = app.dialog().file().add_filter("AI Hub Bar", &["claudepult"]).set_file_name(suggested);
    if let Some(window) = app.get_webview_window("settings") {
        dialog = dialog.set_parent(&window);
    }
    let mut path = dialog.blocking_save_file()?.into_path().ok()?;
    if path.extension().is_none() {
        path.set_extension("claudepult");
    }
    match std::fs::write(&path, text) {
        Ok(()) => {
            eprintln!("exported {}", path.display());
            None
        }
        Err(error) => Some(error.to_string()),
    }
}

/// «Экспорт настроек…»: all profiles in a file the Mac opens too.
#[tauri::command]
pub async fn export_settings(app: AppHandle) -> ImportView {
    let text = app.state::<AppState>().settings.lock().unwrap().export_settings(chrono::Utc::now());
    let error = save_file(&app, "AI Hub Bar.claudepult", text);
    ImportView { error: error.is_some(), message: error, ..pending_view(&app) }
}

/// «Экспорт профиля…»: the current profile alone.
#[tauri::command]
pub async fn export_profile(app: AppHandle) -> ImportView {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let (Some(profile), Some(text)) = (settings.current(), settings.export_profile(chrono::Utc::now())) else { return pending_view(&app) };
    let error = save_file(&app, &file_name(&profile.name), text);
    ImportView { error: error.is_some(), message: error, ..pending_view(&app) }
}

/// «Импорт…»: a `.claudepult` file is read and waits for the person's choice.
#[tauri::command]
pub async fn choose_import(app: AppHandle) -> ImportView {
    let mut dialog = app.dialog().file().add_filter("AI Hub Bar", &["claudepult", "json"]);
    if let Some(window) = app.get_webview_window("settings") {
        dialog = dialog.set_parent(&window);
    }
    let Some(path) = dialog.blocking_pick_file().and_then(|f| f.into_path().ok()) else { return pending_view(&app) };
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    match std::fs::read_to_string(&path).ok().as_deref().and_then(profiles::read_bundle) {
        Some(bundle) => {
            *PENDING.lock().unwrap() = Some((name, bundle));
            pending_view(&app)
        }
        None => {
            *PENDING.lock().unwrap() = None;
            let message = strings(&app).format("Не удалось прочитать «%@»: это не файл настроек AI Hub Bar.", &[&name]);
            ImportView { message: Some(message), error: true, ..ImportView::default() }
        }
    }
}

/// «Заменить все настройки» (`replace`) or «Добавить профили».
#[tauri::command]
pub fn apply_import(app: AppHandle, replace: bool) -> ImportView {
    let Some((file, bundle)) = PENDING.lock().unwrap().take() else { return ImportView::default() };
    let replaces = replace && bundle.is_settings();
    let mut count = 0;
    change(&app, |settings| count = if replaces { settings.import_replace(bundle) } else { settings.import_add(bundle) });
    eprintln!("imported {file}: {count} profile(s), {}", if replaces { "replace" } else { "add" });
    let texts = strings(&app);
    let message = if replaces {
        texts.format("Настройки импортированы: %lld профиль(ов).", &[&count.to_string()])
    } else {
        texts.format("Добавлено профилей: %lld.", &[&count.to_string()])
    };
    ImportView { message: Some(message), ..ImportView::default() }
}

#[tauri::command]
pub fn cancel_import() -> ImportView {
    *PENDING.lock().unwrap() = None;
    ImportView::default()
}

#[cfg(test)]
mod tests {
    #[test]
    fn file_names() {
        assert_eq!(super::file_name("Разработчик (GitHub)"), "Разработчик (GitHub).claudepult");
        assert_eq!(super::file_name("a/b: c?"), "a-b- c-.claudepult");
        assert_eq!(super::file_name(" ... "), "AI Hub Bar.claudepult");
    }
}
