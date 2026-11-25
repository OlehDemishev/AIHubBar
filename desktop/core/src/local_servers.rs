//! «Локальные серверы» (the Mac's `LocalServers`): a process that listens on a TCP port and runs inside a project
//! folder — a dev server, a preview, a database started from the project. Only the person's own processes are seen:
//! the system's TCP table names each listening port's process (`GetExtendedTcpTable` on Windows, `/proc/net/tcp` on
//! Linux) and the process's working folder says which project it belongs to.

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct LocalServer {
    pub pid: u32,
    /// The program, «node.exe».
    pub command: String,
    pub port: u16,
    /// The process's working folder.
    pub folder: PathBuf,
}

impl LocalServer {
    pub fn id(&self) -> String {
        format!("{}:{}", self.pid, self.port)
    }

    pub fn url(&self) -> String {
        format!("http://localhost:{}", self.port)
    }
}

/// Every listening process of the person with a working folder, by port then process.
pub fn scan() -> Vec<LocalServer> {
    let listeners = listening();
    if listeners.is_empty() {
        return Vec::new();
    }
    let pids: Vec<sysinfo::Pid> = listeners.iter().map(|(pid, _)| sysinfo::Pid::from_u32(*pid)).collect::<BTreeSet<_>>().into_iter().collect();
    let Ok(mut system) = sysinfo::System::new() else { return Vec::new() };
    let refresh = sysinfo::ProcessRefreshKind::nothing().with_cwd(sysinfo::UpdateKind::Always).with_exe(sysinfo::UpdateKind::Always);
    system.refresh_processes_specifics(sysinfo::ProcessesToUpdate::Some(&pids), true, refresh);
    let mut servers: Vec<LocalServer> = listeners
        .into_iter()
        .filter_map(|(pid, port)| {
            let process = system.process(sysinfo::Pid::from_u32(pid))?;
            let folder = process.cwd()?.to_path_buf();
            let command = process.exe().and_then(Path::file_name).unwrap_or_else(|| process.name()).to_string_lossy().into_owned();
            Some(LocalServer { pid, command, port, folder })
        })
        .collect();
    servers.sort_by_key(|server| (server.port, server.pid));
    servers.dedup_by(|a, b| a.port == b.port && a.pid == b.pid);
    servers
}

/// The servers that run in a project's folder or below it (its worktrees too). Windows' folders are compared
/// without regard to case, as Windows does.
pub fn servers_in(all: &[LocalServer], project: &Path) -> Vec<LocalServer> {
    let normal = |path: &Path| {
        let text = path.to_string_lossy().replace('\\', "/");
        let text = text.trim_end_matches('/').to_owned();
        if cfg!(windows) { text.to_lowercase() } else { text }
    };
    let root = normal(project);
    all.iter()
        .filter(|server| {
            let folder = normal(&server.folder);
            folder == root || folder.starts_with(&(root.clone() + "/"))
        })
        .cloned()
        .collect()
}

/// Asks the process to quit — only if it still listens on that port from that folder, so a process id that has passed
/// to another program is left alone. On Windows there is no polite signal for a console program: it is ended.
pub fn stop(server: &LocalServer) -> bool {
    if server.pid == 0 || !scan().contains(server) {
        return false;
    }
    crate::runs::kill(server.pid, false);
    true
}

/// (pid, port) of every listening TCP socket; a port on IPv4 and IPv6 is kept once.
#[cfg(windows)]
fn listening() -> Vec<(u32, u16)> {
    use windows_sys::Win32::NetworkManagement::IpHelper::{GetExtendedTcpTable, MIB_TCP6ROW_OWNER_PID, MIB_TCPROW_OWNER_PID, TCP_TABLE_OWNER_PID_LISTENER};
    fn table(family: u32) -> Vec<u8> {
        let mut size = 0u32;
        unsafe { GetExtendedTcpTable(std::ptr::null_mut(), &mut size, 0, family, TCP_TABLE_OWNER_PID_LISTENER, 0) };
        // The table can grow between the two calls: a little room, and once more if it still did not fit.
        for _ in 0..3 {
            let mut buffer = vec![0u8; size as usize + 1024];
            let mut room = buffer.len() as u32;
            let result = unsafe { GetExtendedTcpTable(buffer.as_mut_ptr().cast(), &mut room, 0, family, TCP_TABLE_OWNER_PID_LISTENER, 0) };
            if result == 0 {
                return buffer;
            }
            size = room;
        }
        Vec::new()
    }
    fn rows<T: Copy>(buffer: &[u8]) -> Vec<T> {
        if buffer.len() < 4 {
            return Vec::new();
        }
        let count = u32::from_ne_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]) as usize;
        // The rows start after the count, at the row type's alignment.
        let start = std::mem::align_of::<T>().max(4);
        (0..count)
            .filter_map(|i| {
                let at = start + i * std::mem::size_of::<T>();
                (at + std::mem::size_of::<T>() <= buffer.len()).then(|| unsafe { std::ptr::read_unaligned(buffer[at..].as_ptr().cast::<T>()) })
            })
            .collect()
    }
    let port = |raw: u32| u16::from_be((raw & 0xffff) as u16);
    let mut found: Vec<(u32, u16)> = rows::<MIB_TCPROW_OWNER_PID>(&table(2)).into_iter().map(|row| (row.dwOwningPid, port(row.dwLocalPort))).collect();
    found.extend(rows::<MIB_TCP6ROW_OWNER_PID>(&table(23)).into_iter().map(|row| (row.dwOwningPid, port(row.dwLocalPort))));
    found.retain(|(pid, _)| *pid > 4);
    found.sort();
    found.dedup();
    found
}

/// (pid, port) of every listening TCP socket: `/proc/net/tcp` and `tcp6` give the socket's inode, `/proc/<pid>/fd`
/// the process that holds it (only the person's own processes can be read).
#[cfg(not(windows))]
fn listening() -> Vec<(u32, u16)> {
    let mut ports: HashMap<u64, u16> = HashMap::new();
    for file in ["/proc/net/tcp", "/proc/net/tcp6"] {
        ports.extend(parse_proc_tcp(&std::fs::read_to_string(file).unwrap_or_default()));
    }
    if ports.is_empty() {
        return Vec::new();
    }
    let mut found = Vec::new();
    for entry in std::fs::read_dir("/proc").into_iter().flatten().flatten() {
        let Some(pid) = entry.file_name().to_str().and_then(|name| name.parse::<u32>().ok()) else { continue };
        for fd in std::fs::read_dir(entry.path().join("fd")).into_iter().flatten().flatten() {
            let Ok(link) = std::fs::read_link(fd.path()) else { continue };
            let link = link.to_string_lossy();
            let inode = link.strip_prefix("socket:[").and_then(|rest| rest.strip_suffix(']')).and_then(|n| n.parse::<u64>().ok());
            if let Some(port) = inode.and_then(|inode| ports.get(&inode)) {
                found.push((pid, *port));
            }
        }
    }
    found.sort();
    found.dedup();
    found
}

/// `/proc/net/tcp` rows in the listening state (`0A`): the socket's inode and its local port (hex after the colon).
pub fn parse_proc_tcp(text: &str) -> HashMap<u64, u16> {
    text.lines()
        .skip(1)
        .filter_map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            if fields.get(3) != Some(&"0A") {
                return None;
            }
            let port = u16::from_str_radix(fields.get(1)?.rsplit(':').next()?, 16).ok()?;
            let inode = fields.get(9)?.parse::<u64>().ok()?;
            Some((inode, port))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn server(port: u16, folder: &str) -> LocalServer {
        LocalServer { pid: 100 + u32::from(port), command: "node.exe".into(), port, folder: PathBuf::from(folder) }
    }

    #[test]
    fn which_project_a_server_belongs_to() {
        let root = if cfg!(windows) { "C:\\Users\\Олег\\Projects\\Shop" } else { "/home/oleh/Projects/Shop" };
        let all = vec![
            server(5173, root),
            server(3000, &format!("{root}{}.claude{0}worktrees{0}cb-x", std::path::MAIN_SEPARATOR)),
            server(8080, &format!("{root}2")),
            server(9000, if cfg!(windows) { "C:\\Users" } else { "/home" }),
        ];
        let found: Vec<u16> = servers_in(&all, Path::new(root)).iter().map(|s| s.port).collect();
        assert_eq!(found, [5173, 3000], "the project and its worktrees, not «Shop2» next to it");
        if cfg!(windows) {
            assert_eq!(servers_in(&all, Path::new("c:/users/олег/projects/shop/")).len(), 2, "Windows ignores case");
        }
        assert_eq!(all[0].url(), "http://localhost:5173");
        assert_eq!(all[0].id(), "5273:5173");
    }

    #[test]
    fn linux_listening_sockets() {
        let text = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   0: 0100007F:1435 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 123456 1 0000000000000000 100 0 0 10 0\n   1: 0100007F:9C40 0100007F:1435 01 00000000:00000000 00:00000000 00000000  1000        0 654321 1 0000000000000000 20 4 30 10 -1\n";
        let found = parse_proc_tcp(text);
        assert_eq!(found.get(&123_456), Some(&5173), "0x1435 is 5173, listening");
        assert_eq!(found.len(), 1, "an established connection is not a server");
    }

    /// A real listener: this test's own socket shows up with this process's folder.
    #[test]
    fn a_listening_socket_is_seen() {
        let socket = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = socket.local_addr().unwrap().port();
        let mine = scan().into_iter().find(|server| server.port == port && server.pid == std::process::id());
        let Some(mine) = mine else { panic!("port {port} of process {} not found", std::process::id()) };
        assert_eq!(mine.folder, std::env::current_dir().unwrap());
    }
}
