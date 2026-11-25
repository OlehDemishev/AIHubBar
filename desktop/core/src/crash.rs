//! The crash report (the Mac's `CrashReport` and `CrashReports`): a panic of the app is written to a file of its own —
//! the version, the system, the message, where it happened and the stack — and at the next start the app offers to
//! report it on GitHub: the bug form opens filled from the report, with the home folder and the account name taken
//! out, and the full report is shown in the file manager to drag into the form. The app sends nothing itself. Only
//! the app's own panics are caught: a crash of WebView2 or of Windows itself leaves no report here.

use crate::feedback::{self, Template};
use chrono::{DateTime, Utc};
use std::path::{Path, PathBuf};

/// GitHub refuses links much over 8 KB; the stack loses its last frames until the link fits.
pub const MAX_URL_LENGTH: usize = 7_500;
/// The frames kept in a report: the ones nearest to the panic.
pub const FRAME_COUNT: usize = 12;

/// Writes every panic to `<dir>/crash-<time>.txt`, then lets the default hook print it as before.
pub fn install(dir: PathBuf, version: &'static str) {
    let default = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let message = info.payload().downcast_ref::<&str>().map(|s| (*s).to_owned()).or_else(|| info.payload().downcast_ref::<String>().cloned()).unwrap_or_else(|| "panic".to_owned());
        let location = info.location().map(|l| format!("{}:{}", l.file(), l.line())).unwrap_or_default();
        let thread = std::thread::current().name().unwrap_or("unnamed").to_owned();
        let stack = std::backtrace::Backtrace::force_capture().to_string();
        let now = Utc::now();
        let text = format!(
            "AI Hub Bar {version}\nsystem: {}\ntime: {}\nthread: {thread}\nmessage: {message}\nlocation: {location}\n\n{stack}",
            feedback::system(),
            now.to_rfc3339()
        );
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(dir.join(format!("crash-{}.txt", now.format("%Y%m%d-%H%M%S%.3f"))), text);
        default(info);
    }));
}

#[derive(Debug, Clone, PartialEq)]
pub struct Crash {
    pub file: PathBuf,
    pub date: DateTime<Utc>,
    pub version: String,
    pub system: String,
    pub message: String,
    pub location: String,
    /// The stack's lines that name a function, nearest first.
    pub frames: Vec<String>,
}

impl Crash {
    pub fn parse(text: &str, file: &Path) -> Option<Crash> {
        let field = |name: &str| text.lines().find_map(|line| line.strip_prefix(&format!("{name}: "))).map(str::to_owned);
        let version = text.lines().next()?.strip_prefix("AI Hub Bar ")?.to_owned();
        let date = DateTime::parse_from_rfc3339(&field("time")?).ok()?.with_timezone(&Utc);
        let stack = text.split_once("\n\n").map_or("", |(_, rest)| rest);
        let frames = stack
            .lines()
            .map(str::trim)
            .filter_map(|line| line.split_once(": ").map(|(_, name)| name.to_owned()))
            .filter(|name| !name.starts_with("std::") && !name.starts_with("core::") && !name.contains("backtrace") && !name.contains("crash::install"))
            .take(FRAME_COUNT)
            .collect();
        Some(Crash { file: file.to_path_buf(), date, version, system: field("system").unwrap_or_default(), message: field("message").unwrap_or_default(), location: field("location").unwrap_or_default(), frames })
    }

    /// The issue's title: the message and the place, short.
    pub fn title(&self) -> String {
        let message = self.message.lines().next().unwrap_or_default();
        let message = if message.chars().count() > 80 { message.chars().take(79).collect::<String>() + "…" } else { message.to_owned() };
        format!("Crash: {message} at {}", self.location)
    }

    /// The «What happened» field: a line for the person to fill, then the crash in short.
    pub fn summary(&self, frames: usize) -> String {
        let mut lines = vec![format!("AI Hub Bar crashed on {}.", self.date.to_rfc3339()), String::new(), "What I was doing: ".to_owned(), String::new(), "```".to_owned(), self.message.clone(), format!("at {}", self.location)];
        lines.extend(self.frames.iter().take(frames).cloned());
        lines.push("```".to_owned());
        lines.join("\n")
    }

    /// The bug form filled from the report, home folder and account name out; frames go until the link fits.
    pub fn issue_url(&self, home: &str, user: &str) -> String {
        let mut frames = self.frames.len();
        loop {
            let what = redacted(&self.summary(frames), home, user);
            let url = feedback::issue_url(Template::Bug, &[("title", &redacted(&self.title(), home, user)), ("what", &what), ("version", &self.version), ("macos", &self.system), ("area", "Something else")]);
            if url.len() <= MAX_URL_LENGTH || frames == 0 {
                return url;
            }
            frames -= 1;
        }
    }
}

/// The home folder and the account name out of anything that goes into an issue.
pub fn redacted(text: &str, home: &str, user: &str) -> String {
    let mut text = text.to_owned();
    for home in [home.to_owned(), home.replace('\\', "/")] {
        if home.len() > 3 {
            text = text.replace(&home, "~");
        }
    }
    if user.len() > 1 {
        text = text.replace(&format!("\\{user}\\"), "\\USER\\").replace(&format!("/{user}/"), "/USER/");
    }
    text
}

/// The newest report written after `since`; None without one.
pub fn latest_since(dir: &Path, since: DateTime<Utc>) -> Option<Crash> {
    std::fs::read_dir(dir)
        .ok()?
        .flatten()
        .filter(|entry| entry.file_name().to_string_lossy().starts_with("crash-"))
        .filter_map(|entry| Crash::parse(&std::fs::read_to_string(entry.path()).ok()?, &entry.path()))
        .filter(|crash| crash.date > since)
        .max_by_key(|crash| crash.date)
}

/// Reports older than a month go.
pub fn tidy(dir: &Path, now: DateTime<Utc>) {
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let old = entry.metadata().and_then(|m| m.modified()).ok().is_some_and(|at| DateTime::<Utc>::from(at) < now - chrono::Duration::days(30));
        if old {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const REPORT: &str = "AI Hub Bar 0.1.11\nsystem: Windows 11 Home (26100), x86_64\ntime: 2026-11-25T12:00:00+00:00\nthread: main\nmessage: index out of bounds: the len is 0 but the index is 3\nlocation: app\\src\\projects.rs:412\n\n   0: std::backtrace_rs::backtrace::trace\n             at /rustc/x/library/std/src/backtrace.rs:1\n   1: claudepult_core::crash::install::{{closure}}\n   2: AIHubBar::projects::Projects::refresh\n             at C:\\Users\\Олег\\Projects\\AIHubBar\\desktop\\app\\src\\projects.rs:412\n   3: AIHubBar::projects::Projects::start::{{closure}}\n   4: std::sys::backtrace::__rust_begin_short_backtrace\n";

    #[test]
    fn a_report_reads() {
        let crash = Crash::parse(REPORT, Path::new("crash-1.txt")).unwrap();
        assert_eq!((crash.version.as_str(), crash.location.as_str()), ("0.1.11", "app\\src\\projects.rs:412"));
        assert_eq!(crash.frames, ["AIHubBar::projects::Projects::refresh", "AIHubBar::projects::Projects::start::{{closure}}"], "the app's own frames");
        assert_eq!(crash.title(), "Crash: index out of bounds: the len is 0 but the index is 3 at app\\src\\projects.rs:412");
        assert!(crash.summary(9).contains("What I was doing: ") && crash.summary(9).contains("AIHubBar::projects::Projects::refresh"));
        assert!(Crash::parse("not a report", Path::new("x")).is_none());
    }

    #[test]
    fn the_form_keeps_names_out_and_fits() {
        let mut crash = Crash::parse(REPORT, Path::new("crash-1.txt")).unwrap();
        crash.message = "failed to read C:\\Users\\Олег\\Projects\\x".into();
        let url = crash.issue_url("C:\\Users\\Олег", "Олег");
        assert!(url.starts_with("https://github.com/OlehDemishev/AIHubBar/issues/new?template=bug_report.yml&title=Crash"));
        assert!(!url.contains("%D0%9E%D0%BB%D0%B5%D0%B3"), "the account name is not in the link");
        crash.frames = (0..400).map(|i| format!("AIHubBar::some::long::function::name::number_{i}")).collect();
        let long = crash.issue_url("C:\\Users\\Олег", "Олег");
        assert!(long.len() <= MAX_URL_LENGTH, "{}", long.len());
        assert_eq!(redacted("at C:/Users/oleh/x and /home/oleh/y", "C:\\Users\\oleh", "oleh"), "at ~/x and /home/USER/y");
    }

    /// A real panic, caught: the hook writes a report the next start can read.
    #[test]
    fn a_panic_leaves_a_report() {
        let dir = std::env::temp_dir().join(format!("claudepult-panic-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        install(dir.clone(), "9.9.9");
        let caught = std::panic::catch_unwind(|| {
            let empty: Vec<u8> = Vec::new();
            std::hint::black_box(&empty)[3]
        });
        let _ = std::panic::take_hook();
        assert!(caught.is_err());
        let crash = latest_since(&dir, Utc::now() - chrono::Duration::minutes(1)).expect("a report");
        assert_eq!(crash.version, "9.9.9");
        assert!(crash.message.contains("index out of bounds"), "{}", crash.message);
        assert!(crash.location.contains("crash.rs"), "{}", crash.location);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_newest_report_since_a_time() {
        let dir = std::env::temp_dir().join(format!("claudepult-crash-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("crash-a.txt"), REPORT).unwrap();
        std::fs::write(dir.join("crash-b.txt"), REPORT.replace("2026-11-25T12:00:00", "2026-11-25T15:00:00")).unwrap();
        std::fs::write(dir.join("notes.txt"), REPORT).unwrap();
        let since = DateTime::parse_from_rfc3339("2026-11-25T13:00:00+00:00").unwrap().with_timezone(&Utc);
        assert_eq!(latest_since(&dir, since).map(|c| c.file.file_name().unwrap().to_string_lossy().into_owned()).as_deref(), Some("crash-b.txt"));
        assert!(latest_since(&dir, since + chrono::Duration::hours(5)).is_none(), "nothing new");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
