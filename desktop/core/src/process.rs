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

/// Freezes the process and what it started, where they are; `resume_tree` lets them go on. For the limit guard: a
/// background run near a limit waits for the reset instead of being cut off by it. On a Mac and Linux this is the
/// Mac app's SIGSTOP of the process itself; Windows has no such signal, so the process and each of its descendants
/// is suspended. False when the process could not be reached.
#[cfg(windows)]
pub fn suspend_tree(pid: u32) -> bool {
    // The root first: it starts nothing new while its children are looked up.
    let reached = windows_tree::each(&[pid], true);
    windows_tree::each(&windows_tree::descendants(pid), true);
    reached
}

#[cfg(windows)]
pub fn resume_tree(pid: u32) -> bool {
    windows_tree::each(&windows_tree::descendants(pid), false);
    windows_tree::each(&[pid], false)
}

#[cfg(windows)]
mod windows_tree {
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS};
    use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_SUSPEND_RESUME};

    // What Process Explorer's «Suspend» calls: every thread of the process at once.
    #[link(name = "ntdll")]
    extern "system" {
        fn NtSuspendProcess(process: HANDLE) -> i32;
        fn NtResumeProcess(process: HANDLE) -> i32;
    }

    /// True when every process was reached.
    pub fn each(pids: &[u32], suspend: bool) -> bool {
        let mut all = true;
        for pid in pids {
            unsafe {
                let handle = OpenProcess(PROCESS_SUSPEND_RESUME, 0, *pid);
                if handle.is_null() {
                    all = false;
                    continue;
                }
                let status = if suspend { NtSuspendProcess(handle) } else { NtResumeProcess(handle) };
                all &= status >= 0;
                CloseHandle(handle);
            }
        }
        all
    }

    /// Every process started by `root` or by what it started, as the system lists them now. A parent's id can be
    /// one a gone process had, so a child counts only when it is younger than its parent.
    pub fn descendants(root: u32) -> Vec<u32> {
        let mut pairs: Vec<(u32, u32)> = Vec::new();
        unsafe {
            let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if snapshot == INVALID_HANDLE_VALUE {
                return Vec::new();
            }
            let mut entry: PROCESSENTRY32W = std::mem::zeroed();
            entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
            let mut more = Process32FirstW(snapshot, &mut entry) != 0;
            while more {
                pairs.push((entry.th32ProcessID, entry.th32ParentProcessID));
                more = Process32NextW(snapshot, &mut entry) != 0;
            }
            CloseHandle(snapshot);
        }
        let mut found = vec![root];
        let mut next = 0;
        while next < found.len() {
            let parent = found[next];
            next += 1;
            let born = super::started_at(parent);
            for (pid, of) in &pairs {
                let younger = match (born, super::started_at(*pid)) {
                    (Some(parent), Some(child)) => child >= parent,
                    _ => true,
                };
                if *of == parent && *pid != 0 && younger && !found.contains(pid) {
                    found.push(*pid);
                }
            }
        }
        found.remove(0);
        found
    }
}

#[cfg(unix)]
pub fn suspend_tree(pid: u32) -> bool {
    libc::pid_t::try_from(pid).is_ok_and(|pid| pid > 0 && unsafe { libc::kill(pid, libc::SIGSTOP) } == 0)
}

#[cfg(unix)]
pub fn resume_tree(pid: u32) -> bool {
    libc::pid_t::try_from(pid).is_ok_and(|pid| pid > 0 && unsafe { libc::kill(pid, libc::SIGCONT) } == 0)
}

#[cfg(test)]
mod freeze_tests {
    use super::*;
    use std::time::Duration;

    /// A loop that adds a line to a file a few times a second stands still while frozen and goes on after.
    #[test]
    fn a_frozen_process_stands_still() {
        let file = std::env::temp_dir().join(format!("claudepult-freeze-{}.txt", std::process::id()));
        let _ = std::fs::remove_file(&file);
        let mut command = if cfg!(windows) {
            let mut command = std::process::Command::new("cmd");
            // As typed: `cmd` reads its own line, the usual quoting would break the redirect.
            #[cfg(windows)]
            std::os::windows::process::CommandExt::raw_arg(&mut command, format!("/c for /l %i in (1,1,200) do @(echo x>>\"{}\" & ping -n 1 -w 200 192.0.2.1 >nul)", file.display()));
            command
        } else {
            let mut command = std::process::Command::new("sh");
            command.args(["-c", &format!("while true; do echo x >> '{}'; sleep 0.2; done", file.display())]);
            command
        };
        let mut child = command.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).spawn().unwrap();
        let size = || std::fs::metadata(&file).map(|m| m.len()).unwrap_or(0);
        let wait_for_growth = |from: u64| (0..100).any(|_| { std::thread::sleep(Duration::from_millis(100)); size() > from });
        assert!(wait_for_growth(0), "the loop writes");

        assert!(suspend_tree(child.id()));
        // What was already on its way lands; then nothing more.
        std::thread::sleep(Duration::from_millis(700));
        let frozen = size();
        std::thread::sleep(Duration::from_millis(1500));
        assert_eq!(size(), frozen, "nothing is written while frozen");

        assert!(resume_tree(child.id()));
        assert!(wait_for_growth(frozen), "and it goes on after");

        crate::runs::kill(child.id(), true);
        let _ = child.kill();
        let _ = child.wait();
        let _ = std::fs::remove_file(&file);
        assert!(!suspend_tree(0), "no such process");
    }
}
