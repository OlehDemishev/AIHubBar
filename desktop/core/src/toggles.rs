//! «Быстрые переключатели» (SPEC-profiles §4.4, SPEC-windows §4.10), the Mac's `QuickToggle`: each runs only when
//! the person clicks it. On Windows: dark mode (the two `Personalize` values and `WM_SETTINGCHANGE`, as Settings
//! does), desktop icons (the same command as Explorer's «Show desktop icons»), lock (`LockWorkStation`), the display
//! off (`SC_MONITORPOWER`), the Recycle Bin emptied (`SHEmptyRecycleBinW`, after a confirmation). On Linux what GNOME
//! and its tools offer. «Извлечь диски» needs its own check and comes later; the island is the Mac's own.

use crate::i18n::Strings;

/// The Mac's `QuickToggle` names, in its order.
pub const TOGGLES: [&str; 5] = ["darkMode", "desktopIcons", "lockScreen", "displaySleep", "emptyTrash"];

pub fn title(toggle: &str, s: &Strings) -> String {
    s.t(match toggle {
        "darkMode" => "Тёмная тема",
        "desktopIcons" => "Значки на рабочем столе",
        "lockScreen" => "Заблокировать экран",
        "displaySleep" => "Погасить экран",
        _ => "Очистить корзину",
    })
    .to_owned()
}

/// Under the tile.
pub fn short_title(toggle: &str, s: &Strings) -> String {
    s.t(match toggle {
        "darkMode" => "Тема",
        "desktopIcons" => "Значки",
        "lockScreen" => "Замок",
        "displaySleep" => "Экран",
        _ => "Корзина",
    })
    .to_owned()
}

pub fn glyph(toggle: &str) -> &'static str {
    match toggle {
        "darkMode" => "◐",
        "desktopIcons" => "▦",
        "lockScreen" => "🔒",
        "displaySleep" => "🖥",
        _ => "🗑",
    }
}

/// Can't be undone: asked first.
pub fn needs_confirmation(toggle: &str) -> bool {
    toggle == "emptyTrash"
}

/// The toggles this system can do.
pub fn available() -> Vec<&'static str> {
    TOGGLES.into_iter().filter(|t| system::can(t)).collect()
}

/// On or off, for the toggles whose state can be read (dark mode, desktop icons).
pub fn state(toggle: &str) -> Option<bool> {
    system::state(toggle)
}

/// Does it. Ok(Some(note)) when there is something to say without it being an error («Корзина уже пуста»).
pub fn perform(toggle: &str, s: &Strings) -> Result<Option<String>, String> {
    if !TOGGLES.contains(&toggle) {
        return Err(format!("{toggle}: no such toggle"));
    }
    system::perform(toggle, s)
}

#[cfg(windows)]
mod system {
    use crate::i18n::Strings;
    use windows_sys::Win32::Foundation::{HWND, LPARAM};
    use windows_sys::Win32::System::Registry::{RegGetValueW, RegSetKeyValueW, HKEY_CURRENT_USER, REG_DWORD, RRF_RT_REG_DWORD};
    use windows_sys::Win32::System::Shutdown::LockWorkStation;
    use windows_sys::Win32::UI::Shell::{SHEmptyRecycleBinW, SHQueryRecycleBinW, SHERB_NOCONFIRMATION, SHERB_NOPROGRESSUI, SHERB_NOSOUND, SHQUERYRBINFO};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        EnumWindows, FindWindowExW, FindWindowW, PostMessageW, SendMessageTimeoutW, HWND_BROADCAST, SC_MONITORPOWER, SMTO_ABORTIFHUNG, WM_COMMAND, WM_SETTINGCHANGE, WM_SYSCOMMAND,
    };

    const PERSONALIZE: &str = r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    const ADVANCED: &str = r"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";
    /// Explorer's own «Show desktop icons» command on the desktop's view.
    const TOGGLE_DESKTOP_ICONS: usize = 0x7402;

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(Some(0)).collect()
    }

    fn read_dword(key: &str, value: &str) -> Option<u32> {
        let mut data = 0u32;
        let mut size = 4u32;
        let result = unsafe { RegGetValueW(HKEY_CURRENT_USER, wide(key).as_ptr(), wide(value).as_ptr(), RRF_RT_REG_DWORD, std::ptr::null_mut(), (&mut data as *mut u32).cast(), &mut size) };
        (result == 0).then_some(data)
    }

    fn write_dword(key: &str, value: &str, data: u32) -> bool {
        unsafe { RegSetKeyValueW(HKEY_CURRENT_USER, wide(key).as_ptr(), wide(value).as_ptr(), REG_DWORD, (&data as *const u32).cast(), 4) == 0 }
    }

    pub fn can(_toggle: &str) -> bool {
        true
    }

    pub fn state(toggle: &str) -> Option<bool> {
        match toggle {
            "darkMode" => Some(read_dword(PERSONALIZE, "AppsUseLightTheme").unwrap_or(1) == 0),
            "desktopIcons" => Some(read_dword(ADVANCED, "HideIcons").unwrap_or(0) == 0),
            _ => None,
        }
    }

    /// The window that draws the desktop's icons: under Progman, or under a WorkerW while a slideshow runs.
    fn desktop_view() -> HWND {
        unsafe extern "system" fn find(window: HWND, found: LPARAM) -> i32 {
            let class = wide("SHELLDLL_DefView");
            let view = unsafe { FindWindowExW(window, std::ptr::null_mut(), class.as_ptr(), std::ptr::null()) };
            if view.is_null() {
                return 1;
            }
            unsafe { *(found as *mut HWND) = view };
            0
        }
        unsafe {
            let progman = FindWindowW(wide("Progman").as_ptr(), std::ptr::null());
            let view = FindWindowExW(progman, std::ptr::null_mut(), wide("SHELLDLL_DefView").as_ptr(), std::ptr::null());
            if !view.is_null() {
                return view;
            }
            let mut found: HWND = std::ptr::null_mut();
            EnumWindows(Some(find), &mut found as *mut HWND as LPARAM);
            found
        }
    }

    pub fn perform(toggle: &str, s: &Strings) -> Result<Option<String>, String> {
        let failed = || s.t("Не получилось").to_owned();
        match toggle {
            "darkMode" => {
                let light = u32::from(state("darkMode") == Some(true));
                if !(write_dword(PERSONALIZE, "AppsUseLightTheme", light) && write_dword(PERSONALIZE, "SystemUsesLightTheme", light)) {
                    return Err(failed());
                }
                // Windows' own apps and the taskbar repaint on this, as when Settings switches the theme.
                let topic = wide("ImmersiveColorSet");
                let mut result = 0usize;
                unsafe { SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0, topic.as_ptr() as LPARAM, SMTO_ABORTIFHUNG, 1000, &mut result) };
                Ok(None)
            }
            "desktopIcons" => {
                let view = desktop_view();
                if view.is_null() {
                    return Err(failed());
                }
                let mut result = 0usize;
                unsafe { SendMessageTimeoutW(view, WM_COMMAND, TOGGLE_DESKTOP_ICONS, 0, SMTO_ABORTIFHUNG, 2000, &mut result) };
                // Explorer writes `HideIcons` after redrawing.
                std::thread::sleep(std::time::Duration::from_millis(300));
                Ok(None)
            }
            "lockScreen" => (unsafe { LockWorkStation() } != 0).then_some(None).ok_or_else(|| s.t("Не удалось заблокировать экран").to_owned()),
            "displaySleep" => {
                // The click that asked for it must not wake the display at once.
                std::thread::sleep(std::time::Duration::from_millis(600));
                (unsafe { PostMessageW(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER as usize, 2) } != 0).then_some(None).ok_or_else(|| s.t("Не удалось погасить экран").to_owned())
            }
            _ => {
                let mut info = SHQUERYRBINFO { cbSize: std::mem::size_of::<SHQUERYRBINFO>() as u32, ..Default::default() };
                if unsafe { SHQueryRecycleBinW(std::ptr::null(), &mut info) } == 0 && info.i64NumItems == 0 {
                    return Ok(Some(s.t("Корзина уже пуста").to_owned()));
                }
                let result = unsafe { SHEmptyRecycleBinW(std::ptr::null_mut(), std::ptr::null(), SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND) };
                if result == 0 { Ok(None) } else { Err(s.format("Не получилось: %@", &[&format!("0x{:08X}", result as u32)])) }
            }
        }
    }
}

#[cfg(all(unix, not(target_os = "macos")))]
mod system {
    use crate::i18n::Strings;
    use std::process::Command;

    fn tool(name: &str) -> bool {
        crate::command::find(name).is_some()
    }

    fn run(program: &str, args: &[&str]) -> Option<String> {
        let output = crate::command::run({
            let mut c = Command::new(program);
            c.args(args);
            c
        }, std::time::Duration::from_secs(10))?;
        output.ok().then_some(output.stdout)
    }

    /// GNOME's settings, lock through logind, the display through X11's DPMS, the trash through GIO.
    pub fn can(toggle: &str) -> bool {
        match toggle {
            "darkMode" => tool("gsettings"),
            "lockScreen" => tool("loginctl"),
            "displaySleep" => tool("xset") && std::env::var_os("DISPLAY").is_some(),
            "emptyTrash" => tool("gio"),
            _ => false,
        }
    }

    pub fn state(toggle: &str) -> Option<bool> {
        (toggle == "darkMode").then(|| run("gsettings", &["get", "org.gnome.desktop.interface", "color-scheme"]).is_some_and(|v| v.contains("dark")))
    }

    pub fn perform(toggle: &str, s: &Strings) -> Result<Option<String>, String> {
        let failed = || s.t("Не получилось").to_owned();
        let done = match toggle {
            "darkMode" => {
                let scheme = if state("darkMode") == Some(true) { "default" } else { "prefer-dark" };
                run("gsettings", &["set", "org.gnome.desktop.interface", "color-scheme", scheme])
            }
            "lockScreen" => run("loginctl", &["lock-session"]),
            "displaySleep" => {
                std::thread::sleep(std::time::Duration::from_millis(600));
                run("xset", &["dpms", "force", "off"])
            }
            "emptyTrash" => {
                let files = dirs::data_dir().map(|d| d.join("Trash/files"));
                if files.is_some_and(|f| std::fs::read_dir(f).map_or(true, |mut d| d.next().is_none())) {
                    return Ok(Some(s.t("Корзина уже пуста").to_owned()));
                }
                run("gio", &["trash", "--empty"])
            }
            _ => None,
        };
        done.map(|_| None).ok_or_else(failed)
    }
}

/// The Mac build is only for developing this one: the Mac app has its own toggles.
#[cfg(target_os = "macos")]
mod system {
    use crate::i18n::Strings;

    pub fn can(_toggle: &str) -> bool {
        false
    }

    pub fn state(_toggle: &str) -> Option<bool> {
        None
    }

    pub fn perform(_toggle: &str, s: &Strings) -> Result<Option<String>, String> {
        Err(s.t("Не получилось").to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_rules() {
        let s = Strings::from_json("{}");
        assert_eq!(TOGGLES.map(|t| short_title(t, &s)), ["Тема", "Значки", "Замок", "Экран", "Корзина"]);
        assert_eq!(title("emptyTrash", &s), "Очистить корзину");
        assert!(needs_confirmation("emptyTrash") && !needs_confirmation("lockScreen"));
        assert!(perform("ejectDisks", &s).is_err(), "not here yet");
        if cfg!(windows) {
            assert_eq!(available(), TOGGLES, "every toggle on Windows");
            assert!(state("darkMode").is_some() && state("desktopIcons").is_some() && state("lockScreen").is_none());
        }
        if cfg!(target_os = "macos") {
            assert!(available().is_empty());
        }
    }
}
