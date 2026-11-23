//! The search field in the panel (the Mac's `PanelSearchField` / `PanelSearchResults`).

use claudepult_core::search::{self, Item, Kind};
use serde::Serialize;
use tauri::AppHandle;

use crate::strings;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FoundRow {
    kind: Kind,
    id: String,
    title: String,
    detail: String,
    /// What Enter or a click does.
    hint: String,
}

/// What the panel shows now — its sessions, projects and quick commands — searched by the typed text.
#[tauri::command]
pub fn panel_search(app: AppHandle, query: String, sessions: Vec<Item>, projects: Vec<Item>, quick_commands: Vec<Item>) -> Vec<FoundRow> {
    let texts = strings(&app);
    search::results(&query, &sessions, &projects, &quick_commands)
        .into_iter()
        .map(|found| FoundRow {
            hint: match found.kind {
                Kind::Session => texts.t("Показать сессию").to_owned(),
                Kind::Project => texts.t("Раскрыть проект в панели").to_owned(),
                Kind::QuickCommand => texts.t("Запустить").to_owned(),
            },
            detail: if found.kind == Kind::QuickCommand { texts.t("быстрая команда").to_owned() } else { found.detail },
            kind: found.kind,
            id: found.id,
            title: found.title,
        })
        .collect()
}
