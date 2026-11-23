//! Subscription limits (SPEC §2.8, docs/specs/SPEC-windows.md §4.2), ported from the Mac app's `Usage.swift` and
//! `UsageService.swift` with the same rules: the undocumented `/api/oauth/usage` endpoint read tolerantly, the
//! forecast, alerts once per window, `usage.json` in the same format for `report.py` and the bot.
//! The token is read from Claude Code's own file for each request and never stored, logged or refreshed.

use chrono::{DateTime, Duration, Utc};
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;
use std::path::Path;

pub const ENDPOINT: &str = "https://api.anthropic.com/api/oauth/usage";

// MARK: - Credentials

#[derive(Debug, Clone, PartialEq)]
pub struct Credentials {
    pub access_token: String,
    pub expires_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum UsageError {
    /// No `.credentials.json` or no token in it: `claude` → `/login`.
    NoCredentials,
    /// The token's time is over; Claude Code renews it the next time `claude` runs.
    Expired,
    Http(u16),
    /// HTTP 429, with the seconds from `Retry-After` when it came.
    RateLimited(Option<u64>),
    Network(String),
    BadResponse,
}

/// `{"claudeAiOauth": {"accessToken": "…", "expiresAt": <ms>}}`, as Claude Code stores it
/// (`%USERPROFILE%\.claude\.credentials.json` on Windows, `~/.claude/.credentials.json` on Linux).
pub fn parse_credentials(text: &str) -> Option<Credentials> {
    let value: Value = serde_json::from_str(text.trim()).ok()?;
    let oauth = value.get("claudeAiOauth")?;
    let token = oauth.get("accessToken")?.as_str()?.to_owned();
    if token.is_empty() {
        return None;
    }
    let expires_at = oauth.get("expiresAt").and_then(Value::as_f64).and_then(|ms| DateTime::from_timestamp_millis(ms as i64));
    Some(Credentials { access_token: token, expires_at })
}

pub fn read_credentials(claude_dir: &Path, now: DateTime<Utc>) -> Result<Credentials, UsageError> {
    let text = std::fs::read_to_string(claude_dir.join(".credentials.json")).map_err(|_| UsageError::NoCredentials)?;
    let credentials = parse_credentials(&text).ok_or(UsageError::NoCredentials)?;
    if credentials.expires_at.is_some_and(|expires| expires < now) {
        return Err(UsageError::Expired);
    }
    Ok(credentials)
}

/// `Retry-After` is either seconds or an HTTP date (RFC 9110 §10.2.3).
pub fn retry_after(header: Option<&str>, now: DateTime<Utc>) -> Option<u64> {
    let header = header?.trim();
    if header.is_empty() {
        return None;
    }
    if let Ok(seconds) = header.parse::<f64>() {
        return Some(seconds.max(0.0) as u64);
    }
    let date: DateTime<Utc> = httpdate::parse_http_date(header).ok()?.into();
    Some((date - now).num_seconds().max(0) as u64)
}

/// One request with the token from Claude Code's file; the body as text. The headers are the Mac app's.
pub fn fetch(credentials: &Credentials, now: DateTime<Utc>) -> Result<String, UsageError> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_global(Some(std::time::Duration::from_secs(20)))
        .build()
        .into();
    let mut response = agent
        .get(ENDPOINT)
        .header("Authorization", &format!("Bearer {}", credentials.access_token))
        .header("anthropic-beta", "oauth-2025-04-20")
        .header("Accept", "application/json")
        .header("User-Agent", "AIHubBar")
        .call()
        .map_err(|error| UsageError::Network(error.to_string()))?;
    let status = response.status().as_u16();
    if status == 429 {
        let header = response.headers().get("retry-after").and_then(|v| v.to_str().ok());
        return Err(UsageError::RateLimited(retry_after(header, now)));
    }
    if status != 200 {
        return Err(UsageError::Http(status));
    }
    response.body_mut().read_to_string().map_err(|_| UsageError::BadResponse)
}

/// The pause after a 429: 5, 10, 20, 40, then 60 minutes, or longer if `Retry-After` says so. A shorter
/// `Retry-After` is not trusted: the server answered «Retry-After: 0» and went on refusing (Mac app, 2026-10).
pub fn backoff_seconds(strike: u32, retry_after: Option<u64>) -> u64 {
    let exponential = 300u64.saturating_mul(1 << strike.clamp(1, 8).saturating_sub(1));
    exponential.max(retry_after.unwrap_or(0)).min(3600)
}

/// How often to ask: every 2 minutes while the session grows, else every 5 (the endpoint answered 429 at 1).
pub fn poll_seconds(grew_recently: bool) -> u64 {
    if grew_recently { 120 } else { 300 }
}

// MARK: - The response

#[derive(Debug, Clone, PartialEq)]
pub struct UsageWindow {
    pub key: String,
    pub utilization: f64,
    pub resets_at: Option<DateTime<Utc>>,
    /// For the per-model weeks from `limits`: the model's own name («Opus»).
    pub model: Option<String>,
}

impl UsageWindow {
    /// The reset in whole minutes, rounded to the nearest 10: the API sends the same reset with a different
    /// fraction of a second on every fetch, so exact dates never compare equal.
    pub fn reset_minutes(date: Option<DateTime<Utc>>) -> Option<i64> {
        date.map(|date| ((date.timestamp() as f64 / 600.0).round() as i64) * 10)
    }

    pub fn same_reset(a: Option<DateTime<Utc>>, b: Option<DateTime<Utc>>) -> bool {
        Self::reset_minutes(a) == Self::reset_minutes(b)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ExtraUsage {
    pub is_enabled: bool,
    pub used_credits: Option<f64>,
    pub monthly_limit: Option<f64>,
    pub currency: Option<String>,
    pub decimal_places: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct UsageSnapshot {
    pub fetched_at: DateTime<Utc>,
    pub windows: Vec<UsageWindow>,
    pub extra: Option<ExtraUsage>,
}

fn number(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

fn date(value: Option<&Value>) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value?.as_str()?).ok().map(|d| d.with_timezone(&Utc))
}

impl UsageSnapshot {
    pub fn session(&self) -> Option<&UsageWindow> {
        self.windows.iter().find(|w| w.key == "five_hour")
    }

    pub fn week(&self) -> Option<&UsageWindow> {
        self.windows.iter().find(|w| w.key == "seven_day")
    }

    /// Per-model weeks worth a row: an unused one (0 %) only takes room.
    pub fn shown_other_windows(&self) -> Vec<&UsageWindow> {
        self.windows.iter().filter(|w| w.key != "five_hour" && w.key != "seven_day" && w.utilization >= 1.0).collect()
    }

    /// `five_hour`, `seven_day`, optional `seven_day_<model>` windows and per-model weeks from `limits`
    /// (`kind: weekly_scoped`); the many code-named objects are ignored. None without a session window.
    pub fn decode(text: &str, fetched_at: DateTime<Utc>) -> Option<UsageSnapshot> {
        let object: Map<String, Value> = serde_json::from_str(text).ok()?;
        let mut windows = Vec::new();
        let window = |key: &str, raw: Option<&Value>, model: Option<String>, windows: &mut Vec<UsageWindow>| {
            let Some(raw) = raw.filter(|raw| raw.is_object()) else { return };
            let Some(utilization) = number(raw.get("utilization")).or_else(|| number(raw.get("percent"))) else { return };
            windows.push(UsageWindow { key: key.to_owned(), utilization, resets_at: date(raw.get("resets_at")), model });
        };
        window("five_hour", object.get("five_hour"), None, &mut windows);
        window("seven_day", object.get("seven_day"), None, &mut windows);
        let mut keys: Vec<&String> =
            object.keys().filter(|key| key.starts_with("seven_day_") && *key != "seven_day_breakdown").collect();
        keys.sort();
        for key in keys {
            window(key, object.get(key), None, &mut windows);
        }
        for limit in object.get("limits").and_then(Value::as_array).into_iter().flatten() {
            if limit.get("kind").and_then(Value::as_str) != Some("weekly_scoped") {
                continue;
            }
            let model = limit.pointer("/scope/model/display_name").and_then(Value::as_str).filter(|m| !m.is_empty());
            let Some(model) = model else { continue };
            let key = format!("seven_day_{}", model.to_lowercase().replace(' ', "_"));
            if windows.iter().any(|w| w.key == key) {
                continue;
            }
            window(&key, Some(limit), Some(model.to_owned()), &mut windows);
        }
        if !windows.iter().any(|w| w.key == "five_hour") {
            return None;
        }
        let extra = object.get("extra_usage").filter(|raw| raw.is_object()).map(|raw| ExtraUsage {
            is_enabled: raw.get("is_enabled").and_then(Value::as_bool).unwrap_or(false),
            used_credits: number(raw.get("used_credits")),
            monthly_limit: number(raw.get("monthly_limit")),
            currency: raw.get("currency").and_then(Value::as_str).map(str::to_owned),
            decimal_places: raw.get("decimal_places").and_then(Value::as_u64).unwrap_or(2) as u32,
        });
        Some(UsageSnapshot { fetched_at, windows, extra })
    }
}

// MARK: - Levels, forecast, alerts

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UsageLevel {
    Low,
    Medium,
    High,
}

impl UsageLevel {
    /// Green < 50 %, orange 50–80 %, red > 80 % (SPEC §2.8).
    pub fn of(percent: f64) -> UsageLevel {
        if percent > 80.0 {
            UsageLevel::High
        } else if percent >= 50.0 {
            UsageLevel::Medium
        } else {
            UsageLevel::Low
        }
    }
}

/// A point of the session history the forecast reads.
#[derive(Debug, Clone, PartialEq)]
pub struct UsagePoint {
    pub date: DateTime<Utc>,
    pub session: f64,
    pub session_resets_at: Option<DateTime<Utc>>,
}

/// Anthropic's public status page (the Mac's `ServiceStatus`): asked only after the limits failed in a way an outage
/// could explain, to tell an outage from a problem on this computer. No account or token is involved.
pub const STATUS_PAGE: &str = "https://status.claude.com";

impl UsageError {
    /// A failure Anthropic's own trouble could explain, so its status page is worth asking.
    pub fn may_be_outage(&self) -> bool {
        match self {
            UsageError::Http(code) => *code >= 500,
            UsageError::Network(_) | UsageError::BadResponse => true,
            _ => false,
        }
    }
}

/// The page's own words when something is wrong; None when all is well or the answer can't be read.
pub fn status_problem(body: &str) -> Option<String> {
    let value: Value = serde_json::from_str(body).ok()?;
    let status = value.get("status")?;
    if status.get("indicator")?.as_str()? == "none" {
        return None;
    }
    status.get("description")?.as_str().map(str::trim).filter(|text| !text.is_empty()).map(str::to_owned)
}

/// None also when the page can't be reached: without internet nothing is known about Anthropic.
pub fn check_status() -> Option<String> {
    let agent: ureq::Agent = ureq::Agent::config_builder().http_status_as_error(false).timeout_global(Some(std::time::Duration::from_secs(10))).build().into();
    let mut response = agent.get(&format!("{STATUS_PAGE}/api/v2/status.json")).header("User-Agent", "AIHubBar").call().ok()?;
    status_problem(&response.body_mut().read_to_string().ok()?)
}

/// «Продлевать вход Claude Code сам» (the Mac's `LoginRenewal`). Claude Code renews its sign-in only while `claude`
/// runs; working in the Claude app leaves the sign-in file out of date and the limits stop. A one-word request
/// through `claude` renews it for about 8 hours: the smallest model, one turn, no tools, no MCP servers, no settings
/// (so no hooks), nothing kept in the session history. AI Hub Bar never touches the token itself.
pub const RENEWAL_ARGUMENTS: [&str; 12] = ["-p", "OK", "--model", "haiku", "--max-turns", "1", "--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", ""];

/// At most one try an hour, whether it worked or not.
pub fn should_renew(last_try: Option<DateTime<Utc>>, now: DateTime<Utc>) -> bool {
    last_try.is_none_or(|at| now - at >= Duration::hours(1))
}

/// Runs the request in a folder of its own (Claude Code keeps a folder of records per working folder); true when
/// `claude` ended well within a minute.
pub fn renew_sign_in(claude: &Path) -> bool {
    let folder = std::env::temp_dir().join("claudepult-renew");
    let _ = std::fs::create_dir_all(&folder);
    let mut command = crate::command::command(claude);
    command.args(RENEWAL_ARGUMENTS).current_dir(&folder).stdin(std::process::Stdio::null());
    crate::command::run(command, std::time::Duration::from_secs(60)).is_some_and(|output| output.ok())
}

// MARK: - Limit hits (the Mac's `LimitHits`)

/// When a Claude limit reached 100 %: the window («five_hour», «seven_day») and the moment.
pub type LimitHit = (String, DateTime<Utc>);

/// How long a hit is kept.
pub const HITS_DAYS: i64 = 30;

/// The hits with a new one when the window has just reached 100 %. A window is hit once while it lasts — five hours
/// or seven days — so a restart with the limit still at 100 % is not a second hit. Older than 30 days are dropped.
pub fn noting_hit(hits: &[LimitHit], window: &str, before: Option<f64>, fresh: Option<f64>, now: DateTime<Utc>) -> Vec<LimitHit> {
    let mut kept: Vec<LimitHit> = hits.iter().filter(|(_, date)| now - *date < Duration::days(HITS_DAYS)).cloned().collect();
    let length = if window == "seven_day" { Duration::days(7) } else { Duration::hours(5) };
    let counted = kept.iter().any(|(name, date)| name == window && now - *date < length);
    if fresh.is_some_and(|value| value >= 100.0) && before.unwrap_or(0.0) < 100.0 && !counted {
        kept.push((window.to_owned(), now));
    }
    kept
}

/// `limit-hits.json`: «five_hour|1763700000», the Mac's form of a hit.
pub fn hits_json(hits: &[LimitHit]) -> String {
    Value::Array(hits.iter().map(|(window, date)| Value::String(format!("{window}|{}", date.timestamp()))).collect()).to_string()
}

/// A file that can't be read is no hits.
pub fn parse_hits(text: &str) -> Vec<LimitHit> {
    serde_json::from_str::<Vec<String>>(text)
        .unwrap_or_default()
        .iter()
        .filter_map(|item| {
            let (window, seconds) = item.split_once('|')?;
            Some((window.to_owned(), DateTime::from_timestamp(seconds.parse::<f64>().ok()? as i64, 0)?))
        })
        .collect()
}

/// How long a reading helps the forecast.
pub const HISTORY_HOURS: i64 = 2;

/// `usage-history.json`, the Mac's file: the session's readings, so the forecast is there right after a restart
/// instead of half an hour later.
pub fn history_json(points: &[UsagePoint]) -> String {
    let stamp = |date: &DateTime<Utc>| date.format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let list: Vec<Value> = points
        .iter()
        .map(|point| {
            let mut entry = serde_json::json!({ "date": stamp(&point.date), "session": point.session });
            if let Some(resets) = &point.session_resets_at {
                entry["sessionResetsAt"] = Value::from(stamp(resets));
            }
            entry
        })
        .collect();
    serde_json::to_string(&list).unwrap_or_else(|_| "[]".to_owned())
}

/// The readings young enough to count, oldest first; a file that can't be read is no history.
pub fn parse_history(text: &str, now: DateTime<Utc>) -> Vec<UsagePoint> {
    let date = |value: Option<&Value>| value.and_then(Value::as_str).and_then(|text| DateTime::parse_from_rfc3339(text).ok()).map(|date| date.with_timezone(&Utc));
    let mut points: Vec<UsagePoint> = serde_json::from_str::<Vec<Value>>(text)
        .unwrap_or_default()
        .iter()
        .filter_map(|entry| Some(UsagePoint { date: date(entry.get("date"))?, session: entry.get("session")?.as_f64()?, session_resets_at: date(entry.get("sessionResetsAt")) }))
        .filter(|point| point.date <= now && now - point.date < chrono::Duration::hours(HISTORY_HOURS))
        .collect();
    points.sort_by_key(|point| point.date);
    points
}

#[derive(Debug, Clone, PartialEq)]
pub enum UsageForecast {
    /// At the current pace the session limit is reached at this time, before the reset.
    RunsOutAt(DateTime<Utc>),
    LastsUntilReset,
    Unknown,
}

impl UsageForecast {
    /// The pace over the last 30 minutes of the current session window (the same `resets_at`).
    pub fn make(history: &[UsagePoint], current: Option<&UsageWindow>, now: DateTime<Utc>) -> UsageForecast {
        let window = Duration::minutes(30);
        let (Some(current), Some(resets)) = (current, current.and_then(|c| c.resets_at)) else {
            return UsageForecast::Unknown;
        };
        let first = history
            .iter()
            .filter(|p| p.session_resets_at.is_some_and(|r| (r - resets).num_seconds().abs() < 60) && now - p.date <= window)
            .min_by_key(|p| p.date);
        let Some(first) = first else { return UsageForecast::Unknown };
        let elapsed = (now - first.date).num_milliseconds() as f64 / 1000.0;
        let grown = current.utilization - first.session;
        if elapsed < 300.0 {
            return UsageForecast::Unknown;
        }
        if grown <= 0.0 {
            return UsageForecast::LastsUntilReset;
        }
        let seconds = (100.0 - current.utilization) / (grown / elapsed);
        let runs_out = now + Duration::milliseconds((seconds * 1000.0) as i64);
        if runs_out < resets { UsageForecast::RunsOutAt(runs_out) } else { UsageForecast::LastsUntilReset }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Alert {
    Crossed { window_key: String, threshold: u32, utilization: f64, resets_at: Option<DateTime<Utc>> },
    Restored { window_key: String },
}

/// Alerts for a new snapshot; `notified` keeps `<window>|<reset>|<threshold>`. Only the highest newly crossed
/// threshold of a window alerts, so starting at 85 % gives one alert, not two.
pub fn evaluate_alerts(
    previous: Option<&UsageSnapshot>,
    current: &UsageSnapshot,
    thresholds: &[u32],
    notified: &mut BTreeSet<String>,
) -> Vec<Alert> {
    let mut alerts = Vec::new();
    for window in current.windows.iter().filter(|w| w.key == "five_hour" || w.key == "seven_day") {
        let period = UsageWindow::reset_minutes(window.resets_at).map_or("none".to_owned(), |m| m.to_string());
        let mut crossed: Vec<u32> = thresholds.iter().copied().filter(|t| f64::from(*t) <= window.utilization).collect();
        crossed.sort_unstable();
        let fresh: Vec<u32> =
            crossed.iter().copied().filter(|t| !notified.contains(&format!("{}|{period}|{t}", window.key))).collect();
        if let Some(highest) = fresh.last() {
            alerts.push(Alert::Crossed {
                window_key: window.key.clone(),
                threshold: *highest,
                utilization: window.utilization,
                resets_at: window.resets_at,
            });
        }
        for threshold in crossed {
            notified.insert(format!("{}|{period}|{threshold}", window.key));
        }
        if let Some(before) = previous.and_then(|p| p.windows.iter().find(|w| w.key == window.key)) {
            let new_period = before.resets_at.is_some() && !UsageWindow::same_reset(window.resets_at, before.resets_at);
            if before.utilization > 80.0
                && (window.utilization < before.utilization - 30.0 || (new_period && window.utilization < 50.0))
            {
                alerts.push(Alert::Restored { window_key: window.key.clone() });
            }
        }
    }
    alerts
}

// MARK: - usage.json

/// The same file the Mac app writes for `report.py` and the bot: `five_hour`, `seven_day`, `updated`.
pub fn usage_file_json(snapshot: &UsageSnapshot) -> Value {
    let window = |w: Option<&UsageWindow>| match w {
        Some(w) => json!({
            "utilization": w.utilization,
            "resets_at": w.resets_at.map(|d| d.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)),
        }),
        None => Value::Null,
    };
    json!({
        "five_hour": window(snapshot.session()),
        "seven_day": window(snapshot.week()),
        "updated": snapshot.fetched_at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn limit_hits() {
        let now = DateTime::parse_from_rfc3339("2026-11-21T12:00:00Z").unwrap().with_timezone(&Utc);
        let hits = noting_hit(&[], "five_hour", Some(97.0), Some(100.0), now);
        assert_eq!(hits, [("five_hour".to_owned(), now)]);
        assert_eq!(noting_hit(&hits, "five_hour", Some(100.0), Some(100.0), now + Duration::minutes(5)).len(), 1, "still at the limit");
        assert_eq!(noting_hit(&hits, "five_hour", None, Some(100.0), now + Duration::minutes(5)).len(), 1, "a restart at the limit is not a second hit");
        assert_eq!(noting_hit(&hits, "five_hour", Some(40.0), Some(100.0), now + Duration::hours(6)).len(), 2, "the next session");
        assert_eq!(noting_hit(&hits, "seven_day", None, Some(100.0), now + Duration::minutes(5)).len(), 2, "the week is its own window");
        assert_eq!(noting_hit(&hits, "five_hour", Some(40.0), Some(99.9), now).len(), 1);
        assert_eq!(noting_hit(&hits, "five_hour", Some(40.0), None, now).len(), 1);
        assert!(noting_hit(&hits, "five_hour", None, None, now + Duration::days(31)).is_empty(), "kept 30 days");

        let text = hits_json(&hits);
        assert_eq!(text, r#"["five_hour|1795262400"]"#);
        assert_eq!(parse_hits(&text), hits);
        assert_eq!(parse_hits(r#"["seven_day|1795262400.25","bad","x|y"]"#), [("seven_day".to_owned(), now)], "the Mac writes fractions");
        assert!(parse_hits("not json").is_empty());
    }

    fn at(text: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(text).unwrap().with_timezone(&Utc)
    }

    const SAMPLE: &str = r#"{
        "five_hour": {"utilization": 42.0, "resets_at": "2026-11-02T20:00:00.048+00:00"},
        "seven_day": {"utilization": 31, "resets_at": "2026-11-06T09:00:00Z"},
        "seven_day_opus": {"utilization": "12.5", "resets_at": null},
        "seven_day_breakdown": {"utilization": 100},
        "codename_thing": {"utilization": 100},
        "limits": [
            {"kind": "weekly_scoped", "scope": {"model": {"display_name": "Sonnet 5"}}, "utilization": 7},
            {"kind": "weekly_scoped", "scope": {"model": {"display_name": "Opus"}}, "utilization": 99},
            {"kind": "other", "utilization": 50}
        ],
        "extra_usage": {"is_enabled": true, "used_credits": 1250, "monthly_limit": 5000, "currency": "EUR"}
    }"#;

    #[test]
    fn credentials() {
        let creds = parse_credentials(r#" {"claudeAiOauth": {"accessToken": "sk-x", "expiresAt": 1762110000000}} "#).unwrap();
        assert_eq!(creds.access_token, "sk-x");
        assert_eq!(creds.expires_at, DateTime::from_timestamp_millis(1762110000000));
        assert!(parse_credentials(r#"{"claudeAiOauth": {"accessToken": ""}}"#).is_none());
        assert!(parse_credentials("{}").is_none());

        let dir = std::env::temp_dir().join(format!("claudepult-creds-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(read_credentials(&dir, Utc::now()), Err(UsageError::NoCredentials));
        std::fs::write(dir.join(".credentials.json"), r#"{"claudeAiOauth": {"accessToken": "t", "expiresAt": 1000}}"#).unwrap();
        assert_eq!(read_credentials(&dir, Utc::now()), Err(UsageError::Expired));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn response() {
        let snapshot = UsageSnapshot::decode(SAMPLE, at("2026-11-02T18:00:00Z")).unwrap();
        let keys: Vec<&str> = snapshot.windows.iter().map(|w| w.key.as_str()).collect();
        assert_eq!(keys, ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet_5"], "the Opus limit is already there");
        assert_eq!(snapshot.session().unwrap().utilization, 42.0);
        assert_eq!(snapshot.windows[2].utilization, 12.5, "numbers as strings too");
        assert_eq!(snapshot.windows[3].model.as_deref(), Some("Sonnet 5"));
        assert_eq!(snapshot.extra.as_ref().unwrap().decimal_places, 2);
        assert_eq!(snapshot.shown_other_windows().len(), 2);
        assert!(UsageSnapshot::decode(r#"{"seven_day": {"utilization": 1}}"#, Utc::now()).is_none(), "no session window");
        assert!(UsageSnapshot::decode("[]", Utc::now()).is_none());
    }

    #[test]
    fn same_reset_despite_fractions() {
        assert!(UsageWindow::same_reset(Some(at("2026-11-02T09:00:00.048Z")), Some(at("2026-11-02T08:59:59.981Z"))));
        assert!(!UsageWindow::same_reset(Some(at("2026-11-02T09:00:00Z")), Some(at("2026-11-02T14:00:00Z"))));
    }

    #[test]
    fn levels() {
        assert_eq!(UsageLevel::of(49.9), UsageLevel::Low);
        assert_eq!(UsageLevel::of(50.0), UsageLevel::Medium);
        assert_eq!(UsageLevel::of(80.0), UsageLevel::Medium);
        assert_eq!(UsageLevel::of(80.1), UsageLevel::High);
    }

    #[test]
    fn retry_after_header() {
        let now = at("2015-10-21T07:27:00Z");
        assert_eq!(retry_after(Some("120"), now), Some(120));
        assert_eq!(retry_after(Some("Wed, 21 Oct 2015 07:28:00 GMT"), now), Some(60));
        assert_eq!(retry_after(Some(" "), now), None);
        assert_eq!(retry_after(None, now), None);
    }

    #[test]
    fn forecast() {
        let resets = at("2026-11-02T20:00:00Z");
        let now = at("2026-11-02T18:00:00Z");
        let point = |minutes_ago: i64, session: f64| UsagePoint {
            date: now - Duration::minutes(minutes_ago),
            session,
            session_resets_at: Some(resets),
        };
        let current = |utilization: f64| UsageWindow { key: "five_hour".into(), utilization, resets_at: Some(resets), model: None };
        // 10 % in 20 minutes: 40 % left takes 80 minutes, before the reset in 120.
        assert_eq!(
            UsageForecast::make(&[point(20, 50.0)], Some(&current(60.0)), now),
            UsageForecast::RunsOutAt(now + Duration::minutes(80))
        );
        assert_eq!(UsageForecast::make(&[point(20, 59.0)], Some(&current(60.0)), now), UsageForecast::LastsUntilReset);
        assert_eq!(UsageForecast::make(&[point(20, 60.0)], Some(&current(60.0)), now), UsageForecast::LastsUntilReset);
        assert_eq!(UsageForecast::make(&[point(2, 50.0)], Some(&current(60.0)), now), UsageForecast::Unknown, "too soon");
        assert_eq!(UsageForecast::make(&[point(45, 50.0)], Some(&current(60.0)), now), UsageForecast::Unknown, "too old");
        assert_eq!(UsageForecast::make(&[], None, now), UsageForecast::Unknown);
    }

    #[test]
    fn alerts_once_per_window() {
        let resets = Some(at("2026-11-02T20:00:00Z"));
        let snap = |session: f64, resets_at| UsageSnapshot {
            fetched_at: Utc::now(),
            windows: vec![UsageWindow { key: "five_hour".into(), utilization: session, resets_at, model: None }],
            extra: None,
        };
        let mut notified = BTreeSet::new();
        let first = evaluate_alerts(None, &snap(85.0, resets), &[50, 80, 95], &mut notified);
        assert_eq!(first.len(), 1, "85 % crosses 50 and 80 but alerts once");
        assert!(matches!(first[0], Alert::Crossed { threshold: 80, .. }));
        assert!(evaluate_alerts(Some(&snap(85.0, resets)), &snap(86.0, resets), &[50, 80, 95], &mut notified).is_empty());
        let restored = evaluate_alerts(Some(&snap(86.0, resets)), &snap(3.0, Some(at("2026-11-03T01:00:00Z"))), &[50, 80, 95], &mut notified);
        assert_eq!(restored, vec![Alert::Restored { window_key: "five_hour".into() }]);
    }

    #[test]
    fn pauses() {
        assert_eq!(backoff_seconds(1, None), 300);
        assert_eq!(backoff_seconds(2, Some(0)), 600, "a short Retry-After is not trusted");
        assert_eq!(backoff_seconds(3, Some(2000)), 2000);
        assert_eq!(backoff_seconds(9, None), 3600);
        assert_eq!(poll_seconds(true), 120);
        assert_eq!(poll_seconds(false), 300);
    }

    #[test]
    fn usage_file() {
        let snapshot = UsageSnapshot::decode(SAMPLE, at("2026-11-02T18:00:00Z")).unwrap();
        let file = usage_file_json(&snapshot);
        assert_eq!(file["five_hour"]["utilization"], 42.0);
        assert_eq!(file["five_hour"]["resets_at"], "2026-11-02T20:00:00Z");
        assert_eq!(file["updated"], "2026-11-02T18:00:00Z");
        assert!(file.get("seven_day_opus").is_none(), "only what report.py reads");
    }

    #[test]
    fn outages() {
        assert_eq!(status_problem(r#"{"page": {}, "status": {"indicator": "none", "description": "All Systems Operational"}}"#), None);
        assert_eq!(status_problem(r#"{"status": {"indicator": "major", "description": " Partial System Outage "}}"#).as_deref(), Some("Partial System Outage"));
        assert_eq!(status_problem(r#"{"status": {"indicator": "minor"}}"#), None);
        assert_eq!(status_problem("<html>"), None);
        assert!(UsageError::Http(503).may_be_outage() && UsageError::Network("x".into()).may_be_outage() && UsageError::BadResponse.may_be_outage());
        assert!(!UsageError::Http(401).may_be_outage() && !UsageError::Expired.may_be_outage() && !UsageError::NoCredentials.may_be_outage() && !UsageError::RateLimited(None).may_be_outage());
    }

    /// Asks the real page: `cargo test -p claudepult-core status_page_live -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn status_page_live() {
        println!("Anthropic status: {:?}", check_status());
    }

    #[test]
    fn renewal_is_one_small_request_an_hour() {
        let now = Utc::now();
        assert!(should_renew(None, now));
        assert!(!should_renew(Some(now - Duration::minutes(59)), now));
        assert!(should_renew(Some(now - Duration::minutes(60)), now));
        let arguments = RENEWAL_ARGUMENTS.join(" ");
        assert!(arguments.starts_with("-p OK --model haiku --max-turns 1 --tools  --no-session-persistence"), "{arguments}");
        assert_eq!(RENEWAL_ARGUMENTS[RENEWAL_ARGUMENTS.len() - 2..], ["--setting-sources", ""], "no settings, so no hooks");
    }

    #[test]
    fn history_survives_a_restart() {
        let now = DateTime::parse_from_rfc3339("2026-11-20T12:00:00Z").unwrap().with_timezone(&Utc);
        let at = |minutes: i64| now - chrono::Duration::minutes(minutes);
        let points = vec![
            UsagePoint { date: at(200), session: 10.0, session_resets_at: None },
            UsagePoint { date: at(30), session: 40.5, session_resets_at: Some(at(-120)) },
            UsagePoint { date: at(5), session: 47.0, session_resets_at: Some(at(-120)) },
        ];
        let text = history_json(&points);
        assert!(text.contains(r#""date":"2026-11-20T11:30:00Z""#) && text.contains(r#""sessionResetsAt":"2026-11-20T14:00:00Z""#), "{text}");
        assert_eq!(parse_history(&text, now), points[1..], "older than two hours is dropped");
        // The Mac writes fractions of a second in some versions; both read.
        let mac = r#"[{"date":"2026-11-20T11:55:00.123Z","session":47,"sessionResetsAt":"2026-11-20T14:00:00Z"},{"date":"bad","session":1},{"session":2}]"#;
        assert_eq!(parse_history(mac, now).len(), 1);
        assert!(parse_history("not json", now).is_empty());
        assert!(parse_history(&history_json(&[UsagePoint { date: at(-10), session: 1.0, session_resets_at: None }]), now).is_empty(), "a reading from the future is not trusted");
    }
}
