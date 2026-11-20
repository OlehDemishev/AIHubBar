//! «Telegram» in Settings and the messages the app sends there (`core/src/telegram.rs`, docs/specs/SPEC-telegram.md).
//! Stage 1: the person's own bot — its token among the API keys, the chat bound with «Start», a test message, and the
//! same alerts the notifications show (background results, limit thresholds, calendar, PRs), each with its switch.
//! Stage 2: with «Этот компьютер отвечает боту» on, the app reads the bot — `/menu` shows 🏠, 🤖 lists the sessions —
//! and with «Запросы разрешений в этот бот» a permission request comes to the chat, with ✅ / ❌ when this computer
//! reads the bot. Only the bound chat is answered; old messages and presses after a gap do nothing.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use chrono::{DateTime, Utc};
use claudepult_core::i18n::Strings;
use claudepult_core::approvals::{self, Request};
use claudepult_core::sessions::State as SessionState;
use claudepult_core::{keys, paths, telegram};
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
    /// The reader got an answer from Telegram on its last try.
    reading: bool,
    /// Requests that have a message in the chat: its id, the request and the project's name.
    sent: HashMap<String, (i64, Request, String)>,
    /// Requests answered from the chat, until their message is closed.
    answered: HashMap<String, bool>,
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
    /// «Этот компьютер отвечает боту» and whether it does right now.
    answers: bool,
    reading: bool,
    /// «Запросы разрешений в этот бот».
    requests: bool,
}

fn view(app: &AppHandle) -> TelegramView {
    let texts = crate::strings(app);
    let (chat, off, answers, requests) = {
        let state = app.state::<crate::AppState>();
        let settings = state.settings.lock().unwrap();
        (settings.telegram_chat.clone(), settings.telegram_off.clone(), settings.telegram_answers, settings.telegram_requests)
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
        answers,
        reading: answers && state.reading,
        requests,
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
        std::thread::spawn({
            let app = app.clone();
            move || loop {
                sync_requests(&app);
                std::thread::sleep(Duration::from_secs(3));
            }
        });
        read_loop(app);
    });
}

// MARK: - Reading the bot (stage 2)

/// The token and the chat, when both are set.
fn bot(app: &AppHandle) -> Option<(String, String)> {
    let chat = app.state::<crate::AppState>().settings.lock().unwrap().telegram_chat.clone()?;
    Some((keys::read(telegram::KEY)?, chat))
}

fn answers_here(app: &AppHandle) -> bool {
    app.state::<crate::AppState>().settings.lock().unwrap().telegram_answers
}

fn set_reading(app: &AppHandle, reading: bool, status: Option<String>, conflict: bool) {
    let state = app.state::<Telegram>();
    let mut state = state.state.lock().unwrap();
    if state.reading != reading || state.conflict != conflict || (status.is_some() && state.status != status) {
        state.reading = reading;
        state.conflict = conflict;
        if status.is_some() {
            state.status = status;
        }
        drop(state);
        let _ = app.emit("telegram-changed", ());
    }
}

/// One `getUpdates` after another while «Этот компьютер отвечает боту» is on, the bot and the chat are set and no
/// chat is being bound (the binding reads the bot itself).
fn read_loop(app: AppHandle) {
    let mut offset: Option<i64> = None;
    let mut last_read: Option<DateTime<Utc>> = None;
    let mut commands_for: Option<String> = None;
    loop {
        let binding = app.state::<Telegram>().state.lock().unwrap().binding.is_some();
        let Some((token, chat)) = bot(&app).filter(|_| answers_here(&app) && !binding) else {
            set_reading(&app, false, None, false);
            offset = None;
            std::thread::sleep(Duration::from_secs(5));
            continue;
        };
        if commands_for.as_deref() != Some(token.as_str()) {
            let texts = crate::strings(&app);
            if telegram::set_commands(&token, texts.t("Главная: лимиты, сессии, фоновые задачи")).is_ok() {
                commands_for = Some(token.clone());
            }
        }
        match telegram::read(&token, offset, 25) {
            Ok(updates) => {
                set_reading(&app, true, None, false);
                // A press carries no time: right after a gap (the computer slept, the app started) it only navigates.
                let after_gap = last_read.is_none_or(|at| (Utc::now() - at).num_seconds() > telegram::MAX_AGE_SECONDS);
                last_read = Some(Utc::now());
                offset = telegram::next_offset(&updates).or(offset);
                for update in telegram::parse_updates(&updates) {
                    handle(&app, &token, &chat, update, after_gap);
                }
            }
            Err(telegram::Error::Http(409)) => {
                let texts = crate::strings(&app);
                set_reading(&app, false, Some(texts.t("Этого бота уже читает другой Mac или программа").to_owned()), true);
                std::thread::sleep(Duration::from_secs(60));
            }
            Err(telegram::Error::Http(401)) | Err(telegram::Error::Http(404)) => {
                let texts = crate::strings(&app);
                set_reading(&app, false, Some(texts.t("Telegram не принял токен").to_owned()), false);
                std::thread::sleep(Duration::from_secs(60));
            }
            Err(error) => {
                eprintln!("telegram getUpdates: {error:?}");
                set_reading(&app, false, None, false);
                std::thread::sleep(Duration::from_secs(10));
            }
        }
    }
}

fn handle(app: &AppHandle, token: &str, chat: &str, update: telegram::Update, after_gap: bool) {
    // Anyone else who found the bot gets nothing back.
    if !update.is_from(chat) {
        return;
    }
    let texts = crate::strings(app);
    match &update.kind {
        telegram::UpdateKind::Message { text } => {
            if update.is_stale(Utc::now().timestamp()) {
                eprintln!("telegram: an old command skipped");
                return;
            }
            if let Some(screen) = telegram::command(text) {
                let _ = telegram::send_message(token, chat, &screen_message(app, screen, &texts));
            }
        }
        telegram::UpdateKind::Press { callback, data, message } => {
            let Some(route) = telegram::Route::parse(data) else {
                telegram::answer_press(token, callback, Some(texts.t("Кнопка устарела")));
                if let Some(message) = message {
                    let _ = telegram::edit_message(token, chat, *message, &screen_message(app, telegram::Screen::Home, &texts));
                }
                return;
            };
            if route.is_action() && after_gap {
                telegram::answer_press(token, callback, Some(texts.t("Устарело — откройте меню заново")));
                return;
            }
            match route {
                telegram::Route::Show(screen) => {
                    telegram::answer_press(token, callback, None);
                    if let Some(message) = message {
                        let _ = telegram::edit_message(token, chat, *message, &screen_message(app, screen, &texts));
                    }
                }
                telegram::Route::Answer { request, allow } => {
                    let open = open_requests().iter().any(|(r, _)| r.id == request);
                    if !open || approvals::decide(&paths::approvals_dir(), &request, allow).is_err() {
                        telegram::answer_press(token, callback, Some(texts.t("Ответ уже дан")));
                        return;
                    }
                    eprintln!("telegram: permission {}", if allow { "allowed" } else { "denied" });
                    app.state::<Telegram>().state.lock().unwrap().answered.insert(request.clone(), allow);
                    telegram::answer_press(token, callback, Some(if allow { texts.t("Разрешено") } else { texts.t("Отклонено") }));
                    let _ = app.emit("sessions-changed", ());
                    // A press on 🤖 or «Подробнее»: that message shows the rest; the request's own closes in `sync_requests`.
                    let own = app.state::<Telegram>().state.lock().unwrap().sent.get(&request).map(|entry| entry.0);
                    if let Some(message) = message.filter(|m| Some(*m) != own) {
                        let _ = telegram::edit_message(token, chat, message, &screen_message(app, telegram::Screen::Sessions, &texts));
                    }
                    sync_requests(app);
                }
                telegram::Route::LimitAlerts(on) => {
                    telegram::answer_press(token, callback, None);
                    crate::save(app, |settings| {
                        settings.telegram_off.retain(|e| e != "lim");
                        if !on {
                            settings.telegram_off.push("lim".to_owned());
                        }
                    });
                    let _ = app.emit("telegram-changed", ());
                    if let Some(message) = message {
                        let _ = telegram::edit_message(token, chat, *message, &screen_message(app, telegram::Screen::Limits, &texts));
                    }
                }
                telegram::Route::Details(request) => {
                    telegram::answer_press(token, callback, None);
                    let shown = crate::sessions::shown();
                    let found = open_requests().into_iter().find(|(r, _)| r.id == request);
                    let details = match found {
                        Some((request, project)) => {
                            let session = shown.iter().find(|(s, _)| s.id == request.session_id).map(|(s, _)| s);
                            let answered = app.state::<Telegram>().state.lock().unwrap().answered.contains_key(&request.id);
                            telegram::request_details(&request, &project, session.and_then(|s| s.task.as_deref()), session.map(|s| s.cwd.as_str()), !answered, &texts)
                        }
                        None => telegram::Message { html: format!("☑️ {}", telegram::escape(texts.t("Ответ уже дан"))), buttons: Vec::new() },
                    };
                    let _ = telegram::send_message(token, chat, &details);
                }
            }
        }
    }
}

/// The open permission requests, oldest first, each with its project's name.
fn open_requests() -> Vec<(Request, String)> {
    let shown = crate::sessions::shown();
    let mut open: Vec<(Request, String)> = crate::sessions::open_requests(&shown)
        .into_values()
        .map(|request| {
            let project = shown.iter().find(|(s, _)| s.id == request.session_id).map(|(s, _)| s.display_project()).or_else(|| request.project.clone()).unwrap_or_else(|| "Claude".to_owned());
            (request, project)
        })
        .collect();
    open.sort_by(|a, b| a.0.created.total_cmp(&b.0.created));
    open
}

fn screen_message(app: &AppHandle, screen: telegram::Screen, texts: &Strings) -> telegram::Message {
    let shown = crate::sessions::shown();
    match screen {
        telegram::Screen::Home => {
            let (session, week) = app.state::<crate::limits::Limits>().brief(texts);
            let home = telegram::Home {
                computer: computer_name(),
                session,
                week,
                working: shown.iter().filter(|(_, state)| *state == SessionState::Running).count(),
                waiting: shown.iter().filter(|(_, state)| *state == SessionState::Waiting).count(),
                runs: app.state::<crate::runs::Runs>().list().iter().filter(|run| run.is_running()).count(),
            };
            telegram::home_screen(&home, texts)
        }
        telegram::Screen::Limits => {
            let mut services = vec![app.state::<crate::limits::Limits>().telegram_service(texts)];
            services.retain(|service| !service.windows.is_empty());
            services.extend(app.state::<crate::hub::Hub>().telegram_services(texts));
            let alerts_on = !app.state::<crate::AppState>().settings.lock().unwrap().telegram_off.iter().any(|e| e == "lim");
            telegram::limits_screen(&services, alerts_on, &crate::limits::thresholds(app), texts)
        }
        telegram::Screen::Sessions => {
            let now = Utc::now();
            let lines: Vec<telegram::SessionLine> = shown
                .iter()
                .filter(|(_, state)| matches!(state, SessionState::Waiting | SessionState::Running))
                .map(|(session, state)| {
                    let waiting = *state == SessionState::Waiting;
                    telegram::SessionLine {
                        project: session.display_project(),
                        agent: session.agent_name().to_owned(),
                        waiting,
                        detail: if waiting { session.message.clone().or_else(|| session.task.clone()) } else { session.action_text(texts).or_else(|| session.task.clone()) },
                        ago: Some(claudepult_core::projects::ago(texts, session.updated_at, now)),
                    }
                })
                .collect();
            let answered = app.state::<Telegram>().state.lock().unwrap().answered.clone();
            let requests: Vec<telegram::RequestLine> = open_requests()
                .into_iter()
                .filter(|(request, _)| !answered.contains_key(&request.id))
                .map(|(request, project)| telegram::RequestLine { id: request.id, project, tool: request.tool, summary: request.summary })
                .collect();
            telegram::sessions_screen(&lines, &requests, true, texts)
        }
    }
}

fn computer_name() -> String {
    std::env::var("COMPUTERNAME").or_else(|_| std::env::var("HOSTNAME")).ok().filter(|name| !name.is_empty()).unwrap_or_else(|| "PC".to_owned())
}

/// New requests get a message in the chat; answered ones (from the chat, in the panel, in the terminal or by the
/// agent itself) lose their buttons. Runs every few seconds and right after an answer from the chat.
fn sync_requests(app: &AppHandle) {
    let on = app.state::<crate::AppState>().settings.lock().unwrap().telegram_requests;
    let Some((token, chat)) = bot(app).filter(|_| on) else { return };
    let texts = crate::strings(app);
    let can_answer = answers_here(app);
    let open = open_requests();
    for (request, project) in &open {
        if app.state::<Telegram>().state.lock().unwrap().sent.contains_key(&request.id) {
            continue;
        }
        match telegram::send_message(&token, &chat, &telegram::request_message(request, project, can_answer, &texts)) {
            Ok(message) => {
                app.state::<Telegram>().state.lock().unwrap().sent.insert(request.id.clone(), (message, request.clone(), project.clone()));
            }
            Err(error) => eprintln!("telegram: request not sent: {error:?}"),
        }
    }
    let closed: Vec<(String, (i64, Request, String), Option<bool>)> = {
        let state = app.state::<Telegram>();
        let mut state = state.state.lock().unwrap();
        let gone: Vec<String> = state.sent.keys().filter(|id| !open.iter().any(|(r, _)| &r.id == *id)).cloned().collect();
        let closed = gone.into_iter().filter_map(|id| { let entry = state.sent.remove(&id)?; let outcome = state.answered.remove(&id); Some((id, entry, outcome)) }).collect();
        state.answered.retain(|id, _| open.iter().any(|(r, _)| &r.id == id));
        closed
    };
    for (_, (message, request, project), outcome) in closed {
        let _ = telegram::edit_message(&token, &chat, message, &telegram::request_closed(&request, &project, outcome, &texts));
    }
}

/// «Этот компьютер отвечает боту».
#[tauri::command]
pub fn set_telegram_answers(app: AppHandle, on: bool) -> TelegramView {
    crate::save(&app, |settings| settings.telegram_answers = on);
    change(&app, |state| {
        state.status = None;
        state.conflict = false;
    });
    view(&app)
}

/// «Запросы разрешений в этот бот».
#[tauri::command]
pub fn set_telegram_requests(app: AppHandle, on: bool) -> TelegramView {
    crate::save(&app, |settings| settings.telegram_requests = on);
    view(&app)
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
