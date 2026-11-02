//! Claude Code sessions as the hook writes them (`<data dir>/sessions/<id>.json`), with the Mac's rules
//! (`Session.swift`, `SessionRules`): which ones the panel shows, in what order, and what each is doing.

use crate::i18n::Strings;
use chrono::{DateTime, Duration, Utc};
use serde_json::Value;
use std::path::Path;

/// No events for this long and no live process: stale, hidden.
pub const STALE_AFTER_HOURS: i64 = 2;
/// Ended sessions stay a while, so a finished task can still be seen.
pub const KEEP_ENDED_MINUTES: i64 = 15;
/// Files older than this are deleted.
pub const DELETE_AFTER_DAYS: i64 = 7;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum State {
    Waiting,
    Running,
    Error,
    Done,
    Unknown,
    Ended,
}

impl State {
    fn parse(text: Option<&str>) -> State {
        match text {
            Some("waiting") => State::Waiting,
            Some("running") => State::Running,
            Some("error") => State::Error,
            Some("done") => State::Done,
            Some("ended") => State::Ended,
            _ => State::Unknown,
        }
    }

    /// The word for it, from the Mac catalog.
    pub fn title(self, s: &Strings) -> String {
        let key = match self {
            State::Running => "работает",
            State::Waiting => "ждёт ответа",
            State::Done => "готово",
            State::Ended => "завершена",
            State::Error => "ошибка",
            State::Unknown => return "—".into(),
        };
        s.t(key).to_owned()
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Session {
    pub id: String,
    pub cwd: String,
    pub project: Option<String>,
    pub state: State,
    pub updated_at: DateTime<Utc>,
    pub message: Option<String>,
    pub last_tool: Option<String>,
    pub last_target: Option<String>,
    pub claude_pid: Option<u32>,
    pub wt_session: Option<String>,
    /// (done, total) of the task list.
    pub progress: Option<(usize, usize)>,
}

fn text(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_owned)
}

impl Session {
    pub fn parse(json: &str) -> Option<Session> {
        let value: Value = serde_json::from_str(json).ok()?;
        let id = text(&value, "session_id")?;
        let updated_at = text(&value, "updated_at")
            .and_then(|u| DateTime::parse_from_rfc3339(&u).ok())
            .map(|d| d.with_timezone(&Utc))
            .unwrap_or(DateTime::<Utc>::MIN_UTC);
        let progress = value.get("todos").and_then(Value::as_array).filter(|t| !t.is_empty()).map(|todos| {
            (todos.iter().filter(|t| t.get("status").and_then(Value::as_str) == Some("completed")).count(), todos.len())
        });
        Some(Session {
            id,
            cwd: text(&value, "cwd").unwrap_or_default(),
            project: text(&value, "project"),
            state: State::parse(value.get("state").and_then(Value::as_str)),
            updated_at,
            message: text(&value, "message"),
            last_tool: text(&value, "last_tool"),
            last_target: text(&value, "last_target"),
            claude_pid: value.get("claude_pid").and_then(Value::as_u64).map(|p| p as u32),
            wt_session: text(&value, "wt_session"),
            progress,
        })
    }

    /// The project's name, or the last folder of `cwd` for a session outside the projects folder.
    pub fn display_project(&self) -> String {
        self.project.clone().unwrap_or_else(|| {
            self.cwd.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next().unwrap_or(&self.cwd).to_owned()
        })
    }

    /// «правит LimitsView.swift», «запускает npm test»: the last tool call in words, as on the Mac.
    pub fn action_text(&self, s: &Strings) -> Option<String> {
        let tool = self.last_tool.as_deref()?;
        let verb = match tool {
            "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => s.t("правит").to_owned(),
            "Read" => s.t("читает").to_owned(),
            "Bash" | "BashOutput" | "PowerShell" => s.t("запускает").to_owned(),
            "Grep" | "Glob" | "ToolSearch" => s.t("ищет").to_owned(),
            "WebFetch" | "WebSearch" => s.t("смотрит в сети").to_owned(),
            "Agent" | "Task" => s.t("работает с агентом").to_owned(),
            "TodoWrite" | "TaskCreate" | "TaskUpdate" => s.t("обновляет план").to_owned(),
            other if other.starts_with("mcp__") => {
                format!("{} {}", s.t("инструмент"), other.rsplit('_').next().unwrap_or(other))
            }
            other => other.to_owned(),
        };
        Some(match self.last_target.as_deref() {
            Some(target) => format!("{verb} {target}"),
            None => verb,
        })
    }
}

/// The state to show: a session whose process is gone counts as ended.
pub fn effective_state(session: &Session, alive: Option<bool>) -> State {
    if session.state != State::Ended && alive == Some(false) { State::Ended } else { session.state }
}

pub fn is_visible(session: &Session, alive: Option<bool>, now: DateTime<Utc>) -> bool {
    let age = now - session.updated_at;
    match effective_state(session, alive) {
        State::Ended => age < Duration::minutes(KEEP_ENDED_MINUTES),
        _ => alive == Some(true) || age < Duration::hours(STALE_AFTER_HOURS),
    }
}

/// Waiting first, then running, then the rest; the newest first within a group.
pub fn sort(sessions: &mut [(Session, State)]) {
    sessions.sort_by(|a, b| a.1.cmp(&b.1).then(b.0.updated_at.cmp(&a.0.updated_at)));
}

/// The sessions to show, read from the folder. `alive` tells whether a process still runs (None: unknown).
/// Files older than a week are deleted on the way.
pub fn load(dir: &Path, now: DateTime<Utc>, alive: impl Fn(u32) -> Option<bool>) -> Vec<(Session, State)> {
    let mut shown = Vec::new();
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Some(session) = std::fs::read_to_string(&path).ok().and_then(|t| Session::parse(&t)) else { continue };
        if now - session.updated_at > Duration::days(DELETE_AFTER_DAYS) {
            let _ = std::fs::remove_file(&path);
            continue;
        }
        let is_alive = session.claude_pid.and_then(&alive);
        if is_visible(&session, is_alive, now) {
            let state = effective_state(&session, is_alive);
            shown.push((session, state));
        }
    }
    sort(&mut shown);
    shown
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(state: &str, minutes_ago: i64, now: DateTime<Utc>) -> String {
        serde_json::json!({
            "session_id": format!("{state}-{minutes_ago}"), "cwd": r"C:\Users\me\Projects\Ambo", "state": state,
            "updated_at": (now - Duration::minutes(minutes_ago)).to_rfc3339(), "claude_pid": 42,
        })
        .to_string()
    }

    #[test]
    fn rules() {
        let now = Utc::now();
        let parse = |state, ago| Session::parse(&session(state, ago, now)).unwrap();
        assert!(is_visible(&parse("running", 30), None, now));
        assert!(!is_visible(&parse("running", 180), None, now), "stale after two hours");
        assert!(is_visible(&parse("running", 180), Some(true), now), "unless its process still runs");
        assert!(is_visible(&parse("ended", 10), None, now));
        assert!(!is_visible(&parse("ended", 20), None, now));
        assert_eq!(effective_state(&parse("running", 1), Some(false)), State::Ended, "process gone: ended");
        assert_eq!(parse("done", 1).display_project(), "Ambo", "Windows paths too");
    }

    #[test]
    fn loading_and_order() {
        let now = Utc::now();
        let dir = std::env::temp_dir().join(format!("claudepult-sessions-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for (name, state, ago) in [("a", "done", 5), ("b", "waiting", 30), ("c", "running", 2), ("d", "running", 1), ("e", "done", 60 * 24 * 8)] {
            std::fs::write(dir.join(format!("{name}.json")), session(state, ago, now)).unwrap();
        }
        std::fs::write(dir.join(".lock"), "").unwrap();
        std::fs::write(dir.join("broken.json"), "{").unwrap();
        let shown = load(&dir, now, |_| None);
        let order: Vec<String> = shown.iter().map(|(s, _)| s.id.clone()).collect();
        assert_eq!(order, ["waiting-30", "running-1", "running-2", "done-5"]);
        assert!(!dir.join("e.json").exists(), "older than a week: deleted");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn words() {
        let s = Strings::default();
        let mut parsed = Session::parse(r#"{"session_id": "x", "last_tool": "Edit", "last_target": "main.rs",
            "todos": [{"status": "completed"}, {"status": "in_progress"}, {"status": "pending"}]}"#)
        .unwrap();
        assert_eq!(parsed.action_text(&s).as_deref(), Some("правит main.rs"));
        assert_eq!(parsed.progress, Some((1, 3)));
        parsed.last_tool = Some("mcp__github__create_pull_request".into());
        parsed.last_target = None;
        assert_eq!(parsed.action_text(&s).as_deref(), Some("инструмент request"));
        assert_eq!(State::Waiting.title(&s), "ждёт ответа");
        assert!(Session::parse(r#"{"state": "running"}"#).is_none(), "no id, no session");
    }
}
