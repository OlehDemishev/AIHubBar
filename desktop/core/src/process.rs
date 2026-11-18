//! Whether a process still runs, by its id: for the sessions (Claude's pid, SPEC-windows §4.3) and for the hooks that
//! wait on a permission request. None when it can't be told.

/// Some(true) while it runs, Some(false) once it is gone.
#[cfg(windows)]
pub fn is_alive(pid: u32) -> Option<bool> {
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ACCESS_DENIED, STILL_ACTIVE};
    use windows_sys::Win32::System::Threading::{GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION};
    if pid == 0 {
        return Some(false);
    }
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if handle.is_null() {
            // Another user's or an elevated process: it exists, we just may not look.
            return Some(GetLastError() == ERROR_ACCESS_DENIED);
        }
        let mut code = 0u32;
        let ok = GetExitCodeProcess(handle, &mut code) != 0;
        CloseHandle(handle);
        ok.then_some(code == STILL_ACTIVE as u32)
    }
}

#[cfg(unix)]
pub fn is_alive(pid: u32) -> Option<bool> {
    let pid = libc::pid_t::try_from(pid).ok().filter(|p| *p > 0)?;
    // Signal 0 only checks: EPERM means it runs under someone else.
    let result = unsafe { libc::kill(pid, 0) };
    Some(result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM))
}

/// When the process started, where the system tells it (Windows, Linux); None elsewhere or when it is gone. A pid kept
/// in a file outlives its process, so a run's pid counts as its own only with a start time near the run's.
#[cfg(windows)]
pub fn started_at(pid: u32) -> Option<std::time::SystemTime> {
    use windows_sys::Win32::Foundation::{CloseHandle, FILETIME};
    use windows_sys::Win32::System::Threading::{GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION};
    let empty = || FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
    let (mut created, mut exited, mut kernel, mut user) = (empty(), empty(), empty(), empty());
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if handle.is_null() {
            return None;
        }
        let ok = GetProcessTimes(handle, &mut created, &mut exited, &mut kernel, &mut user) != 0;
        CloseHandle(handle);
        if !ok {
            return None;
        }
    }
    // 100 ns steps since 1601-01-01.
    let ticks = (u64::from(created.dwHighDateTime) << 32) | u64::from(created.dwLowDateTime);
    let unix = ticks.checked_sub(116_444_736_000_000_000)?;
    Some(std::time::UNIX_EPOCH + std::time::Duration::from_nanos(unix * 100))
}

#[cfg(target_os = "linux")]
pub fn started_at(pid: u32) -> Option<std::time::SystemTime> {
    // Field 22 of /proc/<pid>/stat: clock ticks after boot; `btime` in /proc/stat: the boot, in seconds.
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let after_name = &stat[stat.rfind(')')? + 2..];
    let ticks: u64 = after_name.split_whitespace().nth(19)?.parse().ok()?;
    let boot: u64 = std::fs::read_to_string("/proc/stat").ok()?.lines().find_map(|l| l.strip_prefix("btime ")?.trim().parse().ok())?;
    let per_second = u64::try_from(unsafe { libc::sysconf(libc::_SC_CLK_TCK) }).ok().filter(|t| *t > 0)?;
    Some(std::time::UNIX_EPOCH + std::time::Duration::from_secs(boot) + std::time::Duration::from_millis(ticks * 1000 / per_second))
}

#[cfg(target_os = "macos")]
pub fn started_at(_pid: u32) -> Option<std::time::SystemTime> {
    None
}

/// The process runs and, where its start time is known, started within 30 s of `started`.
pub fn is_same_process(pid: u32, started: std::time::SystemTime) -> bool {
    if is_alive(pid) != Some(true) {
        return false;
    }
    match started_at(pid) {
        Some(at) => at.duration_since(started).unwrap_or_else(|e| e.duration()) < std::time::Duration::from_secs(30),
        None => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn start_times() {
        let now = std::time::SystemTime::now();
        let mut child = std::process::Command::new(if cfg!(windows) { "ping" } else { "sleep" })
            .args(if cfg!(windows) { &["-n", "3", "127.0.0.1"][..] } else { &["2"][..] })
            .stdout(std::process::Stdio::null())
            .spawn()
            .unwrap();
        assert!(is_same_process(child.id(), now));
        if cfg!(any(windows, target_os = "linux")) {
            let long_ago = now - std::time::Duration::from_secs(3600);
            assert!(!is_same_process(child.id(), long_ago), "a pid with another start time is someone else");
        }
        child.kill().unwrap();
        child.wait().unwrap();
        assert!(!is_same_process(child.id(), now));
    }

    #[test]
    fn this_one_and_a_finished_one() {
        assert_eq!(is_alive(std::process::id()), Some(true));
        let mut child = std::process::Command::new(if cfg!(windows) { "cmd" } else { "true" })
            .args(if cfg!(windows) { &["/c", "exit"][..] } else { &[][..] })
            .spawn()
            .unwrap();
        let pid = child.id();
        child.wait().unwrap();
        assert_eq!(is_alive(pid), Some(false), "a process that has exited and been reaped");
    }
}
