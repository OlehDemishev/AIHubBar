//! «Сравнение» of a pair (the Mac's `PairCompare`, «одна задача двум»): what each service changed in its own worktree,
//! side by side; a file's changes line by line; one variant against the other; and the three actions — «Оставить
//! этот вариант» removes the other, «Влить в …» merges a variant's branch into the branch the project's folder is on
//! (no push), «Убрать папку и ветку» tidies a merged one. Nothing but a worktree the app made inside the project is
//! ever removed.

use crate::command;
use crate::i18n::Strings;
use crate::runs::{Run, RunState};
use std::path::Path;
use std::time::Duration;

/// Both runs of a pair, Claude first; None without two of them.
pub fn sides<'a>(pair: &str, runs: &'a [Run]) -> Option<Vec<&'a Run>> {
    let mut both: Vec<&Run> = runs.iter().filter(|run| run.pair() == Some(pair) && run.review_of().is_none()).collect();
    both.sort_by_key(|run| run.is_codex());
    (both.len() == 2).then_some(both)
}

/// The other run of the pair; None outside a pair, for a review, or when either side was removed.
pub fn partner<'a>(run: &Run, runs: &'a [Run]) -> Option<&'a Run> {
    let pair = run.pair()?;
    if run.review_of().is_some() || run.discarded() {
        return None;
    }
    runs.iter().find(|other| other.pair() == Some(pair) && other.id != run.id && other.review_of().is_none() && !other.discarded())
}

fn finished(run: &Run) -> bool {
    run.state != RunState::Running
}

/// Only a worktree straight under `<project>/.claude/worktrees/`, on a branch of its own.
pub fn removable(run: &Run) -> bool {
    let root = Path::new(&run.project_path).join(".claude").join("worktrees");
    let folder = Path::new(&run.folder);
    let inside = folder.parent().is_some_and(|parent| parent.components().eq(root.components())) && folder.file_name().is_some();
    inside && run.worktree_branch.as_deref().is_some_and(|branch| !branch.is_empty())
}

/// «Оставить этот вариант» for `keep`: both finished, the other one still there and removable.
pub fn can_keep(keep: &Run, sides: &[&Run]) -> bool {
    sides.len() == 2
        && sides.iter().all(|run| finished(run) && !run.discarded())
        && sides.iter().any(|run| run.id == keep.id)
        && sides.iter().find(|run| run.id != keep.id).is_some_and(|other| removable(other))
}

/// «Влить в …» for a side: finished well, still there, not merged yet, on a branch other than the target.
pub fn can_merge(run: &Run, sides: &[&Run], target: Option<&str>) -> bool {
    let (Some(target), Some(branch)) = (target, run.worktree_branch.as_deref()) else { return false };
    !branch.is_empty() && branch != target && sides.iter().all(|side| finished(side)) && run.state == RunState::Succeeded && !run.discarded() && run.merged_into().is_none()
}

/// «Убрать папку и ветку» for a merged side whose worktree is the app's own and still there.
pub fn can_tidy(run: &Run) -> bool {
    run.merged_into().is_some() && !run.discarded() && removable(run)
}

pub fn merge_warning(s: &Strings, run: &Run, target: &str) -> String {
    s.format("Ветка %@ будет влита в %@ в папке проекта «%@» (git merge, без push). Отменить можно только вручную.", &[run.worktree_branch.as_deref().unwrap_or_default(), target, &run.project])
}

fn folder_name(run: &Run) -> String {
    Path::new(&run.folder).file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default()
}

pub fn tidy_warning(s: &Strings, run: &Run) -> String {
    s.format("Папка %@ и ветка %@ будут удалены. Изменения уже влиты в %@, они останутся.", &[&folder_name(run), run.worktree_branch.as_deref().unwrap_or_default(), run.merged_into().unwrap_or_default()])
}

pub fn removal_warning(s: &Strings, run: &Run) -> String {
    s.format("Вариант «%@» будет удалён: папка %@ и ветка %@. Его изменения пропадут, отменить нельзя.", &[run.agent_title(), &folder_name(run), run.worktree_branch.as_deref().unwrap_or_default()])
}

/// What a side says in place of its state once something was done to it.
pub fn side_state(s: &Strings, run: &Run) -> Option<String> {
    match (run.discarded(), run.merged_into()) {
        (true, Some(target)) => Some(s.format("влит в %@, папка убрана", &[target])),
        (true, None) => Some(s.t("удалён").to_owned()),
        (false, Some(target)) => Some(s.format("влит в %@", &[target])),
        (false, None) => None,
    }
}

// MARK: - Diffs

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DiffKind {
    File,
    Hunk,
    Added,
    Removed,
    Context,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct DiffLine {
    pub kind: DiffKind,
    pub text: String,
}

/// A long diff is cut here: the window is for a look, the whole thing is in a terminal.
pub const DIFF_LIMIT: usize = 1500;

/// `git diff` output as lines to show: «diff --git», «index», «---», «+++» and the mode lines become one file line.
pub fn diff_lines(text: &str, limit: usize) -> (Vec<DiffLine>, bool) {
    let mut lines = Vec::new();
    let mut cut = false;
    for line in text.split('\n').map(|line| line.strip_suffix('\r').unwrap_or(line)) {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            let path = rest.find(" b/").map_or(rest, |at| &rest[at + 3..]);
            lines.push(DiffLine { kind: DiffKind::File, text: path.to_owned() });
            continue;
        }
        let header = ["index ", "--- ", "+++ ", "new file mode", "deleted file mode", "similarity index", "rename ", "old mode", "new mode", "\\ No newline"];
        if header.iter().any(|prefix| line.starts_with(prefix)) {
            continue;
        }
        let kind = if line.starts_with("@@") {
            DiffKind::Hunk
        } else if line.starts_with('+') {
            DiffKind::Added
        } else if line.starts_with('-') {
            DiffKind::Removed
        } else {
            DiffKind::Context
        };
        if lines.len() >= limit {
            cut = true;
            break;
        }
        lines.push(DiffLine { kind, text: line.to_owned() });
    }
    while lines.last().is_some_and(|line| line.kind == DiffKind::Context && line.text.is_empty()) {
        lines.pop();
    }
    (lines, cut)
}

/// Paths both sides changed: there the two answers really differ or really agree.
pub fn common<'a>(first: &'a [String], second: &'a [String]) -> Vec<&'a String> {
    first.iter().filter(|path| second.contains(path)).collect()
}

fn git(program: &Path, folder: &Path, args: &[&str], seconds: u64) -> Result<String, String> {
    let mut command = command::command(program);
    command.arg("-C").arg(folder).args(["-c", "core.quotepath=off"]).args(args);
    command.env("LC_ALL", "C").env("GIT_TERMINAL_PROMPT", "0");
    match command::run(command, Duration::from_secs(seconds)) {
        Some(output) if output.ok() => Ok(output.stdout),
        Some(output) => Err(format!("git {} (code {})", args.first().copied().unwrap_or_default(), output.code.unwrap_or(-1))),
        None => Err("git".to_owned()),
    }
}

/// What one side changed in `path` since its run started; a new, untracked file is shown whole as added lines.
pub fn file_diff(program: &Path, run: &Run, path: &str) -> String {
    let folder = Path::new(&run.folder);
    let base = crate::session_changes::base_commit(program, folder, Some(run.started_at));
    if let Ok(tracked) = git(program, folder, &["diff", &base, "--", path], 20) {
        if !tracked.is_empty() {
            return tracked;
        }
    }
    let file = path.split('/').filter(|part| !part.is_empty() && *part != "..").fold(folder.to_path_buf(), |at, part| at.join(part));
    match std::fs::read(&file) {
        Ok(bytes) if bytes.len() < 400_000 => match String::from_utf8(bytes) {
            Ok(text) => format!("diff --git a/{path} b/{path}\n") + &text.split('\n').map(|line| format!("+{line}")).collect::<Vec<_>>().join("\n"),
            Err(_) => String::new(),
        },
        _ => String::new(),
    }
}

/// The second side against the first, branch against branch: what is committed on both.
pub fn between_diff(program: &Path, sides: &[&Run]) -> String {
    let branches: Vec<&str> = sides.iter().filter_map(|run| run.worktree_branch.as_deref()).collect();
    if branches.len() != 2 {
        return String::new();
    }
    git(program, Path::new(&sides[0].project_path), &["diff", branches[0], branches[1]], 30).unwrap_or_default()
}

// MARK: - Actions

/// The branch the project's own folder is on; None for a detached HEAD or outside a repository.
pub fn current_branch(program: &Path, project: &Path) -> Option<String> {
    let name = git(program, project, &["rev-parse", "--abbrev-ref", "HEAD"], 10).ok()?.trim().to_owned();
    (!name.is_empty() && name != "HEAD").then_some(name)
}

/// The other variant's worktree and branch, removed by force: its changes are what is being thrown away.
pub fn discard_worktree(program: &Path, run: &Run) -> Result<(), String> {
    let (project, branch) = (Path::new(&run.project_path), run.worktree_branch.as_deref().unwrap_or_default());
    if Path::new(&run.folder).exists() {
        git(program, project, &["worktree", "remove", "--force", &run.folder], 60)?;
    } else {
        git(program, project, &["worktree", "prune"], 30)?;
    }
    git(program, project, &["branch", "-D", branch], 30).map(|_| ())
}

/// A local `git merge --no-ff` into the branch the project's folder is on, no push. Refused while that folder has
/// uncommitted changes to tracked files; a merge that stops on conflicts is taken back, so the folder is as it was.
pub fn merge_branch(program: &Path, s: &Strings, run: &Run, target: &str) -> Result<(), String> {
    let (project, branch) = (Path::new(&run.project_path), run.worktree_branch.as_deref().unwrap_or_default());
    if current_branch(program, project).as_deref() != Some(target) {
        return Err(s.t("Папка проекта уже на другой ветке — откройте сравнение заново.").to_owned());
    }
    if !git(program, project, &["status", "--porcelain", "--untracked-files=no"], 20)?.trim().is_empty() {
        return Err(s.t("В папке проекта есть незакоммиченные изменения — сначала закоммитьте или уберите их.").to_owned());
    }
    if git(program, project, &["merge", "--no-ff", "--no-edit", branch], 120).is_err() {
        let _ = git(program, project, &["merge", "--abort"], 30);
        return Err(s.format("Слияние остановилось на конфликтах и отменено: влейте ветку %@ вручную.", &[branch]));
    }
    Ok(())
}

/// A merged variant's worktree and branch go away, and nothing is lost by it: refused while the branch has commits
/// the project's branch lacks or the worktree has anything uncommitted. No force, `branch -d`.
pub fn remove_merged_worktree(program: &Path, s: &Strings, run: &Run) -> Result<(), String> {
    let (project, branch) = (Path::new(&run.project_path), run.worktree_branch.as_deref().unwrap_or_default());
    if git(program, project, &["merge-base", "--is-ancestor", branch, "HEAD"], 10).is_err() {
        return Err(s.format("В ветке %@ есть коммиты, которых нет в ветке проекта — папка и ветка оставлены.", &[branch]));
    }
    if Path::new(&run.folder).exists() {
        if !git(program, Path::new(&run.folder), &["status", "--porcelain"], 20)?.trim().is_empty() {
            return Err(s.t("В папке варианта есть незакоммиченные изменения — папка и ветка оставлены.").to_owned());
        }
        git(program, project, &["worktree", "remove", &run.folder], 60)?;
    } else {
        git(program, project, &["worktree", "prune"], 30)?;
    }
    git(program, project, &["branch", "-d", branch], 30).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(id: &str, agent: Option<&str>, state: &str, extra: &str) -> Run {
        let project = if cfg!(windows) { "C:\\\\P\\\\Shop" } else { "/P/Shop" };
        let sep = if cfg!(windows) { "\\\\" } else { "/" };
        let agent = agent.map(|a| format!(r#","agent":"{a}""#)).unwrap_or_default();
        let text = format!(
            r#"{{"id":"{id}","project":"Shop","projectPath":"{project}","folder":"{project}{sep}.claude{sep}worktrees{sep}{id}","worktreeBranch":"claude/{id}","commandTitle":"t","task":"t","startedAt":"2026-11-23T10:00:00Z","timeLimitMinutes":30,"state":"{state}","notified":false,"pair":"p"{agent}{extra}}}"#
        );
        serde_json::from_str(&text).unwrap()
    }

    #[test]
    fn who_is_in_a_pair_and_what_may_be_done() {
        let claude = run("c", None, "succeeded", "");
        let codex = run("x", Some("codex"), "failed", "");
        let review = run("r", Some("codex"), "succeeded", r#","reviewOf":"c""#);
        let all = vec![codex.clone(), review, claude.clone()];
        let both = sides("p", &all).unwrap();
        assert_eq!(both.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["c", "x"], "Claude first, the review is not a side");
        assert_eq!(partner(&claude, &all).map(|r| r.id.as_str()), Some("x"));
        assert!(sides("other", &all).is_none());
        assert!(removable(&claude) && can_keep(&claude, &both) && can_keep(&codex, &both));
        assert!(can_merge(&claude, &both, Some("main")), "finished well");
        assert!(!can_merge(&codex, &both, Some("main")), "a failed side is not merged");
        assert!(!can_merge(&claude, &both, Some("claude/c")), "not into its own branch");
        assert!(!can_merge(&claude, &both, None), "a detached HEAD");
        let working = run("x", Some("codex"), "running", "");
        let busy = vec![&claude, &working];
        assert!(!can_keep(&claude, &busy) && !can_merge(&claude, &busy, Some("main")), "one still works");
        // A folder outside the project's worktrees is never removed.
        let mut outside = codex.clone();
        outside.folder = outside.project_path.clone();
        assert!(!removable(&outside) && !can_keep(&claude, &[&claude, &outside]));
        let merged = run("c", None, "succeeded", r#","mergedInto":"main""#);
        assert!(can_tidy(&merged) && !can_merge(&merged, &[&merged, &codex], Some("main")));
        let gone = run("x", Some("codex"), "failed", r#","discarded":true"#);
        assert!(partner(&claude, &[claude.clone(), gone.clone()]).is_none() && !can_keep(&claude, &[&claude, &gone]));
        let s = Strings::default();
        assert_eq!(side_state(&s, &merged).as_deref(), Some("влит в main"));
        assert_eq!(side_state(&s, &gone).as_deref(), Some("удалён"));
        assert_eq!(removal_warning(&s, &codex), "Вариант «Codex» будет удалён: папка x и ветка claude/x. Его изменения пропадут, отменить нельзя.");
    }

    #[test]
    fn a_diff_as_lines() {
        let text = "diff --git a/src/a.rs b/src/a.rs\r\nindex 1..2 100644\n--- a/src/a.rs\n+++ b/src/a.rs\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n\\ No newline at end of file\n\n";
        let (lines, cut) = diff_lines(text, DIFF_LIMIT);
        let kinds: Vec<_> = lines.iter().map(|l| (l.kind, l.text.as_str())).collect();
        assert_eq!(kinds, [(DiffKind::File, "src/a.rs"), (DiffKind::Hunk, "@@ -1,2 +1,2 @@"), (DiffKind::Context, " one"), (DiffKind::Removed, "-two"), (DiffKind::Added, "+TWO")]);
        assert!(!cut);
        let (short, cut) = diff_lines(text, 3);
        assert!(cut && short.len() == 3);
        let (a, b) = (vec!["x".to_owned(), "y".to_owned()], vec!["y".to_owned(), "z".to_owned()]);
        assert_eq!(common(&a, &b), [&"y".to_owned()]);
    }

    /// A real repository: two variants in worktrees, one kept, the other merged into main and tidied away.
    #[test]
    fn keep_merge_and_tidy_in_a_real_repository() {
        let Some(git_path) = command::find("git") else { return };
        let root = std::env::temp_dir().join(format!("claudepult-pair-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let project = root.join("Shop");
        std::fs::create_dir_all(&project).unwrap();
        let sh = |folder: &Path, args: &[&str]| {
            let mut command = command::command(&git_path);
            command.arg("-C").arg(folder).args(["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false"]).args(args);
            assert!(command::run(command, Duration::from_secs(30)).is_some_and(|out| out.ok()), "git {args:?}");
        };
        sh(&project, &["init", "-q", "-b", "main"]);
        // The merge commit needs a name: CI runners have none of their own.
        sh(&project, &["config", "user.name", "T"]);
        sh(&project, &["config", "user.email", "t@example.com"]);
        std::fs::write(project.join("a.txt"), "one\n").unwrap();
        sh(&project, &["add", "."]);
        sh(&project, &["commit", "-q", "-m", "start"]);
        let worktree = |name: &str| {
            let folder = project.join(".claude").join("worktrees").join(name);
            sh(&project, &["worktree", "add", "-q", "-b", &format!("claude/{name}"), &folder.to_string_lossy()]);
            std::fs::write(folder.join("a.txt"), format!("one\n{name}\n")).unwrap();
            sh(&folder, &["commit", "-q", "-am", name]);
            folder
        };
        let (first, second) = (worktree("first"), worktree("second"));
        let side = |name: &str, folder: &Path| {
            let mut run = run(name, None, "succeeded", "");
            run.project_path = project.to_string_lossy().into_owned();
            run.folder = folder.to_string_lossy().into_owned();
            run.worktree_branch = Some(format!("claude/{name}"));
            run
        };
        let (keep, other) = (side("first", &first), side("second", &second));
        assert!(removable(&other));
        assert_eq!(current_branch(&git_path, &project).as_deref(), Some("main"));
        let between = between_diff(&git_path, &[&keep, &other]);
        assert!(between.contains("-first") && between.contains("+second"), "{between}");
        discard_worktree(&git_path, &other).unwrap();
        assert!(!second.exists());
        let s = Strings::default();
        // Uncommitted changes in the project's folder stop a merge.
        std::fs::write(project.join("a.txt"), "dirty\n").unwrap();
        assert!(merge_branch(&git_path, &s, &keep, "main").unwrap_err().contains("незакоммиченные"));
        sh(&project, &["checkout", "-q", "--", "a.txt"]);
        merge_branch(&git_path, &s, &keep, "main").unwrap();
        // The person's own git may turn line ends into CRLF on the merge.
        assert_eq!(std::fs::read_to_string(project.join("a.txt")).unwrap().replace('\r', ""), "one\nfirst\n");
        remove_merged_worktree(&git_path, &s, &keep).unwrap();
        assert!(!first.exists());
        let _ = std::fs::remove_dir_all(&root);
    }
}
