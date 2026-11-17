//! Permission requests the hook leaves for the app (`approvals/`, the Mac's `ApprovalFiles`): the hook writes
//! `<id>.request.json` and waits for `<id>.decision`; it waits only while the app keeps `alive` fresh, so with the
//! app closed Claude asks as usual. Claude's own dialog is on screen at the same time: the first answer applies.

use crate::hooks::APPROVAL_WAIT_SECONDS;
use crate::i18n::Strings;
use serde::Deserialize;
use std::collections::HashMap;
use std::io;
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Request {
    pub id: String,
    pub session_id: String,
    #[serde(default)]
    pub project: Option<String>,
    pub tool: String,
    /// The command, file or URL the tool wants, cut to 200 characters.
    #[serde(default)]
    pub summary: String,
    /// Seconds since 1970, as the hook writes them.
    pub created: f64,
    /// The waiting hook: once it is gone (Claude cancelled it), nobody would read an answer.
    #[serde(default)]
    pub pid: Option<u32>,
    /// The hook's `--agent`: `claude` (also when missing) or `codex`.
    #[serde(default)]
    pub agent: Option<String>,
}

impl Request {
    /// «Bash: npm test», or the tool alone.
    pub fn text(&self) -> String {
        if self.summary.is_empty() { self.tool.clone() } else { format!("{}: {}", self.tool, self.summary) }
    }

    /// «Claude просит разрешение» / «Codex просит разрешение».
    pub fn asks_title(&self, s: &Strings) -> String {
        if self.agent.as_deref() == Some("codex") {
            s.t("%@ просит разрешение").replacen("%@", "Codex", 1)
        } else {
            s.t("Claude просит разрешение").to_owned()
        }
    }
}

/// The open requests, oldest first: younger than the hook's wait and with the hook still running.
pub fn requests(dir: &Path, now_secs: f64, alive: impl Fn(u32) -> Option<bool>) -> Vec<Request> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut found: Vec<Request> = entries
        .filter_map(Result::ok)
        .filter(|e| e.file_name().to_string_lossy().ends_with(".request.json"))
        .filter_map(|e| serde_json::from_str::<Request>(&std::fs::read_to_string(e.path()).ok()?).ok())
        .filter(|r| is_valid_id(&r.id))
        .filter(|r| now_secs - r.created < APPROVAL_WAIT_SECONDS as f64)
        .filter(|r| r.pid.and_then(&alive) != Some(false))
        .collect();
    found.sort_by(|a, b| a.created.total_cmp(&b.created));
    found
}

/// The newest open request of each session.
pub fn by_session(requests: Vec<Request>) -> HashMap<String, Request> {
    let mut map: HashMap<String, Request> = HashMap::new();
    for request in requests {
        match map.get(&request.session_id) {
            Some(older) if older.created > request.created => {}
            _ => {
                map.insert(request.session_id.clone(), request);
            }
        }
    }
    map
}

/// The hook's ids are 32 hex digits, the Mac's uuid hex too; nothing that could leave the folder.
pub fn is_valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// Writes the answer the hook waits for. An error leaves the request open, so the person can answer again or in
/// Claude itself.
pub fn decide(dir: &Path, id: &str, allow: bool) -> io::Result<()> {
    if !is_valid_id(id) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "not a request id"));
    }
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!("{id}.decision.tmp"));
    std::fs::write(&tmp, if allow { "allow" } else { "deny" })?;
    std::fs::rename(&tmp, dir.join(format!("{id}.decision")))
}

/// Tells the hooks the app is there and answers (touched every few seconds).
pub fn touch_alive(dir: &Path) {
    let _ = std::fs::create_dir_all(dir);
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
    let _ = std::fs::write(dir.join("alive"), now.to_string());
}

/// On quit: the hooks stop waiting at once instead of in 30 s.
pub fn stop_alive(dir: &Path) {
    let _ = std::fs::remove_file(dir.join("alive"));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(dir: &Path, id: &str, session: &str, created: f64, pid: Option<u32>) {
        let request = serde_json::json!({"id": id, "session_id": session, "project": "Ambo", "tool": "Bash",
                                         "summary": "npm test", "created": created, "pid": pid, "agent": "claude"});
        std::fs::write(dir.join(format!("{id}.request.json")), request.to_string()).unwrap();
    }

    #[test]
    fn open_requests_and_answers() {
        let dir = std::env::temp_dir().join(format!("claudepult-approvals-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let now = 10_000.0;
        write(&dir, "a1", "s-1", now - 20.0, Some(1));
        write(&dir, "a2", "s-1", now - 5.0, Some(1));
        write(&dir, "old", "s-2", now - 400.0, Some(1));
        write(&dir, "gone", "s-3", now - 5.0, Some(2));
        std::fs::write(dir.join("broken.request.json"), "{").unwrap();
        let open = requests(&dir, now, |pid| Some(pid == 1));
        let ids: Vec<&str> = open.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, ["a1", "a2"], "too old, a gone hook and a broken file are skipped; oldest first");
        assert_eq!(open[0].text(), "Bash: npm test");
        let latest = by_session(open);
        assert_eq!(latest.len(), 1);
        assert_eq!(latest["s-1"].id, "a2", "the newest request of a session");

        decide(&dir, "a2", false).unwrap();
        assert_eq!(std::fs::read_to_string(dir.join("a2.decision")).unwrap(), "deny");
        assert!(decide(&dir, "../escape", true).is_err());
        assert!(!dir.join("a2.decision.tmp").exists());

        touch_alive(&dir);
        assert!(dir.join("alive").exists());
        stop_alive(&dir);
        assert!(!dir.join("alive").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
