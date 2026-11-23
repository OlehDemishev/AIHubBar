//! «Агент мог застрять» (the Mac's `StuckWatch`): a session that works but has done nothing for a long while, or keeps
//! running the same command. The session file holds only the last tool call, so the repeats are counted here, from
//! one reading of the files to the next — a hint, not a proof.

use crate::i18n::Strings;
use crate::sessions::{Session, State};
use chrono::{DateTime, Duration, Utc};
use std::collections::{HashMap, HashSet};

/// The row says «тихо» after 10 minutes; a notification waits twice as long.
pub const ROW_QUIET_MINUTES: i64 = 10;
pub const QUIET_MINUTES: i64 = 20;
/// The same command this many times among the last `LOOP_WINDOW` tool calls.
pub const LOOP_TIMES: usize = 5;
pub const LOOP_WINDOW: usize = 12;
/// A session found already quiet for longer than this at the app's start is old news.
const REPLAY_WITHIN_MINUTES: i64 = 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reason {
    Quiet { minutes: i64 },
    Loop { times: usize, command: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Alert {
    pub session_id: String,
    pub reason: Reason,
}

#[derive(Default)]
struct Track {
    prompt: Option<DateTime<Utc>>,
    last_tool_at: Option<DateTime<Utc>>,
    actions: Vec<String>,
    quiet_fired_for: Option<DateTime<Utc>>,
    loop_fired: HashSet<String>,
}

/// The latest sign of life: a tool call, a new request, any hook event.
pub fn last_activity(session: &Session) -> DateTime<Utc> {
    [session.last_tool_at, session.prompt_at].into_iter().flatten().fold(session.updated_at, DateTime::max)
}

/// «тихо 14 мин» on a working session's row; None while it is busy.
pub fn row_quiet_minutes(session: &Session, state: State, now: DateTime<Utc>) -> Option<i64> {
    let quiet = now - last_activity(session);
    (state == State::Running && quiet > Duration::minutes(ROW_QUIET_MINUTES)).then(|| quiet.num_minutes())
}

#[derive(Default)]
pub struct StuckWatch {
    tracks: HashMap<String, Track>,
}

impl StuckWatch {
    /// What is new since the last reading: each quiet spell and each repeated command is told once.
    pub fn evaluate(&mut self, sessions: &[(Session, State)], now: DateTime<Utc>) -> Vec<Alert> {
        let mut alerts = Vec::new();
        self.tracks.retain(|id, _| sessions.iter().any(|(session, _)| &session.id == id));
        for (session, state) in sessions {
            let is_new = !self.tracks.contains_key(&session.id);
            let track = self.tracks.entry(session.id.clone()).or_insert_with(|| Track { prompt: session.prompt_at, ..Track::default() });
            // A new request starts the count again.
            if track.prompt != session.prompt_at {
                *track = Track { prompt: session.prompt_at, ..Track::default() };
            }
            if let (Some(at), Some(tool)) = (session.last_tool_at, session.last_tool.as_deref()) {
                if Some(at) != track.last_tool_at {
                    track.last_tool_at = Some(at);
                    let command = session.last_target.clone().unwrap_or_default();
                    let key = format!("{tool}\u{1}{command}");
                    track.actions.push(key.clone());
                    let excess = track.actions.len().saturating_sub(LOOP_WINDOW);
                    track.actions.drain(..excess);
                    let times = track.actions.iter().filter(|action| **action == key).count();
                    let shell = matches!(tool, "Bash" | "PowerShell");
                    if *state == State::Running && shell && !command.is_empty() && times >= LOOP_TIMES && track.loop_fired.insert(key) {
                        alerts.push(Alert { session_id: session.id.clone(), reason: Reason::Loop { times, command } });
                    }
                }
            }
            if *state != State::Running {
                continue;
            }
            let last = last_activity(session);
            let quiet = now - last;
            if quiet >= Duration::minutes(QUIET_MINUTES) && track.quiet_fired_for != Some(last) {
                track.quiet_fired_for = Some(last);
                if !is_new || quiet < Duration::minutes(QUIET_MINUTES + REPLAY_WITHIN_MINUTES) {
                    alerts.push(Alert { session_id: session.id.clone(), reason: Reason::Quiet { minutes: quiet.num_minutes() } });
                }
            }
        }
        alerts
    }
}

pub fn title(s: &Strings, session: &Session) -> String {
    s.format("%@ мог застрять — %@", &[session.agent_name(), &session.display_project()])
}

pub fn body(s: &Strings, reason: &Reason) -> String {
    match reason {
        Reason::Quiet { minutes } => s.format("Сессия идёт, но уже %lld мин ничего не делает. Посмотрите, не зависла ли она.", &[&minutes.to_string()]),
        Reason::Loop { times, command } => s.format("Раз за разом запускает одно и то же (уже %lld): %@", &[&times.to_string(), command]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(updated: DateTime<Utc>, tool: Option<(&str, &str, DateTime<Utc>)>, prompt: Option<DateTime<Utc>>) -> Session {
        let mut session = Session::parse(&format!(r#"{{"session_id":"s","cwd":"C:/P/Shop","state":"running","updated_at":"{}"}}"#, updated.to_rfc3339())).unwrap();
        if let Some((name, target, at)) = tool {
            session.last_tool = Some(name.into());
            session.last_target = Some(target.into());
            session.last_tool_at = Some(at);
        }
        session.prompt_at = prompt;
        session
    }

    #[test]
    fn a_quiet_session_is_told_once() {
        let start = Utc::now();
        let mut watch = StuckWatch::default();
        let quiet = session(start, None, Some(start));
        assert!(watch.evaluate(&[(quiet.clone(), State::Running)], start + Duration::minutes(5)).is_empty());
        assert_eq!(row_quiet_minutes(&quiet, State::Running, start + Duration::minutes(12)), Some(12));
        assert_eq!(row_quiet_minutes(&quiet, State::Waiting, start + Duration::minutes(12)), None, "waiting is not quiet");
        let alerts = watch.evaluate(&[(quiet.clone(), State::Running)], start + Duration::minutes(21));
        assert_eq!(alerts, [Alert { session_id: "s".into(), reason: Reason::Quiet { minutes: 21 } }]);
        assert!(watch.evaluate(&[(quiet.clone(), State::Running)], start + Duration::minutes(40)).is_empty(), "once per quiet spell");
        // A session the app first sees long quiet is old news.
        let mut fresh = StuckWatch::default();
        assert!(fresh.evaluate(&[(quiet.clone(), State::Running)], start + Duration::minutes(60)).is_empty());
        assert!(fresh.evaluate(&[(quiet, State::Waiting)], start + Duration::minutes(61)).is_empty());
    }

    #[test]
    fn the_same_command_again_and_again() {
        let start = Utc::now();
        let mut watch = StuckWatch::default();
        let mut alerts = Vec::new();
        for i in 0..6 {
            let at = start + Duration::seconds(i * 70);
            let s = session(at, Some(("PowerShell", "npm test", at)), Some(start));
            alerts.extend(watch.evaluate(&[(s, State::Running)], at));
        }
        assert_eq!(alerts, [Alert { session_id: "s".into(), reason: Reason::Loop { times: 5, command: "npm test".into() } }], "told once, at the fifth");
        // A new request starts the count again.
        let mut again = Vec::new();
        for i in 0..4 {
            let at = start + Duration::seconds(1000 + i * 70);
            let s = session(at, Some(("PowerShell", "npm test", at)), Some(start + Duration::seconds(999)));
            again.extend(watch.evaluate(&[(s, State::Running)], at));
        }
        assert!(again.is_empty());
        let s = Strings::default();
        assert_eq!(body(&s, &Reason::Loop { times: 5, command: "npm test".into() }), "Раз за разом запускает одно и то же (уже 5): npm test");
        assert_eq!(title(&s, &session(start, None, None)), "Claude мог застрять — Shop");
    }
}
