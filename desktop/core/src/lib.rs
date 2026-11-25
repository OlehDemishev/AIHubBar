//! What the Windows and Linux versions of AI Hub Bar share and what can be tested on any system: where files live,
//! the settings file, the interface languages and the link between `claudepult` and the running app.
//! The Mac version (Swift) shares no code with this; only file formats and texts (docs/specs/SPEC-windows.md §2, §6).

pub mod agent_hooks;
pub mod agents;
pub mod ai;
pub mod assistant;
pub mod approvals;
pub mod calendar;
pub mod calendar_ics;
pub mod claude_accounts;
pub mod claude_config;
pub mod clipboard;
pub mod command;
pub mod commands;
pub mod crash;
pub mod docx;
pub mod feedback;
pub mod folders;
pub mod help;
pub mod hot_keys;
pub mod hub;
pub mod hooks;
pub mod i18n;
pub mod ipc;
pub mod keep_awake;
pub mod keys;
pub mod launch;
pub mod local_servers;
pub mod notes;
pub mod pair_compare;
pub mod paths;
pub mod process;
pub mod profiles;
pub mod queue;
pub mod quick_commands;
pub mod quick_prompt;
pub mod resources;
pub mod projects;
pub mod runs;
pub mod search;
pub mod session_changes;
pub mod sessions;
pub mod telegram;
pub mod settings;
pub mod stuck;
pub mod texts;
pub mod token_usage;
pub mod toggles;
pub mod tray_icon;
pub mod usage;
pub mod versions;
pub mod word_goal;
pub mod whats_new;

/// The name people see. The programs are `AIHubBar` and `claudepult`; data folders keep the old name `ClaudePult`, as on the Mac.
pub const APP_NAME: &str = "AI Hub Bar";
