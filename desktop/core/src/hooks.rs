//! AI Hub Bar's entries in Claude Code's `settings.json` (docs/SPEC-windows.md §4.3), ported from the Mac's
//! `HookInstaller`: merged into the existing file, backed up first, idempotent, removable, other hooks untouched.
//! Unlike the Mac (a shell command with quoted paths), the entries use Claude Code's exec form — `command` is the
//! program, `args` its arguments — so no shell runs and a path with spaces needs no quoting (Claude Code 2.1.139+).

use serde_json::{json, Map, Value};
use std::io;
use std::path::{Path, PathBuf};

/// The events the hook listens to, as on the Mac.
pub const EVENTS: [&str; 8] =
    ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification", "PostToolUse", "Stop", "StopFailure", "SessionEnd"];

/// Recognises our entries whatever the folder.
pub const MARKER: &str = "claudepult-hook";
pub const TIMEOUT_SECONDS: u64 = 5;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookStatus {
    NotInstalled,
    Installed,
    /// Some events are missing or point elsewhere — installing again fixes it.
    Outdated,
}

/// What goes into `settings.json` for each event.
#[derive(Debug, Clone, PartialEq)]
pub struct HookCommand {
    pub program: String,
    pub args: Vec<String>,
}

impl HookCommand {
    pub fn new(program: &Path, projects_dir: &Path) -> Self {
        HookCommand {
            program: program.to_string_lossy().into_owned(),
            args: vec!["--projects-dir".into(), projects_dir.to_string_lossy().into_owned()],
        }
    }

    fn entry(&self) -> Value {
        json!({"type": "command", "command": self.program, "args": self.args, "timeout": TIMEOUT_SECONDS})
    }
}

fn is_ours(entry: &Value) -> bool {
    entry.get("command").and_then(Value::as_str).is_some_and(|c| c.contains(MARKER))
}

/// Our entries removed; empty groups, events and the `hooks` key itself dropped.
pub fn removed(settings: &Value) -> Value {
    let mut settings = settings.clone();
    let Some(object) = settings.as_object_mut() else { return settings };
    let Some(hooks) = object.get_mut("hooks").and_then(Value::as_object_mut) else { return settings };
    let events: Vec<String> = hooks.keys().cloned().collect();
    for event in events {
        let Some(groups) = hooks.get(&event).and_then(Value::as_array).cloned() else { continue };
        let kept: Vec<Value> = groups
            .into_iter()
            .filter_map(|mut group| {
                let Some(entries) = group.get("hooks").and_then(Value::as_array).cloned() else { return Some(group) };
                let remaining: Vec<Value> = entries.iter().filter(|e| !is_ours(e)).cloned().collect();
                if remaining.len() == entries.len() {
                    return Some(group);
                }
                if remaining.is_empty() {
                    return None;
                }
                group["hooks"] = Value::Array(remaining);
                Some(group)
            })
            .collect();
        if kept.is_empty() {
            hooks.remove(&event);
        } else {
            hooks.insert(event, Value::Array(kept));
        }
    }
    if hooks.is_empty() {
        object.remove("hooks");
    }
    settings
}

/// Previous entries of ours dropped, then one group per event appended.
pub fn merged(settings: &Value, command: &HookCommand) -> Value {
    let mut settings = removed(settings);
    if !settings.is_object() {
        settings = Value::Object(Map::new());
    }
    let hooks = settings.as_object_mut().unwrap().entry("hooks").or_insert_with(|| json!({}));
    if !hooks.is_object() {
        *hooks = json!({});
    }
    let hooks = hooks.as_object_mut().unwrap();
    for event in EVENTS {
        let mut group = json!({"hooks": [command.entry()]});
        if event == "PostToolUse" {
            group["matcher"] = json!("*");
        }
        let groups = hooks.entry(event).or_insert_with(|| json!([]));
        if !groups.is_array() {
            *groups = json!([]);
        }
        groups.as_array_mut().unwrap().push(group);
    }
    settings
}

pub fn status(settings: &Value, command: &HookCommand) -> HookStatus {
    let expected = command.entry();
    let hooks = settings.get("hooks");
    let mut found = 0;
    let mut current = 0;
    for event in EVENTS {
        let ours: Vec<&Value> = hooks
            .and_then(|h| h.get(event))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .flat_map(|group| group.get("hooks").and_then(Value::as_array).into_iter().flatten())
            .filter(|entry| is_ours(entry))
            .collect();
        if !ours.is_empty() {
            found += 1;
        }
        if ours.len() == 1 && *ours[0] == expected {
            current += 1;
        }
    }
    match (found, current) {
        (0, _) => HookStatus::NotInstalled,
        (_, c) if c == EVENTS.len() => HookStatus::Installed,
        _ => HookStatus::Outdated,
    }
}

// MARK: - The file

/// None when there is no file yet; an error (and no change) when it isn't a JSON object.
pub fn read_settings(path: &Path) -> io::Result<Option<Value>> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    if text.trim().is_empty() {
        return Ok(Some(json!({})));
    }
    match serde_json::from_str::<Value>(&text) {
        Ok(value) if value.is_object() => Ok(Some(value)),
        Ok(_) => Err(io::Error::new(io::ErrorKind::InvalidData, "the root is not a JSON object")),
        Err(error) => Err(io::Error::new(io::ErrorKind::InvalidData, error.to_string())),
    }
}

/// `settings.json.claudepult-backup-<stamp>`, never over an earlier one.
fn backup(path: &Path, stamp: &str) -> io::Result<Option<PathBuf>> {
    if !path.exists() {
        return Ok(None);
    }
    let folder = path.parent().unwrap_or(Path::new("."));
    let mut target = folder.join(format!("settings.json.claudepult-backup-{stamp}"));
    let mut counter = 2;
    while target.exists() {
        target = folder.join(format!("settings.json.claudepult-backup-{stamp}-{counter}"));
        counter += 1;
    }
    std::fs::copy(path, &target)?;
    Ok(Some(target))
}

fn write(path: &Path, settings: &Value) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("json.claudepult-tmp");
    std::fs::write(&tmp, serde_json::to_string_pretty(settings).map_err(io::Error::other)? + "\n")?;
    std::fs::rename(&tmp, path)
}

/// Installs or updates our entries; returns the backup made (None when nothing changed or there was no file).
pub fn install(path: &Path, command: &HookCommand, stamp: &str) -> io::Result<Option<PathBuf>> {
    let current = read_settings(path)?;
    let settings = merged(current.as_ref().unwrap_or(&json!({})), command);
    if current.as_ref() == Some(&settings) {
        return Ok(None);
    }
    let made = backup(path, stamp)?;
    write(path, &settings)?;
    Ok(made)
}

pub fn uninstall(path: &Path, stamp: &str) -> io::Result<Option<PathBuf>> {
    let Some(current) = read_settings(path)? else { return Ok(None) };
    let settings = removed(&current);
    if settings == current {
        return Ok(None);
    }
    let made = backup(path, stamp)?;
    write(path, &settings)?;
    Ok(made)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn command() -> HookCommand {
        HookCommand::new(
            Path::new(r"C:\Users\Олег\AppData\Local\Programs\AI Hub Bar\claudepult-hook.exe"),
            Path::new(r"C:\Users\Олег\Projects"),
        )
    }

    #[test]
    fn merge_keeps_other_hooks() {
        let mine = json!({"theme": "dark", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}});
        let result = merged(&mine, &command());
        assert_eq!(result["theme"], "dark");
        assert_eq!(result["hooks"]["Stop"].as_array().unwrap().len(), 2, "theirs and ours");
        assert_eq!(result["hooks"]["Stop"][0]["hooks"][0]["command"], "say done");
        assert_eq!(result["hooks"]["PostToolUse"][0]["matcher"], "*");
        let ours = &result["hooks"]["SessionStart"][0]["hooks"][0];
        assert_eq!(ours["args"][0], "--projects-dir");
        assert_eq!(ours["args"][1], r"C:\Users\Олег\Projects", "exec form: no quotes, spaces are fine");
        assert_eq!(status(&result, &command()), HookStatus::Installed);
        assert_eq!(merged(&result, &command()), result, "installing twice changes nothing");
        assert_eq!(removed(&result), mine, "removal gives back exactly what was there");
        assert_eq!(status(&mine, &command()), HookStatus::NotInstalled);
    }

    #[test]
    fn outdated_when_moved_or_missing() {
        let elsewhere = HookCommand::new(Path::new(r"D:\old\claudepult-hook.exe"), Path::new(r"C:\P"));
        let old = merged(&json!({}), &elsewhere);
        assert_eq!(status(&old, &command()), HookStatus::Outdated);
        let mut partial = merged(&json!({}), &command());
        partial["hooks"].as_object_mut().unwrap().remove("Stop");
        assert_eq!(status(&partial, &command()), HookStatus::Outdated);
        assert_eq!(removed(&json!({"hooks": {}})), json!({}), "an empty hooks key goes");
    }

    #[test]
    fn file_with_backup() {
        let dir = std::env::temp_dir().join(format!("claudepult-hooks-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("settings.json");
        assert_eq!(install(&path, &command(), "20261102-180000").unwrap(), None, "no file: nothing to back up");
        assert_eq!(status(&read_settings(&path).unwrap().unwrap(), &command()), HookStatus::Installed);
        assert_eq!(install(&path, &command(), "20261102-180001").unwrap(), None, "unchanged: no backup");
        let backup = uninstall(&path, "20261102-180002").unwrap().unwrap();
        assert!(backup.ends_with("settings.json.claudepult-backup-20261102-180002"));
        assert_eq!(read_settings(&path).unwrap().unwrap(), json!({}));
        std::fs::write(&path, "[1, 2]").unwrap();
        assert!(install(&path, &command(), "x").is_err(), "not an object: the file is left alone");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "[1, 2]");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
