//! Running other programs (`git`, `gh`, later `claude`) the way Windows needs it (desktop/CLAUDE.md, «Windows
//! pitfalls»): found through `PATH` and `PATHEXT` first, no console window, a time limit, and stdout read while the
//! program runs so a big output never blocks it.

use std::ffi::OsStr;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// The extensions a bare name may stand for: `PATHEXT` on Windows (`.COM;.EXE;.BAT;.CMD` by default), none elsewhere.
fn extensions(pathext: Option<&OsStr>) -> Vec<String> {
    if !cfg!(windows) {
        return vec![String::new()];
    }
    let list = pathext.and_then(OsStr::to_str).filter(|v| !v.trim().is_empty()).unwrap_or(".COM;.EXE;.BAT;.CMD");
    list.split(';').map(str::trim).filter(|e| e.starts_with('.')).map(str::to_ascii_lowercase).collect()
}

/// The first `name` (or `name` + an extension) in the folders of `path`, as a shell would find it.
pub fn find_in(name: &str, path: Option<&OsStr>, pathext: Option<&OsStr>) -> Option<PathBuf> {
    let has_extension = Path::new(name).extension().is_some();
    let extensions = extensions(pathext);
    std::env::split_paths(path?).find_map(|folder| {
        if has_extension && folder.join(name).is_file() {
            return Some(folder.join(name));
        }
        extensions.iter().map(|ext| folder.join(format!("{name}{ext}"))).find(|candidate| is_program(candidate))
    })
}

fn is_program(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata().is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    path.is_file()
}

/// A program by name from this process's `PATH`.
pub fn find(name: &str) -> Option<PathBuf> {
    find_in(name, std::env::var_os("PATH").as_deref(), std::env::var_os("PATHEXT").as_deref())
}

/// A command for the program with no window: `.cmd` and `.bat` go through `cmd /c`, which is how Windows runs them.
pub fn command(program: &Path) -> Command {
    let script = program.extension().and_then(OsStr::to_str).is_some_and(|e| e.eq_ignore_ascii_case("cmd") || e.eq_ignore_ascii_case("bat"));
    let mut command = if script && cfg!(windows) {
        let mut command = Command::new("cmd");
        command.arg("/c").arg(program);
        command
    } else {
        Command::new(program)
    };
    hide_window(&mut command);
    command
}

/// No console window flashing up behind the call on Windows.
pub fn hide_window(command: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(not(windows))]
    let _ = command;
}

pub struct Output {
    pub code: Option<i32>,
    pub stdout: String,
}

impl Output {
    pub fn ok(&self) -> bool {
        self.code == Some(0)
    }
}

/// Runs to the end or for `timeout` at most (then it is killed and the result is None). Stdin is empty, stderr is
/// dropped; stdout is read as UTF-8, broken bytes replaced. A program that ends but leaves a grandchild holding stdout
/// open is still waited for; `git` and `gh` don't.
pub fn run(mut command: Command, timeout: Duration) -> Option<Output> {
    command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    let mut child = command.spawn().ok()?;
    let mut stdout = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = stdout.read_to_end(&mut bytes);
        bytes
    });
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if started.elapsed() < timeout => std::thread::sleep(Duration::from_millis(15)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    // Killed: the reader is left to end on its own, since a grandchild (ssh under `git fetch`) may keep the pipe open.
    let status = status?;
    let bytes = reader.join().unwrap_or_default();
    Some(Output { code: status.code(), stdout: String::from_utf8_lossy(&bytes).into_owned() })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_programs_on_path() {
        let dir = std::env::temp_dir().join(format!("claudepult-command-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let (empty, bin) = (dir.join("empty"), dir.join("bin dir"));
        std::fs::create_dir_all(&empty).unwrap();
        std::fs::create_dir_all(&bin).unwrap();
        let name = if cfg!(windows) { "tool.cmd" } else { "tool" };
        std::fs::write(bin.join(name), "").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(bin.join(name), std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let path = std::env::join_paths([&empty, &bin]).unwrap();
        assert_eq!(find_in("tool", Some(&path), None), Some(bin.join(name)), "PATHEXT's .CMD on Windows");
        assert_eq!(find_in("missing", Some(&path), None), None);
        assert_eq!(find_in("tool", None, None), None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn runs_with_a_time_limit() {
        let git = find("git").expect("git on PATH");
        let mut version = command(&git);
        version.arg("--version");
        let output = run(version, Duration::from_secs(20)).unwrap();
        assert!(output.ok() && output.stdout.starts_with("git version"), "{}", output.stdout);

        let (program, args): (&str, &[&str]) =
            if cfg!(windows) { ("powershell", &["-NoProfile", "-Command", "Start-Sleep 5"]) } else { ("sleep", &["5"]) };
        let mut slow = command(&find(program).unwrap());
        slow.args(args);
        let started = Instant::now();
        assert!(run(slow, Duration::from_millis(300)).is_none());
        assert!(started.elapsed() < Duration::from_secs(4), "killed at the limit");
    }
}
