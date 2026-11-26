//! The «Skills Catalog» window: every skill and plugin installed for Claude Code, Codex, Cursor and Gemini CLI in
//! one list, each with the scanner's verdict (`skill-scanner`, `skill-catalog`): search, filters, and a card with
//! the findings, the files and their text. Looking only — nothing is installed, removed or changed in an agent's
//! folders, and nothing from a skill is ever run.

use claudepult_core::paths;
use serde::Serialize;
use skill_catalog::{Card, Connection, Filters, Preview, Refreshed, Roots, SearchResult};
use tauri::{AppHandle, Manager};

fn text(app: &AppHandle, key: &str) -> String {
    skill_catalog::texts::text(crate::language(app), key)
}

/// The tray menu's line.
pub(crate) fn menu_title(app: &AppHandle) -> String {
    text(app, "tray.item")
}

/// The folders the agents load skills from, with the projects folder of the current profile.
fn roots(app: &AppHandle) -> Roots {
    let home = dirs::home_dir().unwrap_or_else(std::env::temp_dir);
    let projects = app.state::<crate::AppState>().settings.lock().unwrap().projects_dir();
    Roots { home, claude_dir: paths::claude_dir(), codex_dir: paths::codex_dir(), projects_dir: projects.or_else(|| Some(paths::default_projects_dir())) }.or_test_home()
}

/// Opens (or brings forward) the window.
pub(crate) fn show(app: &AppHandle) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
    if let Some(window) = app.get_webview_window("skills") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    let title = format!("{} — {}", claudepult_core::APP_NAME, text(app, "window.title"));
    let app = app.clone();
    crate::off_main_thread(move || {
        let _ = tauri::WebviewWindowBuilder::new(&app, "skills", tauri::WebviewUrl::App("skills.html".into())).title(title).inner_size(1040.0, 680.0).min_inner_size(820.0, 480.0).center().build();
    });
}

#[tauri::command]
pub fn open_skills(app: AppHandle) {
    show(&app);
}

/// The module's own texts in the interface language (`ui/skills-i18n/`), English where it has none.
#[tauri::command]
pub fn skills_texts(app: AppHandle) -> serde_json::Map<String, serde_json::Value> {
    skill_catalog::texts::texts(crate::language(&app))
}

/// The catalog's file is opened for each question and read off the window's thread: a file's text or a folder's
/// listing takes a moment.
async fn with_catalog<T: Send + 'static>(work: impl FnOnce(&mut Connection) -> skill_catalog::Result<T> + Send + 'static) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut db = skill_catalog::open(&Roots::database(paths::skills_db()))?;
        work(&mut db)
    })
    .await
    .map_err(|error| error.to_string())?
    .map_err(|error| error.to_string())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillsRefresh {
    refreshed: Refreshed,
    /// The home folder, for showing paths as `~/…`.
    home: String,
}

/// Looks through the agents' folders and checks what is new or changed.
#[tauri::command]
pub async fn skills_refresh(app: AppHandle) -> Result<SkillsRefresh, String> {
    let roots = roots(&app);
    let home = roots.home.to_string_lossy().into_owned();
    with_catalog(move |db| {
        let refreshed = skill_catalog::refresh_installed(db, &roots, &skill_catalog::now())?;
        if refreshed.scanned > 0 || refreshed.removed > 0 {
            eprintln!("skills: {} found, {} checked, {} gone", refreshed.found, refreshed.scanned, refreshed.removed);
        }
        Ok(SkillsRefresh { refreshed, home })
    })
    .await
}

#[tauri::command]
pub async fn skills_search(filters: Filters) -> Result<SearchResult, String> {
    with_catalog(move |db| skill_catalog::search(db, &filters)).await
}

#[tauri::command]
pub async fn skills_card(id: i64) -> Result<Option<Card>, String> {
    with_catalog(move |db| skill_catalog::card(db, id)).await
}

/// One of a skill's own files as text; the catalog refuses any other path.
#[tauri::command]
pub async fn skills_preview(id: i64, file: String) -> Result<Option<Preview>, String> {
    with_catalog(move |db| skill_catalog::preview(db, id, &file)).await
}

/// «Show in folder»: only a folder the catalog itself lists as an installed skill, never a path from the page.
#[tauri::command]
pub async fn skills_show_folder(id: i64, place: usize) -> Result<(), String> {
    let path = with_catalog(move |db| Ok(skill_catalog::card(db, id)?.and_then(|card| card.places.get(place).map(|place| place.install_path.clone())))).await?.ok_or("no such place")?;
    crate::projects::open_with_system(std::ffi::OsStr::new(&path))
}
