//! Agent CLIs other than Claude Code (docs/specs/SPEC-windows.md §5, the Mac's `AgentKind` and `AgentLocator`):
//! found in PATH and where their installers put them, with their version. They open in a terminal in the project
//! folder; the Mac checks their «no actions» modes live before running them unattended, so neither does this one.
//! Install commands for Windows from the vendors' docs (2026-11-18): npm for Codex and Gemini CLI, winget for
//! Copilot, the PowerShell installers of Antigravity and Cursor.

use crate::command;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub struct Kind {
    /// The Mac's `AgentKind` raw value, in service ids: `agent:codex`.
    pub id: &'static str,
    pub title: &'static str,
    /// In result names and lists: «Codex», «Gemini CLI».
    pub short: &'static str,
    pub binary: &'static str,
    /// How it signs in; AI Hub Bar never touches their tokens.
    pub login: &'static str,
    pub install_windows: &'static str,
    pub install_unix: &'static str,
}

pub const KINDS: [Kind; 5] = [
    Kind { id: "codex", title: "OpenAI Codex CLI", short: "Codex", binary: "codex", login: "codex login", install_windows: "npm install -g @openai/codex", install_unix: "npm install -g @openai/codex" },
    Kind { id: "gemini", title: "Google Gemini CLI", short: "Gemini CLI", binary: "gemini", login: "gemini → Sign in with Google", install_windows: "npm install -g @google/gemini-cli", install_unix: "npm install -g @google/gemini-cli" },
    Kind { id: "antigravity", title: "Google Antigravity CLI", short: "Antigravity", binary: "agy", login: "agy", install_windows: "irm https://antigravity.google/cli/install.ps1 | iex", install_unix: "antigravity.google/docs" },
    Kind { id: "copilot", title: "GitHub Copilot CLI", short: "Copilot", binary: "copilot", login: "copilot login", install_windows: "winget install GitHub.Copilot", install_unix: "npm install -g @github/copilot" },
    Kind { id: "cursor", title: "Cursor CLI", short: "Cursor", binary: "cursor-agent", login: "cursor-agent login", install_windows: "irm 'https://cursor.com/install?win32=true' | iex", install_unix: "curl https://cursor.com/install -fsS | bash" },
];

pub fn kind(id: &str) -> Option<&'static Kind> {
    KINDS.iter().find(|k| k.id == id)
}

impl Kind {
    pub fn install(&self) -> &'static str {
        if cfg!(windows) { self.install_windows } else { self.install_unix }
    }
}

/// Where installers put them when PATH doesn't say: npm's global folder, winget's links, the vendors' own folders;
/// on Linux the usual per-user prefixes. `local` is `%LOCALAPPDATA%`, `roaming` `%APPDATA%`.
pub fn candidates(kind: &Kind, home: &Path, local: Option<&Path>, roaming: Option<&Path>) -> Vec<PathBuf> {
    let mut list = Vec::new();
    if cfg!(windows) {
        let names: Vec<String> = match kind.id {
            "cursor" => vec!["cursor-agent.cmd".into(), "agent.cmd".into()],
            _ => [".cmd", ".exe"].iter().map(|ext| format!("{}{ext}", kind.binary)).collect(),
        };
        let mut folders = Vec::new();
        if let Some(roaming) = roaming {
            folders.push(roaming.join("npm"));
        }
        if let Some(local) = local {
            folders.push(local.join("Microsoft").join("WinGet").join("Links"));
            folders.push(local.join("agy").join("bin"));
            folders.push(local.join("cursor-agent"));
            folders.push(local.join("Programs").join(kind.binary));
        }
        folders.push(home.join(".local").join("bin"));
        for folder in folders {
            list.extend(names.iter().map(|name| folder.join(name)));
        }
    } else {
        for folder in [".local/bin", ".npm-global/bin", ".bun/bin", ".volta/bin", ".yarn/bin", ".cargo/bin", ".asdf/shims", ".local/share/mise/shims"] {
            list.push(home.join(folder).join(kind.binary));
        }
        list.push(PathBuf::from("/usr/local/bin").join(kind.binary));
        // npm under nvm, newest Node first.
        let nvm = home.join(".nvm").join("versions").join("node");
        let mut versions: Vec<PathBuf> = std::fs::read_dir(nvm).into_iter().flatten().flatten().map(|e| e.path()).collect();
        versions.sort();
        list.extend(versions.into_iter().rev().map(|v| v.join("bin").join(kind.binary)));
    }
    list
}

/// PATH first (with PATHEXT on Windows), then the usual places.
pub fn detect(kind: &Kind) -> Option<PathBuf> {
    if let Some(found) = command::find(kind.binary) {
        return Some(found);
    }
    let home = dirs::home_dir()?;
    let local = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
    let roaming = std::env::var_os("APPDATA").map(PathBuf::from);
    candidates(kind, &home, local.as_deref(), roaming.as_deref()).into_iter().find(|p| p.is_file())
}

/// The first line of `--version` without the product name the tool repeats («0.98.0 (Codex)» → «0.98.0»).
pub fn version_from_output(kind: &Kind, output: &str) -> Option<String> {
    let line = output.lines().find(|l| !l.trim().is_empty())?;
    let version = line.replace(&format!("({})", kind.title), "").replace(&format!("({})", kind.short), "").trim().to_owned();
    (!version.is_empty()).then_some(version)
}

pub fn version(kind: &Kind, path: &Path) -> Option<String> {
    let mut process = command::command(path);
    process.arg("--version");
    let output = command::run(process, Duration::from_secs(10))?;
    if output.code != Some(0) {
        return None;
    }
    version_from_output(kind, &output.stdout)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    pub id: &'static str,
    pub path: PathBuf,
    pub version: Option<String>,
}

/// Every installed agent with its version (each asked once, at most 10 s).
pub fn scan() -> Vec<Found> {
    KINDS.iter().filter_map(|kind| detect(kind).map(|path| Found { id: kind.id, version: version(kind, &path), path })).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds_and_versions() {
        assert_eq!(kind("copilot").map(|k| k.binary), Some("copilot"));
        assert!(kind("claude").is_none(), "Claude Code is found by `launch::find_claude`");
        let codex = kind("codex").unwrap();
        assert_eq!(version_from_output(codex, "codex-cli 0.98.0\n").as_deref(), Some("codex-cli 0.98.0"));
        assert_eq!(version_from_output(kind("cursor").unwrap(), "\n2026.11.10 (Cursor)\n").as_deref(), Some("2026.11.10"));
        assert_eq!(version_from_output(codex, "  \n"), None);
        assert!(kind("antigravity").unwrap().install_windows.starts_with("irm https://antigravity.google/"));
    }

    #[test]
    fn places() {
        let home = PathBuf::from("/home/o");
        let list = candidates(kind("cursor").unwrap(), &home, Some(Path::new("/L")), Some(Path::new("/R")));
        if cfg!(windows) {
            assert!(list.contains(&PathBuf::from("/L").join("cursor-agent").join("agent.cmd")));
            assert!(list.contains(&PathBuf::from("/R").join("npm").join("cursor-agent.cmd")));
        } else {
            assert!(list.contains(&home.join(".local/bin/cursor-agent")));
        }
    }

    /// A stand-in agent on disk: found in its installer's folder, its version read.
    #[test]
    fn a_stand_in_agent() {
        let dir = std::env::temp_dir().join(format!("claudepult-agents-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let codex = kind("codex").unwrap();
        let folder = if cfg!(windows) { dir.join("npm") } else { dir.join(".local").join("bin") };
        std::fs::create_dir_all(&folder).unwrap();
        let file = if cfg!(windows) { folder.join("codex.cmd") } else { folder.join("codex") };
        std::fs::write(&file, if cfg!(windows) { "@echo codex-cli 0.98.0\r\n" } else { "#!/bin/sh\necho 'codex-cli 0.98.0'\n" }).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let found = candidates(codex, &dir, Some(&dir), Some(&dir)).into_iter().find(|p| p.is_file());
        assert_eq!(found.as_deref(), Some(file.as_path()));
        assert_eq!(version(codex, &file).as_deref(), Some("codex-cli 0.98.0"));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
