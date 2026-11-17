//! The hook for Codex CLI and Copilot CLI sessions (the Mac's `CodexHooks` and `CopilotHooks`): the same
//! `claudepult-hook` with `--agent codex|copilot` writes their sessions like Claude's.
//!
//! Neither takes Claude Code's exec form, so the program goes into a shell line, quoted for the shell that runs it:
//! - Codex reads `~/.codex/hooks.json` (Claude Code's shape). On Windows it runs `commandWindows` (Codex 0.131+) as
//!   `%COMSPEC% /C "<line>"` — cmd.exe, read in Codex's `hooks/src/engine/command_runner.rs` on 2026-11-17 — and
//!   `command` elsewhere through `sh`. Our entries are merged into the person's file, backed up first. Codex runs a
//!   new or changed hook only after the person trusts it once in `codex` → `/hooks`.
//! - Copilot reads every `*.json` in `~/.copilot/hooks/`; ours is a file of its own. `bash` runs on Unix,
//!   `powershell` on Windows (docs.github.com, Copilot hooks reference). No PermissionRequest: Copilot runs it
//!   before its own rules, so it doesn't mean a prompt is shown — the `permission_prompt` notification does.

use crate::hooks::{self, HookStatus, TIMEOUT_SECONDS};
use serde_json::{json, Map, Value};
use std::io;
use std::path::{Path, PathBuf};

pub const CODEX_EVENTS: [&str; 7] = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd"];
pub const COPILOT_EVENTS: [&str; 6] = ["SessionStart", "UserPromptSubmit", "Notification", "PostToolUse", "Stop", "SessionEnd"];

/// `'…'` for sh: nothing inside is special except `'` itself.
pub fn sh_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// `"…"` for cmd.exe. A Windows path can't hold `"`; a trailing `\` would escape the closing quote for the program's
/// own argument parser, so it goes.
pub fn cmd_quote(text: &str) -> String {
    let text = if text.len() > 3 { text.trim_end_matches('\\') } else { text };
    format!("\"{text}\"")
}

/// `'…'` for PowerShell: `'` doubled.
pub fn ps_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "''"))
}

fn args(agent: &str, projects_dir: &Path, quote: fn(&str) -> String) -> String {
    format!("--agent {agent} --projects-dir {}", quote(&projects_dir.to_string_lossy()))
}

// MARK: - Codex

/// Codex allows `SessionEnd` and `Interrupt` 3 seconds at most; PermissionRequest waits for the app's answer.
pub fn codex_timeout(event: &str) -> u64 {
    if matches!(event, "SessionEnd" | "Interrupt") {
        3
    } else {
        hooks::timeout_for(event)
    }
}

pub fn codex_entry(program: &Path, projects_dir: &Path, event: &str) -> Value {
    let program = program.to_string_lossy();
    json!({
        "type": "command",
        "command": format!("{} {}", sh_quote(&program), args("codex", projects_dir, sh_quote)),
        "commandWindows": format!("{} {}", cmd_quote(&program), args("codex", projects_dir, cmd_quote)),
        "timeout": codex_timeout(event),
    })
}

pub fn codex_status(path: &Path, program: &Path, projects_dir: &Path) -> HookStatus {
    match hooks::read_settings(path) {
        Ok(Some(file)) => hooks::status_entries(&file, &CODEX_EVENTS, |e| codex_entry(program, projects_dir, e)),
        _ => HookStatus::NotInstalled,
    }
}

/// Merges our entries in; returns the backup made (None when nothing changed or there was no file).
pub fn codex_install(path: &Path, program: &Path, projects_dir: &Path, stamp: &str) -> io::Result<Option<PathBuf>> {
    let current = hooks::read_settings(path)?;
    let file = hooks::merged_entries(current.as_ref().unwrap_or(&json!({})), &CODEX_EVENTS, |e| codex_entry(program, projects_dir, e));
    if current.as_ref() == Some(&file) {
        return Ok(None);
    }
    let made = hooks::backup(path, stamp)?;
    hooks::write(path, &file)?;
    Ok(made)
}

/// Takes our entries out; a file left with nothing else in it is removed (we made it).
pub fn codex_uninstall(path: &Path, stamp: &str) -> io::Result<Option<PathBuf>> {
    let Some(current) = hooks::read_settings(path)? else { return Ok(None) };
    let file = hooks::removed(&current);
    if file == current {
        return Ok(None);
    }
    let made = hooks::backup(path, stamp)?;
    if file.as_object().is_some_and(Map::is_empty) {
        std::fs::remove_file(path)?;
    } else {
        hooks::write(path, &file)?;
    }
    Ok(made)
}

// MARK: - Copilot

/// The whole file, as written.
pub fn copilot_configuration(program: &Path, projects_dir: &Path) -> Value {
    let program = program.to_string_lossy();
    let entry = json!({
        "type": "command",
        "bash": format!("{} {}", sh_quote(&program), args("copilot", projects_dir, sh_quote)),
        "powershell": format!("& {} {}", ps_quote(&program), args("copilot", projects_dir, ps_quote)),
        "timeoutSec": TIMEOUT_SECONDS,
    });
    let hooks: Map<String, Value> = COPILOT_EVENTS.iter().map(|e| ((*e).to_owned(), json!([entry.clone()]))).collect();
    json!({"version": 1, "hooks": hooks})
}

pub fn copilot_status(path: &Path, program: &Path, projects_dir: &Path) -> HookStatus {
    let Ok(text) = std::fs::read_to_string(path) else { return HookStatus::NotInstalled };
    match serde_json::from_str::<Value>(&text) {
        Ok(file) if file == copilot_configuration(program, projects_dir) => HookStatus::Installed,
        _ => HookStatus::Outdated,
    }
}

pub fn copilot_install(path: &Path, program: &Path, projects_dir: &Path) -> io::Result<()> {
    hooks::write(path, &copilot_configuration(program, projects_dir))
}

pub fn copilot_uninstall(path: &Path) -> io::Result<()> {
    match std::fs::remove_file(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PROGRAM: &str = r"C:\Users\Олег O'Neil\AppData\Local\Programs\AI Hub Bar\claudepult-hook.exe";
    const PROJECTS: &str = r"C:\Users\Олег O'Neil\Projects";

    #[test]
    fn quoting_per_shell() {
        assert_eq!(sh_quote("/a b/it's"), r"'/a b/it'\''s'");
        assert_eq!(cmd_quote(r"C:\a b\"), r#""C:\a b""#, "a trailing backslash would escape the quote");
        assert_eq!(cmd_quote(r"C:\"), r#""C:\""#, "a drive root keeps its backslash");
        assert_eq!(ps_quote("C:\\O'Neil"), "'C:\\O''Neil'");
    }

    #[test]
    fn codex_file() {
        let dir = std::env::temp_dir().join(format!("claudepult-codex-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("hooks.json");
        let (program, projects) = (Path::new(PROGRAM), Path::new(PROJECTS));
        let theirs = json!({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "notify-send done"}]}]}});
        hooks::write(&path, &theirs).unwrap();

        assert_eq!(codex_status(&path, program, projects), HookStatus::NotInstalled);
        assert!(codex_install(&path, program, projects, "1").unwrap().is_some(), "a backup of their file");
        let file = hooks::read_settings(&path).unwrap().unwrap();
        assert_eq!(codex_status(&path, program, projects), HookStatus::Installed);
        assert_eq!(file["hooks"]["Stop"].as_array().unwrap().len(), 2, "theirs and ours");
        let ours = &file["hooks"]["PermissionRequest"][0]["hooks"][0];
        assert_eq!(
            ours["commandWindows"],
            format!(r#""{PROGRAM}" --agent codex --projects-dir "{PROJECTS}""#),
            "cmd.exe: double quotes, the ' needs nothing"
        );
        assert!(ours["command"].as_str().unwrap().starts_with("'C:\\Users\\Олег O'\\''Neil"));
        assert_eq!(ours["timeout"], 300);
        assert_eq!(file["hooks"]["Interrupt"][0]["hooks"][0]["timeout"], 3, "Codex clamps Interrupt and SessionEnd to 3 s");
        assert_eq!(file["hooks"]["PostToolUse"][0]["matcher"], "*");
        assert!(codex_install(&path, program, projects, "2").unwrap().is_none(), "installing twice changes nothing");

        codex_uninstall(&path, "3").unwrap();
        assert_eq!(hooks::read_settings(&path).unwrap().unwrap(), theirs, "theirs stays exactly");
        hooks::write(&path, &json!({})).unwrap();
        codex_install(&path, program, projects, "4").unwrap();
        codex_uninstall(&path, "5").unwrap();
        assert!(!path.exists(), "a file with only ours goes");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn copilot_file() {
        let dir = std::env::temp_dir().join(format!("claudepult-copilot-{}", std::process::id()));
        let path = dir.join("hooks").join("aihubbar.json");
        let (program, projects) = (Path::new(PROGRAM), Path::new(PROJECTS));
        assert_eq!(copilot_status(&path, program, projects), HookStatus::NotInstalled);
        copilot_install(&path, program, projects).unwrap();
        assert_eq!(copilot_status(&path, program, projects), HookStatus::Installed);
        let file = copilot_configuration(program, projects);
        assert_eq!(
            file["hooks"]["Stop"][0]["powershell"],
            format!("& 'C:\\Users\\Олег O''Neil\\AppData\\Local\\Programs\\AI Hub Bar\\claudepult-hook.exe' --agent copilot --projects-dir 'C:\\Users\\Олег O''Neil\\Projects'")
        );
        assert!(file["hooks"].get("PermissionRequest").is_none());
        assert_eq!(copilot_status(&path, Path::new("/elsewhere/claudepult-hook"), projects), HookStatus::Outdated);
        copilot_uninstall(&path).unwrap();
        copilot_uninstall(&path).unwrap();
        assert_eq!(copilot_status(&path, program, projects), HookStatus::NotInstalled);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
