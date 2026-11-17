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

#[cfg(test)]
mod tests {
    use super::is_alive;

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
