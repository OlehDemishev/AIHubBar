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

    #[test]
    fn event_titles() {
        let s = crate::i18n::Strings::default();
        assert_eq!(EVENTS.map(|e| event_title(e, &s)), ["Итоги фоновых задач", "Пороги лимитов", "Напоминания календаря", "PR и CI"]);
    }
}
