//! `claudepult-hook` — the Claude Code hook of AI Hub Bar for Windows and Linux (docs/specs/SPEC-windows.md §4.3), a port
//! of the Mac's Python hook (`AIHubBar/Services/HookScript.swift`, format 3) so the session files are the same:
//! `<data dir>/sessions/<session_id>.json`. It must never affect Claude: it prints nothing and always exits 0.
//! Answering permission requests from the app is not here yet (a later stage).
//!
//! Instead of a tty it records what finds the window later: the Claude process id (walking up the parents) and
//! `WT_SESSION`, Windows Terminal's tab id.

mod process;

use chrono::{DateTime, Local};
use serde_json::{json, Map, Value};
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};

const WAITING_NOTIFICATIONS: [&str; 4] = ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"];
const PROMPT_LIMIT: usize = 200;
const TODO_TOOLS: [&str; 3] = ["TodoWrite", "TaskCreate", "TaskUpdate"];
const TODO_STATUSES: [&str; 3] = ["pending", "in_progress", "completed"];
const TODO_LIMIT: usize = 20;
const TODO_TEXT: usize = 120;

fn now() -> String {
    Local::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, false)
}

fn squeeze(text: &str, limit: usize) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(limit).collect()
}

fn clip(value: Option<&Value>) -> String {
    squeeze(value.and_then(Value::as_str).unwrap_or(""), PROMPT_LIMIT)
}

fn arg(args: &[String], name: &str) -> Option<String> {
    let index = args.iter().position(|a| a == name)?;
    args.get(index + 1).cloned()
}

/// The project folder when `cwd` is inside the projects folder: (name, path).
fn project_of(cwd: Option<&str>, projects_dir: Option<&str>) -> (Value, Value) {
    let (Some(cwd), Some(root)) = (cwd, projects_dir) else { return (Value::Null, Value::Null) };
    let root = Path::new(root);
    let Ok(rest) = Path::new(cwd).strip_prefix(root) else { return (Value::Null, Value::Null) };
    match rest.components().next() {
        Some(first) => {
            let name = first.as_os_str().to_string_lossy().into_owned();
            let path = root.join(&name).to_string_lossy().into_owned();
            (json!(name), json!(path))
        }
        None => (Value::Null, Value::Null),
    }
}

/// What a tool call did, for «what Claude is doing now»: (tool, target).
fn action_of(data: &Value) -> (String, String) {
    let tool = data.get("tool_name").and_then(Value::as_str).unwrap_or("").to_owned();
    let mut target = String::new();
    if let Some(input) = data.get("tool_input").and_then(Value::as_object) {
        for key in ["file_path", "notebook_path", "command", "pattern", "url", "query", "description", "prompt"] {
            if let Some(value) = input.get(key).and_then(Value::as_str).filter(|v| !v.is_empty()) {
                target = if key.ends_with("_path") {
                    // Windows paths too: the last part after either slash.
                    value.rsplit(['/', '\\']).next().unwrap_or(value).to_owned()
                } else {
                    squeeze(value, 80)
                };
                break;
            }
        }
    }
    (tool, target)
}

fn todo_item(content: Option<&Value>, status: Option<&str>, active_form: Option<&Value>, id: Option<String>) -> Value {
    let mut item = Map::new();
    item.insert("content".into(), json!(squeeze(content.and_then(Value::as_str).unwrap_or(""), TODO_TEXT)));
    let status = status.filter(|s| TODO_STATUSES.contains(s)).unwrap_or("pending");
    item.insert("status".into(), json!(status));
    if let Some(active) = active_form.and_then(Value::as_str).filter(|a| !a.is_empty()) {
        item.insert("active_form".into(), json!(squeeze(active, TODO_TEXT)));
    }
    if let Some(id) = id {
        item.insert("id".into(), json!(id));
    }
    Value::Object(item)
}

/// The task list in `todos`: replaced by TodoWrite, kept task by task for TaskCreate / TaskUpdate.
fn apply_todos(record: &mut Map<String, Value>, data: &Value) {
    let Some(input) = data.get("tool_input").and_then(Value::as_object) else { return };
    let mut todos: Vec<Value> =
        record.get("todos").and_then(Value::as_array).map(|a| a.iter().filter(|t| t.is_object()).cloned().collect()).unwrap_or_default();
    match data.get("tool_name").and_then(Value::as_str) {
        Some("TodoWrite") => {
            let Some(items) = input.get("todos").and_then(Value::as_array) else { return };
            todos = items
                .iter()
                .filter(|t| t.is_object())
                .map(|t| todo_item(t.get("content"), t.get("status").and_then(Value::as_str), t.get("activeForm"), None))
                .collect();
        }
        Some("TaskCreate") => {
            let id = data.pointer("/tool_response/task/id").map(|v| v.as_str().map(str::to_owned).unwrap_or_else(|| v.to_string()));
            let id = id.unwrap_or_else(|| format!("new-{}", todos.len()));
            todos.push(todo_item(input.get("subject"), Some("pending"), input.get("activeForm"), Some(id)));
        }
        Some("TaskUpdate") => {
            let wanted = input.get("taskId").map(|v| v.as_str().map(str::to_owned).unwrap_or_else(|| v.to_string())).unwrap_or_default();
            let Some(index) = todos.iter().position(|t| t.get("id").and_then(Value::as_str) == Some(wanted.as_str())) else { return };
            match input.get("status").and_then(Value::as_str) {
                Some("deleted") => {
                    todos.remove(index);
                }
                status => {
                    let item = todos[index].as_object_mut().unwrap();
                    if let Some(status) = status.filter(|s| TODO_STATUSES.contains(s)) {
                        item.insert("status".into(), json!(status));
                    }
                    if let Some(subject) = input.get("subject").and_then(Value::as_str).filter(|s| !s.is_empty()) {
                        item.insert("content".into(), json!(squeeze(subject, TODO_TEXT)));
                    }
                    if let Some(active) = input.get("activeForm").and_then(Value::as_str).filter(|s| !s.is_empty()) {
                        item.insert("active_form".into(), json!(squeeze(active, TODO_TEXT)));
                    }
                }
            }
        }
        _ => return,
    }
    todos.truncate(TODO_LIMIT);
    if todos.is_empty() {
        record.remove("todos");
    } else {
        record.insert("todos".into(), Value::Array(todos));
    }
}

fn apply(record: &mut Map<String, Value>, data: &Value) {
    let event = data.get("hook_event_name").and_then(Value::as_str).unwrap_or("");
    let had_state = record.get("state").is_some_and(|s| !s.is_null());
    match event {
        "SessionStart" => {
            if data.get("source").and_then(Value::as_str) != Some("compact") || !had_state {
                record.insert("state".into(), json!("done"));
                record.remove("message");
            }
            if matches!(data.get("source").and_then(Value::as_str), Some("startup" | "clear")) {
                record.remove("todos");
            }
        }
        "UserPromptSubmit" => {
            record.insert("state".into(), json!("running"));
            record.remove("message");
            record.insert("prompt_at".into(), json!(now()));
            let finished = record
                .get("todos")
                .and_then(Value::as_array)
                .is_some_and(|t| !t.is_empty() && t.iter().all(|i| i.get("status").and_then(Value::as_str) == Some("completed")));
            if finished {
                record.remove("todos");
            }
            let prompt = clip(data.get("prompt"));
            if !prompt.is_empty() {
                record.insert("last_prompt".into(), json!(prompt));
                record.entry("first_prompt").or_insert(json!(prompt));
            }
        }
        "PermissionRequest" => {
            record.insert("state".into(), json!("waiting"));
            let tool = data.get("tool_name").and_then(Value::as_str).unwrap_or("инструмент");
            record.insert("message".into(), json!(squeeze(&format!("Нужно разрешение: {tool}"), PROMPT_LIMIT)));
        }
        "Notification" => {
            if data.get("notification_type").and_then(Value::as_str).is_some_and(|t| WAITING_NOTIFICATIONS.contains(&t)) {
                record.insert("state".into(), json!("waiting"));
                record.insert("message".into(), json!(clip(data.get("message"))));
            }
        }
        "PostToolUse" => {
            record.insert("state".into(), json!("running"));
            record.remove("message");
            let (tool, target) = action_of(data);
            record.insert("last_tool".into(), json!(tool));
            record.insert("last_target".into(), json!(target));
            record.insert("last_tool_at".into(), json!(now()));
            if data.get("tool_name").and_then(Value::as_str).is_some_and(|t| TODO_TOOLS.contains(&t)) {
                apply_todos(record, data);
            }
        }
        "Stop" => {
            record.insert("state".into(), json!("done"));
            for key in ["message", "last_tool", "last_target", "last_tool_at"] {
                record.remove(key);
            }
        }
        "StopFailure" => {
            record.insert("state".into(), json!("done"));
            record.insert("message".into(), json!("Ответ прерван ошибкой API"));
        }
        "SessionEnd" => {
            record.insert("state".into(), json!("ended"));
            record.insert("end_reason".into(), data.get("reason").cloned().unwrap_or(Value::Null));
            record.remove("todos");
        }
        _ => {}
    }
    record.insert("event".into(), json!(event));
}

/// PostToolUse fires on every tool call: skip the write when the action is the same within a minute (the task
/// list always writes).
fn skip_repeat(record: &Map<String, Value>, data: &Value) -> bool {
    if data.get("hook_event_name").and_then(Value::as_str) != Some("PostToolUse")
        || record.get("state").and_then(Value::as_str) != Some("running")
        || data.get("tool_name").and_then(Value::as_str).is_some_and(|t| TODO_TOOLS.contains(&t))
    {
        return false;
    }
    let Some(updated) = record.get("updated_at").and_then(Value::as_str).and_then(|u| DateTime::parse_from_rfc3339(u).ok()) else {
        return false;
    };
    let (tool, target) = action_of(data);
    let same = record.get("last_tool").and_then(Value::as_str) == Some(tool.as_str())
        && record.get("last_target").and_then(Value::as_str) == Some(target.as_str());
    same && (Local::now().fixed_offset() - updated).num_seconds() < 60
}

fn run() -> Option<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).ok()?;
    let data: Value = serde_json::from_str(&input).ok()?;
    let session_id = data.get("session_id").and_then(Value::as_str)?.to_owned();
    let valid = !session_id.is_empty()
        && session_id.len() <= 128
        && session_id.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'));
    if !valid {
        return None;
    }
    let directory = arg(&args, "--sessions-dir").map(PathBuf::from).unwrap_or_else(claudepult_core::paths::sessions_dir);
    std::fs::create_dir_all(&directory).ok()?;
    let path = directory.join(format!("{session_id}.json"));

    // One writer at a time: hooks of one session can overlap.
    let lock = File::create(directory.join(".lock")).ok()?;
    lock.lock().ok()?;
    let mut record: Map<String, Value> =
        std::fs::read_to_string(&path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
    if skip_repeat(&record, &data) {
        return Some(());
    }
    let stamp = now();
    record.insert("version".into(), json!(1));
    record.insert("session_id".into(), json!(session_id));
    record.insert("updated_at".into(), json!(stamp));
    record.entry("started_at").or_insert(json!(stamp));
    for key in ["cwd", "transcript_path"] {
        if let Some(value) = data.get(key).filter(|v| v.as_str().is_some_and(|s| !s.is_empty())) {
            record.insert(key.into(), value.clone());
        }
    }
    let (project, project_path) = project_of(record.get("cwd").and_then(Value::as_str), arg(&args, "--projects-dir").as_deref());
    record.insert("project".into(), project);
    record.insert("project_path".into(), project_path);
    // A resumed session runs in a new process: follow it.
    let pid = process::claude_pid();
    if !record.contains_key("claude_pid") || (pid.is_some() && pid.map(Value::from) != record.get("claude_pid").cloned()) {
        record.insert("claude_pid".into(), pid.map(Value::from).unwrap_or(Value::Null));
        record.insert("tty".into(), Value::Null);
        record.insert("wt_session".into(), std::env::var("WT_SESSION").ok().map(Value::from).unwrap_or(Value::Null));
        record.insert("term_program".into(), std::env::var("TERM_PROGRAM").ok().map(Value::from).unwrap_or(Value::Null));
        record.insert("entrypoint".into(), std::env::var("CLAUDE_CODE_ENTRYPOINT").ok().map(Value::from).unwrap_or(Value::Null));
    }
    apply(&mut record, &data);

    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_string_pretty(&Value::Object(record)).ok()?).ok()?;
    std::fs::rename(&tmp, &path).ok()?;
    Some(())
}

fn main() {
    // Whatever happens, Claude must not notice: no output, exit code 0.
    let _ = std::panic::catch_unwind(run);
    std::process::exit(0);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projects_and_actions() {
        let (name, path) = project_of(Some("/home/me/Projects/Ambo/src"), Some("/home/me/Projects"));
        assert_eq!(name, json!("Ambo"));
        // The system's own separator joins the folder, as Claude Code's own paths have it.
        assert_eq!(path, json!(Path::new("/home/me/Projects").join("Ambo").to_string_lossy()));
        assert_eq!(project_of(Some("/tmp/x"), Some("/home/me/Projects")), (Value::Null, Value::Null));
        let edit = json!({"tool_name": "Edit", "tool_input": {"file_path": r"C:\Users\me\Projects\Ambo\LimitsView.swift"}});
        assert_eq!(action_of(&edit), ("Edit".into(), "LimitsView.swift".into()));
        let bash = json!({"tool_name": "Bash", "tool_input": {"command": "npm   test"}});
        assert_eq!(action_of(&bash), ("Bash".into(), "npm test".into()));
    }
}
