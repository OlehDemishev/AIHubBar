//! The «Skills Catalog» window: every skill and plugin installed for Claude Code, Codex, Cursor and Gemini CLI in
//! one list, each with the scanner's verdict (`skill-scanner`, `skill-catalog`). Stage 1: looking only — nothing
//! is installed, removed or changed in an agent's folders, and nothing from a skill is ever run.

use claudepult_core::paths;
use serde::Serialize;
use skill_catalog::{InstalledRow, Refreshed, Roots};
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
        let _ = tauri::WebviewWindowBuilder::new(&app, "skills", tauri::WebviewUrl::App("skills.html".into())).title(title).inner_size(900.0, 640.0).min_inner_size(680.0, 440.0).center().build();
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

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillsView {
    rows: Vec<InstalledRow>,
    refreshed: Refreshed,
    scanner_version: u32,
    /// The home folder, for showing paths as `~/…`.
    home: String,
}

/// Looks through the agents' folders, checks what is new or changed, and returns everything installed. Reading
/// files takes a moment, so it runs off the window's thread.
#[tauri::command]
pub async fn skills_view(app: AppHandle) -> Result<SkillsView, String> {
    let roots = roots(&app);
    let home = roots.home.to_string_lossy().into_owned();
    tauri::async_runtime::spawn_blocking(move || -> skill_catalog::Result<SkillsView> {
        let mut db = skill_catalog::open(&Roots::database(paths::skills_db()))?;
        let refreshed = skill_catalog::refresh_installed(&mut db, &roots, &skill_catalog::now())?;
        if refreshed.scanned > 0 || refreshed.removed > 0 {
            eprintln!("skills: {} found, {} checked, {} gone", refreshed.found, refreshed.scanned, refreshed.removed);
        }
        Ok(SkillsView { rows: skill_catalog::installed(&db, None)?, refreshed, scanner_version: skill_scanner::SCANNER_VERSION, home })
    })
    .await
    .map_err(|error| error.to_string())?
    .map_err(|error| error.to_string())
}

/// «Show in folder»: only a folder the catalog itself lists as an installed skill, never a path from the page.
#[tauri::command]
pub fn skills_show_folder(id: i64, place: usize) -> Result<(), String> {
    let db = skill_catalog::open(&Roots::database(paths::skills_db())).map_err(|error| error.to_string())?;
    let rows = skill_catalog::installed(&db, None).map_err(|error| error.to_string())?;
    let row = rows.iter().find(|row| row.id == id).ok_or("no such skill")?;
    let path = row.places.get(place).map(|place| place.install_path.as_str()).ok_or("no such place")?;
    crate::projects::open_with_system(std::ffi::OsStr::new(path))
}
