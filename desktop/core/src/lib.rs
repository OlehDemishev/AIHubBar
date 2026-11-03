//! What the Windows and Linux versions of AI Hub Bar share and what can be tested on any system: where files live,
//! the settings file, the interface languages and the link between `claudepult` and the running app.
//! The Mac version (Swift) shares no code with this; only file formats and texts (docs/specs/SPEC-windows.md §2, §6).

pub mod hooks;
pub mod i18n;
pub mod ipc;
pub mod paths;
pub mod sessions;
pub mod settings;
pub mod texts;
pub mod tray_icon;
pub mod usage;

/// The name people see. The programs are `AIHubBar` and `claudepult`; data folders keep the old name `ClaudePult`, as on the Mac.
pub const APP_NAME: &str = "AI Hub Bar";
