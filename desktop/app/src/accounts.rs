//! «Другие аккаунты Claude» (the Mac's `ClaudeAccountsStore` and its section of Settings): the limits of each extra
//! account, read every five minutes and shown in the panel as a service's row under the main account's. Settings →
//! «Сервисы AI» adds an account by its config folder, names it, signs it in through a terminal and removes it.

use crate::hub::{ServiceView, WindowView};
use crate::{save, strings, AppState};
use chrono::{DateTime, Duration, Utc};
use claudepult_core::claude_accounts::{self, ClaudeAccount};
use claudepult_core::i18n::Strings;
use claudepult_core::usage::{UsageError, UsageSnapshot};
use claudepult_core::{launch, paths, texts};
use serde::Serialize;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_dialog::DialogExt;

#[derive(Clone, Default)]
struct Reading {
    snapshot: Option<UsageSnapshot>,
    error: Option<UsageError>,
}

#[derive(Clone, Default)]
pub struct Accounts {
    readings: Arc<Mutex<HashMap<String, Reading>>>,
    /// After HTTP 429 an account is left alone for a while.
    paused_until: Arc<Mutex<HashMap<String, DateTime<Utc>>>>,
}

fn home() -> std::path::PathBuf {
    dirs::home_dir().unwrap_or_default()
}

fn list(app: &AppHandle) -> Vec<ClaudeAccount> {
    app.state::<AppState>().settings.lock().unwrap().claude_accounts.clone()
}

impl Accounts {
    pub fn start(&self, app: AppHandle) {
        let this = self.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(10));
            loop {
                this.refresh(&app);
                std::thread::sleep(std::time::Duration::from_secs(5 * 60));
            }
        });
    }

    /// Reads every account's limits; the last good reading stays under a new error, as on the Mac.
    pub fn refresh(&self, app: &AppHandle) {
        let accounts = list(app);
        let now = Utc::now();
        for account in &accounts {
            if self.paused_until.lock().unwrap().get(&account.id).is_some_and(|until| *until > now) {
                continue;
            }
            let result = account.read(&home(), now);
            if let Err(UsageError::RateLimited(_)) = result {
                self.paused_until.lock().unwrap().insert(account.id.clone(), now + Duration::minutes(claude_accounts::RATE_LIMIT_PAUSE_MINUTES));
            }
            let mut readings = self.readings.lock().unwrap();
            let before = readings.remove(&account.id).unwrap_or_default();
            let reading = match result {
                Ok(snapshot) => Reading { snapshot: Some(snapshot), error: None },
                Err(error) => Reading { snapshot: before.snapshot, error: Some(error) },
            };
            readings.insert(account.id.clone(), reading);
        }
        self.readings.lock().unwrap().retain(|id, _| accounts.iter().any(|a| a.id == *id));
        if !accounts.is_empty() {
            eprintln!("other Claude accounts: {} read", accounts.len());
        }
        let _ = app.emit("hub-changed", ());
    }

    /// The accounts as rows of the panel's «Другие AI», in the order of Settings; an account not read yet has none.
    pub fn services(&self, app: &AppHandle, s: &Strings, now: DateTime<Utc>) -> Vec<ServiceView> {
        let readings = self.readings.lock().unwrap().clone();
        list(app)
            .into_iter()
            .filter_map(|account| {
                let reading = readings.get(&account.id)?;
                let windows = reading.snapshot.iter().flat_map(claude_accounts::shown_windows).map(|window| WindowView::of_claude(s, window, now)).collect();
                Some(ServiceView { id: format!("claudeAccount.{}", account.id), title: account.name, windows, error: reading.error.as_ref().map(|e| texts::error_text(s, e)) })
            })
            .collect()
    }

    fn status(&self, account: &ClaudeAccount, s: &Strings) -> String {
        let Some(reading) = self.readings.lock().unwrap().get(&account.id).cloned() else { return String::new() };
        if let Some(error) = &reading.error {
            return texts::error_text(s, error);
        }
        let windows = reading.snapshot.iter().flat_map(claude_accounts::shown_windows).take(2);
        windows.map(|w| format!("{} {}", texts::window_title(s, w), texts::percent(w.utilization))).collect::<Vec<_>>().join(" · ")
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountRow {
    id: String,
    name: String,
    config_dir: String,
    /// Its limits in a line, or why they can't be read; empty until the first reading.
    status: String,
    is_error: bool,
}

#[derive(Serialize, Default)]
pub struct AccountsView {
    accounts: Vec<AccountRow>,
    /// Why the last action did nothing.
    message: Option<String>,
}

fn view(app: &AppHandle, message: Option<String>) -> AccountsView {
    let state = app.state::<Accounts>();
    let texts = strings(app);
    let accounts = list(app)
        .into_iter()
        .map(|account| {
            let is_error = state.readings.lock().unwrap().get(&account.id).is_some_and(|r| r.error.is_some());
            AccountRow { status: state.status(&account, &texts), is_error, id: account.id, name: account.name, config_dir: account.config_dir }
        })
        .collect();
    AccountsView { accounts, message }
}

#[tauri::command]
pub fn claude_accounts(app: AppHandle) -> AccountsView {
    view(&app, None)
}

/// «Добавить аккаунт…»: the account's config folder (hidden folders are shown: the usual one is `.claude-…`).
#[tauri::command]
pub async fn add_claude_account(app: AppHandle) -> AccountsView {
    let mut dialog = app.dialog().file().set_title(strings(&app).t("Другие аккаунты Claude")).set_directory(home());
    if let Some(window) = app.get_webview_window("settings") {
        dialog = dialog.set_parent(&window);
    }
    let Some(folder) = dialog.blocking_pick_folder().and_then(|f| f.into_path().ok()) else { return view(&app, None) };
    if !claude_accounts::can_add(&folder, &list(&app), &paths::claude_dir(), &home()) {
        return view(&app, Some(strings(&app).t("Этот аккаунт уже есть в списке.").to_owned()));
    }
    let account = ClaudeAccount::new(&folder, &home());
    eprintln!("other Claude accounts: «{}» added", account.name);
    save(&app, |settings| settings.claude_accounts.push(account));
    refresh_soon(&app);
    view(&app, None)
}

fn refresh_soon(app: &AppHandle) {
    let (state, app) = (app.state::<Accounts>().inner().clone(), app.clone());
    std::thread::spawn(move || state.refresh(&app));
}

#[tauri::command]
pub fn rename_claude_account(app: AppHandle, id: String, name: String) -> AccountsView {
    let name = name.trim().to_owned();
    if !name.is_empty() {
        save(&app, |settings| {
            if let Some(account) = settings.claude_accounts.iter_mut().find(|a| a.id == id) {
                account.name = name;
            }
        });
        let _ = app.emit("hub-changed", ());
    }
    view(&app, None)
}

/// «Убрать аккаунт»: only the entry here; the folder and its sign-in stay.
#[tauri::command]
pub fn remove_claude_account(app: AppHandle, id: String) -> AccountsView {
    save(&app, |settings| settings.claude_accounts.retain(|a| a.id != id));
    app.state::<Accounts>().readings.lock().unwrap().remove(&id);
    let _ = app.emit("hub-changed", ());
    view(&app, None)
}

/// «Войти»: `claude auth login` for the account's folder in a terminal window. The limits are read again when the
/// person comes back to Settings («Обновить» there), not by guessing when the sign-in is over.
#[tauri::command]
pub fn sign_in_claude_account(app: AppHandle, id: String) -> AccountsView {
    let texts = strings(&app);
    let Some(account) = list(&app).into_iter().find(|a| a.id == id) else { return view(&app, None) };
    let Some(claude) = launch::find_claude() else { return view(&app, Some(texts.t("Claude Code не установлен").to_owned())) };
    let folder = account.expanded_dir(&home());
    if let Err(error) = std::fs::create_dir_all(&folder) {
        return view(&app, Some(error.to_string()));
    }
    app.state::<Accounts>().paused_until.lock().unwrap().remove(&id);
    match launch::open_line_in_terminal(&home(), &account.sign_in_line(&claude, &home())) {
        Ok(()) => view(&app, None),
        Err(error) => view(&app, Some(texts.format("Не удалось открыть Терминал: %@", &[&error]))),
    }
}

/// «Обновить»: read every account now.
#[tauri::command]
pub async fn refresh_claude_accounts(app: AppHandle) -> AccountsView {
    let (state, handle) = (app.state::<Accounts>().inner().clone(), app.clone());
    let _ = tauri::async_runtime::spawn_blocking(move || state.refresh(&handle)).await;
    view(&app, None)
}
