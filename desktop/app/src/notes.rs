//! «Заметки» in the panel (the Mac's `NotesView` and `NotesSection`): a note per `.md` file of one folder.

use std::path::PathBuf;

use claudepult_core::notes::{self, KIND};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_dialog::DialogExt;

use crate::{save, strings, AppState};

fn folder(app: &AppHandle) -> PathBuf {
    app.state::<AppState>().settings.lock().unwrap().notes_folder.as_ref().map(PathBuf::from).unwrap_or_else(notes::default_folder)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotesView {
    shown: bool,
    names: Vec<String>,
    selected: Option<String>,
    text: String,
    /// «"План" — в корзину?» for the note shown.
    question: Option<String>,
}

/// The folder's notes and the one shown: the one chosen last, else the first; an empty folder gets «Заметка».
fn view(app: &AppHandle) -> NotesView {
    let state = app.state::<AppState>();
    let (shown, wanted) = {
        let settings = state.settings.lock().unwrap();
        (settings.shows_module(KIND), settings.notes_selected.clone())
    };
    if !shown {
        return NotesView { shown, names: Vec::new(), selected: None, text: String::new(), question: None };
    }
    let texts = strings(app);
    let folder = folder(app);
    let mut names = notes::list(&folder);
    if names.is_empty() {
        match notes::create(&folder, texts.t("Заметка")) {
            Ok(name) => names.push(name),
            Err(error) => eprintln!("notes: the first note not made in {}: {error}", folder.display()),
        }
    }
    let selected = wanted.filter(|name| names.contains(name)).or_else(|| names.first().cloned());
    NotesView {
        shown,
        text: selected.as_ref().map(|name| notes::read(&folder, name)).unwrap_or_default(),
        question: selected.as_ref().map(|name| texts.format("«%@» — в корзину?", &[name])),
        names,
        selected,
    }
}

#[tauri::command]
pub fn notes_view(app: AppHandle) -> NotesView {
    view(&app)
}

#[tauri::command]
pub fn notes_select(app: AppHandle, name: String) -> NotesView {
    save(&app, |settings| settings.notes_selected = Some(name));
    view(&app)
}

#[tauri::command]
pub fn notes_create(app: AppHandle) -> Result<NotesView, String> {
    let texts = strings(&app);
    let name = notes::create(&folder(&app), texts.t("Заметка")).map_err(|error| texts.format("Не сохранено: %@", &[&error]))?;
    save(&app, |settings| settings.notes_selected = Some(name));
    Ok(view(&app))
}

/// What was typed in the panel; the error is the line the panel shows under the note.
#[tauri::command]
pub fn notes_save(app: AppHandle, name: String, text: String) -> Result<(), String> {
    notes::write(&folder(&app), &name, &text).map_err(|error| {
        eprintln!("note «{name}» not saved: {error}");
        strings(&app).format("Не сохранено: %@", &[&error])
    })
}

#[tauri::command]
pub fn notes_trash(app: AppHandle, name: String) -> Result<NotesView, String> {
    let path = notes::file(&folder(&app), &name).filter(|path| path.is_file()).ok_or("no such note")?;
    notes::trash(&path)?;
    eprintln!("note «{name}» moved to the trash");
    Ok(view(&app))
}

/// «Открыть в редакторе»: the note's file in the program the system opens `.md` with.
#[tauri::command]
pub fn notes_open(app: AppHandle, name: String) -> Result<(), String> {
    let path = notes::file(&folder(&app), &name).filter(|path| path.is_file()).ok_or("no such note")?;
    crate::projects::open_with_system(path.as_os_str())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotesSettings {
    on: bool,
    folder: String,
}

#[tauri::command]
pub fn notes_settings(app: AppHandle) -> NotesSettings {
    // Its own statement: the lock must be let go before `folder` takes it again, or the main thread waits for
    // itself and the Settings window freezes.
    let on = app.state::<AppState>().settings.lock().unwrap().module_on(KIND);
    NotesSettings { on, folder: folder(&app).to_string_lossy().into_owned() }
}

/// «Выбрать…»: another folder for the notes; the files stay where they are.
#[tauri::command]
pub async fn choose_notes_folder(app: AppHandle) -> NotesSettings {
    let (sender, receiver) = std::sync::mpsc::channel();
    app.dialog().file().set_directory(folder(&app)).pick_folder(move |picked| {
        let _ = sender.send(picked);
    });
    let picked = tauri::async_runtime::spawn_blocking(move || receiver.recv().ok().flatten()).await.ok().flatten().and_then(|folder| folder.into_path().ok());
    if let Some(path) = picked {
        save(&app, |settings| settings.notes_folder = Some(path.to_string_lossy().into_owned()));
        let _ = app.emit("notes-changed", ());
    }
    notes_settings(app)
}

#[tauri::command]
pub fn open_notes_folder(app: AppHandle) -> Result<(), String> {
    let folder = folder(&app);
    std::fs::create_dir_all(&folder).map_err(|error| error.to_string())?;
    crate::projects::open_with_system(folder.as_os_str())
}
