//! «Изменения сессии» (the Mac's `SessionChangesStore`): what each session or background run shown in the panel
//! changed in its folder, read by git off the main thread, at most every 30 seconds per folder.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use claudepult_core::i18n::Strings;
use claudepult_core::projects::Tools;
use claudepult_core::session_changes::{self, Changes};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

const FRESH_FOR: Duration = Duration::from_secs(30);
/// More files than this are counted, not listed: the list is for a look, not for a review.
const LISTED: usize = 200;

struct Entry {
    checked: Instant,
    reading: bool,
    changes: Option<Changes>,
}

#[derive(Clone, Default)]
pub struct ChangesStore {
    entries: Arc<Mutex<HashMap<String, Entry>>>,
}

fn key(folder: &str, since: Option<DateTime<Utc>>) -> String {
    format!("{folder}|{}", since.map_or(0, |at| at.timestamp()))
}

impl ChangesStore {
    /// What is known now; a reading that is older than half a minute (or was never made) is made again in the
    /// background, and the panel hears `sessions-changed` when it differs.
    pub fn get(&self, app: &AppHandle, folder: &str, since: Option<DateTime<Utc>>) -> Option<Changes> {
        if folder.is_empty() {
            return None;
        }
        let key = key(folder, since);
        let mut entries = self.entries.lock().unwrap();
        let entry = entries.entry(key.clone()).or_insert(Entry { checked: Instant::now() - FRESH_FOR, reading: false, changes: None });
        if !entry.reading && entry.checked.elapsed() >= FRESH_FOR {
            entry.reading = true;
            let (this, app, folder) = (self.clone(), app.clone(), PathBuf::from(folder));
            std::thread::spawn(move || {
                let fresh = Tools::find().and_then(|tools| session_changes::read(&tools.git, &folder, since));
                let mut entries = this.entries.lock().unwrap();
                let Some(entry) = entries.get_mut(&key) else { return };
                let differs = entry.changes != fresh;
                *entry = Entry { checked: Instant::now(), reading: false, changes: fresh };
                drop(entries);
                if differs {
                    let _ = app.emit("sessions-changed", ());
                }
            });
        }
        entry.changes.clone().filter(|changes| !changes.files.is_empty())
    }

    /// Whether the file is one a reading of that folder listed: nothing else is opened.
    fn lists(&self, folder: &str, path: Option<&str>) -> bool {
        let prefix = format!("{folder}|");
        self.entries.lock().unwrap().iter().any(|(key, entry)| key.starts_with(&prefix) && path.is_none_or(|path| entry.changes.as_ref().is_some_and(|changes| changes.files.iter().any(|file| file.path == path))))
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileRow {
    path: String,
    /// «+12», «−3»; «новый» or «двоичный» in `note` instead.
    added: Option<String>,
    removed: Option<String>,
    note: Option<String>,
    is_new: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangesRow {
    folder: String,
    /// «файлов: 3 +120 −8».
    summary: String,
    files: Vec<FileRow>,
    /// How many files are not in the list.
    more: usize,
}

pub fn row(texts: &Strings, folder: &str, changes: &Changes) -> ChangesRow {
    let files = changes
        .files
        .iter()
        .take(LISTED)
        .map(|file| {
            let lines = file.added.zip(file.removed);
            FileRow {
                path: file.path.clone(),
                added: lines.map(|(added, _)| format!("+{added}")),
                removed: lines.map(|(_, removed)| format!("−{removed}")),
                note: if file.is_new { Some(texts.t("новый").to_owned()) } else if lines.is_none() { Some(texts.t("двоичный").to_owned()) } else { None },
                is_new: file.is_new,
            }
        })
        .collect();
    ChangesRow { folder: folder.to_owned(), summary: changes.summary(texts), files, more: changes.files.len().saturating_sub(LISTED) }
}

/// A click on a changed file: the file in the program the system opens it with, or its folder when it is gone
/// (deleted by the session). `path` empty — «Показать папку».
#[tauri::command]
pub fn open_changed(app: AppHandle, folder: String, path: String) -> Result<(), String> {
    let store = app.state::<ChangesStore>();
    if !store.lists(&folder, (!path.is_empty()).then_some(path.as_str())) {
        return Err("not a listed file".into());
    }
    let root = Path::new(&folder);
    let file = path.split('/').filter(|part| !part.is_empty() && *part != "..").fold(root.to_path_buf(), |at, part| at.join(part));
    let target = if file.exists() { file } else { file.parent().filter(|parent| parent.is_dir()).unwrap_or(root).to_path_buf() };
    crate::projects::open_with_system(target.as_os_str())
}
