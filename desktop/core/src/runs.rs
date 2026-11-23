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
    /// The file a folder project's command writes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result_file: Option<String>,
    /// Fields of the Mac's runs this version doesn't use (Codex, pauses, pairs), written back unchanged.
    #[serde(flatten)]
    pub other: serde_json::Map<String, Value>,
}

/// Swift's `.iso8601`: whole seconds and `Z`.
pub(crate) mod iso {
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

    /// When the time limit runs out; time spent paused by the limit guard doesn't count toward it.
    pub fn deadline(&self, now: DateTime<Utc>) -> DateTime<Utc> {
        let earlier = self.other.get("pausedSeconds").and_then(Value::as_f64).unwrap_or(0.0);
        let this_pause = self.paused_at().map_or(0.0, |at| (now - at).num_milliseconds().max(0) as f64 / 1000.0);
        self.started_at + chrono::Duration::minutes(i64::from(self.time_limit_minutes)) + chrono::Duration::milliseconds(((earlier + this_pause) * 1000.0) as i64)
    }

    /// Since when the limit guard holds the run (the Mac's `pausedAt`).
    pub fn paused_at(&self) -> Option<DateTime<Utc>> {
        self.other.get("pausedAt").and_then(Value::as_str).and_then(|text| DateTime::parse_from_rfc3339(text).ok()).map(|at| at.with_timezone(&Utc))
    }

    pub fn is_paused(&self) -> bool {
        self.is_running() && self.paused_at().is_some()
    }

    pub fn mark_paused(&mut self, now: DateTime<Utc>) {
        self.other.insert("pausedAt".into(), Value::String(now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)));
    }

    /// The pause is over: its length joins `pausedSeconds`.
    pub fn mark_resumed(&mut self, now: DateTime<Utc>) {
        let Some(at) = self.paused_at() else { return };
        let earlier = self.other.get("pausedSeconds").and_then(Value::as_f64).unwrap_or(0.0);
        self.other.insert("pausedSeconds".into(), serde_json::json!(earlier + (now - at).num_milliseconds().max(0) as f64 / 1000.0));
        self.other.remove("pausedAt");
    }

    /// Run by Codex (`codex exec`), as the Mac's `BackgroundRun.agent == "codex"`.
    pub fn is_codex(&self) -> bool {
        self.other.get("agent").and_then(Value::as_str) == Some(codex::AGENT)
    }

    /// «Codex» or «Claude Code»: who does the run.
    pub fn agent_title(&self) -> &'static str {
        if self.is_codex() { "Codex" } else { "Claude Code" }
    }

    /// The run this one reviews (the Mac's `reviewOf`).
    pub fn review_of(&self) -> Option<&str> {
        self.other.get("reviewOf").and_then(Value::as_str)
    }

    fn has_prompt(&self) -> bool {
        self.prompt.as_deref().is_some_and(|prompt| !prompt.is_empty())
    }

    /// «Передать Codex» (the Mac's `Handover`): a Claude run that has not finished well and whose task was kept.
    pub fn can_hand_over(&self) -> bool {
        !self.is_codex() && self.other.get("agent").is_none() && self.has_prompt() && (self.is_paused() || matches!(self.state, RunState::Failed | RunState::Stopped))
    }

    /// «Проверить в …» (the Mac's `CrossReview`): a finished run can be reviewed once; a review is not reviewed
    /// again.
    pub fn can_review(&self, all: &[Run]) -> bool {
        self.state == RunState::Succeeded && self.review_of().is_none() && self.has_prompt() && !all.iter().any(|run| run.review_of() == Some(self.id.as_str()) && run.state != RunState::Failed)
    }

    /// Who reads: the service that did not write. True — Codex.
    pub fn reviewer_is_codex(&self) -> bool {
        !self.is_codex()
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

/// The Mac's `PermissionProfile`s: `code` — git, builds, PRs (`rules`); `filesOnly` — read, search and write inside
/// the project folder, no shell and no network; `filesAndWeb` — that plus web search and page fetching. The shells are
/// denied by name (`Bash`, and `PowerShell` on Windows); secrets stay unreadable in every profile.
pub fn profile_rules(permissions: &str, windows: bool) -> (Vec<String>, Vec<String>) {
    if permissions == REVIEW {
        return review_rules(windows);
    }
    let web = match permissions {
        "filesOnly" => false,
        "filesAndWeb" => true,
        _ => return rules(windows),
    };
    let mut allow: Vec<String> = ["Read", "Glob", "Grep", "Edit(./**)", "TodoWrite"].map(String::from).to_vec();
    let mut deny: Vec<String> = vec!["Bash".into()];
    if windows {
        deny.push("PowerShell".into());
    }
    if web {
        allow.extend(["WebSearch".into(), "WebFetch".into()]);
    } else {
        deny.extend(["WebFetch".into(), "WebSearch".into()]);
    }
    deny.push("NotebookEdit".into());
    deny.extend(READ_DENY.iter().map(|r| (*r).to_owned()));
    (allow, deny)
}

/// The permissions of a review of someone else's work.
pub const REVIEW: &str = "review";

const REVIEW_GIT: &[&str] = &[
    "git status", "git status *", "git diff", "git diff *", "git log *", "git log", "git show *", "git branch", "git branch *",
    "git rev-parse *", "git ls-files *", "git merge-base *",
];

/// A review (the Mac's `BackgroundPermissions.reviewRules`): read files and git history, change nothing, no network.
pub fn review_rules(windows: bool) -> (Vec<String>, Vec<String>) {
    let shells: &[&str] = if windows { &["Bash", "PowerShell"] } else { &["Bash"] };
    let mut allow: Vec<String> = ["Read", "Glob", "Grep", "TodoWrite"].map(String::from).to_vec();
    for shell in shells {
        allow.extend(REVIEW_GIT.iter().map(|c| format!("{shell}({c})")));
    }
    let mut deny: Vec<String> = ["Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch"].map(String::from).to_vec();
    deny.extend(rules(windows).1);
    (allow, deny)
}

pub fn settings_json(permissions: &str, windows: bool) -> Value {
    let (allow, deny) = profile_rules(permissions, windows);
    json!({"permissions": {"allow": allow, "deny": deny, "blockReadsOutsideWorkingDirectories": true}})
}

/// What a run is told about folders, in Claude's own language of instructions (it is not shown to the person). Seen
/// live on Windows with Claude Code 2.1: in `dontAsk` a call that changes folder and runs a build in one line is
/// refused whatever the rules allow, in both shells; Claude tried that form twice and gave up. A change of folder in a
/// call of its own passes in PowerShell and stays for the next call; the tools' own folder options pass everywhere.
pub const FOLDER_NOTE: &str = "Shell calls here are checked against a fixed list of allowed commands, and nobody can approve a refused one. \
    A call that changes folder and runs a command in one line is refused: do not join cd or Set-Location with another command. \
    To work in a subfolder, use the tool's own folder option (cargo test --manifest-path sub/Cargo.toml, npm --prefix sub test, git -C sub status), or change folder in a call of its own (in PowerShell: Set-Location sub) and run the command in the next call. \
    If one form is refused, try the other before reporting that the command could not be run.";

/// `claude`'s arguments; the rules are in `settings_file`.
pub fn arguments(prompt: &str, session_id: &str, settings_file: &Path) -> Vec<String> {
    [
        "-p", prompt, "--session-id", session_id, "--output-format", "stream-json", "--verbose", "--permission-mode",
        "dontAsk", "--permission-prompts", "none", "--append-system-prompt", FOLDER_NOTE, "--settings",
    ]
    .iter()
    .map(|a| (*a).to_owned())
    .chain([settings_file.to_string_lossy().into_owned()])
    .collect()
}

/// What the next agent is asked when a task is handed over at a limit. English: it is read by the agent, and both
/// Claude and Codex take it. The other agent is told that work may already be there, so it reads the folder before
/// it writes.
pub fn handover_prompt(task: &str, from: &str) -> String {
    format!(
        "Another agent ({from}) started this task in this folder and stopped at its usage limit. Before changing anything, \
         look at what is already done: run `git status`, `git diff` and `git log -5 --oneline`. Keep that work and \
         finish the task; do not start over.\n\nThe task:\n{task}"
    )
}

/// What the reviewing agent is asked; the answer comes in the task's language.
pub fn review_prompt(task: &str, author: &str) -> String {
    format!(
        "Review the work another agent ({author}) did in this folder. Do not change, create or delete any file and do \
         not commit: only read. Look at `git status`, `git diff` for uncommitted changes, and the branch's own commits \
         (`git log --oneline -15`, then `git show` or a diff against the branch it started from).\n\n\
         Check against the task below: does the change do what was asked, are there bugs, broken edge cases, missing \
         tests, leftovers or unrelated edits? Start your answer with one line — «OK» if nothing must be fixed, else \
         «Fix: N» with the number of problems. Then list the problems, most serious first, each with file and line and \
         one sentence on what is wrong. Be brief; no praise. Answer in the language of the task.\n\nThe task:\n{task}"
    )
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
    /// `code`, `filesOnly` or `filesAndWeb` (`profile_rules`).
    pub permissions: &'a str,
    /// A folder project's command: the file Claude is to write; the run fails without it.
    pub result_file: Option<&'a Path>,
    /// Run by Codex (`codex exec` in its `workspace-write` sandbox) instead of Claude; `program` is then codex.
    pub codex: bool,
    /// A review: the run it reads (the Mac's `reviewOf`). Codex then gets its `read-only` sandbox; Claude's
    /// `permissions` are `REVIEW`.
    pub review_of: Option<&'a str>,
}

/// Starts `claude -p` (or `codex exec`) in the folder with no window, its output into the log; the run is saved before
/// it returns.
pub fn start(dir: &Path, program: &Path, new: &NewRun) -> io::Result<(Run, Child)> {
    std::fs::create_dir_all(dir)?;
    let id = new_id();
    let settings = settings_path(dir, &id);
    if !new.codex {
        std::fs::write(&settings, serde_json::to_string_pretty(&settings_json(new.permissions, cfg!(windows))).map_err(io::Error::other)?)?;
    }
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
        result_file: new.result_file.map(|f| f.to_string_lossy().into_owned()),
        other: serde_json::Map::new(),
    };
    if new.codex {
        run.other.insert("agent".into(), json!(codex::AGENT));
    }
    if let Some(reviewed) = new.review_of {
        run.other.insert("reviewOf".into(), json!(reviewed));
    }
    let log = File::create(run.log_path(dir))?;
    let mut process = command::command(program);
    let args = if new.codex { codex::arguments(new.prompt, codex::git_directory(new.folder).as_deref(), new.review_of.is_some()) } else { arguments(new.prompt, &id, &settings) };
    process.args(args).current_dir(new.folder);
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

// MARK: - Codex (the Mac's `CodexExec`)

/// A background Codex run: `codex exec --json`. Events are JSON lines: `thread.started {thread_id}`,
/// `item.completed {item: {type: agent_message | command_execution | file_change}}`, then `turn.completed`, or
/// `turn.failed {error: {message}}` / `error {message}`. `exec` never asks. `workspace-write` lets it write in the
/// working folder only; on a Mac and Linux it also keeps the network off, while Codex's own Windows sandbox depends on
/// how Codex is set up there (elevated or not), so this app promises nothing about the network on Windows. The
/// repository's git folder goes in `--add-dir`, or `git commit` fails on its read-only `.git`.
pub mod codex {
    use super::{EntryKind, Outcome};
    use serde_json::Value;
    use std::path::{Path, PathBuf};

    pub const AGENT: &str = "codex";

    /// `read_only` — a review: the `read-only` sandbox, nothing in the folder changes.
    pub fn arguments(prompt: &str, git_directory: Option<&Path>, read_only: bool) -> Vec<String> {
        let mut args = vec!["exec".to_owned(), "--sandbox".to_owned(), if read_only { "read-only" } else { "workspace-write" }.to_owned()];
        if let Some(git) = git_directory.filter(|_| !read_only) {
            args.extend(["--add-dir".to_owned(), git.to_string_lossy().into_owned()]);
        }
        args.extend(["--json".to_owned(), "--skip-git-repo-check".to_owned(), prompt.to_owned()]);
        args
    }

    /// The git folder a commit in `folder` writes to: its `.git`, or for a worktree (`gitdir: <repo>/.git/worktrees/<n>`)
    /// the repository's. None outside a repository.
    pub fn git_directory(folder: &Path) -> Option<PathBuf> {
        let dot_git = folder.join(".git");
        if dot_git.is_dir() {
            return Some(dot_git);
        }
        let text = std::fs::read_to_string(&dot_git).ok()?;
        let line = text.lines().find_map(|l| l.strip_prefix("gitdir:"))?.trim();
        let path = if Path::new(line).is_absolute() { PathBuf::from(line) } else { folder.join(line) };
        let normal = path.to_string_lossy().replace('\\', "/");
        match normal.rfind("/worktrees/") {
            Some(at) => Some(PathBuf::from(&normal[..at])),
            None => Some(path),
        }
    }

    pub fn thread_id(log: &str) -> Option<String> {
        log.lines().take(20).find_map(|line| {
            let event: Value = serde_json::from_str(line.trim()).ok()?;
            (event["type"] == "thread.started").then(|| event["thread_id"].as_str().map(str::to_owned)).flatten()
        })
    }

    fn error_text(event: &Value) -> String {
        event["error"]["message"].as_str().or_else(|| event["message"].as_str()).unwrap_or("error").to_owned()
    }

    /// The turn's end: its last message as the result, or the error; None for a log that isn't Codex's or has no end.
    pub fn outcome(log: &str) -> Option<Outcome> {
        let mut message = None;
        let mut outcome = None;
        for line in log.lines().filter(|l| l.contains("\"type\"")) {
            let Ok(event) = serde_json::from_str::<Value>(line.trim()) else { continue };
            match event["type"].as_str() {
                Some("item.completed") if event["item"]["type"] == "agent_message" => {
                    message = event["item"]["text"].as_str().map(plain_file_links);
                }
                Some("turn.completed") => outcome = Some(Outcome { is_error: false, subtype: Some("turn.completed".into()), result: message.clone(), denied_tools: Vec::new() }),
                // `error` also comes before a retry: a later `turn.completed` replaces it.
                Some(kind @ ("turn.failed" | "error")) => outcome = Some(Outcome { is_error: true, subtype: Some(kind.into()), result: Some(error_text(&event)), denied_tools: Vec::new() }),
                _ => {}
            }
        }
        outcome
    }

    /// A readable line of the run's log, or None for events that say nothing to a person.
    pub fn entry(event: &Value) -> Option<(EntryKind, String)> {
        match event["type"].as_str()? {
            "item.completed" => {
                let item = &event["item"];
                match item["type"].as_str()? {
                    "agent_message" => item["text"].as_str().filter(|t| !t.is_empty()).map(|t| (EntryKind::Text, plain_file_links(t))),
                    "command_execution" => Some((EntryKind::Tool, format!("Bash: {}", shell_command(item["command"].as_str().unwrap_or_default())))),
                    "file_change" => {
                        let names: Vec<String> = item["changes"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(|c| c["path"].as_str())
                            .map(|p| p.rsplit(['/', '\\']).next().unwrap_or(p).to_owned())
                            .collect();
                        Some((EntryKind::Tool, format!("Edit: {}", names.join(", "))))
                    }
                    _ => None,
                }
            }
            "turn.failed" | "error" => Some((EntryKind::Error, error_text(event))),
            _ => None,
        }
    }

    /// `[NOTES.md](/Users/me/p/NOTES.md)` or `[NOTES.md](C:\\p\\NOTES.md)` → `NOTES.md`: Codex links the files it names
    /// by their full path, which a notification would show raw. Links to the web stay.
    pub fn plain_file_links(text: &str) -> String {
        if !text.contains("](") {
            return text.to_owned();
        }
        let mut out = String::new();
        let mut rest = text;
        while let Some(open) = rest.find('[') {
            out.push_str(&rest[..open]);
            let tail = &rest[open..];
            let replaced = tail.find("](").and_then(|mid| {
                let label = &tail[1..mid];
                if label.contains('\n') || label.contains(']') {
                    return None;
                }
                let target = &tail[mid + 2..];
                let end = target.find(')')?;
                let link = &target[..end];
                let local = link.starts_with('/') || link.starts_with("~/") || link.starts_with("file:") || link.get(1..3).is_some_and(|d| d == ":\\" || d == ":/");
                (local && !link.contains('\n')).then(|| (label.to_owned(), mid + 2 + end + 1))
            });
            match replaced {
                Some((label, used)) => {
                    out.push_str(&label);
                    rest = &tail[used..];
                }
                None => {
                    out.push('[');
                    rest = &tail[1..];
                }
            }
        }
        out.push_str(rest);
        out
    }

    /// `/bin/zsh -lc "npm test"` → `npm test`; also PowerShell's `-Command "…"` on Windows.
    pub fn shell_command(command: &str) -> String {
        let Some((_, inner)) = command.split_once(" -lc ").or_else(|| command.split_once(" -Command ")) else { return command.to_owned() };
        let inner = inner.trim();
        let quoted = inner.len() >= 2 && (inner.starts_with('"') || inner.starts_with('\'')) && inner.ends_with(&inner[..1]);
        if quoted { inner[1..inner.len() - 1].to_owned() } else { inner.to_owned() }
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

/// The last `{"type":"result"}` event of a stream-json log, or a `codex exec` turn's end; None when the run ended
/// without one (killed, crashed).
pub fn outcome(log: &str) -> Option<Outcome> {
    codex::outcome(log).or_else(|| claude_outcome(log))
}

fn claude_outcome(log: &str) -> Option<Outcome> {
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
            Some("item.completed" | "turn.failed" | "error") => entries.extend(codex::entry(&event)),
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
    /// «Файл результата не появился: %@» with the file's name.
    pub no_result_file: Box<dyn Fn(&str) -> String>,
}

/// The run as it ended: its state (a stop reason wins), summary, denied tools and PR link.
pub fn finish(run: &mut Run, log: &str, stopped: Option<RunState>, texts: &FinishTexts, now: DateTime<Utc>) {
    if run.is_codex() && !run.other.contains_key("threadID") {
        if let Some(thread) = codex::thread_id(log) {
            run.other.insert("threadID".into(), json!(thread));
        }
    }
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
    if let Some(file) = run.result_file.as_deref().filter(|f| run.state == RunState::Succeeded && !Path::new(f).exists()) {
        let name = Path::new(file).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let line = (texts.no_result_file)(&name);
        run.summary = Some(match run.summary.take() {
            Some(summary) => format!("{summary}\n{line}"),
            None => line,
        });
    }
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
        FinishTexts {
            no_result: "Claude завершился без результата — см. журнал".into(),
            denied: Box::new(|list| format!("Отклонено правилами фона: {list}")),
            no_result_file: Box::new(|name| format!("Файл результата не появился: {name}")),
        }
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
        let at = |text: &str| text.parse::<DateTime<Utc>>().unwrap();
        assert_eq!(run.deadline(at("2026-11-18T10:10:00Z")), at("2026-11-18T11:30:03.5Z"), "the limit and the earlier pause");
        let mut paused = run.clone();
        assert!(!paused.is_paused());
        paused.mark_paused(at("2026-11-18T10:20:00Z"));
        assert!(paused.is_paused());
        assert_eq!(serde_json::to_value(&paused).unwrap()["pausedAt"], "2026-11-18T10:20:00Z", "the Mac's field");
        assert_eq!(paused.deadline(at("2026-11-18T10:50:00Z")), at("2026-11-18T12:00:03.5Z"), "the pause doesn't count toward the limit");
        paused.mark_resumed(at("2026-11-18T11:20:00Z"));
        assert!(!paused.is_paused() && paused.other.get("pausedAt").is_none());
        assert_eq!(paused.other["pausedSeconds"], 3603.5);
        assert_eq!(paused.deadline(at("2026-11-18T13:00:00Z")), at("2026-11-18T12:30:03.5Z"));
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
        // A command that was to write a file and didn't: said so, on top of Claude's summary.
        let mut missing = run();
        missing.result_file = Some(std::env::temp_dir().join("claudepult-no-such-result.md").to_string_lossy().into_owned());
        finish(&mut missing, LOG, None, &texts(), now);
        assert!(missing.summary.as_deref().unwrap().ends_with("\nФайл результата не появился: claudepult-no-such-result.md"));
    }

    #[test]
    fn a_review_only_reads() {
        let (allow, deny) = review_rules(true);
        assert!(allow.contains(&"Read".to_owned()) && allow.contains(&"Bash(git diff *)".to_owned()) && allow.contains(&"PowerShell(git log *)".to_owned()));
        assert!(!allow.iter().any(|rule| rule.starts_with("Edit") || rule.contains("git commit") || rule.contains("git add") || rule.contains("cargo")), "{allow:?}");
        for rule in ["Edit", "Write", "WebFetch", "Bash(rm *)", "Read(**/.env)"] {
            assert!(deny.contains(&rule.to_owned()), "{rule}");
        }
        assert!(!review_rules(false).0.iter().any(|rule| rule.starts_with("PowerShell")));
        assert_eq!(settings_json(REVIEW, false)["permissions"]["allow"].as_array().unwrap().len(), review_rules(false).0.len());
        assert!(review_prompt("Сделай экспорт", "Codex").ends_with("The task:\nСделай экспорт") && review_prompt("x", "Codex").contains("(Codex)"));
        assert!(handover_prompt("Сделай экспорт", "Claude Code").starts_with("Another agent (Claude Code) started this task"));
        assert!(!handover_prompt("x", "y").contains("  "), "the lines are joined with single spaces");
    }

    #[test]
    fn who_can_be_handed_over_and_reviewed() {
        let claude: Run = serde_json::from_str(
            r#"{"id":"c1","project":"Shop","projectPath":"/P/Shop","folder":"/P/Shop","commandTitle":"Своя задача","task":"Экспорт",
                "startedAt":"2026-11-18T10:00:00Z","timeLimitMinutes":90,"pid":42,"state":"running","notified":false,"prompt":"Do the export"}"#,
        )
        .unwrap();
        assert!(!claude.can_hand_over(), "it works");
        let mut paused = claude.clone();
        paused.mark_paused("2026-11-18T10:20:00Z".parse().unwrap());
        assert!(paused.can_hand_over());
        let with = |state: RunState| Run { state, ..claude.clone() };
        assert!(with(RunState::Failed).can_hand_over() && with(RunState::Stopped).can_hand_over());
        assert!(!with(RunState::Succeeded).can_hand_over() && !with(RunState::TimedOut).can_hand_over());
        assert!(!Run { prompt: None, ..with(RunState::Failed) }.can_hand_over(), "the task was not kept");
        let mut codex = with(RunState::Failed);
        codex.other.insert("agent".into(), json!("codex"));
        assert!(!codex.can_hand_over(), "Codex's own run");
        assert_eq!((codex.agent_title(), claude.agent_title()), ("Codex", "Claude Code"));

        let done = with(RunState::Succeeded);
        assert!(done.can_review(&[]) && done.reviewer_is_codex() && !claude.can_review(&[]));
        let mut review = Run { id: "r1".into(), state: RunState::Running, ..claude.clone() };
        review.other.insert("reviewOf".into(), json!("c1"));
        review.other.insert("agent".into(), json!("codex"));
        assert!(!done.can_review(&[review.clone()]), "being reviewed");
        assert!(!Run { state: RunState::Succeeded, ..review.clone() }.can_review(&[]), "a review is not reviewed");
        assert!(done.can_review(&[Run { state: RunState::Failed, ..review.clone() }]), "a failed review can be asked again");
        assert!(!review.reviewer_is_codex());
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
        // Folder projects' profiles: files only, no shell of either kind, the web only when asked for.
        let (allow, deny) = profile_rules("filesOnly", true);
        assert!(allow.contains(&"Edit(./**)".to_owned()) && !allow.iter().any(|r| r.starts_with("Bash") || r.starts_with("PowerShell")));
        for rule in ["Bash", "PowerShell", "WebFetch", "WebSearch", "NotebookEdit", "Read(**/.env)"] {
            assert!(deny.contains(&rule.to_owned()), "{rule}");
        }
        let (allow, deny) = profile_rules("filesAndWeb", false);
        assert!(allow.contains(&"WebSearch".to_owned()) && !deny.contains(&"WebFetch".to_owned()) && !deny.contains(&"PowerShell".to_owned()));
        assert_eq!(profile_rules("code", true), rules(true));
        assert_eq!(settings_json("filesOnly", false)["permissions"]["blockReadsOutsideWorkingDirectories"], true);
        let args = arguments("do it", "id", Path::new("/r/id.settings.json"));
        assert_eq!(args.last().unwrap(), "/r/id.settings.json");
        assert_eq!(&args[..4], ["-p", "do it", "--session-id", "id"]);
        let note = args.iter().position(|a| a == "--append-system-prompt").expect("the folder note is passed");
        assert_eq!(args[note + 1], FOLDER_NOTE);
        // The note goes through a command line, and `claude.cmd` through cmd.exe: nothing a shell would read.
        assert!(!FOLDER_NOTE.contains(['&', '|', ';', '`', '"', '%', '^', '<', '>', '\n']), "plain text only");
    }

    #[test]
    fn codex_runs() {
        assert_eq!(
            codex::arguments("Задача", Some(Path::new("/p/.git")), false),
            ["exec", "--sandbox", "workspace-write", "--add-dir", "/p/.git", "--json", "--skip-git-repo-check", "Задача"]
        );
        assert_eq!(codex::arguments("x", Some(Path::new("/p/.git")), true)[2], "read-only");
        assert!(!codex::arguments("x", Some(Path::new("/p/.git")), true).contains(&"--add-dir".to_owned()), "a review writes nowhere");

        let root = std::env::temp_dir().join(format!("claudepult-codex-git-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("repo/.git/worktrees/cb-x")).unwrap();
        std::fs::create_dir_all(root.join("repo/.claude/worktrees/cb-x")).unwrap();
        let worktree = root.join("repo/.claude/worktrees/cb-x");
        std::fs::write(worktree.join(".git"), format!("gitdir: {}\n", root.join("repo/.git/worktrees/cb-x").display())).unwrap();
        let found = codex::git_directory(&worktree).unwrap();
        assert_eq!(found.to_string_lossy().replace('\\', "/"), root.join("repo/.git").to_string_lossy().replace('\\', "/"));
        assert_eq!(codex::git_directory(&root.join("repo")), Some(root.join("repo/.git")));
        assert_eq!(codex::git_directory(&root), None);
        std::fs::remove_dir_all(root).unwrap();

        let log = [
            r#"{"type":"thread.started","thread_id":"t-42"}"#,
            r#"{"type":"item.completed","item":{"type":"command_execution","command":"/bin/zsh -lc \"npm test\""}}"#,
            r#"{"type":"item.completed","item":{"type":"file_change","changes":[{"path":"C:\\p\\src\\app.rs"},{"path":"/p/README.md"}]}}"#,
            r#"{"type":"error","message":"retrying"}"#,
            r#"{"type":"item.completed","item":{"type":"agent_message","text":"Готово: [NOTES.md](/Users/me/p/NOTES.md), [план](C:\\p\\план.md), https://github.com/o/r/pull/7"}}"#,
            r#"{"type":"turn.completed","usage":{}}"#,
        ]
        .join("\n");
        let ended = outcome(&log).unwrap();
        assert!(!ended.is_error, "a later turn.completed replaces the retry's error");
        assert_eq!(ended.result.as_deref(), Some("Готово: NOTES.md, план, https://github.com/o/r/pull/7"));
        assert_eq!(codex::thread_id(&log).as_deref(), Some("t-42"));
        let lines = entries(&log);
        assert_eq!(lines[0], (EntryKind::Tool, "Bash: npm test".into()));
        assert_eq!(lines[1], (EntryKind::Tool, "Edit: app.rs, README.md".into()));
        assert_eq!(lines[2].0, EntryKind::Error);
        let failed = outcome(r#"{"type":"turn.failed","error":{"message":"sandbox denied"}}"#).unwrap();
        assert_eq!((failed.is_error, failed.result.as_deref()), (true, Some("sandbox denied")));
        assert_eq!(codex::plain_file_links("[site](https://example.com) and [a]"), "[site](https://example.com) and [a]");
        assert_eq!(codex::shell_command(r#"powershell.exe -Command "cargo test""#), "cargo test");

        let mut run = run();
        run.other.insert("agent".into(), json!("codex"));
        assert!(run.is_codex());
        finish(&mut run, &log, None, &texts(), Utc::now());
        assert_eq!((run.state, run.other["threadID"].as_str()), (RunState::Succeeded, Some("t-42")));
        assert_eq!(run.pull_request_url.as_deref(), Some("https://github.com/o/r/pull/7"));
        let saved: Run = serde_json::from_value(serde_json::to_value(&run).unwrap()).unwrap();
        assert_eq!(saved.other["agent"], "codex", "the Mac's `agent` field");
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
            task: "Do it", prompt: "Задача: «it's done» & more", time_limit_minutes: 5, permissions: "code", result_file: None,
            codex: false,
            review_of: None,
        };
        let (mut run, mut child) = start(&runs, &fake, &new).unwrap();
        assert!(child.wait().unwrap().success());
        let log = std::fs::read_to_string(run.log_path(&runs)).unwrap();
        finish(&mut run, &log, None, &texts(), Utc::now());
        assert_eq!(run.state, RunState::Succeeded, "{log}");
        assert_eq!(run.pull_request_url.as_deref(), Some("https://github.com/o/r/pull/5"));
        assert_eq!(load(&runs, Utc::now()).len(), 1);

        // A folder project's command: «Только файлы» in the run's settings, and the result file it was to write.
        let result = dir.join("хуки.md");
        let command = NewRun { permissions: "filesOnly", result_file: Some(&result), command_title: "Хуки", ..new };
        let (mut run, mut child) = start(&runs, &fake, &command).unwrap();
        assert!(child.wait().unwrap().success());
        let rules: Value = serde_json::from_str(&std::fs::read_to_string(settings_path(&runs, &run.id)).unwrap()).unwrap();
        let deny: Vec<&str> = rules["permissions"]["deny"].as_array().unwrap().iter().filter_map(Value::as_str).collect();
        assert!(deny.contains(&"Bash") && deny.contains(&"WebFetch"));
        assert_eq!(deny.contains(&"PowerShell"), cfg!(windows));
        let saved: Value = serde_json::from_str(&std::fs::read_to_string(dir.join("runs").join(format!("{}.json", run.id))).unwrap()).unwrap();
        assert_eq!(saved["resultFile"], result.to_string_lossy().as_ref(), "the Mac's field name");
        let log = std::fs::read_to_string(run.log_path(&runs)).unwrap();
        let mut missing = run.clone();
        finish(&mut missing, &log, None, &texts(), Utc::now());
        assert!(missing.summary.as_deref().unwrap().ends_with("Файл результата не появился: хуки.md"));
        std::fs::write(&result, "хуки").unwrap();
        finish(&mut run, &log, None, &texts(), Utc::now());
        assert_eq!((run.state, run.summary.as_deref()), (RunState::Succeeded, Some("ok https://github.com/o/r/pull/5")));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
