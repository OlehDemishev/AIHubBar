//! Stage 6 «Быстрые команды» (SPEC-windows §4.10, the Mac's `QuickToolsController` and `QuickCommandsView`): the
//! library as buttons in the panel, run one at a time each, the last result under them and a notification for a
//! background script. Settings → «Модули» edits the library. Keyboard shortcuts come later.

use crate::{save, strings, AppState};
use claudepult_core::launch;
use claudepult_core::quick_commands::{self, Invocation, Kind, Outcome, QuickCommand};
use serde::Serialize;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

const KIND: &str = "quickCommands";

#[derive(Clone, Default)]
pub struct QuickCommands {
    running: Arc<Mutex<HashSet<String>>>,
    results: Arc<Mutex<HashMap<String, Outcome>>>,
}

/// The library, or the starting examples in the interface language.
fn library(app: &AppHandle) -> Vec<QuickCommand> {
    let saved = app.state::<AppState>().settings.lock().unwrap().quick_commands.clone();
    saved.unwrap_or_else(|| quick_commands::examples(&strings(app)))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Button {
    id: String,
    title: String,
    glyph: &'static str,
    /// The hover hint: what it runs or opens.
    value: String,
    confirm: bool,
    running: bool,
    result: Option<Outcome>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuickCommandsView {
    shown: bool,
    buttons: Vec<Button>,
}

#[tauri::command]
pub fn quick_commands_view(app: AppHandle) -> QuickCommandsView {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let shown = settings.shows_module(KIND);
    // A profile from a Mac may show only some commands (the Mac's `ProfileModule.commands`).
    let chosen: Option<Vec<String>> = settings
        .current()
        .and_then(|p| p.other.get("modules")?.as_array()?.iter().find(|m| m["kind"] == KIND)?.get("commands")?.as_array().cloned())
        .map(|list| list.iter().filter_map(Value::as_str).map(str::to_owned).collect());
    let state = app.state::<QuickCommands>();
    let running = state.running.lock().unwrap().clone();
    let results = state.results.lock().unwrap().clone();
    let buttons = library(&app)
        .into_iter()
        .filter(|c| c.kind != Kind::Shortcut && chosen.as_ref().is_none_or(|ids| ids.contains(&c.id)))
        .map(|c| Button { glyph: quick_commands::glyph(&c.symbol), running: running.contains(&c.id), result: results.get(&c.id).cloned(), id: c.id, title: c.title, value: c.value, confirm: c.confirm })
        .collect();
    QuickCommandsView { shown, buttons }
}

/// A button pressed (after «Запустить?» when it asks): opened at once, or run in the background with a notification.
#[tauri::command]
pub fn run_quick_command(app: AppHandle, id: String) -> Result<(), String> {
    let command = library(&app).into_iter().find(|c| c.id == id).ok_or("no such command")?;
    let state = app.state::<QuickCommands>().inner().clone();
    if !state.running.lock().unwrap().insert(command.id.clone()) {
        return Ok(());
    }
    let texts = strings(&app);
    let home = quick_commands::home();
    let finish = |state: &QuickCommands, result: Option<Outcome>| {
        state.running.lock().unwrap().remove(&command.id);
        match result {
            Some(result) => state.results.lock().unwrap().insert(command.id.clone(), result),
            None => state.results.lock().unwrap().remove(&command.id),
        };
        let _ = app.emit("quick-commands-changed", ());
    };
    match command.invocation(&home) {
        Invocation::Invalid => finish(&state, Some(Outcome { text: texts.t("Команда пустая — заполните её в Настройках → «Модули».").into(), is_error: true })),
        Invocation::Open(target) => {
            let opened = crate::projects::open_with_system(target.as_ref());
            finish(&state, opened.err().map(|_| Outcome { text: texts.format("Не открылось: %@", &[&target]), is_error: true }));
        }
        Invocation::Terminal(line) => {
            let opened = launch::open_line_in_terminal(&home, &line);
            finish(&state, opened.err().map(|e| Outcome { text: texts.format("Не удалось открыть Терминал: %@", &[&e]), is_error: true }));
        }
        Invocation::Process { program, args } => {
            let _ = app.emit("quick-commands-changed", ());
            let app = app.clone();
            std::thread::spawn(move || {
                let texts = strings(&app);
                let outcome = quick_commands::execute(&program, &args, &home, &texts);
                eprintln!("quick command «{}»: {}", command.title, if outcome.is_error { "failed" } else { "done" });
                let _ = app.notification().builder().title(&command.title).body(&outcome.text).show();
                state.running.lock().unwrap().remove(&command.id);
                state.results.lock().unwrap().insert(command.id.clone(), outcome);
                let _ = app.emit("quick-commands-changed", ());
            });
        }
    }
    Ok(())
}

// MARK: - Settings → «Модули»

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryView {
    on: bool,
    commands: Vec<QuickCommand>,
    /// The Mac's symbol names with the characters drawn for them.
    symbols: Vec<(&'static str, &'static str)>,
}

fn library_view(app: &AppHandle) -> LibraryView {
    let on = app.state::<AppState>().settings.lock().unwrap().module_on(KIND);
    LibraryView { on, commands: library(app), symbols: quick_commands::SYMBOLS.to_vec() }
}

#[tauri::command]
pub fn quick_commands_library(app: AppHandle) -> LibraryView {
    library_view(&app)
}

/// The whole library, as edited: written when a field is left.
#[tauri::command]
pub fn set_quick_commands(app: AppHandle, commands: Vec<QuickCommand>) -> LibraryView {
    let ids: HashSet<String> = commands.iter().map(|c| c.id.clone()).collect();
    save(&app, |settings| settings.quick_commands = Some(commands));
    // A deleted command's last result goes with it.
    app.state::<QuickCommands>().results.lock().unwrap().retain(|id, _| ids.contains(id));
    let _ = app.emit("quick-commands-changed", ());
    library_view(&app)
}

/// «Добавить команду»: a new background script, not saved until its fields are.
#[tauri::command]
pub fn new_quick_command(app: AppHandle) -> QuickCommand {
    QuickCommand::new(strings(&app).t("Новая команда"), "bolt", Kind::Script, "")
}
