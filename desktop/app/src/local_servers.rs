//! «Локальные серверы» in an open project (the Mac's `LocalServersView`): what listens on a port from the project's
//! folder or its worktrees — the port, the program, «Открыть в браузере» and «Остановить процесс» asked twice.

use claudepult_core::local_servers::{self, LocalServer};
use serde::Serialize;
use std::path::Path;
use tauri::AppHandle;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerRow {
    id: String,
    pid: u32,
    port: u16,
    command: String,
    folder: String,
}

fn rows(servers: Vec<LocalServer>) -> Vec<ServerRow> {
    servers.into_iter().map(|s| ServerRow { id: s.id(), pid: s.pid, port: s.port, command: s.command, folder: s.folder.to_string_lossy().into_owned() }).collect()
}

/// The servers of a project the panel opened; read off the main thread (a look at every listening process).
#[tauri::command]
pub async fn project_servers(path: String) -> Vec<ServerRow> {
    tauri::async_runtime::spawn_blocking(move || rows(local_servers::servers_in(&local_servers::scan(), Path::new(&path)))).await.unwrap_or_default()
}

fn find(project: &str, pid: u32, port: u16) -> Option<LocalServer> {
    local_servers::servers_in(&local_servers::scan(), Path::new(project)).into_iter().find(|s| s.pid == pid && s.port == port)
}

/// «Открыть в браузере»: only `http://localhost:<port>` of a server that still runs in that project.
#[tauri::command]
pub async fn open_local_server(project: String, pid: u32, port: u16) -> Result<(), String> {
    let server = tauri::async_runtime::spawn_blocking(move || find(&project, pid, port)).await.map_err(|e| e.to_string())?.ok_or("gone")?;
    crate::projects::open_with_system(server.url().as_ref())
}

/// «Остановить процесс», after the second press: only a process that still listens on that port from that project.
#[tauri::command]
pub async fn stop_local_server(_app: AppHandle, project: String, pid: u32, port: u16) -> Result<Vec<ServerRow>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let server = find(&project, pid, port).ok_or("gone")?;
        let stopped = local_servers::stop(&server);
        eprintln!("local server {} :{} (pid {}) asked to quit: {stopped}", server.command, server.port, server.pid);
        std::thread::sleep(std::time::Duration::from_secs(1));
        Ok(rows(local_servers::servers_in(&local_servers::scan(), Path::new(&project))))
    })
    .await
    .map_err(|e| e.to_string())?
}
