//! Stage 4 «Проекты» (docs/specs/SPEC-windows.md §4.7): the Mac's built-in git scanner (`GitScanner`) and its
//! STATUS.md reader (`StatusText`), with the same rules and texts. Every folder with a `.git` in the projects folder is
//! a project: branch, uncommitted files, stashes, unpushed branches, worktrees, open PRs with CI (when `gh` is there),
//! the STATUS.md summary, and «attention» items whose worst level is the health dot.
//!
//! `git` and `gh` come from PATH (command.rs: no console window, a time limit). Git's own words are read in English
//! (`LC_ALL=C`), and it never asks for a password in the background (`GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never`).

use crate::command;
use crate::i18n::Strings;
use chrono::{DateTime, FixedOffset, Utc};
use serde::Serialize;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::Duration;

pub const STATUS_CANDIDATES: [&str; 2] = ["docs/STATUS.md", "STATUS.md"];
const WORKERS: usize = 6;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    High,
    Mid,
    Low,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Attention {
    pub level: Level,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Health {
    Red,
    Yellow,
    Green,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Ci {
    Ok,
    Fail,
    Pending,
    None,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequest {
    pub number: u64,
    pub title: String,
    pub url: Option<String>,
    pub is_draft: bool,
    pub ci: Ci,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Worktree {
    pub path: String,
    pub branch: String,
    pub dirty: usize,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Summary {
    pub stage: String,
    pub updated: String,
    pub now: Vec<String>,
    pub next: Vec<String>,
    pub needs: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Entry {
    pub date: String,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Status {
    pub path: String,
    pub summary: Option<Summary>,
    pub latest_entry: Option<Entry>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Project {
    pub name: String,
    pub path: PathBuf,
    pub branch: String,
    pub default_branch: String,
    pub remote: Option<String>,
    pub last_activity: Option<DateTime<FixedOffset>>,
    pub dirty: usize,
    pub stashes: usize,
    /// None when `gh` is missing or didn't answer.
    pub open_prs: Option<Vec<PullRequest>>,
    pub worktrees: Vec<Worktree>,
    pub status: Option<Status>,
    pub attention: Vec<Attention>,
    pub health: Health,
}

impl Project {
    /// Attention items minus those repeating a «Needs …» entry, which the expanded row lists already.
    pub fn attention_not_in_status(&self) -> Vec<&Attention> {
        let needs: &[String] = self.status.as_ref().and_then(|s| s.summary.as_ref()).map(|s| s.needs.as_slice()).unwrap_or(&[]);
        self.attention.iter().filter(|item| !needs.iter().any(|n| !n.is_empty() && item.text.ends_with(n.as_str()))).collect()
    }

    /// The worst CI of the open PRs.
    pub fn pull_requests_ci(&self) -> Ci {
        let states: Vec<Ci> = self.open_prs.iter().flatten().map(|pr| pr.ci).collect();
        [Ci::Fail, Ci::Pending, Ci::Ok].into_iter().find(|state| states.contains(state)).unwrap_or(Ci::None)
    }
}

// MARK: - Scanning

/// The programs the scanner runs.
#[derive(Debug, Clone)]
pub struct Tools {
    pub git: PathBuf,
    pub gh: Option<PathBuf>,
}

impl Tools {
    /// None without git: there is nothing to scan with.
    pub fn find() -> Option<Tools> {
        Some(Tools { git: command::find("git")?, gh: command::find("gh") })
    }
}

/// What the texts need: the strings and the interface language (for «файл / файла / файлов»).
pub struct Words<'a> {
    pub strings: &'a Strings,
    pub language: &'a str,
}

/// The folders with a `.git` (a folder, or a file in a worktree or submodule), in name order; hidden ones skipped.
pub fn repositories(root: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(root) else { return Vec::new() };
    let mut repos: Vec<PathBuf> = entries
        .flatten()
        .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
        .map(|e| e.path())
        .filter(|path| path.is_dir() && path.join(".git").exists())
        .collect();
    repos.sort_by_key(|path| path.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default());
    repos
}

/// Every repository of `root`, several at once; the order stays the folder's.
pub fn scan(root: &Path, tools: &Tools, fetch: bool, words: &Words, now: DateTime<Utc>) -> Vec<Project> {
    let repos = repositories(root);
    let results: Mutex<Vec<Option<Project>>> = Mutex::new(vec![None; repos.len()]);
    let next = AtomicUsize::new(0);
    std::thread::scope(|scope| {
        for _ in 0..WORKERS.min(repos.len()) {
            scope.spawn(|| loop {
                let index = next.fetch_add(1, Ordering::Relaxed);
                let Some(repo) = repos.get(index) else { break };
                let scanned = project(repo, tools, fetch, words, now);
                results.lock().unwrap()[index] = Some(scanned);
            });
        }
    });
    results.into_inner().unwrap().into_iter().flatten().collect()
}

fn git(tools: &Tools, repo: &Path, args: &[&str], timeout: Duration) -> String {
    let mut command = command::command(&tools.git);
    command.arg("-C").arg(repo).args(args);
    command.env("LC_ALL", "C").env("GIT_TERMINAL_PROMPT", "0").env("GCM_INTERACTIVE", "never");
    match command::run(command, timeout) {
        // Only the end: `status --porcelain` lines start with a significant space.
        Some(output) if output.ok() => output.stdout.trim_end().to_owned(),
        _ => String::new(),
    }
}

fn git30(tools: &Tools, repo: &Path, args: &[&str]) -> String {
    git(tools, repo, args, Duration::from_secs(30))
}

fn lines(text: &str) -> Vec<&str> {
    text.split('\n').map(|l| l.trim_end_matches('\r')).filter(|l| !l.trim().is_empty()).collect()
}

/// One repository, as the Mac's `GitScanner.project`.
pub fn project(repo: &Path, tools: &Tools, fetch: bool, words: &Words, now: DateTime<Utc>) -> Project {
    let s = words.strings;
    let mut attention = Vec::new();
    let mut attend = |level, text: String| attention.push(Attention { level, text });

    if fetch {
        git(tools, repo, &["fetch", "--all", "--prune", "--quiet"], Duration::from_secs(60));
    }
    let branch = git30(tools, repo, &["branch", "--show-current"]);
    let branch = if branch.is_empty() { "(detached HEAD)".to_owned() } else { branch };
    let base = default_branch(tools, repo);
    let remote = Some(git30(tools, repo, &["remote", "get-url", "origin"])).filter(|r| !r.is_empty());

    let last = git30(tools, repo, &["log", "--exclude=refs/stash", "--all", "-1", "--format=%cI"]);
    let last_activity = DateTime::parse_from_rfc3339(&last).ok();
    if let Some(date) = last_activity {
        let days = (now - date.with_timezone(&Utc)).num_days();
        if days >= 7 {
            attend(Level::Low, s.format("нет коммитов %lld дн.", &[&days.to_string()]));
        }
    }

    let status_text = git30(tools, repo, &["status", "--porcelain=v1"]);
    let changes = lines(&status_text);
    let work = changes
        .iter()
        .filter(|line| {
            let path = line.get(3..).unwrap_or("").trim_matches('"');
            !STATUS_CANDIDATES.contains(&path) && path.trim_matches('/') != "docs"
        })
        .count();
    if work > 0 {
        let count = work.to_string();
        attend(Level::High, s.format("%lld %@ не закоммичено (ветка %@)", &[&count, files_word(words, work), &branch]));
    } else if !changes.is_empty() {
        attend(Level::Low, s.t("изменения в STATUS.md не закоммичены").to_owned());
    }

    let stashes = lines(&git30(tools, repo, &["stash", "list"])).len();
    if stashes > 0 {
        attend(Level::High, s.format("%lld stash — отложенная работа, легко забыть", &[&stashes.to_string()]));
    }

    let refs = git30(tools, repo, &["for-each-ref", "refs/heads", "--format=%(refname:short)\t%(upstream:short)\t%(upstream:track)"]);
    for line in lines(&refs) {
        let parts: Vec<&str> = line.split('\t').collect();
        let [name, upstream, track] = parts[..] else { continue };
        if track.contains("gone") {
            continue;
        }
        if upstream.is_empty() {
            // Pushed under the same name without tracking: only what is not pushed yet counts.
            let same = format!("origin/{name}");
            if !git30(tools, repo, &["rev-parse", "--verify", "--quiet", &same]).is_empty() {
                let ahead = count(&git30(tools, repo, &["rev-list", "--count", &format!("{same}..{name}")]));
                if ahead > 0 {
                    attend(Level::Mid, s.format("ветка %@: %lld не запушено", &[name, &ahead.to_string()]));
                }
                continue;
            }
            let ahead = count(&git30(tools, repo, &["rev-list", "--count", &format!("{base}..{name}")]));
            if ahead > 0 {
                attend(Level::High, s.format("ветка %@: %lld коммит(ов) только на этом компьютере", &[name, &ahead.to_string()]));
            }
        } else if let Some(ahead) = track_ahead(track) {
            attend(Level::Mid, s.format("ветка %@: %lld не запушено", &[name, &ahead.to_string()]));
        }
    }

    let (worktrees, notes) = self::worktrees(tools, repo, words);
    attention.extend(notes);

    let open_prs = match (&tools.gh, &remote) {
        (Some(gh), Some(_)) => pull_requests(gh, repo, words).map(|(prs, notes)| {
            attention.extend(notes);
            prs
        }),
        _ => None,
    };

    let status = read_status(repo);
    if let Some(status) = &status {
        match &status.summary {
            Some(summary) => {
                for item in &summary.needs {
                    attention.push(Attention { level: Level::Mid, text: format!("{}{item}", s.t("нужно от вас: ")) });
                }
            }
            None => attention.push(Attention { level: Level::Low, text: s.t("в STATUS.md нет шапки (Stage / Now / Next)").to_owned() }),
        }
    }

    let health = if attention.iter().any(|a| a.level == Level::High) {
        Health::Red
    } else if attention.iter().any(|a| a.level == Level::Mid) {
        Health::Yellow
    } else {
        Health::Green
    };
    Project {
        name: repo.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
        path: repo.to_path_buf(),
        branch,
        default_branch: base,
        remote,
        last_activity,
        dirty: changes.len(),
        stashes,
        open_prs,
        worktrees,
        status,
        attention,
        health,
    }
}

fn count(text: &str) -> u64 {
    text.trim().parse().unwrap_or(0)
}

/// `[ahead 2]`, `[ahead 2, behind 1]` → 2.
fn track_ahead(track: &str) -> Option<u64> {
    let rest = &track[track.find("ahead ")? + "ahead ".len()..];
    rest.chars().take_while(char::is_ascii_digit).collect::<String>().parse().ok()
}

fn default_branch(tools: &Tools, repo: &Path) -> String {
    let head = git30(tools, repo, &["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]);
    if !head.is_empty() {
        return head;
    }
    ["origin/main", "origin/master", "main", "master"]
        .into_iter()
        .find(|candidate| !git30(tools, repo, &["rev-parse", "--verify", "--quiet", candidate]).is_empty())
        .unwrap_or("HEAD")
        .to_owned()
}

fn same_folder(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}

fn worktrees(tools: &Tools, repo: &Path, words: &Words) -> (Vec<Worktree>, Vec<Attention>) {
    let s = words.strings;
    let (mut result, mut notes, mut prunable) = (Vec::new(), Vec::new(), 0);
    let list = git30(tools, repo, &["worktree", "list", "--porcelain"]).replace("\r\n", "\n");
    for block in list.split("\n\n") {
        let (mut path, mut branch, mut stale) = (None, None, false);
        for line in block.lines() {
            if let Some(rest) = line.strip_prefix("worktree ") {
                path = Some(PathBuf::from(rest));
            }
            if let Some(rest) = line.strip_prefix("branch ") {
                branch = Some(rest.trim_start_matches("refs/heads/").to_owned());
            }
            if line.starts_with("prunable") {
                stale = true;
            }
        }
        let Some(path) = path else { continue };
        if same_folder(&path, repo) {
            continue;
        }
        if stale || !path.exists() {
            prunable += 1;
            continue;
        }
        let dirty = lines(&git30(tools, &path, &["status", "--porcelain=v1"])).len();
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if dirty > 0 {
            notes.push(Attention { level: Level::High, text: s.format("worktree %@: %lld незакоммиченных файлов", &[&name, &dirty.to_string()]) });
        }
        result.push(Worktree { path: path.to_string_lossy().into_owned(), branch: branch.unwrap_or_else(|| "(detached)".into()), dirty });
    }
    if prunable > 0 {
        notes.push(Attention { level: Level::Low, text: s.format("%lld устаревших worktree — `git worktree prune`", &[&prunable.to_string()]) });
    }
    (result, notes)
}

fn pull_requests(gh: &Path, repo: &Path, words: &Words) -> Option<(Vec<PullRequest>, Vec<Attention>)> {
    let mut command = command::command(gh);
    command.args(["pr", "list", "--state", "open", "--limit", "20", "--json", "number,title,isDraft,url,statusCheckRollup"]);
    command.current_dir(repo).env("GH_PROMPT_DISABLED", "1").env("NO_COLOR", "1");
    let output = command::run(command, Duration::from_secs(40)).filter(command::Output::ok)?;
    let list: Vec<Value> = serde_json::from_str(&output.stdout).ok()?;
    Some(pull_requests_from(&list, words))
}

/// `gh pr list --json …` → the PRs and their attention items.
pub fn pull_requests_from(list: &[Value], words: &Words) -> (Vec<PullRequest>, Vec<Attention>) {
    let s = words.strings;
    let mut notes = Vec::new();
    let prs = list
        .iter()
        .filter_map(|pr| {
            let number = pr.get("number")?.as_u64()?;
            let title = pr.get("title").and_then(Value::as_str).unwrap_or("").to_owned();
            let is_draft = pr.get("isDraft").and_then(Value::as_bool).unwrap_or(false);
            let rollup = pr.get("statusCheckRollup").and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]);
            let ci = ci_state(rollup);
            if ci == Ci::Fail {
                notes.push(Attention { level: Level::High, text: s.format("PR #%lld: CI упал", &[&number.to_string()]) });
            } else if !is_draft {
                let short: String = title.chars().take(70).collect();
                notes.push(Attention { level: Level::Mid, text: s.format("PR #%lld ждёт merge: %@", &[&number.to_string(), &short]) });
            }
            let url = pr.get("url").and_then(Value::as_str).filter(|u| u.starts_with("https://")).map(str::to_owned);
            Some(PullRequest { number, title, url, is_draft, ci })
        })
        .collect();
    (prs, notes)
}

pub fn ci_state(rollup: &[Value]) -> Ci {
    if rollup.is_empty() {
        return Ci::None;
    }
    let states: Vec<String> = rollup
        .iter()
        .map(|check| {
            ["conclusion", "state", "status"]
                .iter()
                .find_map(|key| check.get(*key).and_then(Value::as_str))
                .unwrap_or("")
                .to_uppercase()
        })
        .collect();
    let any = |list: &[&str]| states.iter().any(|state| list.contains(&state.as_str()));
    if any(&["FAILURE", "CANCELLED", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED", "ERROR"]) {
        Ci::Fail
    } else if any(&["", "PENDING", "QUEUED", "IN_PROGRESS", "EXPECTED", "WAITING"]) {
        Ci::Pending
    } else {
        Ci::Ok
    }
}

// MARK: - Pull request changes

/// What changed in a PR between two scans (the Mac's `PullRequestAlerts`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PrChangeKind {
    CiFailed,
    CiFixed,
    Closed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrChange {
    pub kind: PrChangeKind,
    pub project: String,
    pub number: u64,
    pub title: String,
    pub url: Option<String>,
}

/// CI went red, or from red to green, or a PR left the open list. A project without PR data in either scan (no
/// `gh`, offline) says nothing: that isn't «all closed».
pub fn pull_request_changes(old: &[Project], new: &[Project]) -> Vec<PrChange> {
    let mut changes = Vec::new();
    for project in new {
        let Some(previous) = old.iter().find(|p| p.name == project.name) else { continue };
        let (Some(was), Some(now)) = (&previous.open_prs, &project.open_prs) else { continue };
        for pr in was {
            let change = |kind, current: &PullRequest| PrChange {
                kind,
                project: project.name.clone(),
                number: pr.number,
                title: current.title.clone(),
                url: current.url.clone(),
            };
            match now.iter().find(|n| n.number == pr.number) {
                None => changes.push(change(PrChangeKind::Closed, pr)),
                Some(updated) if updated.ci == Ci::Fail && pr.ci != Ci::Fail => changes.push(change(PrChangeKind::CiFailed, updated)),
                Some(updated) if pr.ci == Ci::Fail && updated.ci == Ci::Ok => changes.push(change(PrChangeKind::CiFixed, updated)),
                _ => {}
            }
        }
    }
    changes
}

/// A notification's title and text for a change.
pub fn pr_change_text(s: &Strings, change: &PrChange) -> (String, String) {
    let number = change.number.to_string();
    let key = match change.kind {
        PrChangeKind::CiFailed => "❌ CI упал: %@ #%lld",
        PrChangeKind::CiFixed => "✅ CI снова зелёный: %@ #%lld",
        PrChangeKind::Closed => "PR закрыт или смерджен: %@ #%lld",
    };
    (s.format(key, &[&change.project, &number]), change.title.clone())
}

// MARK: - STATUS.md

pub fn read_status(repo: &Path) -> Option<Status> {
    STATUS_CANDIDATES.iter().find_map(|candidate| {
        let text = std::fs::read_to_string(repo.join(candidate)).ok()?;
        Some(Status { path: (*candidate).to_owned(), summary: summary(&text), latest_entry: latest_entry(&text) })
    })
}

/// The field a `**Name:**` line starts, as the Mac's `StatusText.label`.
fn label(name: &str) -> Option<&'static str> {
    let name = name.trim().to_lowercase();
    // «Needs Oleh», «Needs me», «Нужно от …»: whoever the person is.
    if name.starts_with("needs") || name.starts_with("нужно от") {
        return Some("needs");
    }
    Some(match name.as_str() {
        "stage" | "этап" => "stage",
        "updated" | "обновлено" => "updated",
        "now" | "сейчас" | "в работе" => "now",
        "next" | "дальше" | "план" => "next",
        "blocked" | "blockers" | "блокеры" => "needs",
        _ => return None,
    })
}

fn is_dash(text: &str) -> bool {
    text.is_empty() || text == "—" || text == "-"
}

/// The summary between `<!-- summary:start -->` and `<!-- summary:end -->` (the format of `~/Projects/CLAUDE.md`).
pub fn summary(text: &str) -> Option<Summary> {
    let start = text.find("<!-- summary:start -->")? + "<!-- summary:start -->".len();
    let end = start + text[start..].find("<!-- summary:end -->")?;
    let mut result = Summary::default();
    let mut current: Option<&str> = None;
    for raw in text[start..end].split('\n') {
        let line = raw.trim();
        if let Some(close) = line.find(":**").filter(|_| line.starts_with("**")) {
            let key = label(&line[2..close]);
            current = key;
            let value = line[close + 3..].trim();
            match key {
                Some("stage") => result.stage = value.to_owned(),
                Some("updated") => result.updated = value.to_owned(),
                Some(list) if !is_dash(value) => list_of(&mut result, list).push(value.to_owned()),
                _ => {}
            }
            continue;
        }
        let Some(list @ ("now" | "next" | "needs")) = current else { continue };
        let Some(item) = line.strip_prefix("- ").or_else(|| line.strip_prefix("* ")) else { continue };
        let mut item = item.trim();
        for box_ in ["[ ] ", "[x] ", "[X] "] {
            item = item.strip_prefix(box_).unwrap_or(item);
        }
        if !is_dash(item) {
            list_of(&mut result, list).push(item.to_owned());
        }
    }
    Some(result)
}

fn list_of<'a>(summary: &'a mut Summary, key: &str) -> &'a mut Vec<String> {
    match key {
        "now" => &mut summary.now,
        "next" => &mut summary.next,
        _ => &mut summary.needs,
    }
}

/// The newest dated `## ` heading.
pub fn latest_entry(text: &str) -> Option<Entry> {
    let mut best: Option<Entry> = None;
    for line in text.lines() {
        let Some(heading) = line.strip_prefix("## ") else { continue };
        let heading = heading.trim_end_matches('\r');
        let Some(at) = find_date(heading) else { continue };
        let date = &heading[at..at + 10];
        let title = format!("{}{}", &heading[..at], &heading[at + 10..]);
        let title = title.trim_matches(|c: char| " —-·|:\t".contains(c));
        if best.as_ref().is_none_or(|b| date > b.date.as_str()) {
            best = Some(Entry { date: date.to_owned(), title: if title.is_empty() { "(без названия)".into() } else { title.to_owned() } });
        }
    }
    best
}

/// Where `YYYY-MM-DD` starts.
fn find_date(text: &str) -> Option<usize> {
    let bytes = text.as_bytes();
    (0..bytes.len().saturating_sub(9)).find(|&i| {
        let b = &bytes[i..i + 10];
        b.iter().enumerate().all(|(j, c)| if j == 4 || j == 7 { *c == b'-' } else { c.is_ascii_digit() })
    })
}

// MARK: - Words

/// «1 файл · 2 файла · 5 файлов» in Russian and Ukrainian, «1 plik · 2 pliki · 5 plików» in Polish, singular and
/// plural elsewhere — the Mac's `Plural.files`.
pub fn files_word<'a>(words: &'a Words, n: usize) -> &'a str {
    let s = words.strings;
    let (one, few, many) = (s.t("файл"), s.t("файла"), s.t("файлов"));
    let (tens, ones) = (n % 100, n % 10);
    match words.language {
        "ru" | "uk" => {
            if (11..=14).contains(&tens) {
                many
            } else if ones == 1 {
                one
            } else if (2..=4).contains(&ones) {
                few
            } else {
                many
            }
        }
        "pl" => {
            if n == 1 {
                one
            } else if (2..=4).contains(&ones) && !(12..=14).contains(&tens) {
                few
            } else {
                many
            }
        }
        _ if n == 1 => one,
        _ => many,
    }
}

/// «только что», «5 мин назад», «3 ч назад», «2 дн назад».
pub fn ago(s: &Strings, date: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let seconds = (now - date).num_seconds().max(0);
    match seconds {
        0..=59 => s.t("только что").to_owned(),
        60..=3599 => s.format("%lld мин назад", &[&(seconds / 60).to_string()]),
        3600..=86_399 => s.format("%lld ч назад", &[&(seconds / 3600).to_string()]),
        _ => s.format("%lld дн назад", &[&(seconds / 86_400).to_string()]),
    }
}

/// A remote's web page: `git@host:owner/repo.git`, `ssh://git@host/owner/repo.git` and
/// `https://user:token@host/owner/repo.git` all become `https://host/owner/repo`, credentials dropped (the Mac's
/// `GitRemote.webURL`). None for local paths and unknown forms.
pub fn web_url(remote: &str) -> Option<String> {
    let remote = remote.trim();
    if remote.is_empty() {
        return None;
    }
    let (scheme, rest) = match remote.split_once("://") {
        Some((scheme, rest)) => (scheme.to_lowercase(), rest.to_owned()),
        None => {
            // scp-like: [user@]host:path — but not `C:\…`, a Windows path.
            let (host, path) = remote.split_once(':')?;
            if host.len() == 1 || path.starts_with('\\') {
                return None;
            }
            ("ssh".to_owned(), format!("{host}/{path}"))
        }
    };
    if !["https", "http", "ssh", "git"].contains(&scheme.as_str()) {
        return None;
    }
    let (authority, path) = rest.split_once('/').unwrap_or((&rest, ""));
    let host = authority.rsplit('@').next().unwrap_or(authority);
    let host = host.split(':').next().unwrap_or(host);
    if host.is_empty() {
        return None;
    }
    let path = path.trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    Some(if path.is_empty() { format!("https://{host}") } else { format!("https://{host}/{path}") })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const STATUS: &str = "# Status\r\n\r\n<!-- summary:start -->\r\n**Stage:** Beta\r\n**Updated:** 2026-11-18\r\n\r\n**Now:**\r\n- branch `feat/x`\r\n- [ ] ticked off\r\n\r\n**Next:**\r\n- one\r\n* two\r\n\r\n**Needs Oleh:** —\r\n- merge #12\r\n<!-- summary:end -->\r\n\r\n## 2026-11-17 — older (branch `a`)\r\n\r\n## 2026-11-18 — newest (branch `b`)\r\n\r\n## Notes\r\n";

    fn ru() -> Strings {
        Strings::default()
    }

    #[test]
    fn status_summary_with_crlf() {
        let summary = summary(STATUS).unwrap();
        assert_eq!(summary.stage, "Beta");
        assert_eq!(summary.updated, "2026-11-18");
        assert_eq!(summary.now, ["branch `feat/x`", "ticked off"]);
        assert_eq!(summary.next, ["one", "two"]);
        assert_eq!(summary.needs, ["merge #12"], "a dash after the label is nothing");
        assert_eq!(latest_entry(STATUS), Some(Entry { date: "2026-11-18".into(), title: "newest (branch `b`)".into() }));
        assert!(summary_missing());
        let russian = "<!-- summary:start -->\n**Этап:** Альфа\n**Нужно от тебя:**\n- доступ\n<!-- summary:end -->\n## 2026-01-02\n";
        let summary = self::summary(russian).unwrap();
        assert_eq!((summary.stage.as_str(), summary.needs.as_slice()), ("Альфа", ["доступ".to_owned()].as_slice()));
        assert_eq!(latest_entry(russian).unwrap().title, "(без названия)");
    }

    fn summary_missing() -> bool {
        summary("# Status\n## 2026-01-01 — x\n").is_none() && summary("<!-- summary:start -->\n**Stage:** x\n").is_none()
    }

    #[test]
    fn ci_and_pull_requests() {
        assert_eq!(ci_state(&[]), Ci::None);
        assert_eq!(ci_state(&[json!({"conclusion": "SUCCESS"}), json!({"state": "SUCCESS"})]), Ci::Ok);
        assert_eq!(ci_state(&[json!({"conclusion": "SUCCESS"}), json!({"status": "IN_PROGRESS"})]), Ci::Pending);
        assert_eq!(ci_state(&[json!({"conclusion": ""}), json!({"conclusion": "FAILURE"})]), Ci::Fail);
        let s = ru();
        let words = Words { strings: &s, language: "ru" };
        let list = [
            json!({"number": 7, "title": "Fix it", "isDraft": false, "url": "https://github.com/o/r/pull/7", "statusCheckRollup": [{"conclusion": "FAILURE"}]}),
            json!({"number": 8, "title": "Ready", "isDraft": false, "url": "javascript:alert(1)", "statusCheckRollup": []}),
            json!({"number": 9, "title": "Draft", "isDraft": true}),
        ];
        let (prs, notes) = pull_requests_from(&list, &words);
        assert_eq!(prs.len(), 3);
        assert_eq!(prs[1].url, None, "only https links open");
        assert_eq!(notes, [
            Attention { level: Level::High, text: "PR #7: CI упал".into() },
            Attention { level: Level::Mid, text: "PR #8 ждёт merge: Ready".into() },
        ]);
    }

    #[test]
    fn words() {
        let s = ru();
        let ru = Words { strings: &s, language: "ru" };
        let counts: Vec<&str> = [1, 2, 5, 11, 21, 22, 112].iter().map(|n| files_word(&ru, *n)).collect();
        assert_eq!(counts, ["файл", "файла", "файлов", "файлов", "файл", "файла", "файлов"]);
        let en = Strings::from_json(r#"{"файл": "file", "файла": "files", "файлов": "files"}"#);
        assert_eq!(files_word(&Words { strings: &en, language: "en" }, 2), "files");
        let now = Utc::now();
        assert_eq!(ago(&s, now - chrono::Duration::seconds(5), now), "только что");
        assert_eq!(ago(&s, now - chrono::Duration::minutes(15), now), "15 мин назад");
        assert_eq!(ago(&s, now - chrono::Duration::hours(3), now), "3 ч назад");
        assert_eq!(ago(&s, now - chrono::Duration::days(2), now), "2 дн назад");
        assert_eq!(track_ahead("[ahead 2, behind 1]"), Some(2));
        assert_eq!(track_ahead("[behind 1]"), None);
    }

    #[test]
    fn pull_request_alerts() {
        let pr = |number, ci| PullRequest { number, title: format!("PR {number}"), url: None, is_draft: false, ci };
        let project = |name: &str, prs: Option<Vec<PullRequest>>| Project {
            name: name.into(), path: PathBuf::from(name), branch: "main".into(), default_branch: "origin/main".into(),
            remote: None, last_activity: None, dirty: 0, stashes: 0, open_prs: prs, worktrees: vec![], status: None,
            attention: vec![], health: Health::Green,
        };
        let old = [
            project("Shop", Some(vec![pr(1, Ci::Pending), pr(2, Ci::Fail), pr(3, Ci::Ok), pr(4, Ci::Fail)])),
            project("Notes", Some(vec![pr(9, Ci::Ok)])),
        ];
        let new = [
            project("Shop", Some(vec![pr(1, Ci::Fail), pr(2, Ci::Ok), pr(4, Ci::Pending)])),
            project("Notes", None),
            project("Site", Some(vec![pr(5, Ci::Fail)])),
        ];
        let changes = pull_request_changes(&old, &new);
        let kinds: Vec<(u64, PrChangeKind)> = changes.iter().map(|c| (c.number, c.kind.clone())).collect();
        assert_eq!(kinds, [(1, PrChangeKind::CiFailed), (2, PrChangeKind::CiFixed), (3, PrChangeKind::Closed)],
            "red to pending is quiet; no PR data or a new project says nothing");
        assert_eq!(pr_change_text(&ru(), &changes[0]), ("❌ CI упал: Shop #1".to_owned(), "PR 1".to_owned()));
        assert!(pull_request_changes(&[], &new).is_empty(), "the first scan announces nothing");
    }

    #[test]
    fn remotes_to_web_pages() {
        assert_eq!(web_url("git@github.com:o/r.git").as_deref(), Some("https://github.com/o/r"));
        assert_eq!(web_url("ssh://git@github.com:22/o/r.git").as_deref(), Some("https://github.com/o/r"));
        assert_eq!(web_url("https://user:token@github.com/o/r.git/").as_deref(), Some("https://github.com/o/r"));
        assert_eq!(web_url(r"C:\repos\r.git"), None);
        assert_eq!(web_url("/srv/r.git"), None);
        assert_eq!(web_url("file:///srv/r.git"), None);
        assert_eq!(web_url(""), None);
    }

    /// A real repository: uncommitted work, a stash, a branch never pushed, a STATUS.md with «Needs».
    #[test]
    fn scans_a_repository() {
        let Some(tools) = Tools::find() else { panic!("git on PATH") };
        let tools = Tools { gh: None, ..tools };
        let root = std::env::temp_dir().join(format!("claudepult-projects-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let repo = root.join("Проект O'Neil");
        std::fs::create_dir_all(repo.join("docs")).unwrap();
        std::fs::create_dir_all(root.join("not a repo")).unwrap();
        std::fs::create_dir_all(root.join(".hidden").join(".git")).unwrap();
        let run = |args: &[&str]| {
            let mut command = command::command(&tools.git);
            command.arg("-C").arg(&repo).args(["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]).args(args);
            assert!(command::run(command, Duration::from_secs(30)).unwrap().ok(), "git {args:?}");
        };
        run(&["init", "-q", "-b", "main"]);
        std::fs::write(repo.join("docs/STATUS.md"), STATUS).unwrap();
        std::fs::write(repo.join("a.txt"), "a").unwrap();
        run(&["add", "."]);
        run(&["commit", "-q", "-m", "first"]);
        run(&["switch", "-q", "-c", "feat/local"]);
        std::fs::write(repo.join("b.txt"), "b").unwrap();
        run(&["add", "."]);
        run(&["commit", "-q", "-m", "second"]);
        std::fs::write(repo.join("a.txt"), "stashed").unwrap();
        run(&["stash", "-q"]);
        std::fs::write(repo.join("c.txt"), "c").unwrap();
        std::fs::write(repo.join("d.txt"), "d").unwrap();

        assert_eq!(repositories(&root), [repo.clone()]);
        let s = ru();
        let projects = scan(&root, &tools, false, &Words { strings: &s, language: "ru" }, Utc::now());
        let project = &projects[0];
        assert_eq!(project.name, "Проект O'Neil");
        assert_eq!(project.branch, "feat/local");
        assert_eq!(project.default_branch, "main");
        assert_eq!((project.dirty, project.stashes, project.remote.clone(), project.open_prs.clone()), (2, 1, None, None));
        assert!(project.last_activity.is_some());
        let texts: Vec<&str> = project.attention.iter().map(|a| a.text.as_str()).collect();
        assert_eq!(texts, [
            "2 файла не закоммичено (ветка feat/local)",
            "1 stash — отложенная работа, легко забыть",
            "ветка feat/local: 1 коммит(ов) только на этом компьютере",
            "нужно от вас: merge #12",
        ]);
        assert_eq!(project.health, Health::Red);
        assert_eq!(project.attention_not_in_status().len(), 3, "«Needs» is listed in the summary already");
        assert_eq!(project.status.as_ref().unwrap().summary.as_ref().unwrap().stage, "Beta");
        std::fs::remove_dir_all(root).unwrap();
    }
}
