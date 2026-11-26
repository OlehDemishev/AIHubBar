//! The «Skills Catalog» window: every skill and plugin installed for Claude Code, Codex, Cursor and Gemini CLI in
//! one list, each with the scanner's verdict (`skill-scanner`, `skill-catalog`): search, filters, and a card with
//! the findings, the files and their text. Looking only — nothing is installed, removed or changed in an agent's
//! folders, and nothing from a skill is ever run.

use claudepult_core::paths;
use serde::Serialize;
use skill_catalog::manage::{self, Done, FileDiff, LogRow, Plan, UpdateRow};
use skill_catalog::{Card, Connection, Env, Filters, Preview, Refreshed, Roots, SearchResult};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_notification::NotificationExt;
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

// MARK: - Installing, removing, updating (stage 5)

/// Where what is taken out of an agent's folder is kept: beside the catalog's file.
fn backups() -> std::path::PathBuf {
    Roots::database(paths::skills_db()).with_file_name("backups")
}

/// The catalog's file and the place the work happens, for a step that may write into an agent's folder. Each such
/// step checks for itself what it may touch (`skill_catalog::manage`); a path from the page is never trusted.
async fn with_env<T: Send + 'static>(app: &AppHandle, work: impl FnOnce(&mut Connection, Env) -> skill_catalog::Result<T> + Send + 'static) -> Result<T, String> {
    let roots = roots(app);
    with_catalog(move |db| {
        let (backups, now) = (backups(), skill_catalog::now());
        work(db, Env { roots: &roots, backups: &backups, now: &now })
    })
    .await
}

/// «Add a folder…»: the person picks a folder with a skill; it is checked and listed, installed nowhere.
#[tauri::command]
pub async fn skills_add_folder(app: AppHandle) -> Result<Option<i64>, String> {
    let mut dialog = app.dialog().file().set_title(text(&app, "action.addFolder").trim_end_matches('…'));
    if let Some(window) = app.get_webview_window("skills") {
        dialog = dialog.set_parent(&window);
    }
    let Some(folder) = dialog.blocking_pick_folder().and_then(|folder| folder.into_path().ok()) else { return Ok(None) };
    with_catalog(move |db| Ok(Some(manage::import_folder(db, &folder, &skill_catalog::now())?))).await
}

#[tauri::command]
pub async fn skills_forget(id: i64) -> Result<bool, String> {
    with_catalog(move |db| manage::forget(db, id)).await
}

#[tauri::command]
pub async fn skills_plan_install(app: AppHandle, id: i64, agent: String) -> Result<Plan, String> {
    with_env(&app, move |db, env| manage::plan_install(db, env, id, &agent)).await
}

/// Installs what the person confirmed: the hash is the one their plan showed.
#[tauri::command]
pub async fn skills_install(app: AppHandle, id: i64, agent: String, content_hash: String, acknowledged: bool) -> Result<Done, String> {
    let done = with_env(&app, move |db, env| manage::install(db, env, id, &agent, &content_hash, acknowledged)).await?;
    eprintln!("skills: installed {}", done.install_path);
    Ok(done)
}

#[tauri::command]
pub async fn skills_remove(app: AppHandle, install_path: String) -> Result<Done, String> {
    let done = with_env(&app, move |db, env| manage::remove(db, env, &install_path)).await?;
    eprintln!("skills: removed {}", done.install_path);
    Ok(done)
}

#[tauri::command]
pub async fn skills_set_enabled(app: AppHandle, install_path: String, on: bool) -> Result<Done, String> {
    with_env(&app, move |db, env| manage::set_enabled(db, env, &install_path, on)).await
}

#[tauri::command]
pub async fn skills_journal() -> Result<Vec<LogRow>, String> {
    with_catalog(|db| manage::journal(db, 200)).await
}

#[tauri::command]
pub async fn skills_restore(app: AppHandle, journal_id: i64) -> Result<Done, String> {
    with_env(&app, move |db, env| manage::restore(db, env, journal_id)).await
}

#[tauri::command]
pub async fn skills_updates() -> Result<Vec<UpdateRow>, String> {
    with_catalog(|db| manage::updates(db)).await
}

#[derive(Serialize)]
pub struct UpdatePlan {
    plan: Plan,
    changes: Vec<FileDiff>,
}

/// What bringing the newer version in would do, with what it changes line by line.
#[tauri::command]
pub async fn skills_plan_update(app: AppHandle, install_path: String) -> Result<UpdatePlan, String> {
    with_env(&app, move |db, env| Ok(UpdatePlan { plan: manage::plan_update(db, env, &install_path)?, changes: manage::diff(db, &install_path)? })).await
}

#[tauri::command]
pub async fn skills_update(app: AppHandle, install_path: String, content_hash: String, acknowledged: bool) -> Result<Done, String> {
    let done = with_env(&app, move |db, env| manage::update(db, env, &install_path, &content_hash, acknowledged)).await?;
    eprintln!("skills: updated {}", done.install_path);
    Ok(done)
}

/// A minute after the start and then every six hours: a notification for each installed skill whose source has a
/// newer version the person was not told about yet. Nothing is updated by itself.
pub fn start_update_watch(app: AppHandle) {
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_secs(60));
        loop {
            let fresh = skill_catalog::open(&Roots::database(paths::skills_db())).and_then(|db| manage::updates_to_announce(&db));
            match fresh {
                Ok(fresh) => {
                    for update in fresh {
                        let verdict = text(&app, &format!("verdict.{}", update.verdict));
                        let title = text(&app, "notify.updateTitle").replace("%1", &update.name);
                        let body = text(&app, "notify.updateBody").replace("%1", &verdict);
                        let _ = app.notification().builder().title(title).body(body).show();
                    }
                }
                Err(error) => eprintln!("skills: updates not checked: {error}"),
            }
            std::thread::sleep(std::time::Duration::from_secs(6 * 60 * 60));
        }
    });
}
