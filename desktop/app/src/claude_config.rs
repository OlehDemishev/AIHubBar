//! The «Claude Code: инструкции и MCP» window (the Mac's `ClaudeConfigWindow` and `ClaudeConfigStore`): every
//! CLAUDE.md and AGENTS.md with a search and an editor, Claude Code's MCP servers with a switch, the skills, plugins
//! and hooks of Claude Code and Codex. The commands are async: they read files and may wait for `claude`.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::Local;
use claudepult_core::claude_config::{self as config, Scope, Server, Status};
use claudepult_core::{command, hooks, launch, paths};
use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Manager};

use crate::strings;

/// Unsaved edits by path. They live here, not in the window: switching files or closing it loses nothing.
#[derive(Default)]
pub struct ClaudeConfig {
    drafts: Mutex<HashMap<String, String>>,
}

struct Places {
    home: PathBuf,
    claude_dir: PathBuf,
    codex_dir: PathBuf,
    /// `~/.claude.json`; inside the folder of `CLAUDE_CONFIG_DIR` when that is set.
    claude_json: PathBuf,
    settings: PathBuf,
    stash: PathBuf,
}

fn places() -> Places {
    let home = dirs::home_dir().unwrap_or_else(std::env::temp_dir);
    let claude_dir = paths::claude_dir();
    let moved = std::env::var("CLAUDE_CONFIG_DIR").is_ok_and(|value| !value.trim().is_empty());
    Places {
        claude_json: if moved { claude_dir.join(".claude.json") } else { home.join(".claude.json") },
        settings: claude_dir.join("settings.json"),
        stash: paths::data_dir().join("mcp-disabled.json"),
        codex_dir: paths::codex_dir(),
        claude_dir,
        home,
    }
}

fn stamp() -> String {
    Local::now().format("%Y%m%d-%H%M%S").to_string()
}

fn projects(app: &AppHandle) -> Vec<(String, PathBuf)> {
    app.state::<crate::projects::Projects>().names()
}

fn instruction_files(app: &AppHandle, places: &Places) -> Vec<config::InstructionFile> {
    config::instruction_files(&places.home, &places.claude_dir, &crate::profiles::projects_root(app), &projects(app))
}

/// The servers as the files have them now.
fn servers(app: &AppHandle, places: &Places) -> Vec<Server> {
    let claude = config::read_object(&places.claude_json);
    let mut folders: Vec<String> = projects(app).into_iter().map(|(_, path)| path.to_string_lossy().into_owned()).collect();
    // A project Claude Code knows and the profile's folder doesn't hold.
    for known in claude.as_ref().and_then(|j| j.get("projects")).and_then(Value::as_object).into_iter().flat_map(|projects| projects.keys()) {
        if !folders.iter().any(|folder| config::same_path(folder, known)) {
            folders.push(known.clone());
        }
    }
    let (mut mcp_files, mut local) = (BTreeMap::new(), BTreeMap::new());
    for folder in folders {
        let Some(file) = config::read_object(&Path::new(&folder).join(".mcp.json")) else { continue };
        if let Some(settings) = config::read_object(&Path::new(&folder).join(".claude").join("settings.local.json")) {
            local.insert(folder.clone(), settings);
        }
        mcp_files.insert(folder, file);
    }
    config::servers(claude.as_ref(), config::read_object(&places.settings).as_ref(), &mcp_files, &local, &config::load_stash(&places.stash))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FileRow {
    path: String,
    title: String,
    /// «Общие» or the project's name.
    group: String,
    text: String,
    draft: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ServerRow {
    id: String,
    name: String,
    transport: String,
    target: String,
    /// `on`, `off` or `pending`.
    status: &'static str,
    scope: String,
    group: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SkillRow {
    id: String,
    name: String,
    description: String,
    on: bool,
    agent: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PluginRow {
    key: String,
    name: String,
    marketplace: String,
    version: String,
    on: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HookRow {
    event: String,
    command: String,
    agent: &'static str,
    ours: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigView {
    files: Vec<FileRow>,
    servers: Vec<ServerRow>,
    skills: Vec<SkillRow>,
    plugins: Vec<PluginRow>,
    hooks: Vec<HookRow>,
}

fn agent_title(agent: &str) -> &'static str {
    if agent == "codex" { "Codex" } else { "Claude Code" }
}

fn view(app: &AppHandle) -> ConfigView {
    let texts = strings(app);
    let places = places();
    let list = projects(app);
    let drafts = app.state::<ClaudeConfig>().drafts.lock().unwrap().clone();
    let files = instruction_files(app, &places)
        .into_iter()
        .map(|file| {
            let path = file.path.to_string_lossy().into_owned();
            FileRow {
                text: config::shown_text(&std::fs::read_to_string(&file.path).unwrap_or_default()),
                draft: drafts.get(&path).cloned(),
                group: file.project.unwrap_or_else(|| texts.t("Общие").to_owned()),
                title: file.title,
                path,
            }
        })
        .collect();
    let mut found = servers(app, &places);
    // A switched-off server comes last in the list: it goes back under its own heading — «Для всех проектов» first.
    found.sort_by_key(|server| server.scope.project_path().map(|path| path.replace('\\', "/").to_lowercase()));
    let servers = found
        .into_iter()
        .map(|server| {
            let group = match server.scope.project_path() {
                None => texts.t("Для всех проектов").to_owned(),
                Some(path) => list
                    .iter()
                    .find(|(_, folder)| config::same_path(&folder.to_string_lossy(), path))
                    .map(|(name, _)| name.clone())
                    .unwrap_or_else(|| path.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next().unwrap_or(path).to_owned()),
            };
            ServerRow {
                id: server.id(),
                scope: server.scope.title(&texts),
                status: match server.status {
                    Status::On => "on",
                    Status::Off => "off",
                    Status::Pending => "pending",
                },
                name: server.name,
                transport: server.transport,
                target: server.target,
                group,
            }
        })
        .collect();
    let settings = config::read_object(&places.settings);
    let skills = config::skills(&places.home, &places.claude_dir, &places.codex_dir).into_iter().map(|skill| SkillRow { id: skill.id(), agent: agent_title(skill.agent), name: skill.name, description: skill.description, on: skill.on }).collect();
    let plugins = config::plugins(config::read_object(&places.claude_dir.join("plugins").join("installed_plugins.json")).as_ref(), settings.as_ref())
        .into_iter()
        .map(|plugin| PluginRow { name: plugin.name().to_owned(), marketplace: plugin.marketplace().to_owned(), key: plugin.key, version: plugin.version, on: plugin.on })
        .collect();
    let hooks = config::hooks(settings.as_ref(), "claudeCode")
        .into_iter()
        .chain(config::hooks(config::read_object(&places.codex_dir.join("hooks.json")).as_ref(), "codex"))
        .map(|hook| HookRow { agent: agent_title(hook.agent), event: hook.event, command: hook.command, ours: hook.ours })
        .collect();
    ConfigView { files, servers, skills, plugins, hooks }
}

/// Opens (or brings forward) the window.
#[tauri::command]
pub fn open_claude_config(app: AppHandle) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
    if let Some(window) = app.get_webview_window("claude-config") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    let title = format!("{} — {}", claudepult_core::APP_NAME, strings(&app).t("Claude Code: инструкции и MCP"));
    crate::off_main_thread(move || {
        let _ = tauri::WebviewWindowBuilder::new(&app, "claude-config", tauri::WebviewUrl::App("claude-config.html".into())).title(title).inner_size(880.0, 580.0).min_inner_size(760.0, 480.0).center().build();
    });
}

#[tauri::command]
pub async fn claude_config_view(app: AppHandle) -> ConfigView {
    view(&app)
}

/// The instruction file of that path, if it is one of the window's: nothing else is read, written or opened.
fn listed(app: &AppHandle, path: &str) -> Result<PathBuf, String> {
    instruction_files(app, &places()).into_iter().map(|file| file.path).find(|file| file.to_string_lossy() == path).ok_or_else(|| "not an instruction file".to_owned())
}

/// The editor's text as it is typed: kept until saved, or dropped when it is the file's again.
#[tauri::command]
pub async fn claude_config_edit(app: AppHandle, path: String, text: String) -> Result<(), String> {
    let file = listed(&app, &path)?;
    let same = config::shown_text(&std::fs::read_to_string(file).unwrap_or_default()) == text.replace("\r\n", "\n");
    let state = app.state::<ClaudeConfig>();
    let mut drafts = state.drafts.lock().unwrap();
    if same {
        drafts.remove(&path);
    } else {
        drafts.insert(path, text);
    }
    Ok(())
}

/// «Сохранить». `CLAUDE.md` is often a link to `AGENTS.md`: the link stays, the file behind it changes.
#[tauri::command]
pub async fn claude_config_save(app: AppHandle, path: String, text: String) -> Result<ConfigView, String> {
    let file = listed(&app, &path)?;
    let on_disk = std::fs::read_to_string(&file).map_err(|error| error.to_string())?;
    std::fs::write(&file, config::text_to_save(&on_disk, &text)).map_err(|error| error.to_string())?;
    app.state::<ClaudeConfig>().drafts.lock().unwrap().remove(&path);
    eprintln!("saved {path}");
    Ok(view(&app))
}

/// «Папка»: the file chosen in the file manager; «Открыть в редакторе»: in the program the system opens it with.
#[tauri::command]
pub async fn claude_config_open(app: AppHandle, path: String, reveal: bool) -> Result<(), String> {
    let file = listed(&app, &path)?;
    if !reveal {
        return crate::projects::open_with_system(file.as_os_str());
    }
    if cfg!(windows) {
        let mut select = std::ffi::OsString::from("/select,");
        select.push(file.as_os_str());
        let mut explorer = std::process::Command::new("explorer.exe");
        explorer.arg(select);
        // Explorer answers 1 even when the window opened.
        return explorer.spawn().map(|_| ()).map_err(|error| error.to_string());
    }
    crate::projects::open_with_system(file.parent().unwrap_or(&file).as_os_str())
}

// MARK: - Switching

fn read_for_change(path: &Path) -> Result<Value, String> {
    hooks::read_settings(path).map(|value| value.unwrap_or_else(|| json!({}))).map_err(|error| format!("{}: {error}", path.display()))
}

/// `claude mcp …` in the project's folder, 30 seconds at most. The program is started as it is, `.cmd` included:
/// the standard library quotes a batch file's arguments itself and refuses what can't be passed safely.
fn run_claude(arguments: &[&str], folder: Option<&Path>) -> Result<(), String> {
    let program = launch::find_claude().ok_or("claude")?;
    let mut claude = std::process::Command::new(&program);
    claude.args(arguments).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
    if let Some(folder) = folder {
        claude.current_dir(folder);
    }
    command::hide_window(&mut claude);
    let name = format!("claude {}", arguments.iter().take(2).copied().collect::<Vec<_>>().join(" "));
    let mut child = claude.spawn().map_err(|error| format!("{name}: {error}"))?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() < Duration::from_secs(30) => std::thread::sleep(Duration::from_millis(30)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("{name}: timeout"));
            }
        }
    }
    let output = child.wait_with_output().map_err(|error| format!("{name}: {error}"))?;
    if output.status.success() {
        return Ok(());
    }
    let detail = format!("{}{}", String::from_utf8_lossy(&output.stderr), String::from_utf8_lossy(&output.stdout));
    Err(format!("{name}: {}", detail.trim()))
}

/// `~/.claude.json` changes all the time while Claude runs, so it is left to `claude mcp remove` / `add-json`.
fn switch_with_cli(places: &Places, server: &Server, on: bool) -> Result<(), String> {
    let scope = if server.scope == Scope::User { "user" } else { "local" };
    let folder = server.scope.project_path().map(PathBuf::from);
    let key = server.scope.key();
    let mut stash = config::load_stash(&places.stash);
    if on {
        let Some(index) = stash.iter().position(|entry| entry.name == server.name && entry.scope_key == key) else { return Ok(()) };
        run_claude(&["mcp", "add-json", &server.name, &stash[index].config, "-s", scope], folder.as_deref())?;
        stash.remove(index);
        return config::save_stash(&places.stash, &stash).map_err(|error| error.to_string());
    }
    let Some(found) = config::config_of(config::read_object(&places.claude_json).as_ref(), None, &server.scope, &server.name) else { return Ok(()) };
    // Kept before removing, so a failed removal loses nothing.
    stash.push(config::Stashed { name: server.name.clone(), scope_key: key, config: found.to_string() });
    config::save_stash(&places.stash, &stash).map_err(|error| error.to_string())?;
    if let Err(error) = run_claude(&["mcp", "remove", &server.name, "-s", scope], folder.as_deref()) {
        stash.pop();
        if let Err(error) = config::save_stash(&places.stash, &stash) {
            eprintln!("MCP stash not restored: {error}");
        }
        return Err(error);
    }
    Ok(())
}

fn switch_server(places: &Places, server: &Server, on: bool) -> Result<(), String> {
    match &server.scope {
        Scope::Project(path) => {
            let file = Path::new(path).join(".claude").join("settings.local.json");
            config::write_object(&file, &config::settings_local(&read_for_change(&file)?, &server.name, !on)).map_err(|error| error.to_string())
        }
        Scope::Settings => {
            let Some((settings, stash)) = config::settings_with_server(&read_for_change(&places.settings)?, &config::load_stash(&places.stash), &server.name, on) else { return Ok(()) };
            // The stash first when the server leaves, the file first when it comes back: a failure between the two
            // leaves the config in both places, never in neither.
            let (write_stash, write_file) = (|| config::save_stash(&places.stash, &stash), || config::write_with_backup(&places.settings, &settings, &stamp()));
            if on { write_file().and_then(|()| write_stash()) } else { write_stash().and_then(|()| write_file()) }.map_err(|error| error.to_string())
        }
        Scope::User | Scope::Local(_) => switch_with_cli(places, server, on),
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Changed {
    view: ConfigView,
    error: Option<String>,
}

fn changed(app: &AppHandle, result: Result<(), String>) -> Changed {
    if let Err(error) = &result {
        eprintln!("claude config: {error}");
    }
    Changed { view: view(app), error: result.err() }
}

#[tauri::command]
pub async fn set_mcp_server(app: AppHandle, id: String, on: bool) -> Changed {
    let places = places();
    let result = match servers(&app, &places).into_iter().find(|server| server.id() == id) {
        Some(server) => switch_server(&places, &server, on).inspect(|()| eprintln!("MCP «{}» ({}) {}", server.name, server.scope.key(), if on { "on" } else { "off" })),
        None => Ok(()),
    };
    changed(&app, result)
}

/// Off — the skill's folder moves next to the skills folder; on — back. Nothing inside it changes.
#[tauri::command]
pub async fn set_agent_skill(app: AppHandle, id: String, on: bool) -> Changed {
    let places = places();
    let result = match config::skills(&places.home, &places.claude_dir, &places.codex_dir).into_iter().find(|skill| skill.id() == id) {
        Some(skill) => config::move_skill(&skill, on).map_err(|error| error.to_string()),
        None => Ok(()),
    };
    changed(&app, result)
}

/// `enabledPlugins` in `~/.claude/settings.json`, with a backup of the file first.
#[tauri::command]
pub async fn set_claude_plugin(app: AppHandle, key: String, on: bool) -> Changed {
    let places = places();
    let result = read_for_change(&places.settings).and_then(|settings| config::write_with_backup(&places.settings, &config::settings_with_plugin(&settings, &key, on), &stamp()).map_err(|error| error.to_string()));
    changed(&app, result)
}
