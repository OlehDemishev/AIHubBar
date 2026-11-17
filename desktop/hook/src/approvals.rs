//! Answering a PermissionRequest from the app, as the Mac hook (format 7, `ApprovalFiles` in the Mac app). The files
//! live in `approvals/` next to `sessions/`:
//! - `alive` — touched by the app while it runs with the option on; without it the hook never waits;
//! - `<id>.request.json` — written by the hook: session, project, tool, a short summary, its own pid;
//! - `<id>.decision` — `allow` or `deny`, written by the app.
//! The hook waits up to `APPROVAL_WAIT_SECONDS`, and gives up when Claude moved on (the session file's event is no
//! longer the request), when the app is gone, or at the end. It removes both files either way. When Claude Code
//! kills the hook at its timeout the files stay: the app drops requests whose pid is gone or that are too old.

use claudepult_core::hooks::APPROVAL_WAIT_SECONDS;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const ALIVE_WITHIN: Duration = Duration::from_secs(30);
const POLL: Duration = Duration::from_millis(500);

pub fn alive(directory: &Path) -> bool {
    std::fs::metadata(directory.join("alive"))
        .and_then(|m| m.modified())
        .ok()
        .and_then(|modified| SystemTime::now().duration_since(modified).ok())
        .is_some_and(|age| age < ALIVE_WITHIN)
}

/// 32 hex digits, unique enough for one request (the Mac uses `uuid4().hex`).
fn request_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let mut parts = [0u64; 2];
    for (index, part) in parts.iter_mut().enumerate() {
        let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
        hasher.write_u128(nanos);
        hasher.write_u32(std::process::id());
        hasher.write_usize(index);
        *part = hasher.finish();
    }
    format!("{:016x}{:016x}", parts[0], parts[1])
}

/// Codex's `apply_patch` names its files in `command`: `*** Add File: path` and so on.
pub fn patch_files(data: &Value) -> Vec<String> {
    let command = data.pointer("/tool_input/command").and_then(Value::as_str).unwrap_or("");
    command
        .lines()
        .filter_map(|line| {
            ["*** Add File: ", "*** Update File: ", "*** Delete File: "].iter().find_map(|prefix| line.strip_prefix(prefix))
        })
        .map(|path| {
            let path = path.trim();
            path.rsplit(['/', '\\']).next().unwrap_or(path).to_owned()
        })
        .collect()
}

/// What the request is about in a few words.
fn summary(data: &Value, clip: impl Fn(&str) -> String) -> String {
    if data.get("tool_name").and_then(Value::as_str) == Some("apply_patch") {
        let files = patch_files(data);
        if !files.is_empty() {
            return clip(&files.join(", "));
        }
    }
    let Some(input) = data.get("tool_input").and_then(Value::as_object) else { return String::new() };
    ["command", "file_path", "url", "pattern", "description", "prompt"]
        .iter()
        .find_map(|key| input.get(*key).filter(|v| !v.is_null() && v.as_str() != Some("")))
        .map(|value| clip(&value.as_str().map(str::to_owned).unwrap_or_else(|| value.to_string())))
        .unwrap_or_default()
}

/// Writes the request when the app is there; returns its id.
pub fn open(directory: &Path, data: &Value, session_id: &str, project: &str, agent: &str, clip: impl Fn(&str) -> String) -> Option<String> {
    if !alive(directory) {
        return None;
    }
    let id = request_id();
    let created = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs_f64();
    let request = json!({
        "id": id, "session_id": session_id, "project": project,
        "tool": data.get("tool_name").and_then(Value::as_str).unwrap_or(""),
        "summary": summary(data, clip), "created": created, "pid": std::process::id(), "agent": agent,
    });
    let tmp = directory.join(format!("{id}.tmp"));
    std::fs::write(&tmp, serde_json::to_string(&request).ok()?).ok()?;
    std::fs::rename(&tmp, directory.join(format!("{id}.request.json"))).ok()?;
    Some(id)
}

/// `allow` / `deny` from the app, or None.
pub fn wait(directory: &Path, id: &str, record_path: &Path) -> Option<&'static str> {
    let decision_path = directory.join(format!("{id}.decision"));
    let files: [PathBuf; 2] = [directory.join(format!("{id}.request.json")), decision_path.clone()];
    let started = Instant::now();
    let mut answer = None;
    while started.elapsed() < Duration::from_secs(APPROVAL_WAIT_SECONDS) {
        match std::fs::read_to_string(&decision_path).map(|t| t.trim().to_owned()).as_deref() {
            Ok("allow") => answer = Some("allow"),
            Ok("deny") => answer = Some("deny"),
            _ => {}
        }
        if answer.is_some() {
            break;
        }
        let moved_on = std::fs::read_to_string(record_path)
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
            .is_some_and(|r| !matches!(r.get("event").and_then(Value::as_str), Some("PermissionRequest" | "Notification")));
        if moved_on || !alive(directory) {
            break;
        }
        std::thread::sleep(POLL);
    }
    for file in files {
        let _ = std::fs::remove_file(file);
    }
    answer
}

/// What Claude Code reads from the hook's stdout.
pub fn output(behavior: &str) -> Value {
    let decision = if behavior == "allow" {
        json!({"behavior": "allow"})
    } else {
        json!({"behavior": "deny", "message": "Denied in AI Hub Bar"})
    };
    json!({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}})
}
