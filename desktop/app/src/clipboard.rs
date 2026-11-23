//! «История буфера» (the Mac's `ClipboardHistory` and `ClipboardView`): the clipboard is looked at while the module
//! is on; in memory unless «Помнить после перезапуска» is on, then in `clipboard.json`.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::Utc;
use claudepult_core::clipboard::{self, ClipItem, KIND};
use claudepult_core::paths;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_clipboard_manager::ClipboardExt;

use crate::{save, strings, AppState};

#[derive(Default)]
struct State {
    items: Vec<ClipItem>,
    loaded: bool,
    /// The clipboard as it was at the last look: its number on Windows, its text elsewhere.
    sequence: Option<u32>,
    text: Option<String>,
}

#[derive(Clone, Default)]
pub struct Clipboard {
    state: Arc<Mutex<State>>,
}

fn file() -> std::path::PathBuf {
    paths::data_dir().join("clipboard.json")
}

fn options(app: &AppHandle) -> (bool, usize, bool) {
    let state = app.state::<AppState>();
    let settings = state.settings.lock().unwrap();
    (settings.module_on(KIND), settings.clipboard_limit as usize, settings.clipboard_remember)
}

impl Clipboard {
    pub fn start(&self, app: AppHandle) {
        let this = self.clone();
        std::thread::spawn(move || loop {
            let on = this.look(&app);
            // Switched off, it only checks now and then whether it is back on.
            std::thread::sleep(Duration::from_millis(if on { 700 } else { 5000 }));
        });
    }

    fn keep(&self, state: &State, remember: bool) {
        if remember {
            if let Err(error) = std::fs::write(file(), serde_json::to_string(&state.items).unwrap_or_default()) {
                eprintln!("clipboard history not saved: {error}");
            }
        }
    }

    /// One look at the clipboard; whether the module is on.
    fn look(&self, app: &AppHandle) -> bool {
        let (on, limit, remember) = options(app);
        let mut state = self.state.lock().unwrap();
        if !on {
            if state.loaded || !state.items.is_empty() {
                *state = State::default();
            }
            return false;
        }
        let sequence = clipboard::sequence();
        if !state.loaded {
            // What is on the clipboard when the module starts was copied before it: not recorded.
            state.loaded = true;
            state.sequence = sequence;
            state.text = if sequence.is_none() { app.clipboard().read_text().ok() } else { None };
            if remember {
                state.items = std::fs::read_to_string(file()).map(|text| clipboard::parse(&text)).unwrap_or_default();
            }
            drop(state);
            let _ = app.emit("clipboard-changed", ());
            return true;
        }
        if sequence.is_some() && sequence == state.sequence {
            return true;
        }
        state.sequence = sequence;
        // Copied files first: Explorer puts their paths on the clipboard as a text too in some programs.
        let files = clipboard::read_files();
        let text = match &files {
            Some(_) => String::new(),
            None => match app.clipboard().read_text() {
                Ok(text) => text,
                Err(_) => return true,
            },
        };
        if files.is_none() && sequence.is_none() && state.text.as_deref() == Some(text.as_str()) {
            return true;
        }
        state.text = sequence.is_none().then(|| text.clone());
        let front = clipboard::front_app();
        let excluded = clipboard::excluded_apps(app.state::<AppState>().settings.lock().unwrap().clipboard_excluded_apps.as_deref());
        if !clipboard::should_record(clipboard::marked_hidden(), front.as_deref(), &excluded) {
            return true;
        }
        let before = state.items.first().map(|item| item.text.clone());
        let item = match &files {
            Some(paths) => ClipItem::files(paths, front, Utc::now()),
            None => ClipItem::text(&text, front, Utc::now()),
        };
        state.items = clipboard::adding(item, &state.items, limit);
        if state.items.first().map(|item| &item.text) != before.as_ref() {
            self.keep(&state, remember);
            drop(state);
            let _ = app.emit("clipboard-changed", ());
        }
        true
    }

    fn change(&self, app: &AppHandle, change: impl FnOnce(&mut Vec<ClipItem>)) {
        let (_, _, remember) = options(app);
        let mut state = self.state.lock().unwrap();
        change(&mut state.items);
        self.keep(&state, remember);
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipRow {
    id: String,
    text: String,
    pinned: bool,
    ago: String,
    /// «Скопировать · Code.exe».
    hint: String,
    /// Copied files, shown by their names.
    files: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipboardView {
    shown: bool,
    count: usize,
    rows: Vec<ClipRow>,
}

fn view(app: &AppHandle, query: &str) -> ClipboardView {
    let shown = app.state::<AppState>().settings.lock().unwrap().shows_module(KIND);
    let texts = strings(app);
    let clipboard = app.state::<Clipboard>();
    let state = clipboard.state.lock().unwrap();
    let now = Utc::now();
    ClipboardView {
        shown,
        count: state.items.len(),
        rows: if shown {
            clipboard::shown(&state.items, query)
                .into_iter()
                .map(|item| ClipRow {
                    id: item.id.clone(),
                    text: item.shown_text(),
                    files: item.is_files(),
                    pinned: item.pinned,
                    ago: claudepult_core::projects::ago(&texts, item.date, now),
                    hint: match &item.source_app {
                        Some(app) => format!("{} · {app}", texts.t("Скопировать")),
                        None => texts.t("Скопировать").to_owned(),
                    },
                })
                .collect()
        } else {
            Vec::new()
        },
    }
}

#[tauri::command]
pub fn clipboard_view(app: AppHandle, query: String) -> ClipboardView {
    view(&app, &query)
}

/// A click on an entry: back on the clipboard, and up to the top of the list.
#[tauri::command]
pub fn clipboard_copy(app: AppHandle, id: String, query: String) -> Result<ClipboardView, String> {
    let clipboard = app.state::<Clipboard>();
    let item = clipboard.state.lock().unwrap().items.iter().find(|item| item.id == id).cloned().ok_or("no such entry")?;
    if item.is_files() {
        if !clipboard::write_files(&item.paths()) {
            return Err("the clipboard is busy".into());
        }
    } else {
        app.clipboard().write_text(item.text.clone()).map_err(|error| error.to_string())?;
    }
    let (_, limit, remember) = options(&app);
    {
        let mut state = clipboard.state.lock().unwrap();
        // The app's own copy is not a new entry.
        state.sequence = clipboard::sequence();
        state.text = state.sequence.is_none().then(|| item.text.clone());
        state.items = clipboard::adding(ClipItem { date: Utc::now(), ..item }, &state.items, limit);
        clipboard.keep(&state, remember);
    }
    Ok(view(&app, &query))
}

#[tauri::command]
pub fn clipboard_pin(app: AppHandle, id: String, query: String) -> ClipboardView {
    app.state::<Clipboard>().change(&app, |items| {
        if let Some(item) = items.iter_mut().find(|item| item.id == id) {
            item.pinned = !item.pinned;
        }
    });
    view(&app, &query)
}

#[tauri::command]
pub fn clipboard_remove(app: AppHandle, id: String, query: String) -> ClipboardView {
    app.state::<Clipboard>().change(&app, |items| items.retain(|item| item.id != id));
    view(&app, &query)
}

/// «Очистить»: everything but the pinned entries.
#[tauri::command]
pub fn clipboard_clear(app: AppHandle) -> ClipboardView {
    app.state::<Clipboard>().change(&app, |items| items.retain(|item| item.pinned));
    let _ = app.emit("clipboard-changed", ());
    view(&app, "")
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipboardSettings {
    on: bool,
    limit: u32,
    limits: [u32; 4],
    remember: bool,
    /// «Не запоминать из приложений»: the programs' files.
    excluded: Vec<String>,
}

#[tauri::command]
pub fn clipboard_settings(app: AppHandle) -> ClipboardSettings {
    let state = app.state::<AppState>();
    let settings = state.settings.lock().unwrap();
    ClipboardSettings {
        on: settings.module_on(KIND),
        limit: settings.clipboard_limit,
        limits: clipboard::LIMITS,
        remember: settings.clipboard_remember,
        excluded: clipboard::excluded_apps(settings.clipboard_excluded_apps.as_deref()),
    }
}

/// «Добавить…»: programs by their `.exe`; nothing copied while one of them is in front is recorded.
#[tauri::command]
pub async fn add_clipboard_excluded(app: AppHandle) -> ClipboardSettings {
    use tauri_plugin_dialog::DialogExt;
    let mut dialog = app.dialog().file();
    if cfg!(windows) {
        dialog = dialog.add_filter("exe", &["exe"]);
        if let Some(programs) = std::env::var_os("ProgramFiles") {
            dialog = dialog.set_directory(programs);
        }
    }
    let (sender, receiver) = std::sync::mpsc::channel();
    dialog.pick_files(move |files| {
        let _ = sender.send(files);
    });
    let picked: Vec<String> = tauri::async_runtime::spawn_blocking(move || receiver.recv().ok().flatten())
        .await
        .ok()
        .flatten()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|file| file.into_path().ok())
        .filter_map(|path| path.file_name().map(|name| name.to_string_lossy().into_owned()))
        .collect();
    if !picked.is_empty() {
        save(&app, |settings| {
            let mut apps = clipboard::excluded_apps(settings.clipboard_excluded_apps.as_deref());
            apps.extend(picked);
            settings.clipboard_excluded_apps = Some(clipboard::excluded_apps(Some(&apps)));
        });
    }
    clipboard_settings(app)
}

/// «Убрать» on one program (`reset` false), or «По умолчанию»: the password managers again.
#[tauri::command]
pub fn remove_clipboard_excluded(app: AppHandle, name: String, reset: bool) -> ClipboardSettings {
    save(&app, |settings| {
        settings.clipboard_excluded_apps = if reset {
            None
        } else {
            Some(clipboard::excluded_apps(settings.clipboard_excluded_apps.as_deref()).into_iter().filter(|app| *app != name).collect())
        };
    });
    clipboard_settings(app)
}

/// «Хранить последних» and «Помнить после перезапуска»; switched off, the file goes.
#[tauri::command]
pub fn set_clipboard_options(app: AppHandle, limit: u32, remember: bool) -> ClipboardSettings {
    if clipboard::LIMITS.contains(&limit) {
        save(&app, |settings| {
            settings.clipboard_limit = limit;
            settings.clipboard_remember = remember;
        });
        if remember {
            app.state::<Clipboard>().change(&app, |_| {});
        } else {
            let _ = std::fs::remove_file(file());
        }
    }
    clipboard_settings(app)
}
