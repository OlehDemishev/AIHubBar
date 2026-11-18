//! Stage 6 «Быстрые переключатели» (SPEC-windows §4.10, the Mac's `QuickTogglesView` and `QuickTogglesSection`):
//! tiles in the panel, each one running only when clicked; «Очистить корзину» asks first. Settings → «Модули» picks
//! which tiles show.

use crate::{save, strings, AppState};
use claudepult_core::quick_commands::Outcome;
use claudepult_core::toggles;
use serde::Serialize;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};

const KIND: &str = "toggles";

#[derive(Clone, Default)]
pub struct Toggles {
    running: Arc<Mutex<HashSet<String>>>,
    results: Arc<Mutex<HashMap<String, Outcome>>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Tile {
    id: &'static str,
    short_title: String,
    /// The hover hint: its name and its state when known.
    hint: String,
    glyph: &'static str,
    on: Option<bool>,
    running: bool,
    confirm: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TogglesView {
    shown: bool,
    tiles: Vec<Tile>,
    /// «Очистить корзину? Это нельзя отменить.», per tile that asks.
    questions: HashMap<&'static str, String>,
    results: Vec<Outcome>,
}

/// The tiles shown: the profile's own choice (a Mac profile's `toggles`), else Settings', else all this system has.
fn shown_toggles(app: &AppHandle) -> Vec<&'static str> {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let profile: Option<Vec<String>> = settings
        .current()
        .and_then(|p| p.other.get("modules")?.as_array()?.iter().find(|m| m["kind"] == KIND)?.get("toggles")?.as_array().cloned())
        .map(|list| list.iter().filter_map(Value::as_str).map(str::to_owned).collect());
    let chosen = profile.or(settings.quick_toggles);
    toggles::available().into_iter().filter(|t| chosen.as_ref().is_none_or(|list| list.iter().any(|c| c == t))).collect()
}

#[tauri::command]
pub async fn toggles_view(app: AppHandle) -> TogglesView {
    let shown = app.state::<AppState>().settings.lock().unwrap().shows_module(KIND);
    if !shown {
        return TogglesView { shown, tiles: Vec::new(), questions: HashMap::new(), results: Vec::new() };
    }
    let texts = strings(&app);
    let list = shown_toggles(&app);
    // Reading the registry or gsettings: off the main thread.
    let states: Vec<Option<bool>> = {
        let list = list.clone();
        tauri::async_runtime::spawn_blocking(move || list.iter().map(|t| toggles::state(t)).collect()).await.unwrap_or_default()
    };
    let state = app.state::<Toggles>();
    let running = state.running.lock().unwrap().clone();
    let tiles = list
        .iter()
        .zip(states)
        .map(|(id, on)| {
            let title = toggles::title(id, &texts);
            let hint = match on {
                Some(true) => format!("{title}{}", texts.t(" — включено")),
                Some(false) => format!("{title}{}", texts.t(" — выключено")),
                None => title,
            };
            Tile { id, short_title: toggles::short_title(id, &texts), hint, glyph: toggles::glyph(id), on, running: running.contains(*id), confirm: toggles::needs_confirmation(id) }
        })
        .collect();
    let questions = list.iter().filter(|t| toggles::needs_confirmation(t)).map(|t| (*t, texts.format("%@? Это нельзя отменить.", &[&toggles::title(t, &texts)]))).collect();
    let results = list.iter().filter_map(|t| state.results.lock().unwrap().get(*t).cloned()).collect();
    TogglesView { shown, tiles, questions, results }
}

/// A tile clicked (after «Да» for the Recycle Bin).
#[tauri::command]
pub async fn perform_toggle(app: AppHandle, id: String) -> Result<(), String> {
    let toggle = *toggles::TOGGLES.iter().find(|t| **t == id).ok_or("no such toggle")?;
    let state = app.state::<Toggles>().inner().clone();
    if !state.running.lock().unwrap().insert(id.clone()) {
        return Ok(());
    }
    let _ = app.emit("toggles-changed", ());
    let texts = strings(&app);
    let result = tauri::async_runtime::spawn_blocking(move || toggles::perform(toggle, &texts)).await.map_err(|e| e.to_string())?;
    eprintln!("toggle {id}: {}", if result.is_ok() { "done" } else { "failed" });
    state.running.lock().unwrap().remove(&id);
    match result {
        Ok(Some(note)) => state.results.lock().unwrap().insert(id, Outcome { text: note, is_error: false }),
        Ok(None) => state.results.lock().unwrap().remove(&id),
        Err(error) => state.results.lock().unwrap().insert(id, Outcome { text: error, is_error: true }),
    };
    let _ = app.emit("toggles-changed", ());
    Ok(())
}

// MARK: - Settings → «Модули»

#[derive(Serialize)]
pub struct Choice {
    id: &'static str,
    title: String,
    glyph: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToggleSettings {
    on: bool,
    available: Vec<Choice>,
    chosen: Vec<&'static str>,
}

fn toggle_settings(app: &AppHandle) -> ToggleSettings {
    let texts = strings(app);
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let available = toggles::available();
    let chosen = available.iter().copied().filter(|t| settings.quick_toggles.as_ref().is_none_or(|list| list.iter().any(|c| c == t))).collect();
    ToggleSettings { on: settings.module_on(KIND), available: available.into_iter().map(|id| Choice { id, title: toggles::title(id, &texts), glyph: toggles::glyph(id) }).collect(), chosen }
}

#[tauri::command]
pub fn quick_toggle_settings(app: AppHandle) -> ToggleSettings {
    toggle_settings(&app)
}

#[tauri::command]
pub fn set_quick_toggles(app: AppHandle, chosen: Vec<String>) -> ToggleSettings {
    let chosen: Vec<String> = toggles::TOGGLES.iter().filter(|t| chosen.iter().any(|c| c == *t)).map(|t| (*t).to_owned()).collect();
    save(&app, |settings| settings.quick_toggles = Some(chosen));
    let _ = app.emit("toggles-changed", ());
    toggle_settings(&app)
}
