//! Stage 4 «Фоновые задачи» (docs/specs/SPEC-windows.md §4.6): `claude -p` without a window, as the Mac's `RunStore`,
//! `BackgroundRun`, `StreamJSON` and `BackgroundPermissions`. A run is `runs/<id>.json` (the Mac's shape) next to its
//! log `runs/<id>.log`; Claude writes straight into the log, so a run goes on when the app quits and is picked up again
//! on the next start. The id is also Claude's `--session-id`, so the hook's session file has the same name.
//!
//! Rules: `--permission-mode dontAsk` with `--permission-prompts none` refuses everything not allowed. On Windows
//! Claude runs commands through PowerShell when Git Bash is missing, so every `Bash(…)` rule gets a `PowerShell(…)`
//! twin and PowerShell's own deletions, downloads and environment reads are denied (code.claude.com/docs/en/permissions:
//! PowerShell rules have the Bash rules' shape; a deny at any level wins). The rules go to Claude as a file
//! (`--settings <path>`), so no JSON passes through a command line.

use crate::command;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs::File;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};

/// Finished runs are kept a month (the Mac's `keepFinishedFor`).
pub const KEEP_FINISHED_DAYS: i64 = 30;
/// The Mac's default time limit.
pub const DEFAULT_TIME_LIMIT_MINUTES: u32 = 90;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RunState {
    Running,
    Succeeded,
    Failed,
    Stopped,
    TimedOut,
}

/// The Mac's `BackgroundRun`, field for field where this version uses it; the others are kept as they are read.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Run {
    pub id: String,
    pub project: String,
    pub project_path: String,
    pub folder: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub worktree_branch: Option<String>,
    pub command_title: String,
    pub task: String,
    #[serde(with = "iso")]
    pub started_at: DateTime<Utc>,
    pub time_limit_minutes: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    pub state: RunState,
    #[serde(default, with = "iso_option", skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(rename = "pullRequestURL", skip_serializing_if = "Option::is_none")]
    pub pull_request_url: Option<String>,
    pub notified: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt: Option<String>,
    /// Fields of the Mac's runs this version doesn't use (Codex, pauses, pairs), written back unchanged.
    #[serde(flatten)]
    pub other: serde_json::Map<String, Value>,
}

/// Swift's `.iso8601`: whole seconds and `Z`.
mod iso {
    use chrono::{DateTime, SecondsFormat, Utc};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(date: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&date.to_rfc3339_opts(SecondsFormat::Secs, true))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let text = String::deserialize(d)?;
        DateTime::parse_from_rfc3339(&text).map(|t| t.with_timezone(&Utc)).map_err(serde::de::Error::custom)
    }
}

mod iso_option {
    use chrono::{DateTime, Utc};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(date: &Option<DateTime<Utc>>, s: S) -> Result<S::Ok, S::Error> {
        match date {
            Some(date) => super::iso::serialize(date, s),
            None => s.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<DateTime<Utc>>, D::Error> {
        let text = Option::<String>::deserialize(d)?;
        Ok(text.and_then(|t| DateTime::parse_from_rfc3339(&t).ok()).map(|t| t.with_timezone(&Utc)))
    }
}

impl Run {
    pub fn log_path(&self, dir: &Path) -> PathBuf {
        dir.join(format!("{}.log", self.id))
    }

    pub fn deadline(&self) -> DateTime<Utc> {
        self.started_at + chrono::Duration::minutes(i64::from(self.time_limit_minutes))
    }

    pub fn is_running(&self) -> bool {
        self.state == RunState::Running
    }
}

// MARK: - Files

pub fn save(dir: &Path, run: &Run) -> io::Result<()> {
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!("{}.json.tmp", run.id));
    std::fs::write(&tmp, serde_json::to_string_pretty(run).map_err(io::Error::other)?)?;
    std::fs::rename(&tmp, dir.join(format!("{}.json", run.id)))
}

/// Every run, newest first; finished ones older than a month are deleted with their logs and settings.
pub fn load(dir: &Path, now: DateTime<Utc>) -> Vec<Run> {
    let mut runs = Vec::new();
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") || path.to_string_lossy().ends_with(".settings.json") {
            continue;
        }
        let Some(run) = std::fs::read_to_string(&path).ok().and_then(|t| serde_json::from_str::<Run>(&t).ok()) else { continue };
        if run.finished_at.is_some_and(|f| (now - f).num_days() > KEEP_FINISHED_DAYS) {
            for file in [path.clone(), run.log_path(dir), settings_path(dir, &run.id)] {
                let _ = std::fs::remove_file(file);
            }
            continue;
        }
        runs.push(run);
    }
    runs.sort_by(|a, b| b.started_at.cmp(&a.started_at));
    runs
}

fn settings_path(dir: &Path, id: &str) -> PathBuf {
    dir.join(format!("{id}.settings.json"))
}

/// A new run id: 32 hex digits in the UUID's 8-4-4-4-12 form, lowercase (the Mac's `UUID().uuidString.lowercased()`).
pub fn new_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    let nanos = Utc::now().timestamp_nanos_opt().unwrap_or(0);
    let mut parts = [0u64; 2];
    for (index, part) in parts.iter_mut().enumerate() {
        let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
        hasher.write_i64(nanos);
        hasher.write_u32(std::process::id());
        hasher.write_usize(index);
        *part = hasher.finish();
    }
    // Version 4, variant 10, so Claude takes it as a UUID.
    let a = parts[0];
    let b = (parts[1] & 0x3fff_ffff_ffff_ffff) | 0x8000_0000_0000_0000;
    let hex = format!("{:016x}{:016x}", (a & 0xffff_ffff_ffff_0fff) | 0x0000_0000_0000_4000, b);
    format!("{}-{}-{}-{}-{}", &hex[0..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..32])
}

// MARK: - Rules

const GIT_ALLOW: &[&str] = &[
    "git status", "git status *", "git diff", "git diff *", "git log *", "git show *", "git branch", "git branch *",
    "git rev-parse *", "git ls-files *", "git merge-base *", "git remote -v", "git stash list", "git add *",
    "git commit *", "git mv *", "git rm *", "git checkout -b *", "git switch *", "git fetch", "git fetch *",
    "git push origin *", "git push -u origin *", "git push --set-upstream origin *",
    "gh pr create *", "gh pr view *", "gh pr view", "gh pr list *", "gh pr list", "gh pr checks *", "gh pr status",
];

const TOOLS: &[&str] = &[
    "npm", "pnpm", "npx", "yarn", "bun", "bunx", "node", "tsc", "mvn", "./mvnw", "gradle", "./gradlew", "xcodebuild",
    "xcodegen", "xcrun", "swift", "expo", "pytest", "python3 -m pytest", "python -m pytest", "make", "./scripts/*",
    "scripts/*",
];

/// Windows only: what its projects build with, under the names PowerShell runs them by.
const WINDOWS_TOOLS: &[&str] = &["cargo", "py -m pytest", "dotnet", r".\mvnw", r".\gradlew", r".\scripts\*", "npm.cmd", "npx.cmd"];

const COMMAND_DENY: &[&str] = &[
    "git push", "git push origin", "git push -u origin", "git push --set-upstream origin",
    "git push * main", "git push * main *", "git push *:main", "git push *:main *",
    "git push * master", "git push * master *", "git push *:master", "git push *:master *",
    "git push *HEAD*", "git push *--force*", "git push * -f", "git push * -f *", "git push -f *", "git push *+*",
    "git push *--delete*", "git push * -d *", "git push *--mirror*", "git push *--all*",
    "git reset --hard*", "git reset * --hard*", "git clean *", "git checkout -- *",
    "git branch -D *", "git branch -d *", "git branch --delete *",
    "gh pr merge*", "gh repo delete*", "gh api *", "sudo", "sudo *", "rm *",
    "*.env*", "*.pem*", "*id_rsa*", "*id_ed25519*", "*_daily-report/config.json*",
    "env", "env *", "printenv*", "security *",
];

/// PowerShell's own ways to delete, download, run strings and read the environment.
const POWERSHELL_DENY: &[&str] = &[
    "Remove-Item*", "ri *", "del *", "erase *", "rd *", "rmdir *", "Clear-Content*", "Clear-Item*",
    "Invoke-WebRequest*", "iwr *", "Invoke-RestMethod*", "irm *", "curl *", "wget *", "Start-BitsTransfer*",
    "Invoke-Expression*", "iex *", "Start-Process*", "saps *", "*env:*", "Get-ChildItem Env*", "Get-Item Env*",
    "*Get-Credential*", "*ConvertFrom-SecureString*", "*_daily-report\\config.json*",
];

const READ_DENY: &[&str] = &[
    "Read(**/.env)", "Read(**/.env.*)", "Read(**/*.pem)", "Read(**/*.key)", "Read(**/*.p12)", "Read(~/.ssh/**)",
    "Read(~/.aws/**)", "Read(~/.config/gh/**)", "Read(~/.claude.json)", "Read(**/_daily-report/config.json)",
];

/// The rules of a background run (the Mac's `BackgroundPermissions` for the «код» profile), with PowerShell's on
/// Windows.
pub fn rules(windows: bool) -> (Vec<String>, Vec<String>) {
    let shells: &[&str] = if windows { &["Bash", "PowerShell"] } else { &["Bash"] };
    let mut allow: Vec<String> = ["Read", "Glob", "Grep", "Edit(./**)", "TodoWrite"].map(String::from).to_vec();
    let mut deny: Vec<String> = Vec::new();
    for shell in shells {
        allow.extend(GIT_ALLOW.iter().map(|c| format!("{shell}({c})")));
        let tools = TOOLS.iter().chain(if windows { WINDOWS_TOOLS } else { &[] });
        for tool in tools {
            allow.push(format!("{shell}({tool} *)"));
            if !tool.contains('*') {
                allow.push(format!("{shell}({tool})"));
            }
        }
        deny.extend(COMMAND_DENY.iter().map(|c| format!("{shell}({c})")));
    }
    deny.extend(READ_DENY.iter().map(|r| (*r).to_owned()));
    if windows {
        deny.extend(POWERSHELL_DENY.iter().map(|c| format!("PowerShell({c})")));
    }
    (allow, deny)
}

pub fn settings_json(windows: bool) -> Value {
    let (allow, deny) = rules(windows);
    json!({"permissions": {"allow": allow, "deny": deny, "blockReadsOutsideWorkingDirectories": true}})
}

/// `claude`'s arguments; the rules are in `settings_file`.
pub fn arguments(prompt: &str, session_id: &str, settings_file: &Path) -> Vec<String> {
    [
        "-p", prompt, "--session-id", session_id, "--output-format", "stream-json", "--verbose", "--permission-mode",
        "dontAsk", "--permission-prompts", "none", "--settings",
    ]
    .iter()
    .map(|a| (*a).to_owned())
    .chain([settings_file.to_string_lossy().into_owned()])
    .collect()
}

// MARK: - Start and stop

pub struct NewRun<'a> {
    pub project: &'a str,
    pub project_path: &'a Path,
    pub folder: &'a Path,
    pub worktree_branch: Option<&'a str>,
    pub command_title: &'a str,
    pub task: &'a str,
    pub prompt: &'a str,
    pub time_limit_minutes: u32,
}

/// Starts `claude -p` in the folder with no window, its output into the log; the run is saved before it returns.
pub fn start(dir: &Path, claude: &Path, new: &NewRun) -> io::Result<(Run, Child)> {
    std::fs::create_dir_all(dir)?;
    let id = new_id();
    let settings = settings_path(dir, &id);
    std::fs::write(&settings, serde_json::to_string_pretty(&settings_json(cfg!(windows))).map_err(io::Error::other)?)?;
    let mut run = Run {
        id: id.clone(),
        project: new.project.to_owned(),
        project_path: new.project_path.to_string_lossy().into_owned(),
        folder: new.folder.to_string_lossy().into_owned(),
        worktree_branch: new.worktree_branch.map(str::to_owned),
        command_title: new.command_title.to_owned(),
        task: new.task.to_owned(),
        started_at: Utc::now(),
        time_limit_minutes: new.time_limit_minutes,
        pid: None,
        state: RunState::Running,
        finished_at: None,
        summary: None,
        pull_request_url: None,
        notified: false,
        prompt: Some(new.prompt.to_owned()),
        other: serde_json::Map::new(),
    };
    let log = File::create(run.log_path(dir))?;
    let mut process = command::command(claude);
    process.args(arguments(new.prompt, &id, &settings)).current_dir(new.folder);
    process.stdin(Stdio::null()).stdout(log.try_clone()?).stderr(log);
    let child = process.spawn()?;
    run.pid = Some(child.id());
    save(dir, &run)?;
    Ok((run, child))
}

/// Ends a run's process and everything it started (its tools): `taskkill /T /F` on Windows, SIGTERM elsewhere (Claude
/// runs its SessionEnd hooks then; `force` follows with SIGKILL).
pub fn kill(pid: u32, force: bool) {
    #[cfg(windows)]
    {
        let _ = force;
        let mut taskkill = command::command(Path::new("taskkill.exe"));
        taskkill.args(["/PID", &pid.to_string(), "/T", "/F"]);
        let _ = command::run(taskkill, std::time::Duration::from_secs(15));
    }
    #[cfg(unix)]
    if let Ok(pid) = libc::pid_t::try_from(pid) {
        unsafe {
            libc::kill(pid, if force { libc::SIGKILL } else { libc::SIGTERM });
        }
    }
}

// MARK: - The result

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outcome {
    pub is_error: bool,
    pub subtype: Option<String>,
    pub result: Option<String>,
    pub denied_tools: Vec<String>,
}

/// The last `{"type":"result"}` event of a stream-json log; None when the run ended without one (killed, crashed).
pub fn outcome(log: &str) -> Option<Outcome> {
    log.lines().rev().filter(|l| l.contains("\"result\"")).find_map(|line| {
        let event: Value = serde_json::from_str(line.trim()).ok()?;
        (event.get("type")?.as_str()? == "result").then(|| Outcome {
            is_error: event.get("is_error").and_then(Value::as_bool).unwrap_or(true),
            subtype: event.get("subtype").and_then(Value::as_str).map(str::to_owned),
            result: event.get("result").and_then(Value::as_str).map(str::to_owned),
            denied_tools: event
                .get("permission_denials")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|d| d.get("tool_name")?.as_str().map(str::to_owned))
                .collect(),
        })
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryKind {
    Text,
    Tool,
    Result,
    Error,
}

/// Assistant text, tool calls and the result, for the log in the panel.
pub fn entries(log: &str) -> Vec<(EntryKind, String)> {
    let mut entries = Vec::new();
    for line in log.lines() {
        let Ok(event) = serde_json::from_str::<Value>(line.trim()) else { continue };
        match event.get("type").and_then(Value::as_str) {
            Some("assistant") => {
                for block in event.pointer("/message/content").and_then(Value::as_array).into_iter().flatten() {
                    match block.get("type").and_then(Value::as_str) {
                        Some("text") => {
                            if let Some(text) = block.get("text").and_then(Value::as_str).filter(|t| !t.is_empty()) {
                                entries.push((EntryKind::Text, text.to_owned()));
                            }
                        }
                        Some("tool_use") => {
                            let name = block.get("name").and_then(Value::as_str).unwrap_or("tool");
                            let input = block.get("input");
                            let detail = ["command", "file_path", "pattern", "description"]
                                .iter()
                                .find_map(|key| input.and_then(|i| i.get(*key)).and_then(Value::as_str));
                            entries.push((EntryKind::Tool, detail.map_or_else(|| name.to_owned(), |d| format!("{name}: {d}"))));
                        }
                        _ => {}
                    }
                }
            }
            Some("result") => {
                let is_error = event.get("is_error").and_then(Value::as_bool).unwrap_or(false);
                let text = event.get("result").or_else(|| event.get("subtype")).and_then(Value::as_str).unwrap_or("");
                entries.push((if is_error { EntryKind::Error } else { EntryKind::Result }, text.to_owned()));
            }
            _ => {}
        }
    }
    entries
}

/// The first 1–3 lines of the result that say something, at most 300 characters.
pub fn summary(result: Option<&str>) -> Option<String> {
    let lines: Vec<&str> = result?
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.chars().all(|c| "-=#*_`".contains(c)))
        .take(3)
        .collect();
    if lines.is_empty() {
        return None;
    }
    let text = lines.join("\n");
    Some(if text.chars().count() > 300 { text.chars().take(299).collect::<String>() + "…" } else { text })
}

/// The last GitHub pull request link in the text.
pub fn pull_request_url(text: Option<&str>) -> Option<String> {
    let text = text?;
    let mut found = None;
    let mut rest = text;
    while let Some(at) = rest.find("https://github.com/") {
        let candidate = &rest[at..];
        let end = candidate.find(|c: char| !(c.is_ascii_alphanumeric() || "/_.-:".contains(c))).unwrap_or(candidate.len());
        let url = &candidate[..end];
        let parts: Vec<&str> = url.trim_start_matches("https://github.com/").split('/').collect();
        let number: String = parts.get(3).map(|p| p.chars().take_while(char::is_ascii_digit).collect()).unwrap_or_default();
        if parts.len() >= 4 && parts[2] == "pull" && !parts[0].is_empty() && !parts[1].is_empty() && !number.is_empty() {
            found = Some(format!("https://github.com/{}/{}/pull/{number}", parts[0], parts[1]));
        }
        rest = &candidate[end.max(1)..];
    }
    found
}

/// The words a finished run needs (from the String Catalog, in the app's language).
pub struct FinishTexts {
    pub no_result: String,
    /// «Отклонено правилами фона: %@» with the list filled in.
    pub denied: Box<dyn Fn(&str) -> String>,
}

/// The run as it ended: its state (a stop reason wins), summary, denied tools and PR link.
pub fn finish(run: &mut Run, log: &str, stopped: Option<RunState>, texts: &FinishTexts, now: DateTime<Utc>) {
    let outcome = outcome(log);
    run.state = stopped.unwrap_or(match &outcome {
        Some(o) if !o.is_error => RunState::Succeeded,
        _ => RunState::Failed,
    });
    run.finished_at = Some(now);
    let result = outcome.as_ref().and_then(|o| o.result.as_deref());
    run.summary = summary(result).or_else(|| (outcome.is_none() && run.state == RunState::Failed).then(|| texts.no_result.clone()));
    if let Some(outcome) = &outcome {
        let mut denied = outcome.denied_tools.clone();
        denied.sort();
        denied.dedup();
        if !denied.is_empty() {
            let line = (texts.denied)(&denied.join(", "));
            run.summary = Some(match run.summary.take() {
                Some(summary) => format!("{summary}\n{line}"),
                None => line,
            });
        }
    }
    run.pull_request_url = pull_request_url(result);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Shapes from a real `claude -p --output-format stream-json --verbose` run (the Mac's test log).
    const LOG: &str = r#"{"type":"system","subtype":"hook_started","hook_event":"SessionStart","session_id":"s"}
{"type":"system","subtype":"init","cwd":"/tmp/p","permissionMode":"dontAsk","session_id":"s"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Создаю ветку."},{"type":"tool_use","name":"Bash","input":{"command":"git checkout -b feat/x"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/p/a.swift"}}]}}
not json at all
{"type":"result","subtype":"success","is_error":false,"result":"Готово: добавил экспорт.\n\nPR: https://github.com/OlehDemishev/Ambo/pull/23\nПроверки зелёные.\nЕщё строка.","session_id":"s","permission_denials":[{"tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"git push origin main"}},{"tool_name":"Bash"}]}
"#;

    fn texts() -> FinishTexts {
        FinishTexts { no_result: "Claude завершился без результата — см. журнал".into(), denied: Box::new(|list| format!("Отклонено правилами фона: {list}")) }
    }

    fn run() -> Run {
        serde_json::from_str(
            r#"{"id":"r1","project":"Ambo","projectPath":"/P/Ambo","folder":"/P/Ambo","commandTitle":"Своя задача","task":"Экспорт",
                "startedAt":"2026-11-18T10:00:00Z","timeLimitMinutes":90,"pid":42,"state":"running","notified":false,
                "agent":"codex","pausedSeconds":3.5}"#,
        )
        .unwrap()
    }

    #[test]
    fn reads_and_writes_the_macs_files() {
        let run = run();
        assert_eq!(run.deadline(), "2026-11-18T11:30:00Z".parse::<DateTime<Utc>>().unwrap());
        let written = serde_json::to_value(&run).unwrap();
        assert_eq!(written["startedAt"], "2026-11-18T10:00:00Z");
        assert_eq!(written["agent"], "codex", "fields of the Mac this version doesn't use stay");
        assert!(written.get("finishedAt").is_none());
        let dir = std::env::temp_dir().join(format!("claudepult-runs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        save(&dir, &run).unwrap();
        let mut old = run.clone();
        old.id = "old".into();
        old.finished_at = Some(Utc::now() - chrono::Duration::days(31));
        save(&dir, &old).unwrap();
        std::fs::write(old.log_path(&dir), "x").unwrap();
        std::fs::write(settings_path(&dir, "r1"), "{}").unwrap();
        assert_eq!(load(&dir, Utc::now()), [run], "the month-old run goes with its log; settings files aren't runs");
        assert!(!old.log_path(&dir).exists());
        std::fs::remove_dir_all(dir).unwrap();
        let id = new_id();
        assert_eq!((id.len(), &id[14..15]), (36, "4"));
        assert_ne!(id, new_id());
    }

    #[test]
    fn results() {
        let outcome = outcome(LOG).unwrap();
        assert!(!outcome.is_error);
        assert_eq!(outcome.denied_tools, ["Bash", "Bash"]);
        assert_eq!(pull_request_url(outcome.result.as_deref()).as_deref(), Some("https://github.com/OlehDemishev/Ambo/pull/23"));
        assert_eq!(summary(outcome.result.as_deref()).as_deref(), Some("Готово: добавил экспорт.\nPR: https://github.com/OlehDemishev/Ambo/pull/23\nПроверки зелёные."));
        assert_eq!(super::outcome("{\"type\":\"system\"}\n"), None);
        let error = super::outcome(r#"{"type":"result","subtype":"error_max_turns","is_error":true}"#).unwrap();
        assert!(error.is_error && error.result.is_none());
        assert_eq!(summary(Some("\n\n---\n")), None);
        assert_eq!(summary(Some(&"я".repeat(500))).unwrap().chars().count(), 300);
        assert_eq!(pull_request_url(Some("see https://github.com/o/r/pull/1 and https://github.com/o/r/pull/22.")).as_deref(), Some("https://github.com/o/r/pull/22"));
        assert_eq!(pull_request_url(Some("https://github.com/o/r/issues/3")), None);
        let kinds: Vec<EntryKind> = entries(LOG).into_iter().map(|e| e.0).collect();
        assert_eq!(kinds, [EntryKind::Text, EntryKind::Tool, EntryKind::Tool, EntryKind::Result]);
        assert_eq!(entries(LOG)[1].1, "Bash: git checkout -b feat/x");
    }

    #[test]
    fn finishing() {
        let now = Utc::now();
        let mut done = run();
        finish(&mut done, LOG, None, &texts(), now);
        assert_eq!(done.state, RunState::Succeeded);
        assert!(done.summary.as_deref().unwrap().ends_with("\nОтклонено правилами фона: Bash"));
        assert_eq!(done.pull_request_url.as_deref(), Some("https://github.com/OlehDemishev/Ambo/pull/23"));
        let mut killed = run();
        finish(&mut killed, "{\"type\":\"system\"}", None, &texts(), now);
        assert_eq!((killed.state, killed.summary.as_deref()), (RunState::Failed, Some("Claude завершился без результата — см. журнал")));
        let mut stopped = run();
        finish(&mut stopped, "", Some(RunState::TimedOut), &texts(), now);
        assert_eq!((stopped.state, stopped.summary), (RunState::TimedOut, None));
    }

    #[test]
    fn rules_per_system() {
        let (allow, deny) = rules(false);
        assert!(allow.contains(&"Bash(git push origin *)".to_owned()) && allow.contains(&"Bash(npm)".to_owned()));
        assert!(!allow.iter().any(|r| r.starts_with("PowerShell")));
        assert!(deny.contains(&"Bash(git push * main)".to_owned()) && deny.contains(&"Read(~/.ssh/**)".to_owned()));
        let (allow, deny) = rules(true);
        assert!(allow.contains(&"PowerShell(git commit *)".to_owned()) && allow.contains(&"PowerShell(cargo *)".to_owned()));
        for rule in ["PowerShell(git push * main)", "PowerShell(rm *)", "PowerShell(Remove-Item*)", "PowerShell(*env:*)", "PowerShell(iex *)"] {
            assert!(deny.contains(&rule.to_owned()), "{rule}");
        }
        let args = arguments("do it", "id", Path::new("/r/id.settings.json"));
        assert_eq!(args.last().unwrap(), "/r/id.settings.json");
        assert_eq!(&args[..4], ["-p", "do it", "--session-id", "id"]);
    }

    /// A stand-in for Claude that writes a stream-json result: the run starts with no window, its log fills, it ends.
    #[test]
    fn starts_a_run() {
        let dir = std::env::temp_dir().join(format!("claudepult-run-start-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let fake = if cfg!(windows) { dir.join("claude.cmd") } else { dir.join("claude") };
        let body = if cfg!(windows) {
            "@echo {\"type\":\"result\",\"is_error\":false,\"result\":\"ok https://github.com/o/r/pull/5\"}\r\n"
        } else {
            "#!/bin/sh\necho '{\"type\":\"result\",\"is_error\":false,\"result\":\"ok https://github.com/o/r/pull/5\"}'\n"
        };
        std::fs::write(&fake, body).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let runs = dir.join("runs");
        let new = NewRun {
            project: "Shop", project_path: &dir, folder: &dir, worktree_branch: None, command_title: "Своя задача",
            task: "Do it", prompt: "Задача: «it's done» & more", time_limit_minutes: 5,
        };
        let (mut run, mut child) = start(&runs, &fake, &new).unwrap();
        assert!(child.wait().unwrap().success());
        let log = std::fs::read_to_string(run.log_path(&runs)).unwrap();
        finish(&mut run, &log, None, &texts(), Utc::now());
        assert_eq!(run.state, RunState::Succeeded, "{log}");
        assert_eq!(run.pull_request_url.as_deref(), Some("https://github.com/o/r/pull/5"));
        assert_eq!(load(&runs, Utc::now()).len(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
