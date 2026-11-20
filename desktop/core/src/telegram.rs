//! Telegram (docs/specs/SPEC-telegram.md, SPEC-windows §11.1), stage 1 on Windows and Linux: the person's own bot from
//! @BotFather sends what the notifications say — results of background tasks, limit thresholds, calendar reminders,
//! PR and CI changes. The token is kept like an API key (`keys`, «ClaudePult API key/telegram-bot», the Mac's
//! account), the chat is bound by a one-time code sent with «Start». The bot's menu, answers to permission requests
//! and tasks from the chat are the Mac's later stages and are not here yet: nothing reads the bot's messages besides
//! the few minutes of binding, so a Mac that answers the same bot is not disturbed.
//!
//! The token is only ever in the request's address; errors carry the method and the HTTP code, never the address.

use std::time::Duration;

use serde_json::{json, Value};

/// The account of the token among the API keys (the Mac's `Telegram.keychainAccount`).
pub const KEY: &str = "telegram-bot";

/// What can come to Telegram, by the Mac's `BotEvent` codes: background results, limit thresholds, calendar, PRs.
pub const EVENTS: [&str; 4] = ["bg", "lim", "cal", "pr"];

/// A binding code lives this long (SPEC-telegram §1).
pub const BINDING_MINUTES: i64 = 10;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    /// No answer at all.
    Network,
    /// Telegram answered with this HTTP code: 401 a wrong token, 400 or 403 a chat the bot can't write to, 409
    /// another program reads the bot.
    Http(u16),
}

/// The Mac's event titles (`BotEvent.title`).
pub fn event_title(event: &str, s: &crate::i18n::Strings) -> String {
    match event {
        "bg" => s.t("Итоги фоновых задач"),
        "lim" => s.t("Пороги лимитов"),
        "cal" => s.t("Напоминания календаря"),
        _ => s.t("PR и CI"),
    }
    .to_owned()
}

// MARK: - Messages (Telegram HTML; everything that isn't ours is escaped)

pub fn escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// «⚠️ <b>title</b>⏎body» — a limit threshold, as the Mac sends it.
pub fn alert_html(title: &str, body: &str) -> String {
    format!("⚠️ <b>{}</b>\n{}", escape(title), escape(body))
}

/// «📅 <b>Дедлайн: Ролик</b>⏎завтра».
pub fn calendar_html(title: &str, when: &str) -> String {
    format!("📅 <b>{}</b>\n{}", escape(title), escape(when))
}

/// «title — body» with a «PR» link under it.
pub fn pull_request_html(title: &str, body: &str, url: Option<&str>) -> String {
    let text = format!("{} — {}", escape(title), escape(body));
    match url {
        Some(url) => format!("{text}\n<a href=\"{}\">PR</a>", escape(url)),
        None => text,
    }
}

/// «✅ <b>Shop</b>: начало задачи — итог» with «PR #12» under it (`RunMessage.telegramHTML`).
pub fn run_html(succeeded: bool, project: &str, task_start: &str, outcome: &str, pull_request: Option<&str>) -> String {
    let icon = if succeeded { "✅" } else { "❌" };
    let mut text = format!("{icon} <b>{}</b>: {} — {}", escape(project), escape(task_start), escape(outcome));
    if let Some(url) = pull_request {
        let number = url.rsplit('/').next().filter(|n| !n.is_empty()).map(|n| format!(" #{n}")).unwrap_or_default();
        text += &format!("\n<a href=\"{}\">PR{}</a>", escape(url), escape(&number));
    }
    text
}

// MARK: - The token and the binding code

/// «123456:ABC…» as @BotFather gives it: checked before it goes into a request's address.
pub fn looks_like_token(token: &str) -> bool {
    match token.split_once(':') {
        Some((id, secret)) => {
            !id.is_empty() && id.len() <= 20 && id.bytes().all(|b| b.is_ascii_digit()) && secret.len() >= 20 && secret.len() <= 80 && secret.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        }
        None => false,
    }
}

/// Eight characters nobody can guess in ten minutes; the seed is the standard library's per-process random one.
pub fn new_code() -> String {
    use std::hash::{BuildHasher, Hasher};
    const LETTERS: &[u8] = b"abcdefghjkmnpqrstuvwxyz23456789";
    let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
    hasher.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0));
    let mut value = hasher.finish();
    (0..8)
        .map(|_| {
            let letter = LETTERS[(value % LETTERS.len() as u64) as usize] as char;
            value /= LETTERS.len() as u64;
            letter
        })
        .collect()
}

/// The link whose «Start» sends `/start <code>` to the bot.
pub fn binding_link(bot: &str, code: &str) -> String {
    format!("https://t.me/{bot}?start={code}")
}

/// The private chat that sent `/start <code>` — the person's own chat with the bot: a group, a channel, a message
/// passed on by someone else or another code is not it.
pub fn binding_chat(updates: &Value, code: &str) -> Option<String> {
    let wanted = format!("/start {code}");
    updates.get("result")?.as_array()?.iter().find_map(|update| {
        let message = update.get("message")?;
        let chat = message.get("chat")?;
        let id = chat.get("id")?.as_i64()?;
        let own = chat.get("type").and_then(Value::as_str) == Some("private") && message.get("from").and_then(|from| from.get("id")).and_then(Value::as_i64) == Some(id);
        (own && message.get("text").and_then(Value::as_str).map(str::trim) == Some(wanted.as_str())).then(|| id.to_string())
    })
}

/// The offset for the next `getUpdates`: one past the last update read.
pub fn next_offset(updates: &Value) -> Option<i64> {
    updates.get("result")?.as_array()?.iter().filter_map(|update| update.get("update_id")?.as_i64()).max().map(|id| id + 1)
}

// MARK: - The Bot API

fn call(token: &str, method: &str, body: Value, timeout: Duration) -> Result<Value, Error> {
    if !looks_like_token(token) {
        return Err(Error::Http(401));
    }
    let agent: ureq::Agent = ureq::Agent::config_builder().http_status_as_error(false).timeout_global(Some(timeout)).build().into();
    let request = agent.post(&format!("https://api.telegram.org/bot{token}/{method}")).header("Content-Type", "application/json").header("User-Agent", "AIHubBar");
    let mut response = request.send(body.to_string()).map_err(|_| Error::Network)?;
    let status = response.status().as_u16();
    if status != 200 {
        return Err(Error::Http(status));
    }
    let text = response.body_mut().read_to_string().map_err(|_| Error::Network)?;
    serde_json::from_str(&text).map_err(|_| Error::Network)
}

/// `getMe`: the bot's user name, which is also the check of a token.
pub fn bot_name(token: &str) -> Result<String, Error> {
    let reply = call(token, "getMe", json!({}), Duration::from_secs(20))?;
    reply.get("result").and_then(|bot| bot.get("username")).and_then(Value::as_str).map(str::to_owned).ok_or(Error::Network)
}

pub fn send(token: &str, chat: &str, html: &str) -> Result<(), Error> {
    call(token, "sendMessage", json!({ "chat_id": chat, "text": html, "parse_mode": "HTML", "disable_web_page_preview": true }), Duration::from_secs(20)).map(|_| ())
}

/// `getUpdates`, waiting up to `wait` seconds for a message. Only while a chat is being bound.
pub fn updates(token: &str, offset: Option<i64>, wait: u64) -> Result<Value, Error> {
    let mut body = json!({ "timeout": wait, "allowed_updates": ["message"] });
    if let Some(offset) = offset {
        body["offset"] = json!(offset);
    }
    call(token, "getUpdates", body, Duration::from_secs(wait + 15))
}

// MARK: - What comes from the chat (stage 2; the Mac's `BotUpdate`, `BotRoute`)

/// A message or a button press older than this is not acted on: the computer slept, the app was closed.
pub const MAX_AGE_SECONDS: i64 = 30 * 60;

#[derive(Debug, Clone, PartialEq)]
pub enum UpdateKind {
    Message { text: String },
    Press { callback: String, data: String, message: Option<i64> },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Update {
    pub chat: String,
    pub from: Option<String>,
    pub private: bool,
    /// When the message was sent; a press has no time of its own.
    pub date: Option<i64>,
    pub kind: UpdateKind,
}

impl Update {
    /// Only the bound chat is answered; in a private chat the sender must be that chat's person.
    pub fn is_from(&self, chat: &str) -> bool {
        !chat.is_empty() && self.chat == chat && (!self.private || self.from.as_deref() == Some(chat))
    }

    pub fn is_stale(&self, now: i64) -> bool {
        self.date.is_some_and(|date| now - date > MAX_AGE_SECONDS)
    }
}

/// The messages and presses of a `getUpdates` answer; anything else (edits, joins, channels' posts) is left out.
pub fn parse_updates(updates: &Value) -> Vec<Update> {
    let id = |value: Option<&Value>| value.and_then(|v| v.get("id")).and_then(Value::as_i64).map(|id| id.to_string());
    updates
        .get("result")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(|update| {
                    if let Some(message) = update.get("message") {
                        let chat = message.get("chat")?;
                        Some(Update {
                            chat: id(Some(chat))?,
                            from: id(message.get("from")),
                            private: chat.get("type").and_then(Value::as_str) == Some("private"),
                            date: message.get("date").and_then(Value::as_i64),
                            kind: UpdateKind::Message { text: message.get("text")?.as_str()?.to_owned() },
                        })
                    } else {
                        let press = update.get("callback_query")?;
                        let message = press.get("message");
                        let chat = message.and_then(|m| m.get("chat"))?;
                        Some(Update {
                            chat: id(Some(chat))?,
                            from: id(press.get("from")),
                            private: chat.get("type").and_then(Value::as_str) == Some("private"),
                            date: None,
                            kind: UpdateKind::Press {
                                callback: press.get("id")?.as_str()?.to_owned(),
                                data: press.get("data")?.as_str()?.to_owned(),
                                message: message.and_then(|m| m.get("message_id")).and_then(Value::as_i64),
                            },
                        })
                    }
                })
                .collect()
        })
        .unwrap_or_default()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Screen {
    Home,
    Sessions,
}

/// What a button means, by its callback data (SPEC-telegram §3; the Mac's format).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Route {
    Show(Screen),
    Answer { request: String, allow: bool },
    Details(String),
}

impl Route {
    pub fn parse(data: &str) -> Option<Route> {
        let (verb, argument) = data.split_once(':')?;
        match (verb, argument) {
            ("nav", "home") => Some(Route::Show(Screen::Home)),
            ("nav", "sessions") => Some(Route::Show(Screen::Sessions)),
            ("allow", id) if crate::approvals::is_valid_id(id) => Some(Route::Answer { request: id.to_owned(), allow: true }),
            ("deny", id) if crate::approvals::is_valid_id(id) => Some(Route::Answer { request: id.to_owned(), allow: false }),
            ("req", id) if crate::approvals::is_valid_id(id) => Some(Route::Details(id.to_owned())),
            _ => None,
        }
    }

    pub fn data(&self) -> String {
        match self {
            Route::Show(Screen::Home) => "nav:home".to_owned(),
            Route::Show(Screen::Sessions) => "nav:sessions".to_owned(),
            Route::Answer { request, allow: true } => format!("allow:{request}"),
            Route::Answer { request, allow: false } => format!("deny:{request}"),
            Route::Details(request) => format!("req:{request}"),
        }
    }

    /// An action, not a look: refused right after a gap in reading (a press carries no time).
    pub fn is_action(&self) -> bool {
        matches!(self, Route::Answer { .. })
    }
}

/// `/start` and `/menu` (also as `/menu@my_bot`) open 🏠; other text is not a command.
pub fn command(text: &str) -> Option<Screen> {
    let first = text.split_whitespace().next()?;
    let name = first.strip_prefix('/')?.split('@').next()?.to_lowercase();
    matches!(name.as_str(), "start" | "menu").then_some(Screen::Home)
}

// MARK: - What the bot says (the Mac's `BotScreens`)

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Message {
    pub html: String,
    /// Rows of buttons: a title and the route it carries.
    pub buttons: Vec<Vec<(String, Route)>>,
}

impl Message {
    fn keyboard(&self) -> Value {
        json!({ "inline_keyboard": self.buttons.iter().map(|row| row.iter().map(|(title, route)| json!({ "text": title, "callback_data": route.data() })).collect::<Vec<_>>()).collect::<Vec<_>>() })
    }
}

fn button(icon: &str, title: &str, route: Route) -> (String, Route) {
    (format!("{icon} {title}"), route)
}

fn percent(value: f64) -> String {
    format!("{} %", value.round() as i64)
}

/// What 🏠 shows.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Home {
    pub computer: String,
    /// Claude's session: percent used and «сброс через 2 ч 14 мин».
    pub session: Option<(f64, Option<String>)>,
    pub week: Option<f64>,
    pub working: usize,
    pub waiting: usize,
    pub runs: usize,
}

pub fn home_screen(home: &Home, s: &crate::i18n::Strings) -> Message {
    let mut limits = Vec::new();
    if let Some((used, reset)) = &home.session {
        let mut text = s.format("сессия %@", &[&percent(*used)]);
        if let Some(reset) = reset {
            text += &format!(" ({reset})");
        }
        limits.push(text);
    }
    if let Some(week) = home.week {
        limits.push(s.format("неделя %@", &[&percent(week)]));
    }
    let lines = [
        format!("🏠 <b>AI Hub Bar</b> · {}", escape(&home.computer)),
        format!("⏳ Claude: {}", escape(&if limits.is_empty() { s.t("лимиты ещё не загружены").to_owned() } else { limits.join(", ") })),
        format!("🤖 {}", escape(&s.format("Сессии: %lld работают, %lld ждут", &[&home.working.to_string(), &home.waiting.to_string()]))),
        format!("🚀 {}", escape(&s.format("Фоновые задачи: %lld", &[&home.runs.to_string()]))),
    ];
    Message {
        html: lines.join("\n"),
        buttons: vec![vec![button("🤖", s.t("Сессии"), Route::Show(Screen::Sessions)), button("🔄", s.t("Обновить"), Route::Show(Screen::Home))]],
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct SessionLine {
    pub project: String,
    pub agent: String,
    pub waiting: bool,
    pub detail: Option<String>,
    /// «5 мин назад».
    pub ago: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RequestLine {
    pub id: String,
    pub project: String,
    pub tool: String,
    pub summary: String,
}

fn head(text: &str, limit: usize) -> String {
    text.chars().take(limit).collect()
}

/// 🤖: waiting sessions first, then working ones; open permission requests numbered, with ✅ / ❌ when this computer
/// answers the bot, and «ℹ️» always.
pub fn sessions_screen(lines: &[SessionLine], requests: &[RequestLine], can_answer: bool, s: &crate::i18n::Strings) -> Message {
    let mut text = vec![format!("🤖 <b>{}</b>", escape(s.t("Сессии")))];
    let ordered: Vec<&SessionLine> = lines.iter().filter(|l| l.waiting).chain(lines.iter().filter(|l| !l.waiting)).collect();
    if ordered.is_empty() {
        text.push(escape(s.t("Сессий сейчас нет.")));
    }
    for line in ordered.iter().take(15) {
        let mut row = format!("{} <b>{}</b> · {}", if line.waiting { "✋" } else { "⚙️" }, escape(&line.project), escape(&line.agent));
        if let Some(ago) = &line.ago {
            row += &format!(" · {}", escape(ago));
        }
        if let Some(detail) = line.detail.as_deref().filter(|d| !d.is_empty()) {
            row += &format!("\n    {}", escape(&head(detail, 120)));
        }
        text.push(row);
    }
    if ordered.len() > 15 {
        text.push(escape(&s.format("… и ещё %lld", &[&(ordered.len() - 15).to_string()])));
    }
    let mut rows = Vec::new();
    if !requests.is_empty() {
        text.push(String::new());
        text.push(format!("✋ <b>{}</b>", escape(s.t("Запросы разрешений"))));
        for (index, request) in requests.iter().take(8).enumerate() {
            let number = index + 1;
            let summary = if request.summary.is_empty() { String::new() } else { format!(" — <code>{}</code>", escape(&head(&request.summary, 80))) };
            text.push(format!("{number}. <b>{}</b>: {}{summary}", escape(&request.project), escape(&request.tool)));
            let mut row = Vec::new();
            if can_answer {
                row.push((format!("✅ {number}"), Route::Answer { request: request.id.clone(), allow: true }));
                row.push((format!("❌ {number}"), Route::Answer { request: request.id.clone(), allow: false }));
            }
            row.push((format!("ℹ️ {number}"), Route::Details(request.id.clone())));
            rows.push(row);
        }
    }
    rows.push(vec![button("🔄", s.t("Обновить"), Route::Show(Screen::Sessions)), button("⬅️", s.t("Главная"), Route::Show(Screen::Home))]);
    Message { html: text.join("\n"), buttons: rows }
}

fn request_html(request: &crate::approvals::Request, project: &str, s: &crate::i18n::Strings) -> String {
    let summary = if request.summary.is_empty() { String::new() } else { format!("\n<code>{}</code>", escape(&request.summary)) };
    format!("✋ <b>{}</b>: {} — {}{summary}", escape(project), escape(&request.asks_title(s)), escape(&request.tool))
}

/// «✋ <b>Shop</b>: Claude просит разрешение — Bash» with the command under it; ✅ / ❌ only when a press can reach
/// this computer (it reads the bot).
pub fn request_message(request: &crate::approvals::Request, project: &str, can_answer: bool, s: &crate::i18n::Strings) -> Message {
    let mut row = Vec::new();
    if can_answer {
        row.push(button("✅", s.t("Разрешить"), Route::Answer { request: request.id.clone(), allow: true }));
        row.push(button("❌", s.t("Отклонить"), Route::Answer { request: request.id.clone(), allow: false }));
        row.push(button("ℹ️", s.t("Подробнее"), Route::Details(request.id.clone())));
    }
    Message { html: request_html(request, project, s), buttons: if row.is_empty() { Vec::new() } else { vec![row] } }
}

/// The request's message once it is answered — from the chat (`Some`), or in the panel, in the terminal or by the
/// agent itself (`None`): no more buttons.
pub fn request_closed(request: &crate::approvals::Request, project: &str, outcome: Option<bool>, s: &crate::i18n::Strings) -> Message {
    let note = match outcome {
        Some(true) => format!("✅ {}", escape(s.t("Разрешено"))),
        Some(false) => format!("❌ {}", escape(s.t("Отклонено"))),
        None => format!("☑️ {}", escape(s.t("Ответ уже дан"))),
    };
    Message { html: format!("{}\n{note}", request_html(request, project, s)), buttons: Vec::new() }
}

/// «Подробнее»: the whole request and what the session was asked to do.
pub fn request_details(request: &crate::approvals::Request, project: &str, task: Option<&str>, folder: Option<&str>, can_answer: bool, s: &crate::i18n::Strings) -> Message {
    let mut lines = vec![format!("✋ <b>{}</b> — {}", escape(project), escape(&request.tool))];
    if !request.summary.is_empty() {
        lines.push(format!("<pre>{}</pre>", escape(&head(&request.summary, 3000))));
    }
    if let Some(task) = task.filter(|t| !t.is_empty()) {
        lines.push(format!("{} {}", escape(s.t("Задача сессии:")), escape(&head(task, 300))));
    }
    if let Some(folder) = folder {
        lines.push(format!("📁 <code>{}</code>", escape(folder)));
    }
    let mut rows = Vec::new();
    if can_answer {
        rows.push(vec![button("✅", s.t("Разрешить"), Route::Answer { request: request.id.clone(), allow: true }), button("❌", s.t("Отклонить"), Route::Answer { request: request.id.clone(), allow: false })]);
    }
    rows.push(vec![button("🤖", s.t("Сессии"), Route::Show(Screen::Sessions))]);
    Message { html: lines.join("\n"), buttons: rows }
}

// MARK: - The Bot API for the reader

/// Sends a screen or a message; the message's id, for editing it later.
pub fn send_message(token: &str, chat: &str, message: &Message) -> Result<i64, Error> {
    let mut body = json!({ "chat_id": chat, "text": message.html, "parse_mode": "HTML", "disable_web_page_preview": true });
    if !message.buttons.is_empty() {
        body["reply_markup"] = message.keyboard();
    }
    let reply = call(token, "sendMessage", body, Duration::from_secs(20))?;
    reply.get("result").and_then(|m| m.get("message_id")).and_then(Value::as_i64).ok_or(Error::Network)
}

/// Replaces a message's text and buttons. Telegram answers 400 when nothing changed; that is not a failure here.
pub fn edit_message(token: &str, chat: &str, id: i64, message: &Message) -> Result<(), Error> {
    let body = json!({ "chat_id": chat, "message_id": id, "text": message.html, "parse_mode": "HTML", "disable_web_page_preview": true, "reply_markup": message.keyboard() });
    match call(token, "editMessageText", body, Duration::from_secs(20)) {
        Ok(_) | Err(Error::Http(400)) => Ok(()),
        Err(error) => Err(error),
    }
}

/// Ends a button's spinner; `text` shows as a small note over the chat.
pub fn answer_press(token: &str, callback: &str, text: Option<&str>) {
    let mut body = json!({ "callback_query_id": callback });
    if let Some(text) = text {
        body["text"] = json!(text);
    }
    let _ = call(token, "answerCallbackQuery", body, Duration::from_secs(10));
}

/// `getUpdates` for the reader: messages and button presses, waiting up to `wait` seconds.
pub fn read(token: &str, offset: Option<i64>, wait: u64) -> Result<Value, Error> {
    let mut body = json!({ "timeout": wait, "allowed_updates": ["message", "callback_query"] });
    if let Some(offset) = offset {
        body["offset"] = json!(offset);
    }
    call(token, "getUpdates", body, Duration::from_secs(wait + 15))
}

/// The bot's Menu button: `/menu`.
pub fn set_commands(token: &str, menu_description: &str) -> Result<(), Error> {
    call(token, "setMyCommands", json!({ "commands": [{ "command": "menu", "description": menu_description }] }), Duration::from_secs(20)).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_escape_what_is_not_ours() {
        assert_eq!(escape(r#"a<b> & "c""#), "a&lt;b&gt; &amp; &quot;c&quot;");
        assert_eq!(alert_html("Claude: 80 %", "сессия <5 ч>"), "⚠️ <b>Claude: 80 %</b>\nсессия &lt;5 ч&gt;");
        assert_eq!(calendar_html("Дедлайн: Ролик", "завтра"), "📅 <b>Дедлайн: Ролик</b>\nзавтра");
        assert_eq!(pull_request_html("❌ CI упал: shop #7", "Fix <cart>", Some("https://github.com/o/shop/pull/7")), "❌ CI упал: shop #7 — Fix &lt;cart&gt;\n<a href=\"https://github.com/o/shop/pull/7\">PR</a>");
        assert_eq!(pull_request_html("PR закрыт или смерджен: shop #7", "Fix", None), "PR закрыт или смерджен: shop #7 — Fix");
        assert_eq!(
            run_html(true, "Shop & Co", "почини <корзину>", "готово", Some("https://github.com/o/shop/pull/12")),
            "✅ <b>Shop &amp; Co</b>: почини &lt;корзину&gt; — готово\n<a href=\"https://github.com/o/shop/pull/12\">PR #12</a>"
        );
        assert_eq!(run_html(false, "Shop", "задача", "остановлено вручную", None), "❌ <b>Shop</b>: задача — остановлено вручную");
    }

    #[test]
    fn tokens_and_codes() {
        assert!(looks_like_token("123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"));
        for wrong in ["", "123456789", "abc:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw", "123:short", "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw/getMe", "123456789:AAHdqTcvCH1vGWJxfSeof SAs0K5PALDsaw"] {
            assert!(!looks_like_token(wrong), "{wrong}");
        }
        let (one, two) = (new_code(), new_code());
        assert!(one.len() == 8 && one.bytes().all(|b| b.is_ascii_alphanumeric()));
        assert_ne!(one, two);
        assert_eq!(binding_link("my_bot", "abc23456"), "https://t.me/my_bot?start=abc23456");
        // Nothing leaves for a token that isn't one.
        assert_eq!(send("not a token", "1", "x"), Err(Error::Http(401)));
    }

    #[test]
    fn only_the_persons_own_chat_is_bound() {
        let updates: Value = serde_json::from_str(
            r#"{"ok": true, "result": [
                {"update_id": 10, "message": {"chat": {"id": -100, "type": "group"}, "from": {"id": 5}, "text": "/start code1234"}},
                {"update_id": 11, "message": {"chat": {"id": 7, "type": "private"}, "from": {"id": 7}, "text": "/start other"}},
                {"update_id": 12, "message": {"chat": {"id": 8, "type": "private"}, "from": {"id": 9}, "text": "/start code1234"}},
                {"update_id": 13, "message": {"chat": {"id": 42, "type": "private"}, "from": {"id": 42}, "text": "/start code1234 "}}
            ]}"#,
        )
        .unwrap();
        assert_eq!(binding_chat(&updates, "code1234").as_deref(), Some("42"));
        assert_eq!(binding_chat(&updates, "code9999"), None);
        assert_eq!(next_offset(&updates), Some(14));
        assert_eq!(next_offset(&serde_json::json!({"ok": true, "result": []})), None);
    }

    fn request() -> crate::approvals::Request {
        serde_json::from_str(r#"{"id": "0123456789abcdef0123456789abcdef", "session_id": "s1", "project": "shop", "tool": "Bash", "summary": "rm -rf <build>", "created": 100.0}"#).unwrap()
    }

    #[test]
    fn updates_from_the_chat() {
        let updates: Value = serde_json::from_str(
            r#"{"ok": true, "result": [
                {"update_id": 1, "message": {"message_id": 5, "date": 1000, "chat": {"id": 42, "type": "private"}, "from": {"id": 42}, "text": "/menu"}},
                {"update_id": 2, "callback_query": {"id": "cb1", "from": {"id": 42}, "data": "nav:sessions", "message": {"message_id": 9, "chat": {"id": 42, "type": "private"}}}},
                {"update_id": 3, "message": {"message_id": 6, "date": 1000, "chat": {"id": 42, "type": "private"}, "from": {"id": 7}, "text": "/menu"}},
                {"update_id": 4, "edited_message": {"chat": {"id": 42}}},
                {"update_id": 5, "message": {"message_id": 7, "date": 1000, "chat": {"id": 42, "type": "private"}, "from": {"id": 42}, "sticker": {}}}
            ]}"#,
        )
        .unwrap();
        let parsed = parse_updates(&updates);
        assert_eq!(parsed.len(), 3);
        assert_eq!(parsed[0].kind, UpdateKind::Message { text: "/menu".into() });
        assert_eq!(parsed[1].kind, UpdateKind::Press { callback: "cb1".into(), data: "nav:sessions".into(), message: Some(9) });
        assert!(parsed[0].is_from("42") && parsed[1].is_from("42"));
        assert!(!parsed[2].is_from("42"), "someone else's message in the person's chat");
        assert!(!parsed[0].is_from("43") && !parsed[0].is_from(""));
        assert!(!parsed[0].is_stale(1000 + MAX_AGE_SECONDS) && parsed[0].is_stale(1001 + MAX_AGE_SECONDS));
        assert!(!parsed[1].is_stale(i64::MAX / 2), "a press has no time");
    }

    #[test]
    fn routes_and_commands() {
        let id = "0123456789abcdef0123456789abcdef";
        for route in [Route::Show(Screen::Home), Route::Show(Screen::Sessions), Route::Answer { request: id.into(), allow: true }, Route::Answer { request: id.into(), allow: false }, Route::Details(id.into())] {
            assert!(route.data().len() <= 64);
            assert_eq!(Route::parse(&route.data()), Some(route.clone()));
            assert_eq!(route.is_action(), matches!(route, Route::Answer { .. }));
        }
        for wrong in ["", "nav", "nav:mac", "allow:", "allow:../x", "run:1", "allow:0123456789abcdef0123456789abcdef:x"] {
            assert_eq!(Route::parse(wrong), None, "{wrong}");
        }
        assert_eq!(command("/start"), Some(Screen::Home));
        assert_eq!(command("/Menu@my_bot now"), Some(Screen::Home));
        assert_eq!(command("menu"), None);
        assert_eq!(command("/report"), None);
        assert_eq!(command(""), None);
    }

    #[test]
    fn home_and_sessions() {
        let s = crate::i18n::Strings::default();
        let home = Home { computer: "PC <1>".into(), session: Some((41.6, Some("сброс через 2 ч 14 мин".into()))), week: Some(31.0), working: 2, waiting: 1, runs: 3 };
        let message = home_screen(&home, &s);
        assert_eq!(message.html, "🏠 <b>AI Hub Bar</b> · PC &lt;1&gt;\n⏳ Claude: сессия 42 % (сброс через 2 ч 14 мин), неделя 31 %\n🤖 Сессии: 2 работают, 1 ждут\n🚀 Фоновые задачи: 3");
        assert_eq!(message.buttons[0][0], ("🤖 Сессии".to_owned(), Route::Show(Screen::Sessions)));
        assert!(home_screen(&Home::default(), &s).html.contains("⏳ Claude: лимиты ещё не загружены"));

        let lines = [
            SessionLine { project: "shop".into(), agent: "Claude".into(), waiting: false, detail: Some("правит a.rs".into()), ago: Some("5 мин назад".into()) },
            SessionLine { project: "blog".into(), agent: "Codex".into(), waiting: true, detail: None, ago: None },
        ];
        let requests = [RequestLine { id: "0123456789abcdef0123456789abcdef".into(), project: "blog".into(), tool: "Bash".into(), summary: "npm <i>".into() }];
        let screen = sessions_screen(&lines, &requests, true, &s);
        assert_eq!(
            screen.html,
            "🤖 <b>Сессии</b>\n✋ <b>blog</b> · Codex\n⚙️ <b>shop</b> · Claude · 5 мин назад\n    правит a.rs\n\n✋ <b>Запросы разрешений</b>\n1. <b>blog</b>: Bash — <code>npm &lt;i&gt;</code>"
        );
        assert_eq!(screen.buttons[0].iter().map(|b| b.0.as_str()).collect::<Vec<_>>(), ["✅ 1", "❌ 1", "ℹ️ 1"]);
        assert_eq!(sessions_screen(&lines, &requests, false, &s).buttons[0].len(), 1, "no answers where a press can't come");
        assert!(sessions_screen(&[], &[], true, &s).html.ends_with("Сессий сейчас нет."));
    }

    #[test]
    fn request_messages() {
        let s = crate::i18n::Strings::default();
        let request = request();
        let open = request_message(&request, "shop", true, &s);
        assert!(open.html.starts_with("✋ <b>shop</b>: ") && open.html.ends_with(" — Bash\n<code>rm -rf &lt;build&gt;</code>"), "{}", open.html);
        assert_eq!(open.buttons[0].iter().map(|b| b.1.data()).collect::<Vec<_>>(), ["allow:0123456789abcdef0123456789abcdef", "deny:0123456789abcdef0123456789abcdef", "req:0123456789abcdef0123456789abcdef"]);
        assert!(request_message(&request, "shop", false, &s).buttons.is_empty());
        assert!(request_closed(&request, "shop", Some(true), &s).html.ends_with("\n✅ Разрешено"));
        assert!(request_closed(&request, "shop", Some(false), &s).html.ends_with("\n❌ Отклонено"));
        let closed = request_closed(&request, "shop", None, &s);
        assert!(closed.html.ends_with("\n☑️ Ответ уже дан") && closed.buttons.is_empty());
        let details = request_details(&request, "shop", Some("почини корзину"), Some(r"C:\Projects\shop"), true, &s);
        assert_eq!(details.html, "✋ <b>shop</b> — Bash\n<pre>rm -rf &lt;build&gt;</pre>\nЗадача сессии: почини корзину\n📁 <code>C:\\Projects\\shop</code>");
        assert_eq!(details.buttons.len(), 2);
        assert_eq!(open.keyboard()["inline_keyboard"][0][0]["callback_data"], "allow:0123456789abcdef0123456789abcdef");
    }

    #[test]
    fn event_titles() {
        let s = crate::i18n::Strings::default();
        assert_eq!(EVENTS.map(|e| event_title(e, &s)), ["Итоги фоновых задач", "Пороги лимитов", "Напоминания календаря", "PR и CI"]);
    }
}
