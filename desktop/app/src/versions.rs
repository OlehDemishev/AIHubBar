//! «Версии» (the Mac's `VersionKeeper` and `VersionsWindow`): while the module is on, a version of each folder project
//! of the current profile is taken every 10 or 30 minutes when something changed, and always before an AI run on it;
//! the «Версии» window lists a project's versions, shows a file of one next to the file as it is now, and puts one
//! file or the whole version back — the current state is saved first.

use crate::{save, strings, AppState};
use chrono::{DateTime, Local, Utc};
use claudepult_core::paths;
use claudepult_core::versions::{self, Reason, Store, Version};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};

pub const KIND: &str = "versions";

/// The Mac's `VersionsSettings`, kept in `settings.json` as it is on the Mac.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VersionsSettings {
    #[serde(default = "pace")]
    pub pace: String,
    #[serde(default = "keep_days")]
    pub keep_days: i64,
    #[serde(default = "size")]
    pub size_limit_mb: u64,
}

fn pace() -> String {
    "tenMinutes".into()
}
fn keep_days() -> i64 {
    versions::DEFAULT_KEEP_DAYS
}
fn size() -> u64 {
    20
}

impl Default for VersionsSettings {
    fn default() -> Self {
        VersionsSettings { pace: pace(), keep_days: keep_days(), size_limit_mb: size() }
    }
}

impl VersionsSettings {
    fn seconds(&self) -> Option<i64> {
        match self.pace.as_str() {
            "beforeRuns" => None,
            "thirtyMinutes" => Some(1800),
            _ => Some(600),
        }
    }

    pub fn size_limit(&self) -> u64 {
        self.size_limit_mb * 1024 * 1024
    }
}

pub fn store() -> Store {
    Store { root: paths::data_dir().join("versions") }
}

fn settings(app: &AppHandle) -> (bool, VersionsSettings) {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let chosen = settings.mac_settings.get("versions").and_then(|v| serde_json::from_value(v.clone()).ok()).unwrap_or_default();
    (settings.module_on(KIND), chosen)
}

#[derive(Default)]
pub struct Keeper {
    last_sweep: Mutex<Option<DateTime<Utc>>>,
    last_cleanup: Mutex<Option<DateTime<Utc>>>,
    /// The project the «Версии» window shows.
    shown: Mutex<Option<PathBuf>>,
}

/// The current folder profile's projects.
fn projects(app: &AppHandle) -> Vec<PathBuf> {
    app.state::<crate::projects::Projects>().folder_paths()
}

impl Keeper {
    pub fn start(app: AppHandle) {
        std::thread::spawn(move || loop {
            std::thread::sleep(std::time::Duration::from_secs(60));
            app.state::<Keeper>().tick(&app);
        });
    }

    fn tick(&self, app: &AppHandle) {
        let (on, chosen) = settings(app);
        if !on {
            return;
        }
        let now = Utc::now();
        let due = chosen.seconds().is_some_and(|every| self.last_sweep.lock().unwrap().is_none_or(|last| (now - last).num_seconds() >= every));
        let store = store();
        if due {
            *self.last_sweep.lock().unwrap() = Some(now);
            let mut taken = 0;
            for project in projects(app) {
                match store.take(&project, Reason::Automatic {}, now, chosen.size_limit()) {
                    Ok(Some(_)) => taken += 1,
                    Ok(None) => {}
                    Err(error) => eprintln!("versions: {} not kept: {error}", project.display()),
                }
                store.prune(&project, now, chosen.keep_days);
            }
            if taken > 0 {
                eprintln!("versions: {taken} taken");
                let _ = app.emit("versions-changed", ());
            }
        }
        let cleanup = self.last_cleanup.lock().unwrap().is_none_or(|last| (now - last).num_hours() >= 24);
        if cleanup {
            *self.last_cleanup.lock().unwrap() = Some(now);
            let removed = store.remove_orphans(now, chosen.keep_days);
            if !removed.is_empty() {
                eprintln!("versions: stores of {} gone projects removed", removed.len());
            }
        }
    }
}

/// Before an AI run on a folder project: a version of what is there, so the run can be undone.
pub fn before_run(app: &AppHandle, project: &Path, title: &str) {
    let (on, chosen) = settings(app);
    if !on {
        return;
    }
    match store().take(project, Reason::BeforeRun { title: title.to_owned() }, Utc::now(), chosen.size_limit()) {
        Ok(Some(_)) => {
            eprintln!("versions: taken before «{title}»");
            let _ = app.emit("versions-changed", ());
        }
        Ok(None) => {}
        Err(error) => eprintln!("versions: not kept before «{title}»: {error}"),
    }
}

// MARK: - The window

/// «Версии» of a project in the panel: the window comes up on it.
#[tauri::command]
pub fn open_versions(app: AppHandle, path: String) {
    *app.state::<Keeper>().shown.lock().unwrap() = Some(PathBuf::from(path));
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
    if let Some(window) = app.get_webview_window("versions") {
        let _ = window.emit("versions-changed", ());
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    let title = format!("{} — {}", claudepult_core::APP_NAME, strings(&app).t("Версии"));
    crate::off_main_thread(move || {
        let _ = tauri::WebviewWindowBuilder::new(&app, "versions", tauri::WebviewUrl::App("versions.html".into())).title(title).inner_size(900.0, 580.0).min_inner_size(700.0, 420.0).center().build();
    });
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EntryRow {
    path: String,
    /// `changed`, `missing`, `same` or `added`.
    status: &'static str,
    title: String,
    in_version: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct VersionRow {
    id: String,
    /// «25 нояб., 14:06».
    taken: String,
    reason: String,
    /// «как сейчас» or «файлов с отличиями: 2».
    differs: String,
    differing: usize,
    skipped: Option<String>,
    entries: Vec<EntryRow>,
}

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct VersionsView {
    project: String,
    path: String,
    versions: Vec<VersionRow>,
}

fn when(date: DateTime<Utc>) -> String {
    date.with_timezone(&Local).format("%d.%m.%Y %H:%M").to_string()
}

fn shown(app: &AppHandle) -> Option<PathBuf> {
    app.state::<Keeper>().shown.lock().unwrap().clone()
}

fn view(app: &AppHandle) -> VersionsView {
    let texts = strings(app);
    let Some(project) = shown(app) else { return VersionsView::default() };
    let (_, chosen) = settings(app);
    let current = Store::current(&project, chosen.size_limit());
    let rows = store()
        .versions(&project)
        .into_iter()
        .map(|version| {
            let differing = version.differing(&current);
            let mut entries: Vec<EntryRow> = version
                .files
                .iter()
                .map(|file| {
                    let status = match current.get(&file.path) {
                        None => "missing",
                        Some(hash) if *hash == file.hash => "same",
                        Some(_) => "changed",
                    };
                    let key = match status {
                        "missing" => "%@ — сейчас нет в папке",
                        "same" => "%@ — как сейчас",
                        _ => "%@ — изменён с тех пор",
                    };
                    EntryRow { title: texts.format(key, &[&file.path]), path: file.path.clone(), status, in_version: true }
                })
                .collect();
            entries.extend(version.added(&current).into_iter().map(|path| EntryRow { title: texts.format("%@ — появился позже", &[&path]), path, status: "added", in_version: false }));
            VersionRow {
                taken: when(version.taken_at),
                reason: versions::reason_text(&version.reason, &texts),
                differs: if differing.is_empty() { texts.t("как сейчас").to_owned() } else { texts.format("файлов с отличиями: %lld", &[&differing.len().to_string()]) },
                differing: differing.len(),
                skipped: (!version.skipped.is_empty()).then(|| texts.format("Не сохранены из-за размера: %@", &[&version.skipped.join(", ")])),
                id: version.id,
                entries,
            }
        })
        .collect();
    VersionsView { project: project.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(), path: project.to_string_lossy().into_owned(), versions: rows }
}

#[tauri::command]
pub async fn versions_view(app: AppHandle) -> VersionsView {
    tauri::async_runtime::spawn_blocking(move || view(&app)).await.unwrap_or_default()
}

fn find(app: &AppHandle, id: &str) -> Result<(PathBuf, Version), String> {
    let project = shown(app).ok_or("no project")?;
    let version = store().versions(&project).into_iter().find(|v| v.id == id).ok_or("no such version")?;
    Ok((project, version))
}

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct CompareView {
    rows: Vec<(Option<String>, Option<String>)>,
    cut: bool,
    /// «Файл такой же, как сейчас.», «Не удалось прочитать файл из версии.»
    note: Option<String>,
    taken: String,
}

/// A file of a version next to the file as it is now, line by line.
#[tauri::command]
pub async fn version_compare(app: AppHandle, id: String, path: String) -> Result<CompareView, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let texts = strings(&app);
        let (project, version) = find(&app, &id)?;
        let taken = texts.format("Версия: %@", &[&when(version.taken_at)]);
        let old = version.files.iter().find(|f| f.path == path).and_then(|f| store().content(&project, &f.hash)).and_then(|data| versions::text_of(&data, &path));
        let target = path.split('/').fold(project.clone(), |at, part| at.join(part));
        let new = std::fs::read(&target).ok().and_then(|data| versions::text_of(&data, &path)).unwrap_or_default();
        let Some(old) = old else {
            if version.files.iter().any(|f| f.path == path) {
                return Ok(CompareView { note: Some(texts.t("Не удалось прочитать файл из версии.").to_owned()), taken, ..CompareView::default() });
            }
            // Appeared later: only the side of now.
            let (rows, cut) = versions::compare_rows("", &new, 3000);
            return Ok(CompareView { rows, cut, note: None, taken });
        };
        if old == new {
            return Ok(CompareView { note: Some(texts.t("Файл такой же, как сейчас.").to_owned()), taken, ..CompareView::default() });
        }
        let (rows, cut) = versions::compare_rows(&old, &new, 3000);
        Ok(CompareView { rows, cut, note: None, taken })
    })
    .await
    .map_err(|e| e.to_string())?
}

/// «Вернуть этот файл» (`path`) or «Вернуть всю версию» (no `path`), after the window asked.
#[tauri::command]
pub async fn version_restore(app: AppHandle, id: String, path: Option<String>) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let texts = strings(&app);
        let (project, version) = find(&app, &id)?;
        let (_, chosen) = settings(&app);
        let only: Option<HashSet<String>> = path.map(|p| [p].into_iter().collect());
        let written = store().restore(&project, &version, only.as_ref(), Utc::now(), chosen.size_limit()).map_err(|e| e.text(&texts))?;
        eprintln!("versions: {} files put back in {}", written.len(), project.display());
        let _ = app.emit("versions-changed", ());
        let _ = app.emit("projects-changed", ());
        Ok(texts.format("Возвращено файлов: %lld. То, что было до этого, сохранено в списке версий.", &[&written.len().to_string()]))
    })
    .await
    .map_err(|e| e.to_string())?
}

/// The questions before putting back, with the Mac's words.
#[tauri::command]
pub fn version_questions(app: AppHandle, id: String, path: Option<String>) -> Result<String, String> {
    let texts = strings(&app);
    let (project, version) = find(&app, &id)?;
    let taken = when(version.taken_at);
    Ok(match path {
        Some(path) => texts.format("«%@» станет таким, как в версии от %@. То, что есть сейчас, сначала сохранится отдельной версией.", &[&path, &taken]),
        None => {
            let (_, chosen) = settings(&app);
            let differing = version.differing(&Store::current(&project, chosen.size_limit())).len();
            texts.format("Файлов: %lld — станут такими, как в версии от %@. То, что есть сейчас, сначала сохранится отдельной версией. Файлы, которые появились позже, останутся.", &[&differing.to_string(), &taken])
        }
    })
}

/// «Открыть файл»: the file as it is now.
#[tauri::command]
pub fn version_open_file(app: AppHandle, path: String) -> Result<(), String> {
    let project = shown(&app).ok_or("no project")?;
    if !Store::is_safe(&path) {
        return Err("not a project file".into());
    }
    let target = path.split('/').fold(project, |at, part| at.join(part));
    crate::projects::open_with_system(target.as_os_str())
}

// MARK: - Settings → «Модули» → «Версии»

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VersionsSettingsView {
    on: bool,
    pace: String,
    keep_days: i64,
    size_limit_mb: u64,
    paces: Vec<(String, String)>,
    /// «12,3 МБ».
    size: String,
    empty: bool,
}

fn settings_view(app: &AppHandle) -> VersionsSettingsView {
    let texts = strings(app);
    let (on, chosen) = settings(app);
    let bytes = store().size();
    let size = if bytes < 1024 * 1024 { format!("{} KB", bytes / 1024) } else { format!("{:.1} MB", bytes as f64 / 1_048_576.0) };
    VersionsSettingsView {
        on,
        paces: [("tenMinutes", "Каждые 10 минут, если что-то изменилось"), ("thirtyMinutes", "Каждые 30 минут, если что-то изменилось"), ("beforeRuns", "Только перед запуском AI")].into_iter().map(|(id, key)| (id.to_owned(), texts.t(key).to_owned())).collect(),
        pace: chosen.pace,
        keep_days: chosen.keep_days,
        size_limit_mb: chosen.size_limit_mb,
        size,
        empty: bytes == 0,
    }
}

#[tauri::command]
pub async fn versions_settings(app: AppHandle) -> VersionsSettingsView {
    tauri::async_runtime::spawn_blocking(move || settings_view(&app)).await.unwrap()
}

#[tauri::command]
pub fn set_versions_settings(app: AppHandle, pace: String, keep_days: i64, size_limit_mb: u64) -> VersionsSettingsView {
    let chosen = VersionsSettings {
        pace: if ["tenMinutes", "thirtyMinutes", "beforeRuns"].contains(&pace.as_str()) { pace } else { "tenMinutes".into() },
        keep_days: if [30, 90].contains(&keep_days) { keep_days } else { versions::DEFAULT_KEEP_DAYS },
        size_limit_mb: if [5, 20, 100].contains(&size_limit_mb) { size_limit_mb } else { 20 },
    };
    save(&app, |settings| {
        settings.mac_settings.insert("versions".into(), serde_json::to_value(&chosen).unwrap_or_default());
    });
    settings_view(&app)
}

/// «Очистить», after the page asked.
#[tauri::command]
pub fn clear_versions(app: AppHandle) -> VersionsSettingsView {
    store().clear();
    eprintln!("versions: all removed");
    let _ = app.emit("versions-changed", ());
    settings_view(&app)
}

/// «Показать папку»: where the versions lie.
#[tauri::command]
pub fn open_versions_folder() -> Result<(), String> {
    let root = store().root;
    let _ = std::fs::create_dir_all(&root);
    crate::projects::open_with_system(root.as_os_str())
}
