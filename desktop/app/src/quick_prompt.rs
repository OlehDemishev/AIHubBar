//! «Быстрый запрос» (the Mac's `QuickPromptController` and `QuickPromptWindow`): while the module is on, a global hot
//! key (Ctrl+Alt+P by default) opens a small window over every other one — the task, the project, the agent, where it
//! runs. Claude Code goes through the projects' own launch, Codex to the background (`codex exec`), other agents (and
//! Codex in a terminal) open in a terminal with the task on the clipboard. Also `claudepult --app-command quick-prompt`.

use crate::profiles::projects_root;
use crate::projects::{launch_now, Projects};
use crate::{language, save, strings, AppState};
use claudepult_core::launch::{self, ClaudeCommand, Style};
use claudepult_core::quick_prompt::{self, HotKey, HOT_KEYS};
use serde::Serialize;
use std::path::Path;
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};

const KIND: &str = "quickPrompt";

/// The front window's title when the hot key was pressed, and the hot key registered now.
#[derive(Default)]
pub struct QuickPrompt {
    front: Mutex<Option<String>>,
    registered: Mutex<Option<Shortcut>>,
}

/// The plugin with its one handler: a press of the registered key opens the window; a command's key runs it.
pub fn plugin() -> tauri::plugin::TauriPlugin<tauri::Wry> {
    tauri_plugin_global_shortcut::Builder::new()
        .with_handler(|app, shortcut, event| {
            if event.state() != ShortcutState::Pressed {
                return;
            }
            let ours = *app.state::<QuickPrompt>().registered.lock().unwrap() == Some(*shortcut);
            if ours {
                show(app);
            } else if !crate::search::pressed(app, shortcut) {
                crate::command_hot_keys::pressed(app, shortcut);
            }
        })
        .build()
}

fn hot_key(app: &AppHandle) -> Option<HotKey> {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    // Settings is recording a command's combination: this key must reach its window too.
    if !settings.module_on(KIND) || app.state::<crate::command_hot_keys::CommandHotKeys>().recording() {
        return None;
    }
    HotKey::parse(&settings.quick_prompt_hot_key).filter(|k| *k != HotKey::Off)
}

/// Registers the hot key for the module and the setting as they are now; another program holding it is logged.
/// Called through `command_hot_keys::sync`, which lets a command's key go first.
pub fn sync(app: &AppHandle) {
    let state = app.state::<QuickPrompt>();
    let wanted = hot_key(app).and_then(HotKey::accelerator).and_then(|a| a.parse::<Shortcut>().ok());
    let mut registered = state.registered.lock().unwrap();
    if *registered == wanted {
        return;
    }
    if let Some(old) = registered.take() {
        let _ = app.global_shortcut().unregister(old);
    }
    if let Some(shortcut) = wanted {
        match app.global_shortcut().register(shortcut) {
            Ok(()) => *registered = Some(shortcut),
            Err(error) => eprintln!("quick prompt hot key not registered: {error}"),
        }
    }
    eprintln!("quick prompt hot key: {}", registered.map(|s| s.to_string()).unwrap_or_else(|| "off".into()));
}

/// The hot key and `--app-command quick-prompt`: reads the front window first, then brings the window up; with the
/// module off, Settings instead.
pub fn show(app: &AppHandle) {
    if !app.state::<AppState>().settings.lock().unwrap().module_on(KIND) {
        crate::open_settings_page(app, Some("module.quickPrompt"));
        return;
    }
    *app.state::<QuickPrompt>().front.lock().unwrap() = quick_prompt::front_title();
    if let Some(window) = app.get_webview_window("quick-prompt") {
        let _ = window.emit("quick-prompt-opened", ());
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    let title = format!("{} — {}", claudepult_core::APP_NAME, strings(app).t("Быстрый запрос"));
    let app = app.clone();
    crate::off_main_thread(move || {
        let _ = WebviewWindowBuilder::new(&app, "quick-prompt", WebviewUrl::App("quick-prompt.html".into()))
            .title(title)
            .inner_size(560.0, 330.0)
            .resizable(false)
            .always_on_top(true)
            .center()
            .focused(true)
            .build();
    });
}

#[derive(Serialize)]
pub struct Choice {
    id: String,
    name: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentChoice {
    id: String,
    name: String,
    /// `background` and `terminal`, or `terminal` only.
    modes: Vec<&'static str>,
    /// What the window starts with for this agent.
    start_mode: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Start {
    projects: Vec<Choice>,
    project: Option<String>,
    agents: Vec<AgentChoice>,
}

/// What a new request starts with: the projects, the one in front (or the last), Claude Code first.
#[tauri::command]
pub fn quick_prompt_start(app: AppHandle) -> Start {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let candidates = app.state::<Projects>().candidates();
    let front = app.state::<QuickPrompt>().front.lock().unwrap().clone();
    let project = quick_prompt::default_project(&candidates, front.as_deref(), settings.quick_prompt_last_project.as_deref());
    let last = settings.quick_prompt_last_mode.clone();
    let preferred = settings.launch_mode();
    let agent = |id: &str, name: String| AgentChoice {
        id: id.to_owned(),
        name,
        modes: quick_prompt::modes(id).to_vec(),
        start_mode: quick_prompt::mode(id, last.as_deref(), preferred.as_deref()),
    };
    let mut agents = vec![agent("claude-code", "Claude Code".into())];
    for found in app.state::<crate::services::Agents>().found() {
        if let Some(kind) = claudepult_core::agents::kind(found.id) {
            agents.push(agent(found.id, kind.title.to_owned()));
        }
    }
    Start { projects: candidates.into_iter().map(|c| Choice { id: c.path, name: c.name }).collect(), project, agents }
}

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct SendReply {
    message: String,
    error: bool,
    /// The folder is busy: «Запустить всё равно» sends again with `allow_busy`.
    confirm: bool,
    /// On its way and nothing asked: the window closes.
    close: bool,
    /// An agent opened in a terminal: the note about the clipboard stays a little longer.
    linger: bool,
}

/// Sends the task (the Mac's `QuickPromptController.send`).
#[tauri::command]
pub async fn quick_prompt_send(app: AppHandle, text: String, project: String, agent: String, mode: String, allow_busy: bool, files: Option<Vec<String>>) -> SendReply {
    // Files dropped on the window go with the task as their paths; only files that are still there.
    let files = quick_prompt::adding_files(&files.unwrap_or_default(), &[]);
    let text = if quick_prompt::can_send(&text, Some(&project)) { quick_prompt::task_with_files(&text, &files) } else { text };
    if !quick_prompt::can_send(&text, Some(&project)) {
        return SendReply::default();
    }
    let handle = app.clone();
    tauri::async_runtime::spawn_blocking(move || send(&handle, text, project, agent, mode, allow_busy)).await.unwrap_or_default()
}

fn send(app: &AppHandle, text: String, project: String, agent: String, mode: String, allow_busy: bool) -> SendReply {
    let texts = strings(app);
    let mode = quick_prompt::mode(&agent, Some(&mode), None).to_owned();
    save(app, |settings| {
        settings.quick_prompt_last_project = Some(project.clone());
        settings.quick_prompt_last_mode = Some(mode.clone());
    });
    let codex_background = agent == "codex" && mode == "background";
    if agent == "claude-code" || codex_background {
        eprintln!("quick prompt → {agent} ({mode}) in {project}");
        return match launch_now(app, Path::new(&project), "custom", Some(text), allow_busy, Some(mode), false, codex_background, true) {
            Ok(reply) => SendReply { close: !reply.confirm, confirm: reply.confirm, message: reply.message, ..SendReply::default() },
            Err(error) => SendReply { message: error, error: true, ..SendReply::default() },
        };
    }
    // Other agents only in a terminal, as «Открыть в…»: the agent opens in the folder, the task waits on the clipboard.
    let Some(found) = app.state::<crate::services::Agents>().found().into_iter().find(|f| f.id == agent) else {
        let name = claudepult_core::agents::kind(&agent).map_or(agent.as_str(), |k| k.title);
        return SendReply { message: texts.format("%@ не установлен", &[name]), error: true, ..SendReply::default() };
    };
    let title = claudepult_core::agents::kind(found.id).map_or(found.id, |k| k.title);
    let prompt = ClaudeCommand::CustomTask(text).prompt(&Style::for_projects(&projects_root(app)), language(app));
    if let Err(error) = app.clipboard().write_text(prompt) {
        return SendReply { message: error.to_string(), error: true, ..SendReply::default() };
    }
    eprintln!("quick prompt → {} in a terminal: {project}", found.id);
    match launch::open_in_terminal(Path::new(&project), &found.path, &[]) {
        Ok(()) => SendReply { message: texts.format("%@ открыт в Терминале — задача скопирована, вставьте Ctrl+V", &[title]), close: true, linger: true, ..SendReply::default() },
        Err(error) => SendReply { message: texts.format("Не удалось открыть Терминал: %@", &[&error]), error: true, ..SendReply::default() },
    }
}

// MARK: - Settings → «Модули»

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuickPromptSettings {
    on: bool,
    hot_key: String,
    hot_keys: Vec<(String, String)>,
}

fn settings_view(app: &AppHandle) -> QuickPromptSettings {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let texts = strings(app);
    let hot_keys = HOT_KEYS.into_iter().map(|k| (k.id().to_owned(), k.accelerator().map_or_else(|| texts.t("Выключено").to_owned(), str::to_owned))).collect();
    QuickPromptSettings { on: settings.module_on(KIND), hot_key: settings.quick_prompt_hot_key, hot_keys }
}

#[tauri::command]
pub fn quick_prompt_settings(app: AppHandle) -> QuickPromptSettings {
    settings_view(&app)
}

#[tauri::command]
pub fn set_quick_prompt_hot_key(app: AppHandle, hot_key: String) -> QuickPromptSettings {
    if HotKey::parse(&hot_key).is_some() {
        save(&app, |settings| settings.quick_prompt_hot_key = hot_key);
        crate::command_hot_keys::sync(&app);
    }
    settings_view(&app)
}

/// Esc, «Отмена», or the task on its way.
#[tauri::command]
pub fn close_quick_prompt(app: AppHandle) {
    if let Some(window) = app.get_webview_window("quick-prompt") {
        let _ = window.close();
    }
}

/// «Открыть» in Settings: the window, as the hot key opens it.
#[tauri::command]
pub fn open_quick_prompt(app: AppHandle) {
    show(&app);
}
