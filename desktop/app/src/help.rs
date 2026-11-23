//! The «Справка» window (the Mac's `HelpView`): topics on the left with a search, a topic's page on the right — its
//! summary, «Как начать», what it does, and «Открыть в настройках». Opened by «?» in the panel's header and by
//! `claudepult --app-command help`.

use crate::strings;
use claudepult_core::help::{self, Topic};
use serde::Serialize;
use tauri::{AppHandle, Manager};

#[derive(Serialize)]
pub struct HelpView {
    topics: Vec<Topic>,
    /// The topics the search found, in order; every topic while nothing is typed.
    found: Vec<&'static str>,
}

#[tauri::command]
pub fn help_view(app: AppHandle, query: String) -> HelpView {
    let topics = help::topics(&strings(&app));
    let found = topics.iter().filter(|t| t.matches(&query)).map(|t| t.id).collect();
    HelpView { topics, found }
}

/// Opens (or brings forward) the window.
pub fn show(app: &AppHandle) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
    if let Some(window) = app.get_webview_window("help") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    let title = format!("{} — {}", claudepult_core::APP_NAME, strings(app).t("Справка"));
    let app = app.clone();
    crate::off_main_thread(move || {
        let _ = tauri::WebviewWindowBuilder::new(&app, "help", tauri::WebviewUrl::App("help.html".into())).title(title).inner_size(760.0, 560.0).min_inner_size(620.0, 420.0).center().build();
    });
}

/// «Предложить идею…» (`idea`) and «Сообщить о проблеме…» (`bug`): the repository's form in the browser.
#[tauri::command]
pub fn open_feedback(kind: String) -> Result<(), String> {
    let template = claudepult_core::feedback::Template::parse(&kind).ok_or("no such form")?;
    let url = claudepult_core::feedback::url(template, env!("CARGO_PKG_VERSION"));
    eprintln!("feedback: the {kind} form opens");
    crate::projects::open_with_system(url.as_ref())
}

#[tauri::command]
pub fn open_help(app: AppHandle) {
    show(&app);
}
