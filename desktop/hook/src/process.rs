//! The Claude Code process above the hook: walking up the parents until `claude` (`claude.exe`), at most five
//! steps. Windows reads one process snapshot (Toolhelp); Linux and macOS ask `ps`, like the Mac hook.

#[cfg(windows)]
pub fn claude_pid() -> Option<u32> {
    use std::collections::HashMap;
    use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
    };

    // pid → (parent, exe name)
    let mut table: HashMap<u32, (u32, String)> = HashMap::new();
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == INVALID_HANDLE_VALUE {
            return None;
        }
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        if Process32FirstW(snapshot, &mut entry) != 0 {
            loop {
                let length = entry.szExeFile.iter().position(|&c| c == 0).unwrap_or(entry.szExeFile.len());
                let name = String::from_utf16_lossy(&entry.szExeFile[..length]);
                table.insert(entry.th32ProcessID, (entry.th32ParentProcessID, name));
                if Process32NextW(snapshot, &mut entry) == 0 {
                    break;
                }
            }
        }
        CloseHandle(snapshot);
    }
    let mut pid = table.get(&std::process::id())?.0;
    for _ in 0..5 {
        let (parent, name) = table.get(&pid)?;
        if name.eq_ignore_ascii_case("claude.exe") {
            return Some(pid);
        }
        if *parent == 0 || *parent == pid {
            return None;
        }
        pid = *parent;
    }
    None
}

#[cfg(unix)]
pub fn claude_pid() -> Option<u32> {
    let mut pid = std::os::unix::process::parent_id();
    for _ in 0..5 {
        let output = std::process::Command::new("ps").args(["-o", "ppid=,comm=", "-p", &pid.to_string()]).output().ok()?;
        let text = String::from_utf8_lossy(&output.stdout);
        let mut parts = text.trim().splitn(2, char::is_whitespace);
        let parent: u32 = parts.next()?.trim().parse().ok()?;
        let command = parts.next()?.trim();
        let name = command.rsplit('/').next().unwrap_or(command);
        if name == "claude" || name == "claude.exe" {
            return Some(pid);
        }
        if parent <= 1 {
            return None;
        }
        pid = parent;
    }
    None
}
