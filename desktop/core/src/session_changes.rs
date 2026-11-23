//! What a session changed in its folder (the Mac's `SessionChanges`): files and lines since it started, committed
//! or not, plus new files — by git.

use std::path::Path;
use std::time::Duration;

use chrono::{DateTime, SecondsFormat, Utc};

use crate::command;
use crate::i18n::Strings;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileChange {
    pub path: String,
    /// None for binary files.
    pub added: Option<u32>,
    pub removed: Option<u32>,
    pub is_new: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Changes {
    pub files: Vec<FileChange>,
}

/// Git's empty tree: the base when the repository has no commit from before the session.
pub const EMPTY_TREE: &str = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

impl Changes {
    /// `git diff --numstat <base>` («12\t3\tpath», «-\t-\tbinary») and `git ls-files --others --exclude-standard`.
    pub fn parse(numstat: &str, untracked: &str) -> Changes {
        let mut files: Vec<FileChange> = numstat
            .lines()
            .filter_map(|line| {
                let mut parts = line.splitn(3, '\t');
                let (added, removed, path) = (parts.next()?, parts.next()?, parts.next()?);
                Some(FileChange { path: path.trim_end_matches('\r').to_owned(), added: added.parse().ok(), removed: removed.parse().ok(), is_new: false })
            })
            .collect();
        for path in untracked.lines().map(|line| line.trim_end_matches('\r')).filter(|line| !line.is_empty()) {
            if !files.iter().any(|file| file.path == path) {
                files.push(FileChange { path: path.to_owned(), added: None, removed: None, is_new: true });
            }
        }
        Changes { files }
    }

    pub fn added(&self) -> u32 {
        self.files.iter().filter_map(|file| file.added).sum()
    }

    pub fn removed(&self) -> u32 {
        self.files.iter().filter_map(|file| file.removed).sum()
    }

    /// «файлов: 3 +120 −8».
    pub fn summary(&self, s: &Strings) -> String {
        let mut text = s.format("файлов: %lld", &[&self.files.len().to_string()]);
        if self.added() > 0 {
            text += &format!(" +{}", count(self.added()));
        }
        if self.removed() > 0 {
            text += &format!(" −{}", count(self.removed()));
        }
        text
    }
}

/// «982», then «23.9k» from ten thousand lines: the row is narrow, and the exact number is in the list.
pub fn count(lines: u32) -> String {
    if lines < 10_000 {
        return lines.to_string();
    }
    let tenths = (f64::from(lines) / 100.0).round() as u32;
    if tenths % 10 == 0 { format!("{}k", tenths / 10) } else { format!("{}.{}k", tenths / 10, tenths % 10) }
}

fn git(program: &Path, folder: &Path, args: &[&str], seconds: u64) -> Option<String> {
    let mut command = command::command(program);
    // Paths as they are, not `"\320\237..."`: names with other letters stay readable and openable.
    command.arg("-C").arg(folder).args(["-c", "core.quotepath=off"]).args(args);
    command.env("LC_ALL", "C").env("GIT_TERMINAL_PROMPT", "0").env("GIT_OPTIONAL_LOCKS", "0");
    command::run(command, Duration::from_secs(seconds)).filter(command::Output::ok).map(|output| output.stdout)
}

/// The commit the changes are counted from: the last one before the session started, `HEAD` without a start.
pub fn base_commit(program: &Path, folder: &Path, since: Option<DateTime<Utc>>) -> String {
    base(program, folder, since)
}

fn base(program: &Path, folder: &Path, since: Option<DateTime<Utc>>) -> String {
    let Some(start) = since else { return "HEAD".into() };
    let before = format!("--before={}", start.to_rfc3339_opts(SecondsFormat::Secs, true));
    git(program, folder, &["rev-list", "-1", &before, "HEAD"], 10).map(|out| out.trim().to_owned()).filter(|commit| !commit.is_empty()).unwrap_or_else(|| EMPTY_TREE.into())
}

/// None when the folder is not in a git repository or git could not tell.
pub fn read(program: &Path, folder: &Path, since: Option<DateTime<Utc>>) -> Option<Changes> {
    git(program, folder, &["rev-parse", "--is-inside-work-tree"], 10)?;
    let numstat = git(program, folder, &["diff", "--numstat", &base(program, folder, since)], 20)?;
    let untracked = git(program, folder, &["ls-files", "--others", "--exclude-standard"], 20).unwrap_or_default();
    Some(Changes::parse(&numstat, &untracked))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_gits_lines() {
        let changes = Changes::parse("12\t3\tsrc/main.rs\r\n-\t-\tassets/logo.png\n0\t40\told name.txt\nbroken line\n", "notes.md\nsrc/main.rs\n\nпапка/файл.txt\n");
        let line = |f: &FileChange| format!("{} {:?} {:?} {}", f.path, f.added, f.removed, f.is_new);
        assert_eq!(
            changes.files.iter().map(line).collect::<Vec<_>>(),
            ["src/main.rs Some(12) Some(3) false", "assets/logo.png None None false", "old name.txt Some(0) Some(40) false", "notes.md None None true", "папка/файл.txt None None true"]
        );
        assert_eq!((changes.added(), changes.removed()), (12, 43));
        assert_eq!(changes.summary(&Strings::default()), "файлов: 5 +12 −43");
        assert_eq!(Changes::parse("", "new.txt\n").summary(&Strings::default()), "файлов: 1");
        assert!(Changes::parse("", "").files.is_empty());
        assert_eq!([count(0), count(982), count(9_999), count(10_000), count(23_940), count(123_456)], ["0", "982", "9999", "10k", "23.9k", "123.5k"]);
    }

    /// A real repository: a commit from before the session, then a committed change, an uncommitted one and a new
    /// file all count; without a start only what is not committed does.
    #[test]
    fn counts_from_before_the_session() {
        let Some(git_path) = command::find("git") else { return };
        let dir = std::env::temp_dir().join(format!("claudepult-changes-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let run = |args: &[&str], date: &str| {
            let mut command = command::command(&git_path);
            command.arg("-C").arg(&dir).args(["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false"]).args(args);
            command.env("GIT_AUTHOR_DATE", date).env("GIT_COMMITTER_DATE", date);
            assert!(command::run(command, Duration::from_secs(30)).is_some_and(|out| out.ok()), "git {args:?}");
        };
        assert_eq!(read(&git_path, &dir, None), None, "not a repository");
        run(&["init", "-q"], "2026-11-01T10:00:00Z");
        std::fs::write(dir.join("a.txt"), "one\ntwo\n").unwrap();
        run(&["add", "."], "2026-11-01T10:00:00Z");
        run(&["commit", "-q", "-m", "before"], "2026-11-01T10:00:00Z");
        std::fs::write(dir.join("a.txt"), "one\nTWO\nthree\n").unwrap();
        run(&["commit", "-q", "-am", "during"], "2026-11-01T12:00:00Z");
        std::fs::write(dir.join("a.txt"), "one\nTWO\nthree\nfour\n").unwrap();
        std::fs::write(dir.join("новый.txt"), "x\n").unwrap();

        let start = "2026-11-01T11:00:00Z".parse::<DateTime<Utc>>().unwrap();
        let since = read(&git_path, &dir, Some(start)).unwrap();
        assert_eq!(since.files, [FileChange { path: "a.txt".into(), added: Some(3), removed: Some(1), is_new: false }, FileChange { path: "новый.txt".into(), added: None, removed: None, is_new: true }]);
        let uncommitted = read(&git_path, &dir, None).unwrap();
        assert_eq!((uncommitted.files[0].added, uncommitted.files[0].removed, uncommitted.files.len()), (Some(1), Some(0), 2));
        // A session older than the repository's first commit: everything counts.
        let all = read(&git_path, &dir, Some("2026-10-01T00:00:00Z".parse().unwrap())).unwrap();
        assert_eq!((all.files[0].added, all.files[0].removed), (Some(4), Some(0)));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
