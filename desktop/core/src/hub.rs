//! Limits and spend of AI services other than the Claude subscription (docs/specs/SPEC-hub.md), the Mac's `HubLimit`,
//! `HubParse`, `HubFetch` and `HubForecast`. Each source turns on by itself when its tool is here or its key is
//! saved; the formats come from third-party docs, so every parser is tolerant and a source that can't be read shows
//! its error instead of numbers. Antigravity (its status line) and Cursor (its settings database, with consent) come
//! later on Windows.

use crate::i18n::Strings;
use chrono::{DateTime, Datelike, Duration as Days, NaiveDate, TimeZone, Utc};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
pub enum Source {
    #[serde(rename = "codex")]
    Codex,
    #[serde(rename = "openRouter")]
    OpenRouter,
    #[serde(rename = "copilot")]
    Copilot,
    #[serde(rename = "gemini")]
    Gemini,
    #[serde(rename = "openAICosts")]
    OpenAiCosts,
    #[serde(rename = "anthropicCosts")]
    AnthropicCosts,
}

/// The Mac's order.
pub const SOURCES: [Source; 6] = [Source::Codex, Source::OpenRouter, Source::Copilot, Source::Gemini, Source::OpenAiCosts, Source::AnthropicCosts];

impl Source {
    /// The Mac's `HubLimit.Source` raw value (kept in `hub_disabled`).
    pub fn id(self) -> &'static str {
        match self {
            Source::Codex => "codex",
            Source::OpenRouter => "openRouter",
            Source::Copilot => "copilot",
            Source::Gemini => "gemini",
            Source::OpenAiCosts => "openAICosts",
            Source::AnthropicCosts => "anthropicCosts",
        }
    }

    pub fn parse(id: &str) -> Option<Source> {
        SOURCES.into_iter().find(|s| s.id() == id)
    }

    pub fn title(self, s: &Strings) -> String {
        match self {
            Source::Codex => "Codex".into(),
            Source::OpenRouter => "OpenRouter".into(),
            Source::Copilot => "GitHub Copilot".into(),
            Source::Gemini => "Gemini CLI".into(),
            Source::OpenAiCosts => s.t("OpenAI API").into(),
            Source::AnthropicCosts => s.t("Anthropic API").into(),
        }
    }

    /// For the tray's hint.
    pub fn short_title(self) -> &'static str {
        match self {
            Source::Codex => "Codex",
            Source::OpenRouter => "OpenRouter",
            Source::Copilot => "Copilot",
            Source::Gemini => "Gemini",
            Source::OpenAiCosts => "OpenAI",
            Source::AnthropicCosts => "Anthropic",
        }
    }

    /// Sources read with a key the person pastes: its name in the key store (the Mac's Keychain account).
    pub fn key_account(self) -> Option<&'static str> {
        match self {
            Source::OpenRouter => Some("hub-openrouter"),
            Source::OpenAiCosts => Some("hub-openai-admin"),
            Source::AnthropicCosts => Some("hub-anthropic-admin"),
            _ => None,
        }
    }

    pub fn key_page(self) -> Option<&'static str> {
        match self {
            Source::OpenRouter => Some("https://openrouter.ai/settings/keys"),
            Source::OpenAiCosts => Some("https://platform.openai.com/settings/organization/admin-keys"),
            Source::AnthropicCosts => Some("https://console.anthropic.com/settings/admin-keys"),
            _ => None,
        }
    }

    /// What it needs, for Settings.
    pub fn requirement(self, s: &Strings) -> String {
        match self {
            Source::Codex => s.t("установленный codex с входом через ChatGPT"),
            Source::OpenRouter => s.t("ключ OpenRouter"),
            Source::Copilot => s.t("установленный gh с входом в GitHub и Copilot"),
            Source::Gemini => s.t("установленный Gemini CLI"),
            Source::OpenAiCosts => s.t("админский ключ организации OpenAI (sk-admin-…)"),
            Source::AnthropicCosts => s.t("админский ключ Anthropic (sk-ant-admin…)"),
        }
        .to_owned()
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Window {
    pub title: String,
    /// 0…100 when the service says how much of a limit is used; None for plain spend.
    pub percent: Option<f64>,
    pub detail: Option<String>,
    pub resets_at: Option<DateTime<Utc>>,
    /// At the pace since this window was first seen, the limit runs out before the reset at this time.
    pub runs_out_at: Option<DateTime<Utc>>,
}

impl Window {
    fn new(title: String, percent: Option<f64>, detail: Option<String>, resets_at: Option<DateTime<Utc>>) -> Window {
        Window { title, percent: percent.map(|p| p.clamp(0.0, 100.0)), detail, resets_at, runs_out_at: None }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Limit {
    pub source: Source,
    pub windows: Vec<Window>,
    pub error: Option<String>,
}

impl Limit {
    /// The fullest limit, for the tray's hint.
    pub fn fullest(&self) -> Option<f64> {
        self.windows.iter().filter_map(|w| w.percent).reduce(f64::max)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Error {
    Http(u16),
    Network,
    Unreadable,
    Missing,
    Failed(String),
}

impl Error {
    pub fn text(&self, s: &Strings) -> String {
        match self {
            Error::Http(code) if *code == 401 || *code == 403 => s.format("ключ или вход не подходят (HTTP %lld)", &[&code.to_string()]),
            Error::Http(code) => s.format("сервис ответил HTTP %lld", &[&code.to_string()]),
            Error::Network => s.t("нет связи").into(),
            Error::Unreadable => s.t("не удалось разобрать ответ — формат мог измениться").into(),
            Error::Missing => s.t("нет данных").into(),
            Error::Failed(message) => message.clone(),
        }
    }
}

// MARK: - Parsing the services' answers (the Mac's `HubParse`)

fn number(value: &Value) -> Option<f64> {
    value.as_f64().or_else(|| value.as_str()?.trim().parse().ok())
}

/// Unix seconds, Unix milliseconds or an ISO date — the services disagree, and change it between versions.
fn date(value: &Value) -> Option<DateTime<Utc>> {
    if let Some(n) = number(value) {
        let seconds = if n > 10_000_000_000.0 { n / 1000.0 } else { n };
        return DateTime::from_timestamp(seconds as i64, 0);
    }
    let text = value.as_str()?;
    DateTime::parse_from_rfc3339(text)
        .map(|d| d.with_timezone(&Utc))
        .ok()
        .or_else(|| NaiveDate::parse_from_str(text, "%Y-%m-%d").ok().and_then(|d| d.and_hms_opt(0, 0, 0)).map(|d| Utc.from_utc_datetime(&d)))
}

fn first<'a>(object: &'a Value, keys: &[&str]) -> &'a Value {
    keys.iter().map(|k| &object[*k]).find(|v| !v.is_null()).unwrap_or(&Value::Null)
}

/// «$12.34».
pub fn money(dollars: f64) -> String {
    format!("${dollars:.2}")
}

/// «5 ч», «неделя», «30 дн»; only a seven-day window is «неделя» (Codex's free plan has a 30-day one).
pub fn window_title(minutes: Option<f64>, s: &Strings) -> String {
    let Some(minutes) = minutes else { return s.t("лимит").into() };
    if minutes <= 24.0 * 60.0 {
        return s.format("%lld ч", &[&((minutes / 60.0).round() as i64).to_string()]);
    }
    if (minutes - 7.0 * 24.0 * 60.0).abs() <= 60.0 { s.t("неделя").into() } else { s.format("%lld дн", &[&((minutes / 1440.0).round() as i64).to_string()]) }
}

/// Codex `account/rateLimits/read`: rateLimits.primary / secondary — usedPercent, resetsAt, windowDurationMins.
pub fn codex_rpc(answer: &Value, now: DateTime<Utc>, s: &Strings) -> Option<Vec<Window>> {
    let result = if answer["result"].is_object() { &answer["result"] } else { answer };
    codex_windows(first(result, &["rateLimits", "rate_limits"]), now, s)
}

/// A session log line: `payload.type == "token_count"` with `payload.rate_limits`.
pub fn codex_session_line(line: &str, s: &Strings) -> Option<Vec<Window>> {
    let object: Value = serde_json::from_str(line).ok()?;
    let payload = &object["payload"];
    if payload["type"] != "token_count" {
        return None;
    }
    let written = object["timestamp"].as_str().and_then(|t| DateTime::parse_from_rfc3339(t).ok()).map_or_else(Utc::now, |d| d.with_timezone(&Utc));
    codex_windows(&payload["rate_limits"], written, s)
}

fn codex_windows(limits: &Value, now: DateTime<Utc>, s: &Strings) -> Option<Vec<Window>> {
    let windows: Vec<Window> = ["primary", "secondary"]
        .into_iter()
        .filter_map(|key| {
            let window = &limits[key];
            let used = number(first(window, &["used_percent", "usedPercent"]))?;
            let minutes = number(first(window, &["window_minutes", "windowDurationMins", "windowMinutes"])).unwrap_or(if key == "primary" { 300.0 } else { 10_080.0 });
            let reset = date(first(window, &["resets_at", "resetsAt"]))
                .or_else(|| number(first(window, &["resets_in_seconds", "resetsInSeconds"])).map(|sec| now + Days::seconds(sec as i64)));
            Some(Window::new(window_title(Some(minutes), s), Some(used), None, reset))
        })
        .collect();
    (!windows.is_empty()).then_some(windows)
}

/// OpenRouter `GET /api/v1/key`: data.limit, limit_remaining, usage, usage_monthly (dollars).
pub fn open_router(body: &Value, s: &Strings) -> Option<Vec<Window>> {
    let data = body.get("data").filter(|d| d.is_object())?;
    let mut windows = Vec::new();
    if let Some(limit) = number(&data["limit"]).filter(|l| *l > 0.0) {
        let remaining = number(&data["limit_remaining"]).unwrap_or(limit);
        windows.push(Window::new(s.t("кредиты").into(), Some((limit - remaining) / limit * 100.0), Some(s.format("осталось %@ из %@", &[&money(remaining), &money(limit)])), None));
    }
    if let Some(month) = number(&data["usage_monthly"]) {
        windows.push(Window::new(s.t("за месяц").into(), None, Some(money(month)), None));
    } else if let Some(usage) = number(&data["usage"]) {
        windows.push(Window::new(s.t("всего").into(), None, Some(money(usage)), None));
    }
    (!windows.is_empty()).then_some(windows)
}

/// Copilot `gh api /copilot_internal/user`: quota_snapshots.* — entitlement, remaining, unlimited; quota_reset_date.
pub fn copilot(body: &Value, s: &Strings) -> Option<Vec<Window>> {
    let snapshots = body.get("quota_snapshots").filter(|v| v.is_object())?;
    let reset = date(first(body, &["quota_reset_date_utc", "quota_reset_date"]));
    let windows: Vec<Window> = [("premium_interactions", "премиум-запросы"), ("chat", "чат"), ("completions", "дополнения")]
        .into_iter()
        .filter_map(|(key, title)| {
            let snapshot = &snapshots[key];
            if snapshot["unlimited"] == true {
                return None;
            }
            let entitlement = number(&snapshot["entitlement"]).filter(|e| *e > 0.0)?;
            let remaining = number(&snapshot["remaining"]).unwrap_or(entitlement);
            let detail = s.format("осталось %lld из %lld", &[&(remaining as i64).to_string(), &(entitlement as i64).to_string()]);
            Some(Window::new(s.t(title).into(), Some((entitlement - remaining) / entitlement * 100.0), Some(detail), reset))
        })
        .collect();
    (!windows.is_empty()).then_some(windows)
}

/// Gemini Code Assist `retrieveUserQuota`: buckets[] — remainingFraction, resetTime, modelId; three at most.
pub fn gemini_quota(body: &Value, s: &Strings) -> Option<Vec<Window>> {
    let windows: Vec<Window> = body["buckets"]
        .as_array()?
        .iter()
        .filter_map(|bucket| {
            let fraction = number(&bucket["remainingFraction"])?;
            let model = bucket["modelId"].as_str().map_or_else(|| s.t("квота").to_owned(), |m| m.replace("gemini-", ""));
            Some(Window::new(model, Some((1.0 - fraction) * 100.0), None, date(&bucket["resetTime"])))
        })
        .take(3)
        .collect();
    (!windows.is_empty()).then_some(windows)
}

/// Pacific time's offset from UTC at this moment: −7 h from the second Sunday of March 2:00 to the first Sunday of
/// November 2:00 (US daylight saving), else −8 h. Gemini's daily limits reset at Pacific midnight.
pub fn pacific_offset_hours(at: DateTime<Utc>) -> i64 {
    let year = at.year();
    let nth_sunday = |month: u32, n: u32| {
        let first = NaiveDate::from_ymd_opt(year, month, 1).expect("a month");
        let to_sunday = (7 - first.weekday().num_days_from_sunday()) % 7;
        first + Days::days(i64::from(to_sunday + 7 * (n - 1)))
    };
    // 2:00 local: 10:00 UTC in March (still −8), 9:00 UTC in November (still −7).
    let start = Utc.from_utc_datetime(&nth_sunday(3, 2).and_hms_opt(10, 0, 0).expect("a time"));
    let end = Utc.from_utc_datetime(&nth_sunday(11, 1).and_hms_opt(9, 0, 0).expect("a time"));
    if at >= start && at < end { -7 } else { -8 }
}

/// The start of today's Pacific day, and of the next one.
pub fn pacific_day(now: DateTime<Utc>) -> (DateTime<Utc>, DateTime<Utc>) {
    let offset = Days::hours(pacific_offset_hours(now));
    let local = (now + offset).date_naive().and_hms_opt(0, 0, 0).expect("midnight");
    let start = Utc.from_utc_datetime(&local) - offset;
    (start, start + Days::days(1))
}

/// Without the quota call: today's requests from the CLI's session files against the plan's daily limit.
pub fn gemini_requests(count: usize, daily_limit: u64, now: DateTime<Utc>, s: &Strings) -> Window {
    Window::new(
        s.t("запросы за день").into(),
        Some(count as f64 / daily_limit.max(1) as f64 * 100.0),
        Some(s.format("%lld из %lld", &[&count.to_string(), &daily_limit.to_string()])),
        Some(pacific_day(now).1),
    )
}

/// User turns in a session file since `start`: «type» or «role» == "user".
pub fn gemini_user_turns(body: &Value, start: DateTime<Utc>) -> usize {
    body["messages"]
        .as_array()
        .map(|messages| messages.iter().filter(|m| first(m, &["type", "role"]) == "user" && date(&m["timestamp"]).is_some_and(|t| t >= start)).count())
        .unwrap_or(0)
}

/// OpenAI `GET /v1/organization/costs`: data[].results[].amount.value (dollars).
pub fn openai_costs(body: &Value, s: &Strings) -> Option<Vec<Window>> {
    let total: f64 = body["data"].as_array()?.iter().flat_map(|b| b["results"].as_array().cloned().unwrap_or_default()).filter_map(|r| number(&r["amount"]["value"])).sum();
    Some(vec![Window::new(s.t("за месяц").into(), None, Some(money(total)), None)])
}

/// Anthropic's cost report: data[].results[].amount — a decimal string in cents.
pub fn anthropic_costs(body: &Value, s: &Strings) -> Option<Vec<Window>> {
    let cents: f64 = body["data"].as_array()?.iter().flat_map(|b| b["results"].as_array().cloned().unwrap_or_default()).filter_map(|r| number(&r["amount"])).sum();
    Some(vec![Window::new(s.t("за месяц").into(), None, Some(money(cents / 100.0)), None)])
}

// MARK: - «Главный сервис» (the Mac's `MainService`)

/// Whose limits lead the panel and the tray icon.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Main {
    Claude,
    Hub(Source),
}

/// The setting's values: `""` — automatic, `claude`, or a source's id.
pub const AUTO: &str = "";
pub const CLAUDE: &str = "claude";

fn has_limits(limit: &Limit) -> bool {
    limit.windows.iter().any(|w| w.percent.is_some())
}

/// Claude while it has limits to show, else the first other service that has them. A chosen service is main while
/// it has limits; without them the choice falls back to the automatic one, so the numbers never go blank because of
/// a setting.
pub fn pick(choice: &str, claude: bool, others: &[Limit]) -> Option<Main> {
    if choice == CLAUDE && claude {
        return Some(Main::Claude);
    }
    if let Some(chosen) = others.iter().find(|l| l.source.id() == choice && has_limits(l)) {
        return Some(Main::Hub(chosen.source));
    }
    if claude {
        return Some(Main::Claude);
    }
    others.iter().find(|l| has_limits(l)).map(|l| Main::Hub(l.source))
}

/// What the setting offers: the services that have limits now, and the saved one even when it has none.
pub fn choices(saved: &str, others: &[Limit]) -> Vec<Source> {
    let mut sources: Vec<Source> = others.iter().filter(|l| has_limits(l)).map(|l| l.source).collect();
    if let Some(kept) = Source::parse(saved).filter(|s| !sources.contains(s)) {
        sources.push(kept);
    }
    sources
}

// MARK: - «Хватит до сброса» (the Mac's `HubForecast`)

/// When the limit runs out at the pace from the first reading to the latest, if before the reset; None when it lasts
/// or there's too little to tell (under 15 minutes, or no growth).
pub fn runs_out(first: (DateTime<Utc>, f64), latest: (DateTime<Utc>, f64), resets_at: Option<DateTime<Utc>>) -> Option<DateTime<Utc>> {
    let elapsed = (latest.0 - first.0).num_seconds() as f64;
    let grown = latest.1 - first.1;
    if elapsed < 15.0 * 60.0 || grown <= 0.0 || latest.1 >= 100.0 {
        return None;
    }
    let at = latest.0 + Days::seconds(((100.0 - latest.1) / grown * elapsed) as i64);
    match resets_at {
        Some(reset) if at >= reset => None,
        _ => Some(at),
    }
}

/// The first reading of each window since its reset, in memory.
#[derive(Debug, Default)]
pub struct History(HashMap<String, (Option<DateTime<Utc>>, DateTime<Utc>, f64)>);

impl History {
    /// Records the readings and fills each window's «runs out at».
    pub fn apply(&mut self, limit: &mut Limit, now: DateTime<Utc>) {
        for window in &mut limit.windows {
            let Some(percent) = window.percent else { continue };
            let key = format!("{}|{}", limit.source.id(), window.title);
            let entry = self.0.entry(key).or_insert((window.resets_at, now, percent));
            // A new reset or a drop starts the window over.
            if entry.0 != window.resets_at || percent < entry.2 {
                *entry = (window.resets_at, now, percent);
            }
            window.runs_out_at = runs_out((entry.1, entry.2), (now, percent), window.resets_at);
        }
    }
}

/// Each window's highest threshold crossed, once per window and reset (the Mac's `HubLimitsStore.announce`): keys of
/// what was announced, and the (title, body) of the new ones.
pub fn alerts(limit: &Limit, thresholds: &[u32], notified: &mut std::collections::HashSet<String>, s: &Strings, now: DateTime<Utc>) -> Vec<(String, String)> {
    let mut found = Vec::new();
    for window in &limit.windows {
        let Some(percent) = window.percent else { continue };
        let Some(threshold) = thresholds.iter().copied().filter(|t| f64::from(*t) <= percent).max() else { continue };
        let reset = window.resets_at.map_or(0, |r| r.timestamp() / 600);
        if !notified.insert(format!("{}|{}|{reset}|{threshold}", limit.source.id(), window.title)) {
            continue;
        }
        let title = s.format("%@: использовано %lld %%", &[&limit.source.title(s), &(percent.round() as i64).to_string()]);
        let body = [Some(window.title.clone()), window.detail.clone(), crate::texts::reset_text(s, window.resets_at, now)].into_iter().flatten().collect::<Vec<_>>().join(" · ");
        found.push((title, body));
    }
    found
}

// MARK: - Reading each service (the Mac's `HubFetch`)

/// What a read needs from Settings and the key store.
#[derive(Debug, Clone, Default)]
pub struct Options {
    pub gemini_quota: bool,
    pub gemini_daily_limit: u64,
    pub key: Option<String>,
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder().http_status_as_error(false).timeout_global(Some(Duration::from_secs(20))).build().into()
}

fn finish(response: Result<ureq::http::Response<ureq::Body>, ureq::Error>) -> Result<Value, Error> {
    let mut response = response.map_err(|_| Error::Network)?;
    let status = response.status().as_u16();
    if !(200..300).contains(&status) {
        return Err(Error::Http(status));
    }
    let text = response.body_mut().read_to_string().map_err(|_| Error::Unreadable)?;
    serde_json::from_str(&text).map_err(|_| Error::Unreadable)
}

fn get(url: &str, headers: &[(&str, &str)]) -> Result<Value, Error> {
    let mut request = agent().get(url).header("User-Agent", "AIHubBar");
    for (name, value) in headers {
        request = request.header(*name, *value);
    }
    finish(request.call())
}

fn post(url: &str, body: &Value, headers: &[(&str, &str)]) -> Result<Value, Error> {
    let mut request = agent().post(url).header("User-Agent", "AIHubBar").header("Content-Type", "application/json");
    for (name, value) in headers {
        request = request.header(*name, *value);
    }
    finish(request.send(body.to_string()))
}

/// Whether the source can be read here: its tool or folder found, or its key saved.
pub fn present(source: Source, home: &Path, has_key: bool) -> bool {
    match source {
        Source::Codex => crate::agents::kind("codex").and_then(crate::agents::detect).is_some() || home.join(".codex/sessions").is_dir(),
        Source::Copilot => crate::command::find("gh").is_some(),
        Source::Gemini => home.join(".gemini").is_dir(),
        Source::OpenRouter | Source::OpenAiCosts | Source::AnthropicCosts => has_key,
    }
}

pub fn read(source: Source, options: &Options, home: &Path, now: DateTime<Utc>, s: &Strings) -> Limit {
    let done = |result: Result<Vec<Window>, Error>| match result {
        Ok(windows) => Limit { source, windows, error: None },
        Err(error) => Limit { source, windows: Vec::new(), error: Some(error.text(s)) },
    };
    let parsed = |result: Result<Value, Error>, parse: &dyn Fn(&Value) -> Option<Vec<Window>>| result.and_then(|body| parse(&body).ok_or(Error::Unreadable));
    let key = options.key.as_deref();
    match source {
        Source::Codex => {
            let rpc = crate::agents::kind("codex").and_then(crate::agents::detect).and_then(|path| codex_app_server(&path)).and_then(|answer| codex_rpc(&answer, now, s));
            done(rpc.or_else(|| codex_sessions(home, s)).ok_or(Error::Missing))
        }
        Source::OpenRouter => match key {
            Some(key) => done(parsed(get("https://openrouter.ai/api/v1/key", &[("Authorization", &format!("Bearer {key}"))]), &|b| open_router(b, s))),
            None => done(Err(Error::Missing)),
        },
        Source::Copilot => done(copilot_user().and_then(|body| copilot(&body, s).ok_or(Error::Unreadable))),
        Source::Gemini => {
            if options.gemini_quota {
                if let Some(windows) = gemini_access_token(home, now).and_then(|token| gemini_quota_call(&token, s)) {
                    return done(Ok(windows));
                }
            }
            done(Ok(vec![gemini_requests(gemini_today_requests(home, now), options.gemini_daily_limit, now, s)]))
        }
        Source::OpenAiCosts => match key {
            Some(key) => {
                let start = month_start(now).timestamp();
                let url = format!("https://api.openai.com/v1/organization/costs?start_time={start}&bucket_width=1d&limit=31");
                done(parsed(get(&url, &[("Authorization", &format!("Bearer {key}"))]), &|b| openai_costs(b, s)))
            }
            None => done(Err(Error::Missing)),
        },
        Source::AnthropicCosts => match key {
            Some(key) => {
                let start = month_start(now).format("%Y-%m-%dT%H:%M:%SZ");
                let url = format!("https://api.anthropic.com/v1/organizations/cost_report?starting_at={start}&bucket_width=1d&limit=31");
                done(parsed(get(&url, &[("x-api-key", key), ("anthropic-version", "2023-06-01")]), &|b| anthropic_costs(b, s)))
            }
            None => done(Err(Error::Missing)),
        },
    }
}

fn month_start(now: DateTime<Utc>) -> DateTime<Utc> {
    let local = now.with_timezone(&chrono::Local);
    local.date_naive().with_day(1).and_then(|d| d.and_hms_opt(0, 0, 0)).and_then(|d| d.and_local_timezone(chrono::Local).earliest()).map_or(now, |d| d.with_timezone(&Utc))
}

/// `codex app-server` over stdio: initialize, then `account/rateLimits/read`; 10 s at most. The CLI keeps its own
/// sign-in.
pub fn codex_app_server(program: &Path) -> Option<Value> {
    let mut command = crate::command::command(program);
    command.arg("app-server").stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    let mut child = command.spawn().ok()?;
    let mut input = child.stdin.take()?;
    let output = child.stdout.take()?;
    let (sender, answer) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(output).lines().map_while(Result::ok) {
            if let Ok(object) = serde_json::from_str::<Value>(&line) {
                if object["id"] == 2 {
                    let _ = sender.send(object);
                    return;
                }
            }
        }
    });
    let mut send = |object: Value| writeln!(input, "{object}").and_then(|_| input.flush());
    let sent = send(json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"clientInfo": {"name": "AIHubBar", "version": "1"}}}))
        .and_then(|_| {
            std::thread::sleep(Duration::from_millis(500));
            send(json!({"jsonrpc": "2.0", "method": "initialized"}))
        })
        .and_then(|_| send(json!({"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": {}})));
    let result = if sent.is_ok() { answer.recv_timeout(Duration::from_secs(10)).ok() } else { None };
    drop(input);
    let _ = child.kill();
    let _ = child.wait();
    result
}

fn newest(root: &Path, keep: &dyn Fn(&Path) -> bool, found: &mut Vec<(std::time::SystemTime, PathBuf)>, depth: usize) {
    if depth > 6 {
        return;
    }
    for entry in std::fs::read_dir(root).into_iter().flatten().flatten() {
        let path = entry.path();
        match entry.file_type() {
            Ok(kind) if kind.is_dir() => newest(&path, keep, found, depth + 1),
            Ok(_) if keep(&path) => {
                if let Ok(modified) = entry.metadata().and_then(|m| m.modified()) {
                    found.push((modified, path));
                }
            }
            _ => {}
        }
    }
}

/// The newest Codex session log's last rate-limit line.
pub fn codex_sessions(home: &Path, s: &Strings) -> Option<Vec<Window>> {
    let mut files = Vec::new();
    newest(&home.join(".codex/sessions"), &|p| p.extension().is_some_and(|e| e == "jsonl"), &mut files, 0);
    let (_, path) = files.into_iter().max_by_key(|(modified, _)| *modified)?;
    let text = std::fs::read_to_string(path).ok()?;
    text.lines().rev().find_map(|line| codex_session_line(line, s))
}

/// `gh api /copilot_internal/user`, with gh's own sign-in.
fn copilot_user() -> Result<Value, Error> {
    let gh = crate::command::find("gh").ok_or(Error::Missing)?;
    let mut command = crate::command::command(&gh);
    command.args(["api", "/copilot_internal/user"]);
    let output = crate::command::run(command, Duration::from_secs(20)).ok_or(Error::Missing)?;
    if !output.ok() {
        return Err(Error::Failed(format!("gh api: {}", output.code.unwrap_or(-1))));
    }
    serde_json::from_str(&output.stdout).map_err(|_| Error::Unreadable)
}

/// Gemini CLI's session files of today's Pacific day: their user turns.
pub fn gemini_today_requests(home: &Path, now: DateTime<Utc>) -> usize {
    let (start, _) = pacific_day(now);
    let since: std::time::SystemTime = start.into();
    let mut files = Vec::new();
    newest(&home.join(".gemini/tmp"), &|p| p.extension().is_some_and(|e| e == "json") && p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("session")), &mut files, 0);
    files
        .into_iter()
        .filter(|(modified, _)| *modified >= since)
        .filter_map(|(_, path)| std::fs::read_to_string(path).ok())
        .filter_map(|text| serde_json::from_str::<Value>(&text).ok())
        .map(|body| gemini_user_turns(&body, start))
        .sum()
}

/// Gemini CLI's own OAuth token, only while it is still valid (no refreshing someone else's sign-in).
pub fn gemini_access_token(home: &Path, now: DateTime<Utc>) -> Option<String> {
    let body: Value = serde_json::from_str(&std::fs::read_to_string(home.join(".gemini/oauth_creds.json")).ok()?).ok()?;
    let token = body["access_token"].as_str()?.to_owned();
    if number(&body["expiry_date"]).is_some_and(|ms| (ms / 1000.0) < now.timestamp() as f64) {
        return None;
    }
    Some(token)
}

fn gemini_quota_call(token: &str, s: &Strings) -> Option<Vec<Window>> {
    let base = "https://cloudcode-pa.googleapis.com/v1internal";
    let auth = format!("Bearer {token}");
    let headers = [("Authorization", auth.as_str())];
    let load = post(&format!("{base}:loadCodeAssist"), &json!({"metadata": {"pluginType": "GEMINI"}}), &headers).ok()?;
    let project = load["cloudaicompanionProject"].as_str()?;
    let quota = post(&format!("{base}:retrieveUserQuota"), &json!({"project": project}), &headers).ok()?;
    gemini_quota(&quota, s)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s() -> Strings {
        Strings::from_json("{}")
    }

    fn at(text: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(text).unwrap().with_timezone(&Utc)
    }

    #[test]
    fn codex_answers() {
        let now = at("2026-11-18T12:00:00Z");
        let rpc = json!({"id": 2, "result": {"rateLimits": {"primary": {"usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1_795_000_000}, "secondary": {"usedPercent": "7.5", "windowDurationMins": 10080}}}});
        let windows = codex_rpc(&rpc, now, &s()).unwrap();
        assert_eq!(windows.iter().map(|w| (w.title.as_str(), w.percent)).collect::<Vec<_>>(), [("5 ч", Some(42.0)), ("неделя", Some(7.5))]);
        assert_eq!(windows[0].resets_at, DateTime::from_timestamp(1_795_000_000, 0));
        let line = r#"{"timestamp":"2026-11-18T11:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":90,"window_minutes":43200,"resets_in_seconds":3600}}}}"#;
        let windows = codex_session_line(line, &s()).unwrap();
        assert_eq!((windows[0].title.as_str(), windows[0].resets_at), ("30 дн", Some(at("2026-11-18T12:00:00Z"))));
        assert!(codex_session_line(r#"{"payload":{"type":"agent_message"}}"#, &s()).is_none());
        assert!(codex_rpc(&json!({"result": {}}), now, &s()).is_none());
    }

    #[test]
    fn other_services_answers() {
        let s = s();
        let router = open_router(&json!({"data": {"limit": 20, "limit_remaining": 15, "usage_monthly": 3.5}}), &s).unwrap();
        assert_eq!((router[0].percent, router[0].detail.as_deref(), router[1].detail.as_deref()), (Some(25.0), Some("осталось $15.00 из $20.00"), Some("$3.50")));
        let pilot = copilot(&json!({"quota_reset_date": "2026-12-01", "quota_snapshots": {"premium_interactions": {"entitlement": 300, "remaining": 75}, "chat": {"unlimited": true}}}), &s).unwrap();
        assert_eq!(pilot.len(), 1);
        assert_eq!((pilot[0].title.as_str(), pilot[0].percent, pilot[0].detail.as_deref()), ("премиум-запросы", Some(75.0), Some("осталось 75 из 300")));
        assert_eq!(pilot[0].resets_at, Some(at("2026-12-01T00:00:00Z")));
        let gemini = gemini_quota(&json!({"buckets": [{"remainingFraction": 0.25, "modelId": "gemini-2.5-pro", "resetTime": "2026-11-19T08:00:00Z"}]}), &s).unwrap();
        assert_eq!((gemini[0].title.as_str(), gemini[0].percent), ("2.5-pro", Some(75.0)));
        let costs = openai_costs(&json!({"data": [{"results": [{"amount": {"value": 1.25}}, {"amount": {"value": "0.5"}}]}]}), &s).unwrap();
        assert_eq!(costs[0].detail.as_deref(), Some("$1.75"));
        let anthropic = anthropic_costs(&json!({"data": [{"results": [{"amount": "1234.5"}]}]}), &s).unwrap();
        assert_eq!(anthropic[0].detail.as_deref(), Some("$12.35"));
        assert!(open_router(&json!({}), &s).is_none() && copilot(&json!({"x": 1}), &s).is_none());
        assert_eq!(Error::Http(401).text(&s), "ключ или вход не подходят (HTTP 401)");
    }

    #[test]
    fn gemini_days_and_turns() {
        assert_eq!(pacific_offset_hours(at("2026-07-01T12:00:00Z")), -7);
        assert_eq!(pacific_offset_hours(at("2026-12-01T12:00:00Z")), -8);
        assert_eq!(pacific_offset_hours(at("2026-03-08T09:59:00Z")), -8, "just before the switch in March 2026");
        assert_eq!(pacific_offset_hours(at("2026-03-08T10:00:00Z")), -7);
        assert_eq!(pacific_offset_hours(at("2026-11-01T08:59:00Z")), -7);
        assert_eq!(pacific_offset_hours(at("2026-11-01T09:00:00Z")), -8);
        let (start, next) = pacific_day(at("2026-11-18T05:00:00Z"));
        assert_eq!((start, next), (at("2026-11-17T08:00:00Z"), at("2026-11-18T08:00:00Z")));
        let session = json!({"messages": [
            {"type": "user", "timestamp": "2026-11-18T09:00:00Z"},
            {"role": "user", "timestamp": "2026-11-18T07:00:00Z"},
            {"type": "gemini", "timestamp": "2026-11-18T09:01:00Z"}
        ]});
        assert_eq!(gemini_user_turns(&session, at("2026-11-18T08:00:00Z")), 1);
        let window = gemini_requests(250, 1000, at("2026-11-18T09:00:00Z"), &s());
        assert_eq!((window.percent, window.detail.as_deref(), window.resets_at), (Some(25.0), Some("250 из 1000"), Some(at("2026-11-19T08:00:00Z"))));
    }

    #[test]
    fn forecast_and_alerts() {
        let start = at("2026-11-18T10:00:00Z");
        assert_eq!(runs_out((start, 20.0), (start + Days::minutes(10), 30.0), None), None, "under 15 minutes");
        assert_eq!(runs_out((start, 20.0), (start + Days::hours(1), 60.0), None), Some(start + Days::hours(2)));
        assert_eq!(runs_out((start, 20.0), (start + Days::hours(1), 60.0), Some(start + Days::minutes(90))), None, "the reset comes first");
        let mut history = History::default();
        let mut limit = Limit { source: Source::Codex, windows: vec![Window::new("5 ч".into(), Some(20.0), None, None)], error: None };
        history.apply(&mut limit, start);
        limit.windows[0].percent = Some(60.0);
        history.apply(&mut limit, start + Days::hours(1));
        assert_eq!(limit.windows[0].runs_out_at, Some(start + Days::hours(2)));

        let s = s();
        let mut notified = std::collections::HashSet::new();
        limit.windows[0].percent = Some(85.0);
        let first = alerts(&limit, &[50, 80, 95], &mut notified, &s, start);
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].0, "Codex: использовано 85 %");
        assert!(alerts(&limit, &[50, 80, 95], &mut notified, &s, start).is_empty(), "once per threshold");
        limit.windows[0].percent = Some(96.0);
        assert_eq!(alerts(&limit, &[50, 80, 95], &mut notified, &s, start).len(), 1, "the next threshold");
    }

    #[test]
    fn the_main_service() {
        let codex = Limit { source: Source::Codex, windows: vec![Window::new("5 ч".into(), Some(40.0), None, None)], error: None };
        let router = Limit { source: Source::OpenRouter, windows: vec![Window::new("за месяц".into(), None, Some("$1".into()), None)], error: None };
        let others = [router.clone(), codex.clone()];
        assert_eq!(pick(AUTO, true, &others), Some(Main::Claude));
        assert_eq!(pick(AUTO, false, &others), Some(Main::Hub(Source::Codex)), "spend alone has no limits to lead with");
        assert_eq!(pick("codex", true, &others), Some(Main::Hub(Source::Codex)));
        assert_eq!(pick("openRouter", true, &others), Some(Main::Claude), "a choice without limits falls back");
        assert_eq!(pick(CLAUDE, false, &others), Some(Main::Hub(Source::Codex)), "Claude chosen but not signed in");
        assert_eq!(pick(AUTO, false, &[router]), None);
        assert_eq!(choices("gemini", &others), [Source::Codex, Source::Gemini], "the saved one stays offered");
    }

    #[test]
    fn files_on_disk() {
        let home = std::env::temp_dir().join(format!("claudepult-hub-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let day = home.join(".codex/sessions/2026/11/18");
        std::fs::create_dir_all(&day).unwrap();
        std::fs::write(day.join("rollout-a.jsonl"), "{\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":33}}}}\n{\"payload\":{\"type\":\"other\"}}\n").unwrap();
        let windows = codex_sessions(&home, &s()).unwrap();
        assert_eq!(windows[0].percent, Some(33.0));
        assert!(present(Source::Codex, &home, false));
        assert!(!present(Source::OpenRouter, &home, false) && present(Source::OpenRouter, &home, true));
        let gemini = home.join(".gemini/tmp/abc/chats");
        std::fs::create_dir_all(&gemini).unwrap();
        let now = Utc::now();
        std::fs::write(gemini.join("session-1.json"), json!({"messages": [{"type": "user", "timestamp": now.to_rfc3339()}, {"type": "user", "timestamp": now.to_rfc3339()}]}).to_string()).unwrap();
        assert_eq!(gemini_today_requests(&home, now), 2);
        std::fs::write(home.join(".gemini/oauth_creds.json"), json!({"access_token": "t", "expiry_date": 1000}).to_string()).unwrap();
        assert_eq!(gemini_access_token(&home, now), None, "an expired token isn't refreshed");
        std::fs::remove_dir_all(home).unwrap();
    }
}
