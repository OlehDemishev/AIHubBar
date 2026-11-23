//! Keyboard shortcuts of «Быстрые команды» (the Mac's `CommandHotKeys`): registered while the module is on, one per
//! command, again on every change of the library, of the module or of «Быстрый запрос»'s own key. A press runs the
//! command the way its panel button does, and asks first when the command is marked «Спрашивать перед запуском».
//! A combination the system refuses is shown under the command in Settings.

use crate::quick_commands::{library, run_quick_command};
use crate::{strings, AppState};
use claudepult_core::hot_keys::{self, Key, KeyCombo, Problem};
use claudepult_core::quick_prompt::HotKey;
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use tauri::{AppHandle, Manager};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut};

const KIND: &str = "quickCommands";

#[derive(Default)]
pub struct CommandHotKeys {
    /// The keys asked for last time: registered again only when they change.
    last: Mutex<Option<Vec<Key>>>,
    registered: Mutex<Vec<(Shortcut, String)>>,
    /// Commands whose combination the system refused.
    failed: Mutex<HashSet<String>>,
    /// Settings is recording a combination: every key of the app is let go, so the press reaches the window.
    recording: AtomicBool,
    /// «Запустить?» is on the screen.
    asking: AtomicBool,
}

impl CommandHotKeys {
    pub fn recording(&self) -> bool {
        self.recording.load(Ordering::SeqCst)
    }
}

/// AI Hub Bar's own keys, by what they do.
fn reserved(app: &AppHandle) -> Vec<(KeyCombo, String)> {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let own = settings.module_on("quickPrompt").then(|| HotKey::parse(&settings.quick_prompt_hot_key).and_then(HotKey::combo)).flatten();
    own.map(|combo| (combo, strings(app).t("Быстрый запрос").to_owned())).into_iter().chain(crate::search::reserved(app)).collect()
}

fn plan(app: &AppHandle) -> hot_keys::Plan {
    let on = app.state::<AppState>().settings.lock().unwrap().module_on(KIND);
    hot_keys::plan(&if on { library(app) } else { Vec::new() }, &reserved(app))
}

/// Every global key of the app as the settings are now. The commands' keys are let go first and taken last, so a
/// key can pass between a command and «Быстрый запрос» in either direction.
pub fn sync(app: &AppHandle) {
    let state = app.state::<CommandHotKeys>();
    let wanted = if state.recording() { Vec::new() } else { plan(app).keys };
    let mut last = state.last.lock().unwrap();
    let changed = last.as_ref() != Some(&wanted);
    let mut registered = state.registered.lock().unwrap();
    if changed {
        for (shortcut, _) in registered.drain(..) {
            let _ = app.global_shortcut().unregister(shortcut);
        }
    }
    crate::quick_prompt::sync(app);
    crate::search::sync(app);
    if !changed {
        return;
    }
    let mut failed = HashSet::new();
    for key in &wanted {
        let shortcut = key.combo.accelerator().and_then(|a| a.parse::<Shortcut>().ok());
        match shortcut.map(|s| app.global_shortcut().register(s).map(|()| s)) {
            Some(Ok(shortcut)) => registered.push((shortcut, key.command.clone())),
            Some(Err(error)) => {
                eprintln!("command hot key {} not registered: {error}", key.combo.title());
                failed.insert(key.command.clone());
            }
            None => {
                failed.insert(key.command.clone());
            }
        }
    }
    eprintln!("command hot keys: {} registered, {} refused", registered.len(), failed.len());
    // While recording nothing is asked for, so nothing new is known about what the system refuses.
    if !state.recording() {
        *state.failed.lock().unwrap() = failed;
    }
    *last = Some(wanted);
}

/// A registered key pressed; false — not a command's key.
pub fn pressed(app: &AppHandle, shortcut: &Shortcut) -> bool {
    let state = app.state::<CommandHotKeys>();
    let Some(id) = state.registered.lock().unwrap().iter().find(|(s, _)| s == shortcut).map(|(_, id)| id.clone()) else { return false };
    let Some(command) = library(app).into_iter().find(|c| c.id == id) else { return true };
    eprintln!("quick command «{}» from its hot key", command.title);
    if !command.confirm {
        let _ = run_quick_command(app.clone(), id);
        return true;
    }
    // There is no button to press twice here: a window asks, as on the Mac. One question at a time.
    if state.asking.swap(true, Ordering::SeqCst) {
        return true;
    }
    let texts = strings(app);
    let handle = app.clone();
    app.dialog()
        .message(&command.value)
        .title(texts.format("Запустить «%@»?", &[&command.title]))
        .buttons(MessageDialogButtons::OkCancelCustom(texts.t("Запустить").to_owned(), texts.t("Отмена").to_owned()))
        .show(move |yes| {
            handle.state::<CommandHotKeys>().asking.store(false, Ordering::SeqCst);
            if yes {
                let _ = run_quick_command(handle.clone(), id);
            }
        });
    true
}

/// A command's combination as Settings and the panel show it.
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct HotKeyView {
    /// «Ctrl+Alt+K».
    pub title: String,
    pub problem: Option<String>,
    /// Not registered: the problem is more than a warning.
    pub blocked: bool,
}

/// By command id: every command that has a combination, with what is wrong with it.
pub fn views(app: &AppHandle) -> HashMap<String, HotKeyView> {
    let texts = strings(app);
    let plan = plan(app);
    let failed = app.state::<CommandHotKeys>().failed.lock().unwrap().clone();
    library(app)
        .into_iter()
        .filter_map(|command| {
            let combo = command.combo()?;
            let blocking = plan.problems.get(&command.id).cloned().or_else(|| failed.contains(&command.id).then_some(Problem::Taken));
            let problem = blocking.or_else(|| hot_keys::warning(combo, hot_keys::altgr_character));
            let view = HotKeyView { title: combo.title(), blocked: problem.as_ref().is_some_and(Problem::blocks), problem: problem.map(|p| p.text(&texts)) };
            Some((command.id, view))
        })
        .collect()
}

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Pressed {
    /// The Mac's `hotKey`, to put into the command.
    combo: Option<KeyCombo>,
    error: Option<String>,
}

/// The recorder's key press: a browser's `keyCode` and `code` with the modifiers held. Neither a combination nor
/// an error — a key that can't be part of one; the recorder goes on waiting.
#[tauri::command]
pub fn hot_key_from_press(app: AppHandle, key_code: u32, code: String, ctrl: bool, alt: bool, shift: bool, meta: bool) -> Pressed {
    match KeyCombo::from_press(key_code, &code, ctrl, alt, shift, meta) {
        Some(combo) if combo.is_valid() => Pressed { combo: Some(combo), error: None },
        Some(_) => Pressed { combo: None, error: Some(strings(&app).t("Нужна Ctrl, Alt или Win — или одна клавиша F1–F20.").to_owned()) },
        None => Pressed::default(),
    }
}

/// «Записать» pressed, or the recording over without a new combination.
#[tauri::command]
pub fn set_hot_key_recording(app: AppHandle, on: bool) {
    stop_or_start_recording(&app, on);
}

pub fn stop_or_start_recording(app: &AppHandle, on: bool) {
    if app.state::<CommandHotKeys>().recording.swap(on, Ordering::SeqCst) != on {
        sync(app);
    }
}

#[cfg(test)]
mod tests {
    use claudepult_core::hot_keys::{KeyCombo, COMMAND, CONTROL, OPTION, SHIFT};
    use tauri_plugin_global_shortcut::Shortcut;

    #[test]
    fn the_plugin_reads_every_key_the_core_names() {
        let mut known = 0;
        for key_code in 0..128 {
            for modifiers in [0, CONTROL | OPTION, COMMAND | SHIFT] {
                let Some(accelerator) = KeyCombo::new(key_code, modifiers).accelerator() else { continue };
                assert!(accelerator.parse::<Shortcut>().is_ok(), "{accelerator}");
                known += 1;
            }
        }
        assert_eq!(known, 94 * 3);
        // Win is the plugin's Super, and the two are different shortcuts.
        let win: Shortcut = KeyCombo::new(40, COMMAND).accelerator().unwrap().parse().unwrap();
        let ctrl: Shortcut = KeyCombo::new(40, CONTROL).accelerator().unwrap().parse().unwrap();
        assert_ne!(win, ctrl);
        assert_eq!(win, "Super+K".parse::<Shortcut>().unwrap());
    }
}
