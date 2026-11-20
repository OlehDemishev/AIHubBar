//! Updates on Windows (docs/specs/SPEC-windows.md §7): Tauri's updater reads a manifest signed with AI Hub Bar's own
//! key from a fixed address on GitHub Releases, where the release workflow puts it once a release is published.
//! A check once a day says a new version is there; it is downloaded and installed only on a click in Settings →
//! «Основные» → «Обновления» — the per-user installer, with no administrator rights — and the app starts again.
//! Linux has no update of its own yet: the package manager or a new AppImage.

use std::sync::Mutex;
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;
use tauri_plugin_updater::{Update, UpdaterExt};

pub const SUPPORTED: bool = cfg!(windows);

/// The newer version the last check found.
#[derive(Default)]
pub struct Updates {
    available: Mutex<Option<String>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdatesView {
    supported: bool,
    daily: bool,
    available: Option<String>,
}

async fn find(app: &AppHandle) -> Result<Option<Update>, String> {
    app.updater().map_err(|error| error.to_string())?.check().await.map_err(|error| error.to_string())
}

/// Keeps what a check found; true when it is news.
fn remember(app: &AppHandle, version: Option<String>) -> bool {
    let state = app.state::<Updates>();
    let mut available = state.available.lock().unwrap();
    let news = *available != version;
    *available = version;
    drop(available);
    if news {
        let _ = app.emit("updates-changed", ());
    }
    news
}

#[tauri::command]
pub fn updates_view(app: AppHandle) -> UpdatesView {
    UpdatesView {
        supported: SUPPORTED,
        daily: app.state::<crate::AppState>().settings.lock().unwrap().updates_daily,
        available: app.state::<Updates>().available.lock().unwrap().clone(),
    }
}

#[tauri::command]
pub fn set_updates_daily(app: AppHandle, enabled: bool) {
    crate::save(&app, |settings| settings.updates_daily = enabled);
}

/// «Проверить сейчас»: the newer version, or None when this one is the latest.
#[tauri::command]
pub async fn check_updates(app: AppHandle) -> Result<Option<String>, String> {
    let version = find(&app).await?.map(|update| update.version);
    remember(&app, version.clone());
    Ok(version)
}

/// «Установить и перезапустить»: downloads the installer, checks its signature against the key in the app, runs it
/// and quits; the installer starts the new version.
#[tauri::command]
pub async fn install_update(app: AppHandle) -> Result<(), String> {
    let Some(update) = find(&app).await? else {
        remember(&app, None);
        return Ok(());
    };
    update.download_and_install(|_, _| {}, || {}).await.map_err(|error| error.to_string())?;
    app.restart()
}

/// A minute after the start and then once a day, while «Проверять раз в день» is on: a notification the first time
/// a version is seen. Nothing is downloaded here.
pub fn watch(app: AppHandle) {
    if !SUPPORTED {
        return;
    }
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(60));
        loop {
            let daily = app.state::<crate::AppState>().settings.lock().unwrap().updates_daily;
            if daily {
                match tauri::async_runtime::block_on(find(&app)) {
                    Ok(update) => {
                        let version = update.map(|update| update.version);
                        if remember(&app, version.clone()) {
                            if let Some(version) = version {
                                let texts = crate::strings(&app);
                                let _ = app.notification().builder().title(claudepult_core::APP_NAME).body(texts.format("Доступна версия %@", &[&version])).show();
                            }
                        }
                    }
                    Err(error) => eprintln!("update check: {error}"),
                }
            }
            std::thread::sleep(Duration::from_secs(24 * 60 * 60));
        }
    });
}
