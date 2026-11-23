//! Stage 6 «Не спать» (SPEC-windows §4.10, the Mac's `KeepAwakeController` and `KeepAwakeView`): the rules are looked
//! at every 15 seconds and on every change; the panel shows what holds the computer, a switch and quick timers;
//! Settings → «Модули» switches the modules (`set_module`, also «Ресурсы компьютера») and these rules. Only while the module is on.

use crate::{save, strings, AppState};
use claudepult_core::keep_awake::{self, App, Hold, Manual, Reason, Rules};
use claudepult_core::runs::RunState;
use claudepult_core::sessions::State;
use serde::Serialize;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_dialog::DialogExt;

const KIND: &str = "keepAwake";

#[derive(Clone, Default)]
pub struct KeepAwake {
    hold: Arc<Mutex<Hold>>,
    reason: Arc<Mutex<Option<Reason>>>,
}

impl KeepAwake {
    pub fn start(&self, app: AppHandle) {
        let this = self.clone();
        std::thread::spawn(move || {
            // The sessions are read at start; the first look waits for them, as on the Mac.
            std::thread::sleep(Duration::from_secs(3));
            loop {
                this.evaluate(&app);
                std::thread::sleep(Duration::from_secs(15));
            }
        });
    }

    /// Takes or releases the hold; the panel and the tray hear about a new reason.
    pub fn evaluate(&self, app: &AppHandle) {
        let (on, rules, manual) = {
            let settings = app.state::<AppState>().settings.lock().unwrap().clone();
            (settings.module_on(KIND), settings.keep_awake.clone(), settings.keep_awake_manual)
        };
        let now = chrono::Utc::now();
        let hold = if on { Manual::from_stored(manual, now) } else { None };
        if manual.is_some() && hold.is_none() {
            // A timer ran out, or the module was switched off: the manual hold is over.
            save(app, |settings| settings.keep_awake_manual = None);
        }
        let reason = if on { rules.reason(hold, &keep_awake::situation(claude_working(app)), now) } else { None };
        self.hold.lock().unwrap().set(reason.as_ref().map(|_| rules.keep_display_on));
        let changed = *self.reason.lock().unwrap() != reason;
        if changed {
            eprintln!("keep awake: {}", reason.as_ref().map(|r| format!("{r:?}")).unwrap_or_else(|| "off".into()));
            *self.reason.lock().unwrap() = reason;
            let _ = app.emit("keep-awake-changed", ());
            app.state::<crate::limits::Limits>().update_tray(app);
        }
    }

    /// On quit: let the computer sleep again at once.
    pub fn release(&self) {
        self.hold.lock().unwrap().set(None);
    }

    /// «держу: работает Claude», for the tray's hint; None while the computer may sleep.
    pub fn tray_line(&self, app: &AppHandle) -> Option<String> {
        let reason = self.reason.lock().unwrap().clone()?;
        Some(format!("☕ {}", keep_awake::status(Some(&reason), chrono::Utc::now(), &strings(app))))
    }
}

/// A Claude Code session working, or a background run (the Mac's `ClaudeActivity.isWorking`).
fn claude_working(app: &AppHandle) -> bool {
    app.state::<crate::runs::Runs>().list().iter().any(|r| r.state == RunState::Running) || app.state::<crate::sessions::Sessions>().states().contains(&State::Running)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KeepAwakeView {
    /// The module is on and the current profile shows it.
    shown: bool,
    /// A manual hold: the switch is on, «Отпустить» shows.
    manual: bool,
    holding: bool,
    status: String,
}

#[tauri::command]
pub fn keep_awake_view(app: AppHandle) -> KeepAwakeView {
    let (shown, manual) = {
        let settings = app.state::<AppState>().settings.lock().unwrap().clone();
        (settings.shows_module(KIND), Manual::from_stored(settings.keep_awake_manual, chrono::Utc::now()).is_some())
    };
    let reason = app.state::<KeepAwake>().reason.lock().unwrap().clone();
    KeepAwakeView { shown, manual, holding: reason.is_some(), status: keep_awake::status(reason.as_ref(), chrono::Utc::now(), &strings(&app)) }
}

/// «15 мин», «1 ч», «2 ч», or the switch (None: until switched off).
#[tauri::command]
pub fn keep_awake_hold(app: AppHandle, minutes: Option<u32>) -> KeepAwakeView {
    let manual = match minutes {
        Some(minutes) => Manual::Until(chrono::Utc::now() + chrono::Duration::minutes(i64::from(minutes))),
        None => Manual::UntilOff,
    };
    save(&app, |settings| settings.keep_awake_manual = Some(manual.stored()));
    app.state::<KeepAwake>().evaluate(&app);
    keep_awake_view(app)
}

/// «Отпустить» or the switch off: the rules decide again.
#[tauri::command]
pub fn keep_awake_release(app: AppHandle) -> KeepAwakeView {
    save(&app, |settings| settings.keep_awake_manual = None);
    app.state::<KeepAwake>().evaluate(&app);
    keep_awake_view(app)
}

// MARK: - Settings → «Модули»

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModulesView {
    keep_awake: bool,
    resources: bool,
    rules: Rules,
}

fn modules(app: &AppHandle) -> ModulesView {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    ModulesView { keep_awake: settings.module_on(KIND), resources: settings.module_on("resources"), rules: settings.keep_awake.clone() }
}

#[tauri::command]
pub fn modules_view(app: AppHandle) -> ModulesView {
    modules(&app)
}

#[tauri::command]
pub fn set_module(app: AppHandle, kind: String, on: bool) -> Result<ModulesView, String> {
    if !claudepult_core::settings::MODULES.contains(&kind.as_str()) {
        return Err(format!("{kind}: no such module"));
    }
    save(&app, |settings| settings.set_module(&kind, on));
    eprintln!("module {kind}: {}", if on { "on" } else { "off" });
    app.state::<KeepAwake>().evaluate(&app);
    let _ = app.emit("keep-awake-changed", ());
    let _ = app.emit("resources-changed", ());
    let _ = app.emit("quick-commands-changed", ());
    let _ = app.emit("toggles-changed", ());
    let _ = app.emit("notes-changed", ());
    crate::command_hot_keys::sync(&app);
    app.state::<crate::limits::Limits>().update_tray(&app);
    Ok(modules(&app))
}

#[tauri::command]
pub fn set_keep_awake_rules(app: AppHandle, rules: Rules) -> ModulesView {
    save(&app, |settings| settings.keep_awake = rules);
    app.state::<KeepAwake>().evaluate(&app);
    modules(&app)
}

/// «Выбрать…»: programs by their `.exe` (any file elsewhere); the name shown is the file's without the extension.
#[tauri::command]
pub async fn choose_keep_awake_apps(app: AppHandle) -> ModulesView {
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
    let picked: Vec<App> = tauri::async_runtime::spawn_blocking(move || receiver.recv().ok().flatten())
        .await
        .ok()
        .flatten()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|file| file.into_path().ok())
        .filter_map(|path| app_of(&path))
        .collect();
    if !picked.is_empty() {
        save(&app, |settings| {
            for app in picked {
                if !settings.keep_awake.while_apps.iter().any(|a| a.exe.eq_ignore_ascii_case(&app.exe)) {
                    settings.keep_awake.while_apps.push(app);
                }
            }
            settings.keep_awake.while_apps.sort_by_key(|a| a.name.to_lowercase());
        });
        app.state::<KeepAwake>().evaluate(&app);
    }
    modules(&app)
}

fn app_of(path: &Path) -> Option<App> {
    let exe = path.file_name()?.to_string_lossy().into_owned();
    let name = path.file_stem()?.to_string_lossy().into_owned();
    Some(App { exe, name })
}
