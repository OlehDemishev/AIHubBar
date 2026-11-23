//! «Другие аккаунты Claude» (the Mac's `ClaudeAccount` and `ClaudeAccountsStore`): Claude Code keeps each account in
//! its own config folder (`CLAUDE_CONFIG_DIR`), with its sign-in in that folder's `.credentials.json` — on a Mac in a
//! Keychain entry named after the folder, here in the file itself. The main account needs no entry. Only the limits
//! are read: history and forecast come from the journals, which belong to the main account.

use crate::agent_hooks::{ps_quote, sh_quote};
use crate::usage::{self, UsageError, UsageSnapshot, UsageWindow};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::{Path, PathBuf};

/// The Mac's `ClaudeAccount`, field for field.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeAccount {
    pub id: String,
    pub name: String,
    /// As chosen; `~` allowed.
    pub config_dir: String,
}

impl ClaudeAccount {
    /// A folder just chosen: named after the folder, kept with `~` when it is inside the home folder.
    pub fn new(folder: &Path, home: &Path) -> ClaudeAccount {
        let name = folder.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
        ClaudeAccount { id: crate::runs::new_id(), name, config_dir: crate::profiles::tilde(folder, home) }
    }

    pub fn expanded_dir(&self, home: &Path) -> PathBuf {
        crate::profiles::expand(&self.config_dir, home)
    }

    /// `claude auth login` for this account, as a line for a terminal: PowerShell on Windows, a shell elsewhere.
    pub fn sign_in_line(&self, claude: &Path, home: &Path) -> String {
        let (folder, claude) = (self.expanded_dir(home).to_string_lossy().into_owned(), claude.to_string_lossy().into_owned());
        if cfg!(windows) {
            format!("$env:CLAUDE_CONFIG_DIR = {}; & {} auth login", ps_quote(&folder), ps_quote(&claude))
        } else {
            format!("CLAUDE_CONFIG_DIR={} {} auth login", sh_quote(&folder), sh_quote(&claude))
        }
    }

    /// The account's limits now.
    pub fn read(&self, home: &Path, now: DateTime<Utc>) -> Result<UsageSnapshot, UsageError> {
        let credentials = usage::read_credentials(&self.expanded_dir(home), now)?;
        let body = usage::fetch(&credentials, now)?;
        UsageSnapshot::decode(&body, now).ok_or(UsageError::BadResponse)
    }
}

/// The accounts from `settings.json`: ones that don't read are skipped, ids made unique.
pub fn accounts(value: Option<&Value>) -> Vec<ClaudeAccount> {
    let mut seen = std::collections::HashSet::new();
    value
        .and_then(Value::as_array)
        .map(|list| list.iter().filter_map(|v| serde_json::from_value::<ClaudeAccount>(v.clone()).ok()).collect::<Vec<_>>())
        .unwrap_or_default()
        .into_iter()
        .map(|mut account| {
            if account.id.is_empty() || !seen.insert(account.id.clone()) {
                account.id = crate::runs::new_id();
                seen.insert(account.id.clone());
            }
            account
        })
        .collect()
}

/// A folder may be added once, and not the main account's own.
pub fn can_add(folder: &Path, existing: &[ClaudeAccount], main: &Path, home: &Path) -> bool {
    let same = |a: &Path, b: &Path| a.components().eq(b.components());
    !same(folder, main) && !existing.iter().any(|account| same(&account.expanded_dir(home), folder))
}

/// What the panel shows of an account: the session, the week and the other windows, as for the main account.
pub fn shown_windows(snapshot: &UsageSnapshot) -> Vec<&UsageWindow> {
    snapshot.session().into_iter().chain(snapshot.week()).chain(snapshot.shown_other_windows()).collect()
}

/// After HTTP 429 an account is left alone for half an hour, as on the Mac.
pub const RATE_LIMIT_PAUSE_MINUTES: i64 = 30;

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_macs_accounts_read_and_go_back() {
        let file = json!([
            {"id": "a", "name": "Работа", "configDir": "~/.claude-work"},
            {"id": "a", "name": "Второй", "configDir": "/srv/claude"},
            {"name": "no folder"}
        ]);
        let list = accounts(Some(&file));
        assert_eq!(list.len(), 2);
        assert_ne!(list[1].id, "a", "a repeated id is made new");
        assert_eq!(serde_json::to_value(&list[0]).unwrap(), file[0], "written back as it came");
        assert!(accounts(None).is_empty() && accounts(Some(&json!("x"))).is_empty());
    }

    #[test]
    fn folders_and_the_sign_in_line() {
        let home = if cfg!(windows) { Path::new("C:\\Users\\Олег") } else { Path::new("/home/oleh") };
        let folder = home.join(".claude-work");
        let account = ClaudeAccount::new(&folder, home);
        assert_eq!((account.name.as_str(), account.config_dir.as_str()), (".claude-work", "~/.claude-work"));
        assert_eq!(account.expanded_dir(home), folder);
        let main = home.join(".claude");
        assert!(!can_add(&main, &[], &main, home), "the main account's own folder");
        assert!(can_add(&folder, &[], &main, home) && !can_add(&folder, &[account.clone()], &main, home), "once");
        // A folder and a program with a space and a quote in their names.
        let odd = ClaudeAccount { config_dir: if cfg!(windows) { "D:\\My Claude's".into() } else { "/opt/my claude's".into() }, ..account };
        let line = odd.sign_in_line(Path::new(if cfg!(windows) { "C:\\Program Files\\claude.exe" } else { "/usr/local/bin/claude" }), home);
        if cfg!(windows) {
            assert_eq!(line, "$env:CLAUDE_CONFIG_DIR = 'D:\\My Claude''s'; & 'C:\\Program Files\\claude.exe' auth login");
        } else {
            assert_eq!(line, "CLAUDE_CONFIG_DIR='/opt/my claude'\\''s' '/usr/local/bin/claude' auth login");
        }
    }

    #[test]
    fn an_account_without_a_sign_in() {
        let folder = std::env::temp_dir().join(format!("claudepult-account-{}", crate::runs::new_id()));
        std::fs::create_dir_all(&folder).unwrap();
        let account = ClaudeAccount { id: "x".into(), name: "x".into(), config_dir: folder.to_string_lossy().into_owned() };
        let now = Utc::now();
        assert_eq!(account.read(Path::new("/nowhere"), now), Err(UsageError::NoCredentials), "no file yet");
        // A sign-in whose time is over: nothing is asked of the server.
        std::fs::write(folder.join(".credentials.json"), r#"{"claudeAiOauth": {"accessToken": "t", "expiresAt": 1000}}"#).unwrap();
        assert_eq!(account.read(Path::new("/nowhere"), now), Err(UsageError::Expired));
        std::fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn what_is_shown_of_an_account() {
        let body = r#"{"five_hour": {"utilization": 42, "resets_at": "2026-11-23T18:00:00Z"}, "seven_day": {"utilization": 31, "resets_at": "2026-11-27T10:00:00Z"}}"#;
        let snapshot = UsageSnapshot::decode(body, Utc::now()).unwrap();
        let keys: Vec<_> = shown_windows(&snapshot).iter().map(|w| w.key.as_str()).collect();
        assert_eq!(keys, ["five_hour", "seven_day"]);
    }
}
