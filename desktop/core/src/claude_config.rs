//! The «Claude Code: инструкции и MCP» window (the Mac's `ClaudeConfig` and `AgentExtras`): every CLAUDE.md and
//! AGENTS.md in one place, Claude Code's MCP servers with a switch, the skills, plugins and hooks of Claude Code and
//! Codex. Reading is pure and tested on sample files; what is switched off is kept whole and comes back as it was.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};

// MARK: - MCP servers

/// Where a server is written.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Scope {
    /// `~/.claude.json` → `mcpServers` (`claude mcp add -s user`).
    User,
    /// `~/.claude/settings.json` → `mcpServers`.
    Settings,
    /// `~/.claude.json` → `projects[path].mcpServers` (`claude mcp add -s local`).
    Local(String),
    /// `<project>/.mcp.json`, shared through the repository.
    Project(String),
}

impl Scope {
    pub fn key(&self) -> String {
        match self {
            Scope::User => "user".into(),
            Scope::Settings => "settings".into(),
            Scope::Local(path) => format!("local:{path}"),
            Scope::Project(path) => format!("project:{path}"),
        }
    }

    pub fn from_key(key: &str) -> Option<Scope> {
        match key {
            "user" => Some(Scope::User),
            "settings" => Some(Scope::Settings),
            _ => key.strip_prefix("local:").map(|p| Scope::Local(p.into())).or_else(|| key.strip_prefix("project:").map(|p| Scope::Project(p.into()))),
        }
    }

    pub fn project_path(&self) -> Option<&str> {
        match self {
            Scope::Local(path) | Scope::Project(path) => Some(path),
            Scope::User | Scope::Settings => None,
        }
    }

    /// The line under a server.
    pub fn title(&self, s: &crate::i18n::Strings) -> String {
        match self {
            Scope::User => s.t("для всех проектов"),
            Scope::Settings => s.t("из ~/.claude/settings.json"),
            Scope::Local(_) => s.t("только у вас в проекте"),
            Scope::Project(_) => s.t("из .mcp.json проекта"),
        }
        .to_owned()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    On,
    Off,
    /// A `.mcp.json` server Claude Code hasn't been allowed to start yet.
    Pending,
}

/// One MCP server Claude Code knows about. Only the name, transport and command or address: `env` and `headers`
/// often hold tokens and never leave the config.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Server {
    pub name: String,
    pub scope: Scope,
    pub transport: String,
    pub target: String,
    pub status: Status,
}

impl Server {
    pub fn id(&self) -> String {
        format!("{}|{}", self.scope.key(), self.name)
    }
}

/// A server switched off from AI Hub Bar: its config as it was, in `mcp-disabled.json` — the Mac's file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Stashed {
    pub name: String,
    pub scope_key: String,
    pub config: String,
}

impl Stashed {
    pub fn config_object(&self) -> Value {
        serde_json::from_str::<Value>(&self.config).ok().filter(Value::is_object).unwrap_or_else(|| json!({}))
    }
}

/// Two spellings of one folder: Claude Code writes `C:/Users/…` where Windows says `C:\Users\…`.
pub fn same_path(a: &str, b: &str) -> bool {
    let plain = |path: &str| {
        let path = path.replace('\\', "/");
        let path = path.trim_end_matches('/').to_owned();
        if cfg!(windows) { path.to_lowercase() } else { path }
    };
    plain(a) == plain(b)
}

fn strings(value: Option<&Value>) -> Vec<String> {
    value.and_then(Value::as_array).map(|list| list.iter().filter_map(Value::as_str).map(str::to_owned).collect()).unwrap_or_default()
}

fn flag(value: Option<&Value>, key: &str) -> bool {
    value.and_then(|v| v.get(key)).and_then(Value::as_bool).unwrap_or(false)
}

/// The servers of Claude Code's files. `mcp_files` and `local_settings` are a project's `.mcp.json` and
/// `.claude/settings.local.json` by the project's path.
pub fn servers(claude_json: Option<&Value>, settings: Option<&Value>, mcp_files: &BTreeMap<String, Value>, local_settings: &BTreeMap<String, Value>, stashed: &[Stashed]) -> Vec<Server> {
    let mut servers: Vec<Server> = Vec::new();
    let mut add = |object: Option<&Value>, scope: Scope, status: &dyn Fn(&str) -> Status| {
        let Some(object) = object.and_then(Value::as_object) else { return };
        let mut names: Vec<&String> = object.keys().collect();
        names.sort();
        for name in names {
            let (transport, target) = describe(&object[name]);
            servers.push(Server { name: name.clone(), scope: scope.clone(), transport, target, status: status(name) });
        }
    };
    add(claude_json.and_then(|j| j.get("mcpServers")), Scope::User, &|_| Status::On);
    add(settings.and_then(|j| j.get("mcpServers")), Scope::Settings, &|_| Status::On);
    let empty = Map::new();
    let projects = claude_json.and_then(|j| j.get("projects")).and_then(Value::as_object).unwrap_or(&empty);
    let mut paths: Vec<&String> = projects.keys().collect();
    paths.sort();
    for path in paths {
        add(projects[path].get("mcpServers"), Scope::Local(path.clone()), &|_| Status::On);
    }
    for (path, file) in mcp_files {
        let project = projects.iter().find(|(known, _)| same_path(known, path)).map(|(_, value)| value);
        let local = local_settings.get(path);
        let listed = |key: &str| [strings(project.and_then(|p| p.get(key))), strings(local.and_then(|l| l.get(key)))].concat();
        let (disabled, enabled) = (listed("disabledMcpjsonServers"), listed("enabledMcpjsonServers"));
        let all = flag(local, "enableAllProjectMcpServers") || flag(settings, "enableAllProjectMcpServers");
        add(file.get("mcpServers"), Scope::Project(path.clone()), &|name| {
            if disabled.iter().any(|n| n == name) {
                Status::Off
            } else if all || enabled.iter().any(|n| n == name) {
                Status::On
            } else {
                Status::Pending
            }
        });
    }
    for entry in stashed {
        // A `.mcp.json` server is switched in the project's own settings, never stashed.
        let Some(scope) = Scope::from_key(&entry.scope_key).filter(|scope| !matches!(scope, Scope::Project(_))) else { continue };
        if servers.iter().any(|s| s.name == entry.name && s.scope == scope) {
            continue;
        }
        let (transport, target) = describe(&entry.config_object());
        servers.push(Server { name: entry.name.clone(), scope, transport, target, status: Status::Off });
    }
    servers
}

/// «stdio · npx -y @x/server», «http · https://mcp.example.com/…» — no query, no sign-in, no secrets.
pub fn describe(config: &Value) -> (String, String) {
    let kind = config.get("type").and_then(Value::as_str);
    if let Some(url) = config.get("url").and_then(Value::as_str) {
        return (kind.unwrap_or("http").to_owned(), clean_url(url));
    }
    let mut words = vec![config.get("command").and_then(Value::as_str).unwrap_or("").to_owned()];
    words.extend(strings(config.get("args")));
    words.retain(|word| !word.is_empty());
    (kind.unwrap_or("stdio").to_owned(), words.join(" "))
}

/// The address without `user:password@`, `?query` and `#fragment`: tokens ride in those.
fn clean_url(url: &str) -> String {
    let Some((scheme, rest)) = url.split_once("://") else { return url.split(['?', '#']).next().unwrap_or("").to_owned() };
    let rest = rest.split(['?', '#']).next().unwrap_or("");
    let (authority, path) = rest.find('/').map_or((rest, ""), |at| rest.split_at(at));
    let host = authority.rsplit('@').next().unwrap_or(authority);
    format!("{scheme}://{host}{path}")
}

/// A project's `.claude/settings.local.json` with a `.mcp.json` server switched off or back on.
pub fn settings_local(settings: &Value, name: &str, off: bool) -> Value {
    let mut changed = if settings.is_object() { settings.clone() } else { json!({}) };
    let object = changed.as_object_mut().expect("an object");
    let mut disabled: Vec<String> = strings(object.get("disabledMcpjsonServers")).into_iter().filter(|n| n != name).collect();
    let mut enabled: Vec<String> = strings(object.get("enabledMcpjsonServers")).into_iter().filter(|n| n != name).collect();
    if off { disabled.push(name.to_owned()) } else { enabled.push(name.to_owned()) }
    for (key, list) in [("disabledMcpjsonServers", disabled), ("enabledMcpjsonServers", enabled)] {
        if list.is_empty() {
            object.remove(key);
        } else {
            object.insert(key.to_owned(), json!(list));
        }
    }
    changed
}

/// The server's config as Claude Code's file has it now; None for a `.mcp.json` server and for one not there.
pub fn config_of(claude_json: Option<&Value>, settings: Option<&Value>, scope: &Scope, name: &str) -> Option<Value> {
    let servers = match scope {
        Scope::User => claude_json?.get("mcpServers"),
        Scope::Settings => settings?.get("mcpServers"),
        Scope::Local(path) => claude_json?.get("projects")?.as_object()?.iter().find(|(known, _)| same_path(known, path))?.1.get("mcpServers"),
        Scope::Project(_) => None,
    };
    servers?.get(name).cloned()
}

/// `~/.claude/settings.json` with a server taken out (to the stash) or put back from it. None when there is nothing
/// to move.
pub fn settings_with_server(settings: &Value, stash: &[Stashed], name: &str, on: bool) -> Option<(Value, Vec<Stashed>)> {
    let mut changed = if settings.is_object() { settings.clone() } else { json!({}) };
    let mut stash = stash.to_vec();
    let key = Scope::Settings.key();
    let object = changed.as_object_mut().expect("an object");
    let mut servers = object.get("mcpServers").and_then(Value::as_object).cloned().unwrap_or_default();
    if on {
        let index = stash.iter().position(|e| e.name == name && e.scope_key == key)?;
        servers.insert(name.to_owned(), stash.remove(index).config_object());
    } else {
        let config = servers.remove(name)?;
        stash.push(Stashed { name: name.to_owned(), scope_key: key, config: config.to_string() });
    }
    object.insert("mcpServers".into(), Value::Object(servers));
    Some((changed, stash))
}

pub fn load_stash(path: &Path) -> Vec<Stashed> {
    std::fs::read_to_string(path).ok().and_then(|text| serde_json::from_str(&text).ok()).unwrap_or_default()
}

/// For the person alone where the system has such a thing: `env` may hold tokens.
pub fn save_stash(path: &Path, entries: &[Stashed]) -> io::Result<()> {
    if let Some(folder) = path.parent() {
        std::fs::create_dir_all(folder)?;
    }
    let tmp = path.with_extension("json.claudepult-tmp");
    std::fs::write(&tmp, serde_json::to_string(entries).map_err(io::Error::other)?)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
    }
    std::fs::rename(&tmp, path)
}

/// A JSON object of a file; None when there is no file or it is something else.
pub fn read_object(path: &Path) -> Option<Value> {
    let text = std::fs::read_to_string(path).ok()?;
    serde_json::from_str::<Value>(text.trim_start_matches('\u{feff}')).ok().filter(Value::is_object)
}

/// Claude Code's settings file written anew, a copy of the old one kept beside it first.
pub fn write_with_backup(path: &Path, value: &Value, stamp: &str) -> io::Result<()> {
    crate::hooks::backup(path, stamp)?;
    crate::hooks::write(path, value)
}

pub fn write_object(path: &Path, value: &Value) -> io::Result<()> {
    crate::hooks::write(path, value)
}

// MARK: - Instruction files

/// One instruction file Claude Code reads: global, the projects folder's, or a project's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstructionFile {
    pub title: String,
    /// None for «Общие».
    pub project: Option<String>,
    pub path: PathBuf,
}

/// `~/…` for a path in the home folder, with `/` — as the Mac writes it.
pub fn with_tilde(path: &Path, home: &Path) -> String {
    match path.strip_prefix(home) {
        Ok(rest) => format!("~/{}", rest.to_string_lossy().replace('\\', "/")),
        Err(_) => path.to_string_lossy().into_owned(),
    }
}

pub fn instruction_files(home: &Path, claude_dir: &Path, projects_dir: &Path, projects: &[(String, PathBuf)]) -> Vec<InstructionFile> {
    let mut files = Vec::new();
    for path in [claude_dir.join("CLAUDE.md"), projects_dir.join("CLAUDE.md")] {
        if path.is_file() && !files.iter().any(|f: &InstructionFile| f.path == path) {
            files.push(InstructionFile { title: with_tilde(&path, home), project: None, path });
        }
    }
    let mut projects: Vec<&(String, PathBuf)> = projects.iter().collect();
    projects.sort_by_key(|(name, _)| name.to_lowercase());
    for (name, folder) in projects {
        for file in ["CLAUDE.md", "CLAUDE.local.md", ".claude/CLAUDE.md", "AGENTS.md"] {
            let path = file.split('/').fold(folder.clone(), |path, part| path.join(part));
            if path.is_file() && !files.iter().any(|f| f.path == path) {
                files.push(InstructionFile { title: file.to_owned(), project: Some(name.clone()), path });
            }
        }
    }
    files
}

/// Lines containing `query` (case ignored), numbered from 1.
pub fn matches(text: &str, query: &str) -> Vec<(usize, String)> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return Vec::new();
    }
    text.lines().enumerate().filter(|(_, line)| line.to_lowercase().contains(&query)).map(|(index, line)| (index + 1, line.trim().to_owned())).collect()
}

/// What the editor shows of a file: no byte order mark, `\n` between lines.
pub fn shown_text(on_disk: &str) -> String {
    on_disk.trim_start_matches('\u{feff}').replace("\r\n", "\n")
}

/// The edited text as the file wants it: the byte order mark and the line ends it had stay.
pub fn text_to_save(on_disk: &str, edited: &str) -> String {
    let edited = edited.replace("\r\n", "\n");
    let body = if on_disk.contains("\r\n") { edited.replace('\n', "\r\n") } else { edited };
    if on_disk.starts_with('\u{feff}') { format!("\u{feff}{body}") } else { body }
}

// MARK: - Skills, plugins, hooks

/// A switched-off skill is moved here whole and moved back as it was: nothing in it is edited.
pub const OFF_SUFFIX: &str = ".disabled";

pub const AGENTS: [&str; 2] = ["claudeCode", "codex"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Skill {
    /// `claudeCode` or `codex`, the Mac's `AgentKind`.
    pub agent: &'static str,
    pub name: String,
    pub description: String,
    /// The skill's folder, where it is now (the skills folder, or the one for switched-off skills).
    pub folder: PathBuf,
    pub on: bool,
}

impl Skill {
    pub fn id(&self) -> String {
        format!("{}:{}", self.agent, self.name)
    }
}

/// Where an agent looks for the person's skills, in the order they are listed.
pub fn skills_folders(agent: &str, home: &Path, claude_dir: &Path, codex_dir: &Path) -> Vec<PathBuf> {
    match agent {
        "claudeCode" => vec![claude_dir.join("skills")],
        "codex" => vec![codex_dir.join("skills"), home.join(".agents").join("skills")],
        _ => Vec::new(),
    }
}

fn beside(folder: &Path, suffix: &str) -> PathBuf {
    let mut name = folder.file_name().unwrap_or_default().to_os_string();
    name.push(suffix);
    folder.with_file_name(name)
}

pub fn skills(home: &Path, claude_dir: &Path, codex_dir: &Path) -> Vec<Skill> {
    let mut found: Vec<Skill> = Vec::new();
    for agent in AGENTS {
        for folder in skills_folders(agent, home, claude_dir, codex_dir) {
            for (root, on) in [(folder.clone(), true), (beside(&folder, OFF_SUFFIX), false)] {
                let mut names: Vec<String> = std::fs::read_dir(&root).into_iter().flatten().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
                names.sort();
                for name in names.into_iter().filter(|name| !name.starts_with('.')) {
                    let path = root.join(&name);
                    let Ok(text) = std::fs::read_to_string(path.join("SKILL.md")) else { continue };
                    let meta = frontmatter(&text);
                    let skill = Skill { agent, name: meta.get("name").cloned().unwrap_or(name), description: meta.get("description").cloned().unwrap_or_default(), folder: path, on };
                    // The same skill in both of Codex's folders is listed once: the first folder wins.
                    if !found.iter().any(|s| s.id() == skill.id()) {
                        found.push(skill);
                    }
                }
            }
        }
    }
    found
}

/// `key: value` lines between the first two `---` lines; quotes around a value are dropped.
pub fn frontmatter(text: &str) -> BTreeMap<String, String> {
    let mut lines = text.trim_start_matches('\u{feff}').lines();
    let mut values = BTreeMap::new();
    if lines.next().map(str::trim) != Some("---") {
        return values;
    }
    for line in lines {
        if line.trim() == "---" {
            break;
        }
        let Some((key, value)) = line.split_once(':') else { continue };
        if line.starts_with(' ') {
            continue;
        }
        let mut value = value.trim();
        let quote = value.chars().next().filter(|c| *c == '"' || *c == '\'');
        if let Some(quote) = quote.filter(|q| value.len() >= 2 && value.ends_with(*q)) {
            value = &value[quote.len_utf8()..value.len() - quote.len_utf8()];
        }
        values.insert(key.to_owned(), value.to_owned());
    }
    values
}

/// Where the skill's folder goes when it is switched: out of the folder it is in to the one beside it, or back.
/// None when it is already there or a folder of that name is in the way.
pub fn destination(skill: &Skill, on: bool) -> Option<PathBuf> {
    if skill.on == on {
        return None;
    }
    let root = skill.folder.parent()?;
    let root_name = root.file_name()?.to_string_lossy().into_owned();
    let other = if on { root.with_file_name(root_name.strip_suffix(OFF_SUFFIX)?) } else { beside(root, OFF_SUFFIX) };
    let target = other.join(skill.folder.file_name()?);
    (!target.exists()).then_some(target)
}

pub fn move_skill(skill: &Skill, on: bool) -> io::Result<()> {
    let target = destination(skill, on).ok_or_else(|| io::Error::new(io::ErrorKind::AlreadyExists, "a folder of that name is in the way"))?;
    if let Some(folder) = target.parent() {
        std::fs::create_dir_all(folder)?;
    }
    std::fs::rename(&skill.folder, target)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plugin {
    /// `name@marketplace`, the key in both files.
    pub key: String,
    pub version: String,
    pub on: bool,
}

impl Plugin {
    pub fn name(&self) -> &str {
        self.key.split('@').next().unwrap_or(&self.key)
    }

    pub fn marketplace(&self) -> &str {
        self.key.split('@').nth(1).unwrap_or("")
    }
}

/// Installed plugins (`~/.claude/plugins/installed_plugins.json`); one that `enabledPlugins` does not name is on, as
/// Claude Code takes it.
pub fn plugins(installed: Option<&Value>, settings: Option<&Value>) -> Vec<Plugin> {
    let enabled = settings.and_then(|s| s.get("enabledPlugins"));
    let Some(plugins) = installed.and_then(|i| i.get("plugins")).and_then(Value::as_object) else { return Vec::new() };
    let mut keys: Vec<&String> = plugins.keys().collect();
    keys.sort();
    keys.into_iter()
        .map(|key| Plugin {
            key: key.clone(),
            version: plugins[key].get(0).and_then(|entry| entry.get("version")).and_then(Value::as_str).unwrap_or("").to_owned(),
            on: enabled.and_then(|e| e.get(key)).and_then(Value::as_bool).unwrap_or(true),
        })
        .collect()
}

/// `~/.claude/settings.json` with a plugin switched in `enabledPlugins`.
pub fn settings_with_plugin(settings: &Value, key: &str, on: bool) -> Value {
    let mut changed = if settings.is_object() { settings.clone() } else { json!({}) };
    let object = changed.as_object_mut().expect("an object");
    let mut enabled = object.get("enabledPlugins").and_then(Value::as_object).cloned().unwrap_or_default();
    enabled.insert(key.to_owned(), json!(on));
    object.insert("enabledPlugins".into(), Value::Object(enabled));
    changed
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hook {
    pub agent: &'static str,
    pub event: String,
    pub command: String,
    /// AI Hub Bar's own entry (session tracking).
    pub ours: bool,
}

/// Command hooks of a `hooks` object (event → groups → `hooks` → `command`), Claude's and Codex's shape alike.
pub fn hooks(object: Option<&Value>, agent: &'static str) -> Vec<Hook> {
    let Some(events) = object.and_then(|o| o.get("hooks")).and_then(Value::as_object) else { return Vec::new() };
    let mut names: Vec<&String> = events.keys().collect();
    names.sort();
    let mut found = Vec::new();
    for event in names {
        for group in events[event].as_array().into_iter().flatten() {
            for hook in group.get("hooks").and_then(Value::as_array).into_iter().flatten() {
                if let Some(command) = hook.get("command").and_then(Value::as_str) {
                    found.push(Hook { agent, event: event.clone(), command: command.to_owned(), ours: command.contains(crate::hooks::MARKER) });
                }
            }
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("claudepult-config-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn servers_of_every_file() {
        let claude = json!({
            "mcpServers": { "zeta": { "command": "npx", "args": ["-y", "@x/server"], "env": { "TOKEN": "secret" } }, "alpha": { "type": "sse", "url": "https://user:pass@mcp.example.com:8443/sse?key=secret#part" } },
            "projects": { "C:/Projects/App": { "mcpServers": { "mine": { "command": "node", "args": ["server.js"] } }, "disabledMcpjsonServers": ["off-one"] } }
        });
        let settings = json!({ "mcpServers": { "old": { "url": "http://localhost:3000/mcp" } } });
        let path = if cfg!(windows) { "C:\\Projects\\App" } else { "C:/Projects/App" }.to_owned();
        let files = BTreeMap::from([(path.clone(), json!({ "mcpServers": { "off-one": { "command": "a" }, "on-one": { "command": "b" }, "new-one": { "command": "c" } } }))]);
        let local = BTreeMap::from([(path.clone(), json!({ "enabledMcpjsonServers": ["on-one"] }))]);
        let stash = [
            Stashed { name: "gone".into(), scope_key: "user".into(), config: r#"{"command":"uvx","args":["tool"]}"#.into() },
            Stashed { name: "zeta".into(), scope_key: "user".into(), config: "{}".into() },
            Stashed { name: "odd".into(), scope_key: "nonsense".into(), config: "{}".into() },
        ];
        let found = servers(Some(&claude), Some(&settings), &files, &local, &stash);
        let line = |s: &Server| format!("{} {} {} [{}] {:?}", s.scope.key(), s.name, s.transport, s.target, s.status);
        assert_eq!(
            found.iter().map(line).collect::<Vec<_>>(),
            [
                "user alpha sse [https://mcp.example.com:8443/sse] On".to_owned(),
                "user zeta stdio [npx -y @x/server] On".to_owned(),
                "settings old http [http://localhost:3000/mcp] On".to_owned(),
                "local:C:/Projects/App mine stdio [node server.js] On".to_owned(),
                format!("project:{path} new-one stdio [c] Pending"),
                format!("project:{path} off-one stdio [a] Off"),
                format!("project:{path} on-one stdio [b] On"),
                "user gone stdio [uvx tool] Off".to_owned(),
            ]
        );
        assert!(found.iter().all(|s| !s.target.contains("secret")), "no token leaves the config");
        assert_eq!(servers(None, Some(&json!({ "enableAllProjectMcpServers": true })), &files, &BTreeMap::new(), &[]).iter().filter(|s| s.status == Status::On).count(), 3);
        assert!(servers(None, None, &BTreeMap::new(), &BTreeMap::new(), &[]).is_empty());
    }

    #[test]
    fn scopes_and_paths() {
        for scope in [Scope::User, Scope::Settings, Scope::Local("C:/a b".into()), Scope::Project("/home/x/app".into())] {
            assert_eq!(Scope::from_key(&scope.key()), Some(scope));
        }
        assert_eq!(Scope::from_key("else"), None);
        assert!(same_path("/a/b/", "/a/b"));
        assert_eq!(same_path("C:\\Projects\\App", "c:/projects/app"), cfg!(windows));
        assert_eq!(describe(&json!({ "url": "not a link?x=1" })).1, "not a link");
    }

    #[test]
    fn a_project_server_is_switched_in_the_local_settings() {
        let off = settings_local(&json!({ "permissions": { "allow": [] }, "enabledMcpjsonServers": ["a", "b"] }), "a", true);
        assert_eq!(off, json!({ "permissions": { "allow": [] }, "enabledMcpjsonServers": ["b"], "disabledMcpjsonServers": ["a"] }));
        assert_eq!(settings_local(&off, "a", false), json!({ "permissions": { "allow": [] }, "enabledMcpjsonServers": ["b", "a"] }));
        assert_eq!(settings_local(&Value::Null, "x", true), json!({ "disabledMcpjsonServers": ["x"] }));
    }

    #[test]
    fn a_settings_server_goes_to_the_stash_and_back() {
        let settings = json!({ "model": "opus", "mcpServers": { "one": { "command": "x", "env": { "KEY": "v" } }, "two": { "url": "https://e.com" } } });
        let (without, stash) = settings_with_server(&settings, &[], "one", false).unwrap();
        assert_eq!(without, json!({ "model": "opus", "mcpServers": { "two": { "url": "https://e.com" } } }));
        assert_eq!(stash.len(), 1);
        let (back, empty) = settings_with_server(&without, &stash, "one", true).unwrap();
        assert_eq!(back, settings, "as it was, env and all");
        assert!(empty.is_empty());
        assert!(settings_with_server(&settings, &[], "none", false).is_none() && settings_with_server(&settings, &[], "one", true).is_none());
        assert_eq!(config_of(None, Some(&settings), &Scope::Settings, "two"), Some(json!({ "url": "https://e.com" })));
        let claude = json!({ "mcpServers": { "u": { "command": "c" } }, "projects": { "/p/app": { "mcpServers": { "l": { "command": "d" } } } } });
        assert_eq!(config_of(Some(&claude), None, &Scope::User, "u"), Some(json!({ "command": "c" })));
        assert_eq!(config_of(Some(&claude), None, &Scope::Local("/p/app/".into()), "l"), Some(json!({ "command": "d" })));
        assert_eq!(config_of(Some(&claude), None, &Scope::Project("/p/app".into()), "l"), None);
    }

    #[test]
    fn the_stash_file() {
        let dir = temp("stash");
        let file = dir.join("deep").join("mcp-disabled.json");
        assert!(load_stash(&file).is_empty());
        let entries = vec![Stashed { name: "one".into(), scope_key: "local:C:/p".into(), config: r#"{"command":"x"}"#.into() }];
        save_stash(&file, &entries).unwrap();
        assert_eq!(load_stash(&file), entries);
        assert!(std::fs::read_to_string(&file).unwrap().contains("\"scopeKey\""), "the Mac's field names");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn instruction_files_and_search() {
        let home = temp("files");
        let claude = home.join(".claude");
        let projects = home.join("Projects");
        for (folder, file) in [(claude.clone(), "CLAUDE.md"), (projects.clone(), "CLAUDE.md"), (projects.join("beta"), "AGENTS.md"), (projects.join("Alpha").join(".claude"), "CLAUDE.md"), (projects.join("Alpha"), "CLAUDE.local.md")] {
            std::fs::create_dir_all(&folder).unwrap();
            std::fs::write(folder.join(file), "x").unwrap();
        }
        let list = [("beta".to_owned(), projects.join("beta")), ("Alpha".to_owned(), projects.join("Alpha")), ("none".to_owned(), projects.join("none"))];
        let found = instruction_files(&home, &claude, &projects, &list);
        assert_eq!(
            found.iter().map(|f| format!("{}|{}", f.project.as_deref().unwrap_or("-"), f.title)).collect::<Vec<_>>(),
            ["-|~/.claude/CLAUDE.md", "-|~/Projects/CLAUDE.md", "Alpha|CLAUDE.local.md", "Alpha|.claude/CLAUDE.md", "beta|AGENTS.md"]
        );
        assert_eq!(matches("One\n  two ONE  \nthree", "one"), [(1, "One".to_owned()), (2, "two ONE".to_owned())]);
        assert_eq!(matches("Правило\nдругое", "ПРАВ"), [(1, "Правило".to_owned())]);
        assert!(matches("text", " ").is_empty());
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn a_saved_file_keeps_its_line_ends_and_mark() {
        assert_eq!(shown_text("\u{feff}a\r\nb\r\n"), "a\nb\n");
        assert_eq!(text_to_save("\u{feff}a\r\nb\r\n", "a\nc\n"), "\u{feff}a\r\nc\r\n");
        assert_eq!(text_to_save("a\nb\n", "a\r\nc\n"), "a\nc\n");
        assert_eq!(text_to_save("", "new\n"), "new\n");
    }

    #[test]
    fn skills_are_found_and_moved_whole() {
        let home = temp("skills");
        let (claude, codex) = (home.join(".claude"), home.join(".codex"));
        let write = |folder: PathBuf, text: &str| {
            std::fs::create_dir_all(&folder).unwrap();
            std::fs::write(folder.join("SKILL.md"), text).unwrap();
        };
        write(claude.join("skills").join("review"), "---\nname: code-review\ndescription: \"Reads a diff: carefully\"\n  nested: no\n---\nbody\nname: not this");
        write(claude.join("skills.disabled").join("old"), "no frontmatter");
        write(codex.join("skills").join("shared"), "---\ndescription: 'first'\n---");
        write(home.join(".agents").join("skills").join("shared"), "---\ndescription: second\n---");
        std::fs::create_dir_all(claude.join("skills").join("not-a-skill")).unwrap();
        write(claude.join("skills").join(".hidden"), "---\nname: hidden\n---");
        let found = skills(&home, &claude, &codex);
        assert_eq!(
            found.iter().map(|s| format!("{} {} [{}] {}", s.agent, s.name, s.description, s.on)).collect::<Vec<_>>(),
            ["claudeCode code-review [Reads a diff: carefully] true", "claudeCode old [] false", "codex shared [first] true"]
        );
        let review = &found[0];
        assert_eq!(destination(review, true), None, "already on");
        assert_eq!(destination(review, false), Some(claude.join("skills.disabled").join("review")));
        move_skill(review, false).unwrap();
        assert!(claude.join("skills.disabled").join("review").join("SKILL.md").is_file() && !claude.join("skills").join("review").exists());
        let after = skills(&home, &claude, &codex);
        let review = after.iter().find(|s| s.name == "code-review").unwrap();
        assert!(!review.on);
        // A folder of that name in the way: nothing is overwritten.
        std::fs::create_dir_all(claude.join("skills").join("review")).unwrap();
        assert!(move_skill(review, true).is_err());
        std::fs::remove_dir(claude.join("skills").join("review")).unwrap();
        move_skill(review, true).unwrap();
        assert_eq!(std::fs::read_to_string(claude.join("skills").join("review").join("SKILL.md")).unwrap().lines().nth(1), Some("name: code-review"));
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn plugins_and_hooks() {
        let installed = json!({ "plugins": { "b@market": [{ "version": "1.2.0" }], "a@other": [], "plain": [{}] } });
        let settings = json!({ "enabledPlugins": { "b@market": false }, "hooks": {
            "Stop": [{ "hooks": [{ "type": "command", "command": "C:\\x\\claudepult-hook.exe --event Stop" }, { "type": "command", "command": "say done" }] }],
            "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "check.sh" }, { "type": "prompt" }] }]
        } });
        let found = plugins(Some(&installed), Some(&settings));
        assert_eq!(found.iter().map(|p| format!("{}|{}|{}|{}", p.name(), p.marketplace(), p.version, p.on)).collect::<Vec<_>>(), ["a|other||true", "b|market|1.2.0|false", "plain|||true"]);
        assert!(plugins(None, Some(&settings)).is_empty());
        let on = settings_with_plugin(&settings, "b@market", true);
        assert_eq!(on["enabledPlugins"], json!({ "b@market": true }));
        assert_eq!(on["hooks"], settings["hooks"], "the rest of the file stays");
        assert_eq!(settings_with_plugin(&json!({}), "a@other", false), json!({ "enabledPlugins": { "a@other": false } }));
        let hooks = hooks(Some(&settings), "claudeCode");
        assert_eq!(hooks.iter().map(|h| format!("{} {} {}", h.event, h.command, h.ours)).collect::<Vec<_>>(), ["PreToolUse check.sh false", "Stop C:\\x\\claudepult-hook.exe --event Stop true", "Stop say done false"]);
    }
}
