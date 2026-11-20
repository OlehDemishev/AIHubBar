//! «Telegram» in Settings and the messages the app sends there (`core/src/telegram.rs`, docs/specs/SPEC-telegram.md).
//! Stage 1: the person's own bot — its token among the API keys, the chat bound with «Start», a test message, and the
//! same alerts the notifications show (background results, limit thresholds, calendar, PRs), each with its switch.

use std::sync::Mutex;
use std::time::Duration;

use chrono::{DateTime, Utc};
use claudepult_core::i18n::Strings;
use claudepult_core::{keys, telegram};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

#[derive(Default)]
pub struct Telegram {
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    /// The bot's user name, once Telegram has confirmed the token.
    bot: Option<String>,
    /// «Привязать чат» waits for `/start <code>` until this time.
    binding: Option<(String, DateTime<Utc>)>,
    /// The line under the rows: what the last action came to.
    status: Option<String>,
    /// Another program reads this bot, so «Start» can't reach this one: the chat's id is typed instead.
    conflict: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EventRow {
    id: &'static str,
    title: String,
    on: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TelegramView {
    /// False where there is nowhere to keep the token (Linux for now).
    available: bool,
    has_token: bool,
    bot: Option<String>,
    chat: Option<String>,
    binding_code: Option<String>,
    status: Option<String>,
    conflict: bool,
    events: Vec<EventRow>,
}

fn view(app: &AppHandle) -> TelegramView {
    let texts = crate::strings(app);
    let (chat, off) = {
        let state = app.state::<crate::AppState>();
        let settings = state.settings.lock().unwrap();
        (settings.telegram_chat.clone(), settings.telegram_off.clone())
    };
    let state = app.state::<Telegram>();
    let state = state.state.lock().unwrap();
    TelegramView {
        available: keys::available(),
        has_token: keys::read(telegram::KEY).is_some(),
        bot: state.bot.clone(),
        chat,
        binding_code: state.binding.as_ref().filter(|(_, until)| *until > Utc::now()).map(|(code, _)| code.clone()),
        status: state.status.clone(),
        conflict: state.conflict,
        events: telegram::EVENTS.iter().map(|&id| EventRow { id, title: telegram::event_title(id, &texts), on: !off.iter().any(|e| e == id) }).collect(),
    }
}

fn change(app: &AppHandle, change: impl FnOnce(&mut State)) {
    change(&mut app.state::<Telegram>().state.lock().unwrap());
    let _ = app.emit("telegram-changed", ());
}

fn problem_text(s: &Strings, error: telegram::Error) -> String {
    match error {
        telegram::Error::Network => s.t("Нет связи").to_owned(),
        telegram::Error::Http(401) | telegram::Error::Http(404) => s.t("Telegram не принял токен").to_owned(),
        telegram::Error::Http(400) | telegram::Error::Http(403) => s.t("Бот не может написать в этот чат — откройте его в Telegram и нажмите «Start»").to_owned(),
        telegram::Error::Http(409) => s.t("Этого бота уже читает другой Mac или программа").to_owned(),
        telegram::Error::Http(_) => s.t("Не отправилось: проверьте токен и ID чата").to_owned(),
    }
}

/// The bot's name for a saved token, asked once after the start (and again after an error).
pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        if let Some(token) = keys::read(telegram::KEY) {
            match telegram::bot_name(&token) {
                Ok(name) => change(&app, |state| state.bot = Some(name)),
                Err(error) => eprintln!("telegram getMe: {error:?}"),
            }
        }
    });
}

#[tauri::command]
pub fn telegram_view(app: AppHandle) -> TelegramView {
    view(&app)
}

/// «Сохранить»: the token is kept only after Telegram names the bot it belongs to.
#[tauri::command]
pub async fn telegram_save_token(app: AppHandle, token: String) -> Result<TelegramView, String> {
    let texts = crate::strings(&app);
    let token = token.trim().to_owned();
    if !telegram::looks_like_token(&token) {
        return Err(texts.t("Telegram не принял токен").to_owned());
    }
    let asked = token.clone();
    let name = tauri::async_runtime::spawn_blocking(move || telegram::bot_name(&asked)).await.map_err(|e| e.to_string())?.map_err(|error| problem_text(&texts, error))?;
    keys::save(telegram::KEY, &token).map_err(|e| e.to_string())?;
    eprintln!("telegram: token saved for @{name}");
    change(&app, |state| *state = State { bot: Some(name), ..State::default() });
    Ok(view(&app))
}

/// «Удалить»: the token leaves the key store; the chat's id stays for the next bot.
#[tauri::command]
pub fn telegram_remove_token(app: AppHandle) -> Result<TelegramView, String> {
    keys::delete(telegram::KEY).map_err(|e| e.to_string())?;
    change(&app, |state| *state = State::default());
    Ok(view(&app))
}

/// «Привязать чат»: opens the bot with a one-time code and waits up to ten minutes for `/start <code>` from the
/// person's own chat. Nothing else reads the bot's messages.
#[tauri::command]
pub async fn telegram_bind(app: AppHandle) -> Result<TelegramView, String> {
    let texts = crate::strings(&app);
    let Some(token) = keys::read(telegram::KEY) else { return Err(texts.t("Сначала сохраните токен бота").to_owned()) };
    let known = app.state::<Telegram>().state.lock().unwrap().bot.clone();
    let bot = match known {
        Some(bot) => bot,
        None => {
            let asked = token.clone();
            let name = tauri::async_runtime::spawn_blocking(move || telegram::bot_name(&asked)).await.map_err(|e| e.to_string())?.map_err(|error| problem_text(&texts, error))?;
            change(&app, |state| state.bot = Some(name.clone()));
            name
        }
    };
    let code = telegram::new_code();
    let until = Utc::now() + chrono::Duration::minutes(telegram::BINDING_MINUTES);
    change(&app, |state| {
        state.binding = Some((code.clone(), until));
        state.status = None;
        state.conflict = false;
    });
    crate::projects::open_with_system(telegram::binding_link(&bot, &code).as_ref())?;
    let waiting = app.clone();
    std::thread::spawn(move || wait_for_start(waiting, token, code));
    Ok(view(&app))
}

/// Reads the bot's messages until the code comes, the time is up or the wait is cancelled.
fn wait_for_start(app: AppHandle, token: String, code: String) {
    let mut offset = None;
    loop {
        let still = app.state::<Telegram>().state.lock().unwrap().binding.as_ref().is_some_and(|(current, until)| *current == code && *until > Utc::now());
        if !still {
            // Cancelled, replaced by a newer code or out of time.
            change(&app, |state| {
                if state.binding.as_ref().is_some_and(|(current, _)| *current == code) {
                    state.binding = None;
                }
            });
            return;
        }
        match telegram::updates(&token, offset, 20) {
            Ok(updates) => {
                if let Some(chat) = telegram::binding_chat(&updates, &code) {
                    // Confirm what was read, so the next reader of this bot doesn't get the «Start» again.
                    let _ = telegram::updates(&token, telegram::next_offset(&updates), 0);
                    crate::save(&app, |settings| settings.telegram_chat = Some(chat.clone()));
                    let texts = crate::strings(&app);
                    let sent = telegram::send(&token, &chat, &telegram::escape(texts.t("Чат привязан к AI Hub Bar.")));
                    eprintln!("telegram: chat bound, greeting {}", if sent.is_ok() { "sent" } else { "not sent" });
                    change(&app, |state| {
                        state.binding = None;
                        state.status = None;
                    });
                    return;
                }
                offset = telegram::next_offset(&updates).or(offset);
            }
            Err(telegram::Error::Http(409)) => {
                let texts = crate::strings(&app);
                change(&app, |state| {
                    state.binding = None;
                    state.conflict = true;
                    state.status = Some(texts.t("Этого бота уже читает другой Mac или программа").to_owned());
                });
                return;
            }
            Err(error) => {
                eprintln!("telegram getUpdates: {error:?}");
                std::thread::sleep(Duration::from_secs(5));
            }
        }
    }
}

#[tauri::command]
pub fn telegram_cancel_binding(app: AppHandle) -> TelegramView {
    change(&app, |state| state.binding = None);
    view(&app)
}

/// «Отвязать», or a chat's id typed by hand when another program reads the bot.
#[tauri::command]
pub fn telegram_set_chat(app: AppHandle, chat: Option<String>) -> Result<TelegramView, String> {
    let chat = chat.map(|c| c.trim().to_owned()).filter(|c| !c.is_empty());
    if let Some(chat) = &chat {
        let digits = chat.strip_prefix('-').unwrap_or(chat);
        if digits.is_empty() || digits.len() > 20 || !digits.bytes().all(|b| b.is_ascii_digit()) {
            return Err(crate::strings(&app).t("Не отправилось: проверьте токен и ID чата").to_owned());
        }
    }
    crate::save(&app, |settings| settings.telegram_chat = chat);
    change(&app, |state| state.status = None);
    Ok(view(&app))
}

/// «Проверить»: a test message into the bound chat.
#[tauri::command]
pub async fn telegram_test(app: AppHandle) -> TelegramView {
    let texts = crate::strings(&app);
    let chat = app.state::<crate::AppState>().settings.lock().unwrap().telegram_chat.clone();
    let status = match (keys::read(telegram::KEY), chat) {
        (None, _) => texts.t("Сначала сохраните токен бота").to_owned(),
        (_, None) => texts.t("Сначала привяжите чат").to_owned(),
        (Some(token), Some(chat)) => {
            let html = telegram::escape(texts.t("AI Hub Bar: уведомления работают"));
            match tauri::async_runtime::spawn_blocking(move || telegram::send(&token, &chat, &html)).await {
                Ok(Ok(())) => texts.t("Работает: тестовое сообщение отправлено").to_owned(),
                Ok(Err(error)) => problem_text(&texts, error),
                Err(error) => error.to_string(),
            }
        }
    };
    change(&app, |state| state.status = Some(status));
    view(&app)
}

#[tauri::command]
pub fn set_telegram_event(app: AppHandle, event: String, on: bool) -> TelegramView {
    if telegram::EVENTS.contains(&event.as_str()) {
        crate::save(&app, |settings| {
            settings.telegram_off.retain(|e| *e != event);
            if !on {
                settings.telegram_off.push(event);
            }
        });
    }
    view(&app)
}

/// Sends `html` when the event's switch is on and the bot and the chat are set; quietly nothing otherwise. Never on
/// the caller's thread.
pub fn notify(app: &AppHandle, event: &'static str, html: String) {
    let chat = {
        let state = app.state::<crate::AppState>();
        let settings = state.settings.lock().unwrap();
        if settings.telegram_off.iter().any(|e| e == event) {
            return;
        }
        settings.telegram_chat.clone()
    };
    let Some(chat) = chat else { return };
    std::thread::spawn(move || {
        let Some(token) = keys::read(telegram::KEY) else { return };
        match telegram::send(&token, &chat, &html) {
            Ok(()) => eprintln!("telegram: {event} sent"),
            Err(error) => eprintln!("telegram: {event} not sent: {error:?}"),
        }
    });
}
