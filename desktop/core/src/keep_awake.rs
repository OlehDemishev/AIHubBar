//! «Не спать» (SPEC-profiles §4.2, SPEC-windows §4.10), the Mac's `KeepAwakeRules` / `KeepAwakeController`: the
//! computer doesn't sleep while a rule holds. Nothing in the system's settings changes: on Windows a power request
//! (`PowerCreateRequest`, seen in `powercfg /requests`), on Linux `systemd-inhibit`, on a Mac (only to develop this
//! version) `caffeinate`; when no rule holds, it is released and the computer sleeps as usual. «С закрытой крышкой»
//! needs the power plan changed and comes later (SPEC-windows §11.2).

use crate::i18n::Strings;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;

/// A program chosen for «Пока открыты приложения»: its file name (`obs64.exe`), matched without letter case.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct App {
    pub exe: String,
    pub name: String,
}

/// The rules, kept in `settings.json` as `keep_awake` (the Mac keeps them on that Mac too: they don't travel in
/// `.claudepult`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Rules {
    /// While a Claude Code session or a background run works.
    pub while_claude_works: bool,
    pub while_on_power: bool,
    pub while_external_display: bool,
    pub while_apps: Vec<App>,
    /// The display stays on too, not only the system.
    pub keep_display_on: bool,
}

impl Default for Rules {
    fn default() -> Self {
        Rules { while_claude_works: true, while_on_power: false, while_external_display: false, while_apps: Vec::new(), keep_display_on: false }
    }
}

impl Rules {
    /// Tolerant like the Mac's decoder: a broken field takes its default, the others stay.
    pub fn from_value(value: Option<&Value>) -> Rules {
        let defaults = Rules::default();
        let Some(value) = value.and_then(Value::as_object) else { return defaults };
        let flag = |key: &str, default: bool| value.get(key).and_then(Value::as_bool).unwrap_or(default);
        Rules {
            while_claude_works: flag("whileClaudeWorks", defaults.while_claude_works),
            while_on_power: flag("whileOnPower", false),
            while_external_display: flag("whileExternalDisplay", false),
            while_apps: value.get("whileApps").and_then(Value::as_array).into_iter().flatten().filter_map(|a| serde_json::from_value(a.clone()).ok()).collect(),
            keep_display_on: flag("keepDisplayOn", false),
        }
    }

    /// Why the computer is held awake, or None: a manual hold first, then the rules in the order they're listed.
    pub fn reason(&self, manual: Option<Manual>, situation: &Situation, now: DateTime<Utc>) -> Option<Reason> {
        match manual {
            Some(Manual::UntilOff) => return Some(Reason::Manual(None)),
            Some(Manual::Until(until)) if until > now => return Some(Reason::Manual(Some(until))),
            _ => {}
        }
        if self.while_claude_works && situation.claude_working {
            return Some(Reason::Claude);
        }
        if self.while_on_power && situation.on_power {
            return Some(Reason::Power);
        }
        if self.while_external_display && situation.external_display {
            return Some(Reason::Display);
        }
        self.while_apps.iter().find(|app| situation.running.contains(&app.exe.to_lowercase())).map(|app| Reason::App(app.name.clone()))
    }
}

/// What is around right now, as the rules see it.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Situation {
    pub claude_working: bool,
    pub on_power: bool,
    pub external_display: bool,
    /// Running programs' file names, lower case.
    pub running: HashSet<String>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Manual {
    UntilOff,
    Until(DateTime<Utc>),
}

impl Manual {
    /// Kept as the Mac keeps it: −1 — until switched off, else the end in seconds since 1970. A hold whose time
    /// passed while the app was closed is gone.
    pub fn from_stored(stored: Option<f64>, now: DateTime<Utc>) -> Option<Manual> {
        let stored = stored?;
        if stored < 0.0 {
            return Some(Manual::UntilOff);
        }
        let until = DateTime::from_timestamp(stored as i64, 0)?;
        (until > now).then_some(Manual::Until(until))
    }

    pub fn stored(self) -> f64 {
        match self {
            Manual::UntilOff => -1.0,
            Manual::Until(until) => until.timestamp() as f64,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Reason {
    /// None — until switched off.
    Manual(Option<DateTime<Utc>>),
    Claude,
    Power,
    Display,
    App(String),
}

/// The Mac's `KeepAwakeText.status`, with «компьютер» for «Mac».
pub fn status(reason: Option<&Reason>, now: DateTime<Utc>, s: &Strings) -> String {
    match reason {
        None => s.t("Компьютер засыпает как обычно").to_owned(),
        Some(Reason::Manual(None)) => s.t("держу до выключения").to_owned(),
        Some(Reason::Manual(Some(until))) => s.format("держу ещё %lld мин", &[&((*until - now).num_minutes().max(1)).to_string()]),
        Some(Reason::Claude) => s.t("держу: работает Claude").to_owned(),
        Some(Reason::Power) => s.t("держу: подключено питание").to_owned(),
        Some(Reason::Display) => s.t("держу: подключён монитор").to_owned(),
        Some(Reason::App(name)) => s.format("держу: запущено «%@»", &[name]),
    }
}

/// «Внешний монитор»: a laptop's second screen, or any screen of a computer without a battery (Windows can't tell
/// a laptop's own screen apart without asking each monitor).
pub fn external_display(monitors: u32, has_battery: bool) -> bool {
    if has_battery { monitors > 1 } else { monitors > 0 }
}

// MARK: - The system

/// What the system says: on mains power, has a battery, how many monitors, which programs run.
pub fn situation(claude_working: bool) -> Situation {
    let (on_power, has_battery) = system::power();
    Situation { claude_working, on_power, external_display: external_display(system::monitors(), has_battery), running: system::running() }
}

/// The hold itself: kept while wanted, released when dropped.
#[derive(Default)]
pub struct Hold {
    held: Option<(system::Handle, bool)>,
}

impl Hold {
    /// None releases; Some(display) holds the system, and the display too when asked. True when it holds now.
    pub fn set(&mut self, want: Option<bool>) -> bool {
        match (want, &self.held) {
            (None, _) => self.held = None,
            (Some(display), Some((_, held_display))) if *held_display == display => {}
            (Some(display), _) => {
                self.held = None;
                self.held = system::hold(display).map(|handle| (handle, display));
                if self.held.is_none() {
                    eprintln!("keep awake: the system refused the hold");
                }
            }
        }
        self.held.is_some()
    }
}

#[cfg(windows)]
mod system {
    use std::collections::HashSet;
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS};
    use windows_sys::Win32::System::Power::{
        GetSystemPowerStatus, PowerClearRequest, PowerCreateRequest, PowerRequestDisplayRequired, PowerRequestSystemRequired, PowerSetRequest, SYSTEM_POWER_STATUS,
    };
    use windows_sys::Win32::System::Threading::{POWER_REQUEST_CONTEXT_SIMPLE_STRING, REASON_CONTEXT, REASON_CONTEXT_0};
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetSystemMetrics, SM_CMONITORS};

    /// A power request; cleared and closed when dropped.
    pub struct Handle {
        handle: HANDLE,
        display: bool,
    }

    // The handle is a kernel object, usable from any thread.
    unsafe impl Send for Handle {}

    impl Drop for Handle {
        fn drop(&mut self) {
            unsafe {
                PowerClearRequest(self.handle, PowerRequestSystemRequired);
                if self.display {
                    PowerClearRequest(self.handle, PowerRequestDisplayRequired);
                }
                CloseHandle(self.handle);
            }
        }
    }

    pub fn hold(display: bool) -> Option<Handle> {
        // Shown by `powercfg /requests`.
        let mut reason: Vec<u16> = "AI Hub Bar: Не спать".encode_utf16().chain(Some(0)).collect();
        let context = REASON_CONTEXT { Version: 0, Flags: POWER_REQUEST_CONTEXT_SIMPLE_STRING, Reason: REASON_CONTEXT_0 { SimpleReasonString: reason.as_mut_ptr() } };
        unsafe {
            let handle = PowerCreateRequest(&context);
            if handle.is_null() || handle == INVALID_HANDLE_VALUE {
                return None;
            }
            let handle = Handle { handle, display };
            if PowerSetRequest(handle.handle, PowerRequestSystemRequired) == 0 {
                return None;
            }
            if display {
                PowerSetRequest(handle.handle, PowerRequestDisplayRequired);
            }
            Some(handle)
        }
    }

    /// (on mains power, has a battery); unknown counts as on power, as on the Mac.
    pub fn power() -> (bool, bool) {
        let mut status = SYSTEM_POWER_STATUS::default();
        if unsafe { GetSystemPowerStatus(&mut status) } == 0 {
            return (true, false);
        }
        (status.ACLineStatus != 0, status.BatteryFlag & 128 == 0 && status.BatteryFlag != 255)
    }

    pub fn monitors() -> u32 {
        u32::try_from(unsafe { GetSystemMetrics(SM_CMONITORS) }).unwrap_or(1)
    }

    pub fn running() -> HashSet<String> {
        let mut names = HashSet::new();
        unsafe {
            let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if snapshot == INVALID_HANDLE_VALUE {
                return names;
            }
            let mut entry = PROCESSENTRY32W { dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
            let mut more = Process32FirstW(snapshot, &mut entry) != 0;
            while more {
                let end = entry.szExeFile.iter().position(|&c| c == 0).unwrap_or(entry.szExeFile.len());
                names.insert(String::from_utf16_lossy(&entry.szExeFile[..end]).to_lowercase());
                more = Process32NextW(snapshot, &mut entry) != 0;
            }
            CloseHandle(snapshot);
        }
        names
    }
}

#[cfg(not(windows))]
mod system {
    use std::collections::HashSet;
    use std::process::{Child, Command, Stdio};

    /// `systemd-inhibit` on Linux, `caffeinate` on a Mac: the hold lasts while the child runs.
    pub struct Handle(Child);

    impl Drop for Handle {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    /// The child also ends with this process, so a crash never leaves the computer held awake.
    pub fn hold(display: bool) -> Option<Handle> {
        let pid = std::process::id().to_string();
        let mut command = if cfg!(target_os = "macos") {
            let mut c = Command::new("caffeinate");
            c.args([if display { "-di" } else { "-i" }, "-w", &pid]);
            c
        } else {
            let mut c = Command::new("systemd-inhibit");
            c.args([if display { "--what=idle:sleep" } else { "--what=sleep" }, "--who=AI Hub Bar", "--why=Не спать", "--mode=block", "tail", "--pid", &pid, "-f", "/dev/null"]);
            c
        };
        command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().ok().map(Handle)
    }

    /// Linux: `/sys/class/power_supply` (a «Mains» or «USB» supply online, a «Battery» present); elsewhere on power.
    pub fn power() -> (bool, bool) {
        let mut on_power = None;
        let mut battery = false;
        for entry in std::fs::read_dir("/sys/class/power_supply").into_iter().flatten().flatten() {
            let read = |name: &str| std::fs::read_to_string(entry.path().join(name)).unwrap_or_default().trim().to_owned();
            match read("type").as_str() {
                "Battery" => battery = true,
                "Mains" | "USB" => on_power = Some(on_power.unwrap_or(false) || read("online") == "1"),
                _ => {}
            }
        }
        (on_power.unwrap_or(true), battery)
    }

    /// Linux: connected outputs in `/sys/class/drm`; one elsewhere.
    pub fn monitors() -> u32 {
        let connected = std::fs::read_dir("/sys/class/drm")
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| std::fs::read_to_string(e.path().join("status")).is_ok_and(|s| s.trim() == "connected"))
            .count();
        u32::try_from(connected).unwrap_or(1).max(1)
    }

    /// Linux: `/proc/<pid>/comm`; nothing elsewhere.
    pub fn running() -> HashSet<String> {
        std::fs::read_dir("/proc")
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().chars().all(|c| c.is_ascii_digit()))
            .filter_map(|e| std::fs::read_to_string(e.path().join("comm")).ok())
            .map(|name| name.trim().to_lowercase())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn rules_and_reasons() {
        let now = Utc::now();
        let rules = Rules::from_value(Some(&json!({"whileOnPower": true, "whileApps": [{"exe": "OBS64.exe", "name": "OBS"}, {"bad": 1}], "keepDisplayOn": "x"})));
        assert_eq!((rules.while_claude_works, rules.while_on_power, rules.while_apps.len(), rules.keep_display_on), (true, true, 1, false));
        assert_eq!(Rules::from_value(None), Rules::default());
        let idle = Situation::default();
        assert_eq!(rules.reason(None, &idle, now), None);
        let busy = Situation { claude_working: true, on_power: true, ..Situation::default() };
        assert_eq!(rules.reason(None, &busy, now), Some(Reason::Claude), "Claude comes before power");
        assert_eq!(rules.reason(Some(Manual::UntilOff), &busy, now), Some(Reason::Manual(None)), "a manual hold first");
        let past = Manual::Until(now - chrono::Duration::minutes(1));
        assert_eq!(rules.reason(Some(past), &idle, now), None, "a hold whose time passed");
        let obs = Situation { running: ["obs64.exe".to_owned()].into(), ..Situation::default() };
        assert_eq!(rules.reason(None, &obs, now), Some(Reason::App("OBS".into())), "names match without letter case");
        let display = Rules { while_external_display: true, ..Rules::default() };
        assert_eq!(display.reason(None, &Situation { external_display: true, ..Situation::default() }, now), Some(Reason::Display));
        let saved = serde_json::to_value(&rules).unwrap();
        assert_eq!(saved["whileApps"][0]["exe"], "OBS64.exe");
        assert_eq!(Rules::from_value(Some(&saved)), rules);
    }

    #[test]
    fn manual_hold_and_texts() {
        let now = DateTime::from_timestamp(1_800_000_000, 0).unwrap();
        assert_eq!(Manual::from_stored(Some(-1.0), now), Some(Manual::UntilOff));
        assert_eq!(Manual::from_stored(Some(1_800_000_600.0), now), Some(Manual::Until(now + chrono::Duration::minutes(10))));
        assert_eq!(Manual::from_stored(Some(1_799_999_000.0), now), None);
        assert_eq!(Manual::from_stored(None, now), None);
        assert_eq!(Manual::Until(now).stored(), 1_800_000_000.0);
        let s = Strings::from_json("{}");
        assert_eq!(status(None, now, &s), "Компьютер засыпает как обычно");
        assert_eq!(status(Some(&Reason::Manual(Some(now + chrono::Duration::seconds(2830)))), now, &s), "держу ещё 47 мин");
        assert_eq!(status(Some(&Reason::Manual(Some(now + chrono::Duration::seconds(20)))), now, &s), "держу ещё 1 мин");
        assert_eq!(status(Some(&Reason::App("OBS".into())), now, &s), "держу: запущено «OBS»");
        assert!(!external_display(1, true) && external_display(2, true) && external_display(1, false));
    }

    #[test]
    fn the_system_answers() {
        // Whatever this machine is: the calls work and a hold can be taken and released.
        let found = situation(false);
        assert!(!found.claude_working);
        let mut hold = Hold::default();
        let held = hold.set(Some(false));
        if cfg!(windows) {
            assert!(held, "Windows grants a power request to any program");
        }
        hold.set(None);
        assert!(!hold.set(None));
    }
}
