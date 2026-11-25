//! After a crash (the Mac's `CrashReports.checkAtLaunch`): at start, a report written since the last check — the
//! first check looks one day back — brings a question: «Сообщить на GitHub…» opens the bug form filled from the
//! report and shows a copy of the report (home folder out) in File Explorer, or «Не сейчас». The Mac's third button,
//! «Больше не предлагать», Windows' message box does not draw: the switch «После сбоя предлагать отправить отчёт» in
//! Settings → «Основные» turns the question off.

use crate::{save, strings, AppState};
use chrono::{Duration, Utc};
use claudepult_core::{crash, paths};
use tauri::{AppHandle, Manager};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogResult};

pub fn dir() -> std::path::PathBuf {
    paths::data_dir().join("crashes")
}

fn home_and_user() -> (String, String) {
    let home = dirs::home_dir().map(|h| h.to_string_lossy().into_owned()).unwrap_or_default();
    let user = dirs::home_dir().and_then(|h| h.file_name().map(|n| n.to_string_lossy().into_owned())).unwrap_or_default();
    (home, user)
}

/// Once at start, off the main thread: the newest report since the last check.
pub fn check_at_start(app: &AppHandle) {
    let now = Utc::now();
    let (asks, since) = {
        let settings = app.state::<AppState>().settings.lock().unwrap().clone();
        (settings.ask_after_crash, settings.crash_checked_at.and_then(|at| chrono::DateTime::from_timestamp(at, 0)).unwrap_or(now - Duration::days(1)))
    };
    save(app, |settings| settings.crash_checked_at = Some(now.timestamp()));
    crash::tidy(&dir(), now);
    if !asks {
        return;
    }
    let Some(report) = crash::latest_since(&dir(), since) else { return };
    eprintln!("crash report found: {}", report.file.display());
    ask(app, report);
}

fn ask(app: &AppHandle, report: crash::Crash) {
    let texts = strings(app);
    let when = report.date.with_timezone(&chrono::Local).format("%d.%m.%Y %H:%M").to_string();
    let (send, later) = (texts.t("Сообщить на GitHub…").to_owned(), texts.t("Не сейчас").to_owned());
    app.dialog()
        .message(texts.format("Сбой %@. Можно сообщить о нём на GitHub: откроется форма с описанием сбоя, версией и системой — перед отправкой видно всё, что уходит. Полный отчёт откроется в Проводнике, его можно перетащить в форму.", &[&when]))
        .title(texts.t("В прошлый раз AI Hub Bar закрылся с ошибкой"))
        .buttons(MessageDialogButtons::OkCancelCustom(send.clone(), later))
        .show_with_result(move |answer| {
            let chosen = match answer {
                MessageDialogResult::Custom(label) => label,
                MessageDialogResult::Yes | MessageDialogResult::Ok => send.clone(),
                _ => String::new(),
            };
            if chosen == send {
                send_report(&report);
            }
        });
}

/// The form in the browser, and a copy of the full report with the home folder taken out, shown in the file manager.
fn send_report(report: &crash::Crash) {
    let (home, user) = home_and_user();
    if let Ok(text) = std::fs::read_to_string(&report.file) {
        let copy = report.file.with_file_name(format!("{}-report.txt", report.file.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()));
        if std::fs::write(&copy, crash::redacted(&text, &home, &user)).is_ok() {
            show_in_file_manager(&copy);
        }
    }
    let _ = crate::projects::open_with_system(report.issue_url(&home, &user).as_ref());
}

fn show_in_file_manager(file: &std::path::Path) {
    #[cfg(windows)]
    {
        let mut command = std::process::Command::new("explorer.exe");
        command.arg(format!("/select,{}", file.display()));
        let _ = command.spawn();
    }
    #[cfg(not(windows))]
    {
        let _ = crate::projects::open_with_system(file.parent().unwrap_or(file).as_os_str());
    }
}

#[tauri::command]
pub fn crash_reports_asked(app: AppHandle) -> bool {
    app.state::<AppState>().settings.lock().unwrap().ask_after_crash
}

#[tauri::command]
pub fn set_crash_reports_asked(app: AppHandle, on: bool) -> bool {
    save(&app, |settings| settings.ask_after_crash = on);
    on
}
