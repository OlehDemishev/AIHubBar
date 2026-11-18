//! Stage 4 «Claude в терминале» (docs/specs/SPEC-windows.md §4.4): the Mac's three Claude commands for a project
//! (`ClaudeCommand`, `ClaudeLauncher`) — «Следующий шаг», «Своя задача», «Завершить сессию» — with the same prompts,
//! the same choice of folder (a new worktree when a Claude session already works in the project) and a terminal window
//! of its own:
//! - Windows: PowerShell with the script as `-EncodedCommand` (UTF-16LE in base64), so no quoting passes through
//!   `wt.exe` or the console's command line; in a Windows Terminal tab when `wt` is there, in a console of its own
//!   otherwise. `-NoExit` keeps the window when Claude ends, like Terminal on the Mac.
//! - Linux: the first terminal found, running `sh -c '<claude> <prompt>; exec $SHELL'`.

use crate::agent_hooks::{ps_quote, sh_quote};
use crate::command;
use crate::projects::Tools;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClaudeCommand {
    NextStep,
    CustomTask(String),
    FinishSession,
}

/// Whose rules the prompts follow: one shared CLAUDE.md in the projects folder (the `~/Projects` setup), or the
/// project's own CLAUDE.md / AGENTS.md.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Style {
    Workspace { rules_file: String },
    Generic,
}

impl Style {
    /// Workspace when the projects folder has its own CLAUDE.md (the Mac picks it by profile template).
    pub fn for_projects(projects_dir: &Path) -> Style {
        let rules = projects_dir.join("CLAUDE.md");
        if !rules.is_file() {
            return Style::Generic;
        }
        // `~/Projects/CLAUDE.md` as on the Mac; the full path on Windows, where `~` means nothing to cmd or Claude.
        let home = dirs::home_dir();
        let rules_file = match home.as_deref().and_then(|h| rules.strip_prefix(h).ok()) {
            Some(rest) if !cfg!(windows) => format!("~/{}", rest.to_string_lossy()),
            _ => rules.to_string_lossy().into_owned(),
        };
        Style::Workspace { rules_file }
    }
}

/// The Mac's prompts for a project without shared rules, per content language (`scripts/strings.py` writes them).
fn generic_prompts() -> &'static BTreeMap<String, BTreeMap<String, String>> {
    static TABLE: OnceLock<BTreeMap<String, BTreeMap<String, String>>> = OnceLock::new();
    TABLE.get_or_init(|| serde_json::from_str(include_str!("../../ui/i18n/prompts.json")).unwrap_or_default())
}

impl ClaudeCommand {
    /// The command's prompt, verbatim from the Mac. `language` is the interface language.
    pub fn prompt(&self, style: &Style, language: &str) -> String {
        match style {
            Style::Generic => {
                let table = generic_prompts();
                let words = table.get(language).or_else(|| table.get("en"));
                let get = |key: &str| words.and_then(|w| w.get(key)).cloned().unwrap_or_default();
                match self {
                    ClaudeCommand::NextStep => get("nextStep"),
                    ClaudeCommand::CustomTask(task) => get("customTask").replace("{task}", task.trim()),
                    ClaudeCommand::FinishSession => get("finishSession"),
                }
            }
            Style::Workspace { rules_file: rules } => match self {
                ClaudeCommand::NextStep => format!("Прочитай только шапку docs/STATUS.md и последнюю запись журнала. Возьми первый пункт из Next и выполни его по правилам {rules}: отдельная ветка от origin/main, проверки проекта, коммит, push, PR, запись в STATUS.md и обновление шапки. Если пункт требует решения человека или неясен — ничего не меняй, а запиши вопрос в поле Needs шапки STATUS.md и закончи."),
                ClaudeCommand::CustomTask(task) => format!("Задача: {}. Работай по правилам {rules}: отдельная ветка от origin/main, проверки, коммит, push, PR, запись в STATUS.md.", task.trim()),
                ClaudeCommand::FinishSession => format!("Заверши текущую работу в этой папке по разделу \"Конец сессии\" из {rules}: проверки, коммит, push, PR, запись в STATUS.md и шапка. Новых изменений кода не делай. Если незакоммиченные изменения относятся к разным задачам — разнеси их по отдельным веткам и PR."),
            },
        }
    }

    /// «Завершить сессию» is about the work already in the folder, so it never moves to a worktree.
    pub fn can_use_worktree(&self) -> bool {
        *self != ClaudeCommand::FinishSession
    }

    /// What the worktree and branch are named after: the task, or the first Next item.
    pub fn name_source(&self, next_items: &[String]) -> String {
        match self {
            ClaudeCommand::CustomTask(task) => task.clone(),
            ClaudeCommand::NextStep => next_items.first().cloned().unwrap_or_else(|| "next step".into()),
            ClaudeCommand::FinishSession => "finish session".into(),
        }
    }
}

// MARK: - Folder

/// A project folder is busy when a session works in it or below it, except inside its `.claude/worktrees`.
pub fn is_busy(project: &Path, working_directories: &[PathBuf]) -> bool {
    let worktrees = project.join(".claude").join("worktrees");
    working_directories.iter().any(|cwd| {
        let same = |a: &Path, b: &Path| a.starts_with(b) || lowercase(a).starts_with(lowercase(b));
        same(cwd, project) && !same(cwd, &worktrees)
    })
}

/// Windows paths ignore case; elsewhere this only lowers what was the same anyway.
fn lowercase(path: &Path) -> PathBuf {
    if cfg!(windows) {
        PathBuf::from(path.to_string_lossy().to_lowercase())
    } else {
        path.to_path_buf()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorktreePlan {
    pub slug: String,
    pub path: PathBuf,
    pub branch: String,
}

const MAX_SLUG: usize = 32;

/// Russian and Ukrainian letters in Latin, close to what the Mac's ICU «Any-Latin» gives.
fn latin(c: char) -> Option<&'static str> {
    Some(match c {
        'а' => "a", 'б' => "b", 'в' => "v", 'г' => "g", 'ґ' => "g", 'д' => "d", 'е' => "e", 'ё' => "e", 'є' => "ie",
        'ж' => "zh", 'з' => "z", 'и' => "i", 'і' => "i", 'ї' => "i", 'й' => "j", 'к' => "k", 'л' => "l", 'м' => "m",
        'н' => "n", 'о' => "o", 'п' => "p", 'р' => "r", 'с' => "s", 'т' => "t", 'у' => "u", 'ф' => "f", 'х' => "h",
        'ц' => "c", 'ч' => "ch", 'ш' => "sh", 'щ' => "shch", 'ъ' => "", 'ы' => "y", 'ь' => "", 'э' => "e", 'ю' => "yu",
        'я' => "ya",
        _ => return None,
    })
}

/// A short ASCII slug: transliterated, lowercased, words joined with `-`, at most 32 characters.
pub fn slug(text: &str) -> String {
    let mut ascii = String::new();
    for c in text.to_lowercase().chars() {
        match latin(c) {
            Some(l) => ascii.push_str(l),
            None => ascii.push(c),
        }
    }
    let all: Vec<&str> = ascii.split(|c: char| !c.is_ascii_alphanumeric()).filter(|w| !w.is_empty()).collect();
    let mut words: Vec<&str> = Vec::new();
    let mut length = 0;
    for word in &all {
        let next = length + word.len() + usize::from(!words.is_empty());
        if next > MAX_SLUG {
            break;
        }
        words.push(word);
        length = next;
    }
    match (words.is_empty(), all.first()) {
        (false, _) => words.join("-"),
        (true, Some(first)) => first[..first.len().min(MAX_SLUG)].to_owned(),
        (true, None) => "task".into(),
    }
}

/// `.claude/worktrees/cb-<slug>` on branch `claude/<slug>`, with `-2`, `-3`, … when a name is taken.
pub fn plan(project: &Path, name_source: &str, is_taken: impl Fn(&Path, &str) -> bool) -> WorktreePlan {
    let base = slug(name_source);
    let mut candidate = base.clone();
    let mut counter = 2;
    loop {
        let path = project.join(".claude").join("worktrees").join(format!("cb-{candidate}"));
        let branch = format!("claude/{candidate}");
        if !is_taken(&path, &branch) {
            return WorktreePlan { slug: candidate, path, branch };
        }
        candidate = format!("{base}-{counter}");
        counter += 1;
    }
}

fn git(tools: &Tools, repo: &Path, args: &[&str], timeout: Duration) -> Result<String, String> {
    let mut command = command::command(&tools.git);
    command.arg("-C").arg(repo).args(args).env("LC_ALL", "C").env("GIT_TERMINAL_PROMPT", "0").env("GCM_INTERACTIVE", "never");
    match command::run(command, timeout) {
        Some(output) if output.ok() => Ok(output.stdout),
        Some(_) => Err(format!("git {} failed", args.first().unwrap_or(&""))),
        None => Err(format!("git {} took too long", args.first().unwrap_or(&""))),
    }
}

/// A new worktree from `base_ref` (fetched first; offline the last fetched state is a fine start).
pub fn create_worktree(tools: &Tools, project: &Path, name_source: &str, base_ref: &str) -> Result<WorktreePlan, String> {
    if let Some((remote, branch)) = base_ref.split_once('/').filter(|(r, b)| !r.is_empty() && !b.is_empty()) {
        let _ = git(tools, project, &["fetch", remote, branch], Duration::from_secs(120));
    }
    let branches = git(tools, project, &["for-each-ref", "--format=%(refname:short)", "refs/heads"], Duration::from_secs(30))?;
    let branches: Vec<&str> = branches.lines().map(str::trim).collect();
    let plan = plan(project, name_source, |path, branch| path.exists() || branches.contains(&branch));
    let path = plan.path.to_string_lossy().into_owned();
    git(tools, project, &["worktree", "add", "-b", &plan.branch, &path, base_ref], Duration::from_secs(120))?;
    Ok(plan)
}

// MARK: - Claude and the terminal

/// `claude` on PATH, else where the native installer puts it (`~/.local/bin`), else the old local install.
pub fn find_claude() -> Option<PathBuf> {
    if let Some(found) = command::find("claude") {
        return Some(found);
    }
    let home = dirs::home_dir()?;
    let name = if cfg!(windows) { "claude.exe" } else { "claude" };
    [home.join(".local").join("bin").join(name), home.join(".claude").join("local").join(name)].into_iter().find(|p| p.is_file())
}

/// The prompt as one line: a console's command line can't hold a line break.
pub fn one_line(text: &str) -> String {
    text.split(['\r', '\n']).map(str::trim).filter(|l| !l.is_empty()).collect::<Vec<_>>().join(" ")
}

/// What PowerShell runs in the new window: into the folder, then Claude with its prompt.
pub fn powershell_script(folder: &Path, program: &Path, args: &[&str]) -> String {
    let mut script = format!("Set-Location -LiteralPath {}; & {}", ps_quote(&folder.to_string_lossy()), ps_quote(&program.to_string_lossy()));
    for arg in args {
        script.push(' ');
        script.push_str(&ps_quote(arg));
    }
    script
}

/// `-EncodedCommand`'s form: the script in UTF-16LE, in base64.
pub fn encode_powershell(script: &str) -> String {
    let bytes: Vec<u8> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
    base64(&bytes)
}

fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16) | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8) | u32::from(*chunk.get(2).unwrap_or(&0));
        for (i, shift) in [18, 12, 6, 0].into_iter().enumerate() {
            out.push(if i <= chunk.len() { TABLE[(n >> shift) as usize & 63] as char } else { '=' });
        }
    }
    out
}

/// `sh -c`'s line on Linux: Claude, then a shell, so the window stays when Claude ends.
pub fn shell_line(program: &Path, args: &[&str]) -> String {
    let mut line = sh_quote(&program.to_string_lossy());
    for arg in args {
        line.push(' ');
        line.push_str(&sh_quote(arg));
    }
    line + "; exec \"${SHELL:-sh}\""
}

/// Opens a terminal window in `folder` running `program` with `args`.
pub fn open_in_terminal(folder: &Path, program: &Path, args: &[&str]) -> Result<(), String> {
    let mut child = terminal_command(folder, program, args)?.spawn().map_err(|e| e.to_string())?;
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

#[cfg(windows)]
fn terminal_command(folder: &Path, program: &Path, args: &[&str]) -> Result<std::process::Command, String> {
    use std::os::windows::process::CommandExt;
    let encoded = encode_powershell(&powershell_script(folder, program, args));
    let shell = ["-NoLogo", "-NoExit", "-EncodedCommand", &encoded];
    if let Some(wt) = command::find("wt") {
        let mut command = command::command(&wt);
        command.arg("-d").arg(folder).arg("powershell.exe").args(shell);
        return Ok(command);
    }
    const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;
    let mut command = std::process::Command::new("powershell.exe");
    command.args(shell).current_dir(folder).creation_flags(CREATE_NEW_CONSOLE);
    Ok(command)
}

#[cfg(target_os = "macos")]
fn terminal_command(folder: &Path, program: &Path, args: &[&str]) -> Result<std::process::Command, String> {
    // Development only: Terminal.app types `cd <folder> && <line>`, as the Mac app does.
    let line = format!("cd {} && {}", sh_quote(&folder.to_string_lossy()), shell_line(program, args).trim_end_matches("; exec \"${SHELL:-sh}\""));
    let mut command = std::process::Command::new("osascript");
    command.args(["-e", "on run argv", "-e", "tell application \"Terminal\" to do script (item 1 of argv)", "-e", "tell application \"Terminal\" to activate", "-e", "end run", &line]);
    Ok(command)
}

#[cfg(all(unix, not(target_os = "macos")))]
fn terminal_command(folder: &Path, program: &Path, args: &[&str]) -> Result<std::process::Command, String> {
    let line = shell_line(program, args);
    let (name, terminal) = ["gnome-terminal", "konsole", "xfce4-terminal", "x-terminal-emulator", "kitty", "alacritty", "xterm"]
        .iter()
        .find_map(|name| command::find(name).map(|path| (*name, path)))
        .ok_or("no terminal found")?;
    let mut command = std::process::Command::new(terminal);
    command.current_dir(folder);
    match name {
        "gnome-terminal" => command.arg("--").args(["sh", "-c", &line]),
        "xfce4-terminal" => command.arg("-x").args(["sh", "-c", &line]),
        _ => command.arg("-e").args(["sh", "-c", &line]),
    };
    Ok(command)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompts_as_on_the_mac() {
        let workspace = Style::Workspace { rules_file: "~/Projects/CLAUDE.md".into() };
        let task = ClaudeCommand::CustomTask("  add a button \n".into());
        assert_eq!(
            task.prompt(&workspace, "en"),
            "Задача: add a button. Работай по правилам ~/Projects/CLAUDE.md: отдельная ветка от origin/main, проверки, коммит, push, PR, запись в STATUS.md."
        );
        assert!(task.prompt(&Style::Generic, "en").starts_with("Task: add a button. Follow the project's rules"));
        assert!(ClaudeCommand::NextStep.prompt(&Style::Generic, "de").starts_with("Lies"), "{}", ClaudeCommand::NextStep.prompt(&Style::Generic, "de"));
        assert!(ClaudeCommand::FinishSession.prompt(&Style::Generic, "xx").starts_with("Finish"), "an unknown language falls back to English");
        assert!(!ClaudeCommand::FinishSession.can_use_worktree());
        assert_eq!(ClaudeCommand::NextStep.name_source(&[]), "next step");
    }

    #[test]
    fn slugs_and_plans() {
        assert_eq!(slug("Добавить кнопку «Обновить»"), "dobavit-knopku-obnovit");
        assert_eq!(slug("Fix the checkout: page / totals & tax rounding today"), "fix-the-checkout-page-totals-tax");
        assert_eq!(slug("??"), "task");
        assert_eq!(slug("Їжак"), "izhak");
        let project = Path::new("/p/shop");
        let taken = |path: &Path, branch: &str| path.ends_with("cb-add-tests") || branch == "claude/add-tests-2";
        let plan = plan(project, "Add tests", taken);
        assert_eq!((plan.slug.as_str(), plan.branch.as_str()), ("add-tests-3", "claude/add-tests-3"));
        assert_eq!(plan.path, project.join(".claude").join("worktrees").join("cb-add-tests-3"));
    }

    #[test]
    fn busy_folders() {
        let project = Path::new("/p/shop");
        assert!(is_busy(project, &[PathBuf::from("/p/shop")]));
        assert!(is_busy(project, &[PathBuf::from("/p/shop/src")]));
        assert!(!is_busy(project, &[PathBuf::from("/p/shop/.claude/worktrees/cb-x")]));
        assert!(!is_busy(project, &[PathBuf::from("/p/shopping")]), "a folder of its own, not below");
        assert!(!is_busy(project, &[]));
    }

    #[test]
    fn lines_for_the_terminal() {
        assert_eq!(base64(b"Man"), "TWFu");
        assert_eq!(base64(b"Ma"), "TWE=");
        assert_eq!(base64(b"M"), "TQ==");
        assert_eq!(encode_powershell("ls"), "bABzAA==");
        assert_eq!(one_line("one\r\ntwo\n\n three"), "one two three");
        assert_eq!(
            powershell_script(Path::new(r"C:\Users\O'Neil\shop"), Path::new(r"C:\bin\claude.exe"), &["it's \"done\""]),
            r#"Set-Location -LiteralPath 'C:\Users\O''Neil\shop'; & 'C:\bin\claude.exe' 'it''s "done"'"#
        );
        assert_eq!(shell_line(Path::new("/bin/claude"), &["it's"]), r#"'/bin/claude' 'it'\''s'; exec "${SHELL:-sh}""#);
    }

    /// A real repository: the worktree comes from the base branch, on its own branch, with a free name.
    #[test]
    fn creates_a_worktree() {
        let tools = Tools { gh: None, ..Tools::find().expect("git on PATH") };
        let repo = std::env::temp_dir().join(format!("claudepult-launch-{}", std::process::id())).join("Магазин");
        let _ = std::fs::remove_dir_all(repo.parent().unwrap());
        std::fs::create_dir_all(&repo).unwrap();
        let run = |args: &[&str]| {
            let mut command = command::command(&tools.git);
            command.arg("-C").arg(&repo).args(["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]).args(args);
            assert!(command::run(command, Duration::from_secs(30)).unwrap().ok(), "git {args:?}");
        };
        run(&["init", "-q", "-b", "main"]);
        std::fs::write(repo.join("a.txt"), "a").unwrap();
        run(&["add", "."]);
        run(&["commit", "-q", "-m", "first"]);
        run(&["branch", "claude/add-tests"]);
        let plan = create_worktree(&tools, &repo, "Add tests", "main").unwrap();
        assert_eq!(plan.branch, "claude/add-tests-2", "the branch name is taken");
        assert!(plan.path.join("a.txt").is_file());
        assert!(create_worktree(&tools, &repo, "x", "no-such-ref").is_err());
        std::fs::remove_dir_all(repo.parent().unwrap()).unwrap();
    }

    /// The encoded script really runs: PowerShell goes into a folder with a Cyrillic and apostrophe name and runs a
    /// program with an argument full of quotes, as it will run Claude.
    #[cfg(windows)]
    #[test]
    fn powershell_runs_the_encoded_script() {
        let folder = std::env::temp_dir().join(format!("Проект O'Neil {}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let cmd = PathBuf::from(std::env::var_os("COMSPEC").unwrap());
        let script = powershell_script(&folder, &cmd, &["/c", "cd"]);
        let mut command = command::command(Path::new("powershell.exe"));
        command.args(["-NoProfile", "-NonInteractive", "-EncodedCommand", &encode_powershell(&script)]);
        let output = command::run(command, Duration::from_secs(60)).unwrap();
        assert!(output.ok());
        // cmd prints in the console's code page: only the Latin end of the name is compared.
        assert!(output.stdout.trim().ends_with(&format!("O'Neil {}", std::process::id())), "{}", output.stdout);
        std::fs::remove_dir_all(folder).unwrap();
    }
}
