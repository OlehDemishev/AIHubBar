//! Where AI Hub Bar keeps its files (docs/specs/SPEC-windows.md §6, docs/specs/SPEC-linux.md §6).
//!
//! - Windows: `%LOCALAPPDATA%\ClaudePult\` — machine-local, sessions and runs don't roam with the profile.
//! - Linux: `$XDG_DATA_HOME/claudepult/` (`~/.local/share/claudepult/`).
//! - macOS, only for developing this version: `~/Library/Application Support/ClaudePult Desktop Dev/`, so it never
//!   touches the real Mac app's folder.

use std::path::{Path, PathBuf};

/// The folder for settings, sessions, runs and logs; `base` is the system's local data folder.
pub fn data_dir_in(base: &Path) -> PathBuf {
    if cfg!(target_os = "windows") {
        base.join("ClaudePult")
    } else if cfg!(target_os = "macos") {
        base.join("ClaudePult Desktop Dev")
    } else {
        base.join("claudepult")
    }
}

pub fn data_dir() -> PathBuf {
    data_dir_in(&dirs::data_local_dir().unwrap_or_else(std::env::temp_dir))
}

pub fn settings_file() -> PathBuf {
    data_dir().join("settings.json")
}

pub fn sessions_dir() -> PathBuf {
    data_dir().join("sessions")
}

/// Permission requests from the hook and the app's answers (`approvals.rs`); next to `sessions/`, as the hook expects.
pub fn approvals_dir() -> PathBuf {
    data_dir().join("approvals")
}

pub fn runs_dir() -> PathBuf {
    data_dir().join("runs")
}

pub fn logs_dir() -> PathBuf {
    data_dir().join("logs")
}

/// Claude Code's own folder: `CLAUDE_CONFIG_DIR` when set, else `~/.claude` (`%USERPROFILE%\.claude` on Windows).
pub fn claude_dir_from(config_dir: Option<&str>, home: &Path) -> PathBuf {
    match config_dir.map(str::trim).filter(|value| !value.is_empty()) {
        Some(dir) => PathBuf::from(dir),
        None => home.join(".claude"),
    }
}

/// Codex's folder: `CODEX_HOME` when set, else `~/.codex`.
pub fn codex_dir() -> PathBuf {
    let home = dirs::home_dir().unwrap_or_else(std::env::temp_dir);
    std::env::var("CODEX_HOME").ok().filter(|v| !v.trim().is_empty()).map(PathBuf::from).unwrap_or_else(|| home.join(".codex"))
}

/// Copilot CLI's folder: `COPILOT_HOME` when set, else `~/.copilot`.
pub fn copilot_dir() -> PathBuf {
    let home = dirs::home_dir().unwrap_or_else(std::env::temp_dir);
    std::env::var("COPILOT_HOME").ok().filter(|v| !v.trim().is_empty()).map(PathBuf::from).unwrap_or_else(|| home.join(".copilot"))
}

/// The projects folder: `~/Projects` (`%USERPROFILE%\\Projects` on Windows), as on the Mac; a setting comes with
/// profiles (stage 5).
pub fn projects_dir() -> PathBuf {
    dirs::home_dir().unwrap_or_else(std::env::temp_dir).join("Projects")
}

pub fn claude_dir() -> PathBuf {
    let home = dirs::home_dir().unwrap_or_else(std::env::temp_dir);
    claude_dir_from(std::env::var("CLAUDE_CONFIG_DIR").ok().as_deref(), &home)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn own_folder_per_system() {
        let dir = data_dir_in(Path::new("/base"));
        let name = dir.file_name().unwrap().to_str().unwrap();
        if cfg!(target_os = "windows") {
            assert_eq!(name, "ClaudePult");
        } else if cfg!(target_os = "macos") {
            assert_eq!(name, "ClaudePult Desktop Dev", "never the Mac app's own folder");
        } else {
            assert_eq!(name, "claudepult");
        }
        assert!(settings_file().ends_with("settings.json"));
    }

    #[test]
    fn claude_folder() {
        let home = Path::new("/home/me");
        assert_eq!(claude_dir_from(None, home), home.join(".claude"));
        assert_eq!(claude_dir_from(Some("  "), home), home.join(".claude"));
        assert_eq!(claude_dir_from(Some("/elsewhere"), home), PathBuf::from("/elsewhere"));
    }
}
