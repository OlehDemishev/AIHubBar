//! Background runs for later (the Mac's `NightQueue`, `RunGuard` and the queue of its `LaunchController`): «На ночь»
//! waits for the night start hour and gets one morning summary, «После сброса» waits for the session limit to reset;
//! near a limit a due run waits for that window's reset instead of starting into it. Kept in `queue.json`, the Mac's
//! file and format.

use std::collections::HashSet;
use std::path::Path;

use chrono::{DateTime, Duration, NaiveDateTime, Timelike, Utc};
use serde::{Deserialize, Serialize};

use crate::launch::ClaudeCommand;
use crate::usage::UsageSnapshot;

/// «Ночные задачи начинаются в».
pub const HOURS: [u32; 7] = [22, 23, 0, 1, 2, 3, 4];
pub const DEFAULT_HOUR: u32 = 1;
/// The night lasts from the start hour to this one.
pub const END_HOUR: u32 = 6;
/// Above this session usage a background run asks first.
pub const LAUNCH_WARNING: f64 = 90.0;
/// «Ставить фоновые задачи на паузу»: at this usage of the session or the week running background tasks freeze and
/// queued ones wait for the reset; 0 — never.
pub const GUARD_CHOICES: [u32; 5] = [0, 80, 90, 95, 98];
pub const GUARD_PERCENT: u32 = 95;

/// When a run queued now starts, in the computer's own time: at the next `hour` o'clock, or at once if the night has
/// already begun (queued at 23:30 with a 22:00 start, it must not wait for tomorrow's night).
pub fn next_start(hour: u32, now: NaiveDateTime) -> NaiveDateTime {
    let Some(today) = now.date().and_hms_opt(hour % 24, 0, 0) else { return now };
    let last_start = if today <= now { today } else { today - Duration::days(1) };
    // The first 06:00 after that start: the same morning for a start after midnight, the next one otherwise.
    let end_day = if last_start.hour() < END_HOUR { last_start.date() } else { last_start.date() + Duration::days(1) };
    if end_day.and_hms_opt(END_HOUR, 0, 0).is_some_and(|end| now < end) {
        return now;
    }
    if today > now { today } else { today + Duration::days(1) }
}

/// The Mac's `ClaudeCommand` as Swift writes it: `{"nextStep":{}}`, `{"customTask":{"_0":"…"}}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Command {
    NextStep {},
    CustomTask {
        #[serde(rename = "_0")]
        task: String,
    },
    FinishSession {},
}

impl From<&ClaudeCommand> for Command {
    fn from(command: &ClaudeCommand) -> Self {
        match command {
            ClaudeCommand::NextStep => Command::NextStep {},
            ClaudeCommand::CustomTask(task) => Command::CustomTask { task: task.clone() },
            ClaudeCommand::FinishSession => Command::FinishSession {},
        }
    }
}

impl Command {
    /// `next`, `custom` or `finish` with the task — what the launch takes.
    pub fn parts(&self) -> (&'static str, Option<&str>) {
        match self {
            Command::NextStep {} => ("next", None),
            Command::CustomTask { task } => ("custom", Some(task)),
            Command::FinishSession {} => ("finish", None),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    pub path: String,
    pub name: String,
    #[serde(default)]
    pub next_items: Vec<String>,
    #[serde(default)]
    pub base_ref: String,
}

/// A background run postponed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Queued {
    pub id: String,
    pub command: Command,
    pub target: Target,
    #[serde(with = "crate::runs::iso")]
    pub launch_at: DateTime<Utc>,
    /// Queued «на ночь»: part of the batch that gets a morning summary.
    #[serde(default)]
    pub night: bool,
    /// Waits for the session limit to reset: if the limit is still full at `launch_at`, it waits for the next reset.
    #[serde(default)]
    pub after_reset: bool,
    /// The run goes to Codex (`codex exec`); Claude's limits are then not its concern.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_path: Option<String>,
}

pub fn load(path: &Path) -> Vec<Queued> {
    std::fs::read_to_string(path).ok().and_then(|text| serde_json::from_str(&text).ok()).unwrap_or_default()
}

pub fn save(path: &Path, queued: &[Queued]) -> std::io::Result<()> {
    if let Some(folder) = path.parent() {
        std::fs::create_dir_all(folder)?;
    }
    let tmp = path.with_extension("json.claudepult-tmp");
    std::fs::write(&tmp, serde_json::to_string(queued).map_err(std::io::Error::other)?)?;
    std::fs::rename(&tmp, path)
}

/// What starts on this tick: the due runs, one per project, none for a project that is being started. The others
/// stay due and start on the next ticks.
pub fn due_now(queued: &[Queued], busy: &HashSet<String>, now: DateTime<Utc>) -> Vec<Queued> {
    let mut taken = busy.clone();
    queued.iter().filter(|item| item.launch_at <= now && taken.insert(item.target.path.clone())).cloned().collect()
}

/// «После сброса»: two minutes after the session's reset, or in an hour when the reset is not known.
pub fn after_reset(resets_at: Option<DateTime<Utc>>, now: DateTime<Utc>) -> DateTime<Utc> {
    resets_at.filter(|reset| *reset > now).unwrap_or(now + Duration::hours(1)) + Duration::seconds(120)
}

/// A limit window that holds background work.
#[derive(Debug, Clone, PartialEq)]
pub struct Hold {
    /// `five_hour`, `seven_day`.
    pub key: String,
    pub utilization: f64,
    pub resets_at: Option<DateTime<Utc>>,
}

impl Hold {
    /// When to try again: two minutes after the reset, or in half an hour if the reset is unknown.
    pub fn retry_at(&self, now: DateTime<Utc>) -> DateTime<Utc> {
        self.resets_at.unwrap_or(now + Duration::minutes(30)) + Duration::seconds(120)
    }
}

/// The window over the threshold that resets last; a window whose reset has already passed is stale, not full.
pub fn hold(snapshot: Option<&UsageSnapshot>, threshold: u32, now: DateTime<Utc>) -> Option<Hold> {
    if threshold == 0 {
        return None;
    }
    let snapshot = snapshot?;
    [snapshot.session(), snapshot.week()]
        .into_iter()
        .flatten()
        .filter(|window| window.utilization >= f64::from(threshold) && window.resets_at.is_none_or(|reset| reset > now))
        .max_by_key(|window| window.resets_at.unwrap_or(DateTime::<Utc>::MAX_UTC))
        .map(|window| Hold { key: window.key.clone(), utilization: window.utilization, resets_at: window.resets_at })
}

/// Due runs of Claude that would only hit the limit wait for the next reset: all of them while a window holds, and
/// «после сброса» runs while the session is still above the launch warning. True when something moved.
pub fn postpone_held(queued: &mut [Queued], snapshot: Option<&UsageSnapshot>, threshold: u32, now: DateTime<Utc>) -> bool {
    let holding = hold(snapshot, threshold, now);
    let session = snapshot.and_then(UsageSnapshot::session);
    let mut changed = false;
    for item in queued.iter_mut().filter(|item| item.launch_at <= now && item.codex_path.is_none()) {
        if let Some(hold) = &holding {
            item.launch_at = hold.retry_at(now);
        } else if let Some(reset) = session.filter(|s| item.after_reset && s.utilization > LAUNCH_WARNING).and_then(|s| s.resets_at).filter(|reset| *reset > now) {
            item.launch_at = reset + Duration::seconds(120);
        } else {
            continue;
        }
        changed = true;
    }
    changed
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::usage::UsageWindow;
    use chrono::{NaiveDate, TimeZone};

    fn at(day: u32, hour: u32, minute: u32) -> NaiveDateTime {
        NaiveDate::from_ymd_opt(2026, 11, day).unwrap().and_hms_opt(hour, minute, 0).unwrap()
    }

    fn utc(hour: u32, minute: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 11, 23, hour, minute, 0).unwrap()
    }

    fn item(id: &str, path: &str, launch_at: DateTime<Utc>) -> Queued {
        Queued { id: id.into(), command: Command::NextStep {}, target: Target { path: path.into(), name: path.into(), next_items: vec![], base_ref: "origin/main".into() }, launch_at, night: false, after_reset: false, codex_path: None }
    }

    fn snapshot(session: f64, session_reset: Option<DateTime<Utc>>, week: f64, week_reset: Option<DateTime<Utc>>) -> UsageSnapshot {
        let window = |key: &str, utilization, resets_at| UsageWindow { key: key.into(), utilization, resets_at, model: None };
        UsageSnapshot { fetched_at: utc(12, 0), windows: vec![window("five_hour", session, session_reset), window("seven_day", week, week_reset)], extra: None }
    }

    #[test]
    fn the_night_starts_at_its_hour() {
        assert_eq!(next_start(1, at(23, 15, 0)), at(24, 1, 0), "in the day: tonight after midnight");
        assert_eq!(next_start(22, at(23, 15, 0)), at(23, 22, 0));
        assert_eq!(next_start(22, at(23, 23, 30)), at(23, 23, 30), "the night has begun: at once");
        assert_eq!(next_start(22, at(24, 3, 0)), at(24, 3, 0), "still the same night after midnight");
        assert_eq!(next_start(1, at(24, 5, 59)), at(24, 5, 59));
        assert_eq!(next_start(1, at(24, 6, 0)), at(25, 1, 0), "the morning: the next night");
        assert_eq!(next_start(22, at(24, 6, 30)), at(24, 22, 0));
        assert_eq!(next_start(0, at(23, 23, 59)), at(24, 0, 0));
        assert_eq!(next_start(1, at(23, 1, 0)), at(23, 1, 0), "on the hour itself");
    }

    #[test]
    fn the_file_is_the_macs() {
        let mac = r#"[{"id":"A1","command":{"customTask":{"_0":"Fix the tests"}},"target":{"path":"/p/app","name":"app","nextItems":["one"],"baseRef":"origin/main"},"launchAt":"2026-11-24T01:00:00Z","night":true,"afterReset":false},
            {"id":"B2","command":{"nextStep":{}},"target":{"path":"/p/b","name":"b","nextItems":[],"baseRef":"main"},"launchAt":"2026-11-23T15:02:00Z","codexPath":"/usr/bin/codex"}]"#;
        let read: Vec<Queued> = serde_json::from_str(mac).unwrap();
        assert_eq!(read[0].command.parts(), ("custom", Some("Fix the tests")));
        assert!(read[0].night && !read[0].after_reset && read[0].codex_path.is_none());
        assert_eq!((read[1].command.parts(), read[1].codex_path.as_deref(), read[1].night), (("next", None), Some("/usr/bin/codex"), false));
        let written = serde_json::to_string(&read).unwrap();
        assert!(written.contains(r#""command":{"customTask":{"_0":"Fix the tests"}}"#) && written.contains(r#""command":{"nextStep":{}}"#), "{written}");
        assert!(written.contains(r#""launchAt":"2026-11-24T01:00:00Z""#) && written.contains(r#""nextItems":["one"]"#));
        assert_eq!(serde_json::from_str::<Vec<Queued>>(&written).unwrap(), read);
        assert_eq!(Command::from(&ClaudeCommand::FinishSession), Command::FinishSession {});

        let file = std::env::temp_dir().join(format!("claudepult-queue-{}", std::process::id())).join("queue.json");
        assert!(load(&file).is_empty());
        save(&file, &read).unwrap();
        assert_eq!(load(&file), read);
        let _ = std::fs::remove_dir_all(file.parent().unwrap());
    }

    #[test]
    fn one_due_run_per_project() {
        let queued = [item("a", "/p/one", utc(11, 0)), item("b", "/p/one", utc(11, 30)), item("c", "/p/two", utc(12, 0)), item("d", "/p/three", utc(12, 1)), item("e", "/p/busy", utc(10, 0))];
        let due = due_now(&queued, &HashSet::from(["/p/busy".to_owned()]), utc(12, 0));
        assert_eq!(due.iter().map(|q| q.id.as_str()).collect::<Vec<_>>(), ["a", "c"]);
    }

    #[test]
    fn what_holds_and_until_when() {
        let now = utc(12, 0);
        assert_eq!(hold(Some(&snapshot(94.9, Some(utc(14, 0)), 50.0, None)), 95, now), None);
        assert_eq!(hold(Some(&snapshot(96.0, Some(utc(14, 0)), 50.0, None)), 95, now).map(|h| h.key), Some("five_hour".into()));
        // Both over: the one that resets last holds longest.
        let both = hold(Some(&snapshot(99.0, Some(utc(14, 0)), 97.0, Some(utc(20, 0)))), 95, now).unwrap();
        assert_eq!((both.key.as_str(), both.retry_at(now)), ("seven_day", utc(20, 2)));
        assert_eq!(hold(Some(&snapshot(99.0, Some(utc(11, 0)), 10.0, None)), 95, now), None, "the reset has passed: stale, not full");
        assert_eq!(hold(Some(&snapshot(99.0, None, 10.0, None)), 95, now).unwrap().retry_at(now), utc(12, 32), "no reset known: in half an hour");
        assert_eq!(hold(Some(&snapshot(100.0, Some(utc(14, 0)), 100.0, None)), 0, now), None, "switched off");
        assert_eq!(hold(None, 95, now), None);
        assert_eq!(after_reset(Some(utc(14, 0)), now), utc(14, 2));
        assert_eq!(after_reset(None, now), utc(13, 2));
        assert_eq!(after_reset(Some(utc(11, 0)), now), utc(13, 2), "a reset in the past is not known");
    }

    #[test]
    fn due_runs_wait_for_the_reset() {
        let now = utc(12, 0);
        let fresh = || {
            let mut list = vec![item("due", "/p/a", utc(11, 0)), item("after", "/p/b", utc(11, 59)), item("later", "/p/c", utc(18, 0)), item("codex", "/p/d", utc(11, 0))];
            list[1].after_reset = true;
            list[3].codex_path = Some("codex".into());
            list
        };
        let times = |list: &[Queued]| list.iter().map(|q| q.launch_at).collect::<Vec<_>>();

        let mut held = fresh();
        assert!(postpone_held(&mut held, Some(&snapshot(97.0, Some(utc(14, 0)), 10.0, None)), GUARD_PERCENT, now));
        assert_eq!(times(&held), [utc(14, 2), utc(14, 2), utc(18, 0), utc(11, 0)], "Claude's due runs wait; Codex's and later ones stay");

        let mut warned = fresh();
        assert!(postpone_held(&mut warned, Some(&snapshot(92.0, Some(utc(14, 0)), 10.0, None)), GUARD_PERCENT, now));
        assert_eq!(times(&warned), [utc(11, 0), utc(14, 2), utc(18, 0), utc(11, 0)], "only «после сброса» waits above the warning");

        let mut free = fresh();
        assert!(!postpone_held(&mut free, Some(&snapshot(40.0, Some(utc(14, 0)), 10.0, None)), GUARD_PERCENT, now));
        assert!(!postpone_held(&mut free, None, GUARD_PERCENT, now));
        assert_eq!(times(&free), times(&fresh()));
    }
}
