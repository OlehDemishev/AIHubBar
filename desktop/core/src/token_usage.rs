//! «Расход по проектам» (docs/specs/SPEC-windows.md §4.2; the Mac's `TokenUsage.swift`): token use per project and
//! session from Claude Code's own journals, `<claude dir>/projects/**/*.jsonl` — the `usage` of assistant messages.
//! The format is undocumented: lines are read tolerantly and anything unknown is skipped. It is an estimate of how
//! the use is spread, not the plan's own accounting.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Duration, Utc};
use serde_json::Value;

use crate::i18n::Strings;

#[derive(Debug, Clone, PartialEq)]
pub struct TokenRecord {
    pub date: DateTime<Utc>,
    pub session_id: String,
    pub cwd: String,
    pub input: u64,
    pub output: u64,
    pub cache_creation: u64,
    pub cache_read: u64,
}

impl TokenRecord {
    /// Tokens shown: input, output and cache writes. Cache reads are left out — they dwarf everything else while
    /// costing a tenth; they still count in `weight`.
    pub fn total(&self) -> u64 {
        self.input + self.output + self.cache_creation
    }

    /// A message's rough weight against the limits, in input-token equivalents (relative API prices): only to rank
    /// and to share.
    pub fn weight(&self) -> f64 {
        self.input as f64 + self.output as f64 * 5.0 + self.cache_creation as f64 * 1.25 + self.cache_read as f64 * 0.1
    }
}

/// One assistant message with usage, or None. Streaming writes the same message (same `message.id`) on several lines
/// with the same usage, so the id comes back for de-duplication.
pub fn parse_line(line: &str) -> Option<(String, TokenRecord)> {
    // A cheap filter before JSON: most lines are tool output or the person's messages.
    if !line.contains("\"usage\"") || !line.contains("\"assistant\"") {
        return None;
    }
    let object: Value = serde_json::from_str(line).ok()?;
    if object.get("type").and_then(Value::as_str) != Some("assistant") {
        return None;
    }
    let message = object.get("message")?;
    let usage = message.get("usage")?;
    let date = DateTime::parse_from_rfc3339(object.get("timestamp")?.as_str()?).ok()?.with_timezone(&Utc);
    let count = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0);
    let text = |value: &Value, key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
    let record = TokenRecord {
        date,
        session_id: text(&object, "sessionId").unwrap_or_default(),
        cwd: text(&object, "cwd").unwrap_or_default(),
        input: count("input_tokens"),
        output: count("output_tokens"),
        cache_creation: count("cache_creation_input_tokens"),
        cache_read: count("cache_read_input_tokens"),
    };
    if record.total() + record.cache_read == 0 {
        return None;
    }
    let id = text(message, "id").or_else(|| text(&object, "requestId")).or_else(|| text(&object, "uuid"))?;
    Some((id, record))
}

fn parts(path: &str) -> Vec<String> {
    path.split(['/', '\\']).filter(|part| !part.is_empty()).map(|part| if cfg!(windows) { part.to_lowercase() } else { part.to_owned() }).collect()
}

/// The project of a working folder: the first folder under the projects folder (its worktrees included), in the
/// spelling the folder itself has; None for a folder elsewhere.
pub fn project_of(cwd: &str, projects_dir: &Path) -> Option<String> {
    let root = parts(&projects_dir.to_string_lossy());
    let folder = parts(cwd);
    if root.is_empty() || folder.len() <= root.len() || folder[..root.len()] != root[..] {
        return None;
    }
    cwd.split(['/', '\\']).filter(|part| !part.is_empty()).nth(root.len()).map(str::to_owned)
}

/// Reads the journals a piece at a time: each file from where the last scan stopped.
#[derive(Default)]
pub struct Scanner {
    offsets: HashMap<PathBuf, u64>,
    records: HashMap<String, TokenRecord>,
}

impl Scanner {
    /// Reads what is new in the files changed within `days` and returns every known record since `since`.
    pub fn scan(&mut self, dir: &Path, days: i64, since: DateTime<Utc>, now: DateTime<Utc>) -> Vec<TokenRecord> {
        let cutoff = now - Duration::days(days);
        let mut files = Vec::new();
        journals(dir, 0, &mut files);
        for (path, size, modified) in files {
            if modified > cutoff {
                self.read_new_lines(&path, size);
            }
        }
        self.records.retain(|_, record| record.date > cutoff);
        self.records.values().filter(|record| record.date >= since).cloned().collect()
    }

    fn read_new_lines(&mut self, path: &Path, size: u64) {
        let mut offset = self.offsets.get(path).copied().unwrap_or(0);
        if size < offset {
            // The file was written anew.
            offset = 0;
        }
        if size <= offset {
            return;
        }
        let Ok(mut file) = std::fs::File::open(path) else { return };
        if file.seek(SeekFrom::Start(offset)).is_err() {
            return;
        }
        let mut data = Vec::new();
        if file.read_to_end(&mut data).is_err() {
            return;
        }
        // Whole lines only; a half-written last line is read next time.
        let Some(last) = data.iter().rposition(|byte| *byte == b'\n') else { return };
        for line in data[..last].split(|byte| *byte == b'\n') {
            if let Some((id, record)) = std::str::from_utf8(line).ok().and_then(|line| parse_line(line.trim_end_matches('\r'))) {
                self.records.insert(id, record);
            }
        }
        self.offsets.insert(path.to_owned(), offset + last as u64 + 1);
    }
}

/// Every `.jsonl` under `dir` with its size and when it changed; a few folders deep, as Claude Code keeps them.
fn journals(dir: &Path, depth: usize, found: &mut Vec<(PathBuf, u64, DateTime<Utc>)>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = entry.metadata() else { continue };
        if meta.is_dir() {
            if depth < 4 {
                journals(&path, depth + 1, found);
            }
        } else if path.extension().is_some_and(|ext| ext == "jsonl") {
            if let Ok(modified) = meta.modified() {
                found.push((path, meta.len(), DateTime::<Utc>::from(modified)));
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Row {
    pub name: String,
    pub tokens: u64,
    /// 0…1 of the period's weight.
    pub share: f64,
}

/// A period's totals: per project, and the heaviest session.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Breakdown {
    pub projects: Vec<Row>,
    /// The heaviest session's project, tokens and share.
    pub top_session: Option<Row>,
    pub total_tokens: u64,
}

impl Breakdown {
    /// `other` names the folders outside the projects folder («Другое»).
    pub fn make(records: &[TokenRecord], since: DateTime<Utc>, projects_dir: &Path, other: &str) -> Breakdown {
        let period: Vec<&TokenRecord> = records.iter().filter(|record| record.date >= since).collect();
        let total_weight: f64 = period.iter().map(|record| record.weight()).sum();
        if total_weight <= 0.0 {
            return Breakdown::default();
        }
        let mut by_project: HashMap<String, (u64, f64)> = HashMap::new();
        let mut by_session: HashMap<&str, (String, u64, f64)> = HashMap::new();
        for record in &period {
            let project = project_of(&record.cwd, projects_dir).unwrap_or_else(|| other.to_owned());
            let entry = by_project.entry(project.clone()).or_default();
            entry.0 += record.total();
            entry.1 += record.weight();
            let session = by_session.entry(record.session_id.as_str()).or_insert((project, 0, 0.0));
            session.1 += record.total();
            session.2 += record.weight();
        }
        let mut projects: Vec<Row> = by_project.into_iter().map(|(name, (tokens, weight))| Row { name, tokens, share: weight / total_weight }).collect();
        projects.sort_by(|a, b| b.share.total_cmp(&a.share).then_with(|| a.name.cmp(&b.name)));
        let top_session = by_session.into_values().max_by(|a, b| a.2.total_cmp(&b.2)).map(|(name, tokens, weight)| Row { name, tokens, share: weight / total_weight });
        Breakdown { projects, top_session, total_tokens: period.iter().map(|record| record.total()).sum() }
    }
}

/// «12,3 млн», «850 тыс.», «640».
pub fn tokens_text(tokens: u64, s: &Strings) -> String {
    match tokens {
        1_000_000.. => s.decimal(tokens as f64 / 1_000_000.0) + s.t(" млн"),
        1_000.. => s.format("%lld тыс.", &[&(tokens / 1_000).to_string()]),
        _ => tokens.to_string(),
    }
}

// MARK: - «История расхода»: tokens by day (the Mac's `UsageHistory.swift`, `usage-days.json`)

/// How many days the history keeps.
pub const KEPT_DAYS: i64 = 400;

#[derive(Debug, Clone, PartialEq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageDay {
    /// `yyyy-MM-dd` in the computer's time zone.
    pub day: String,
    #[serde(default)]
    pub input: u64,
    #[serde(default)]
    pub output: u64,
    #[serde(default)]
    pub cache_write: u64,
    #[serde(default)]
    pub cache_read: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_peak: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub week_peak: Option<f64>,
}

impl UsageDay {
    /// As shown elsewhere: without cache reads.
    pub fn tokens(&self) -> u64 {
        self.input + self.output + self.cache_write
    }

    /// What these tokens would cost through the API at the person's own price, dollars per million tokens of input
    /// and of output; cache writes cost a quarter more than input and cache reads a tenth of it.
    pub fn cost(&self, price: (f64, f64)) -> f64 {
        let input_like = self.input as f64 + self.cache_write as f64 * 1.25 + self.cache_read as f64 * 0.1;
        (input_like * price.0 + self.output as f64 * price.1) / 1_000_000.0
    }
}

pub fn day_key(date: DateTime<Utc>) -> String {
    date.with_timezone(&chrono::Local).format("%Y-%m-%d").to_string()
}

fn trimmed(days: HashMap<String, UsageDay>, now: DateTime<Utc>) -> Vec<UsageDay> {
    let oldest = day_key(now - Duration::days(KEPT_DAYS));
    let mut days: Vec<UsageDay> = days.into_values().filter(|day| day.day >= oldest).collect();
    days.sort_by(|a, b| a.day.cmp(&b.day));
    days
}

fn by_day(days: &[UsageDay]) -> HashMap<String, UsageDay> {
    let mut map = HashMap::new();
    for day in days {
        map.entry(day.day.clone()).or_insert_with(|| day.clone());
    }
    map
}

/// Adds what the journals say. The scanner holds only part of the oldest day it returns, so a day's counters never
/// go down.
pub fn merging(days: &[UsageDay], records: &[TokenRecord], now: DateTime<Utc>) -> Vec<UsageDay> {
    let mut fresh: HashMap<String, UsageDay> = HashMap::new();
    for record in records {
        let key = day_key(record.date);
        let day = fresh.entry(key.clone()).or_insert_with(|| UsageDay { day: key, ..UsageDay::default() });
        day.input += record.input;
        day.output += record.output;
        day.cache_write += record.cache_creation;
        day.cache_read += record.cache_read;
    }
    let mut all = by_day(days);
    for (key, new) in fresh {
        let day = all.entry(key.clone()).or_insert_with(|| UsageDay { day: key, ..UsageDay::default() });
        day.input = day.input.max(new.input);
        day.output = day.output.max(new.output);
        day.cache_write = day.cache_write.max(new.cache_write);
        day.cache_read = day.cache_read.max(new.cache_read);
    }
    trimmed(all, now)
}

/// The limits as they stand now; a day keeps its highest figures.
pub fn noting(days: &[UsageDay], session: Option<f64>, week: Option<f64>, now: DateTime<Utc>) -> Vec<UsageDay> {
    let mut all = by_day(days);
    let key = day_key(now);
    let day = all.entry(key.clone()).or_insert_with(|| UsageDay { day: key, ..UsageDay::default() });
    if let Some(session) = session {
        day.session_peak = Some(day.session_peak.unwrap_or(0.0).max(session));
    }
    if let Some(week) = week {
        day.week_peak = Some(day.week_peak.unwrap_or(0.0).max(week));
    }
    trimmed(all, now)
}

/// The last `count` days, today included, every day present — a day without records is an empty one.
pub fn recent(days: &[UsageDay], count: i64, now: DateTime<Utc>) -> Vec<UsageDay> {
    let known = by_day(days);
    (0..count)
        .rev()
        .map(|back| {
            let key = day_key(now - Duration::days(back));
            known.get(&key).cloned().unwrap_or(UsageDay { day: key, ..UsageDay::default() })
        })
        .collect()
}

/// The Mac's CSV: one row a day.
pub fn csv(days: &[UsageDay]) -> String {
    let percent = |value: Option<f64>| value.map(|v| format!("{v:.1}")).unwrap_or_default();
    let mut text = String::from("date,input,output,cache_write,cache_read,session_peak_percent,week_peak_percent\n");
    for day in days {
        text += &format!("{},{},{},{},{},{},{}\n", day.day, day.input, day.output, day.cache_write, day.cache_read, percent(day.session_peak), percent(day.week_peak));
    }
    text
}

/// «Окупается ли подписка»: the period's API cost brought to a month of 30 days, against the plan's price — how many
/// times the API would cost. None without a plan price or without spend.
pub fn plan_ratio(cost: f64, period_days: i64, plan: f64) -> Option<f64> {
    let monthly = if period_days > 0 { cost * 30.0 / period_days as f64 } else { 0.0 };
    (plan > 0.0 && monthly > 0.0).then(|| monthly / plan)
}

/// «Подписка выгоднее API (×3,2)» or «API был бы дешевле подписки (×2,5)».
pub fn plan_verdict(ratio: f64, s: &Strings) -> String {
    let times = if ratio >= 1.0 { ratio } else { 1.0 / ratio };
    let number = if times < 10.0 { s.decimal(times) } else { format!("{}", times.round() as i64) };
    if ratio >= 1.0 {
        s.format("Подписка выгоднее API (×%@)", &[&number])
    } else {
        s.format("API был бы дешевле подписки (×%@)", &[&number])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(id: &str, time: &str, cwd: &str, session: &str, input: u64, output: u64) -> String {
        let cwd = cwd.replace('\\', "\\\\");
        format!(
            r#"{{"type":"assistant","timestamp":"{time}","sessionId":"{session}","cwd":"{cwd}","message":{{"id":"{id}","model":"claude","usage":{{"input_tokens":{input},"output_tokens":{output},"cache_creation_input_tokens":0,"cache_read_input_tokens":1000}}}}}}"#
        )
    }

    #[test]
    fn reads_an_assistant_line() {
        let (id, record) = parse_line(&line("m1", "2026-11-20T10:00:00.000Z", r"C:\Users\Олег\Projects\shop", "s1", 100, 20)).unwrap();
        assert_eq!((id.as_str(), record.session_id.as_str(), record.cwd.as_str()), ("m1", "s1", r"C:\Users\Олег\Projects\shop"));
        assert_eq!((record.total(), record.cache_read), (120, 1000));
        assert_eq!(record.weight(), 100.0 + 20.0 * 5.0 + 1000.0 * 0.1);
        assert!(parse_line(r#"{"type":"user","message":{"usage":{}},"x":"assistant"}"#).is_none());
        assert!(parse_line(r#"{"type":"assistant","timestamp":"2026-11-20T10:00:00Z","message":{"id":"m","usage":{}}}"#).is_none(), "no tokens");
        assert!(parse_line("not json \"usage\" \"assistant\"").is_none());
    }

    #[test]
    fn projects_by_folder() {
        let root = Path::new(if cfg!(windows) { r"C:\Users\Олег\Projects" } else { "/home/o/Projects" });
        let inside = if cfg!(windows) { r"c:\users\олег\projects\Shop\.claude\worktrees\cb-x" } else { "/home/o/Projects/Shop/.claude/worktrees/cb-x" };
        assert_eq!(project_of(inside, root).as_deref(), Some("Shop"));
        assert_eq!(project_of(&root.to_string_lossy(), root), None);
        assert_eq!(project_of(if cfg!(windows) { r"C:\Users\Олег\Projects2\x" } else { "/home/o/Projects2/x" }, root), None);
        assert_eq!(project_of("", root), None);
    }

    #[test]
    fn scans_only_what_is_new() {
        let dir = std::env::temp_dir().join(format!("claudepult-tokens-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("C--shop")).unwrap();
        let file = dir.join("C--shop").join("s1.jsonl");
        let now = Utc::now();
        let stamp = |ago: i64| (now - Duration::minutes(ago)).to_rfc3339();
        let first = format!("{}\n{}\n{}", line("m1", &stamp(30), "/p/shop", "s1", 100, 10), line("m1", &stamp(30), "/p/shop", "s1", 100, 10), "{\"half");
        std::fs::write(&file, &first).unwrap();
        let mut scanner = Scanner::default();
        let since = now - Duration::hours(5);
        assert_eq!(scanner.scan(&dir, 8, since, now).len(), 1, "the same message twice is one");
        // The half line is finished and another message follows.
        std::fs::write(&file, format!("{}\n{}\n{}\n", line("m1", &stamp(30), "/p/shop", "s1", 100, 10), line("m1", &stamp(30), "/p/shop", "s1", 100, 10), line("m2", &stamp(10), "/p/shop", "s1", 50, 5))).unwrap();
        let records = scanner.scan(&dir, 8, since, now);
        assert_eq!(records.len(), 2);
        assert_eq!(scanner.scan(&dir, 8, now - Duration::minutes(20), now).len(), 1, "only since");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn shares_by_weight() {
        let now = Utc::now();
        let record = |session: &str, cwd: &str, input: u64, output: u64, ago: i64| TokenRecord { date: now - Duration::minutes(ago), session_id: session.into(), cwd: cwd.into(), input, output, cache_creation: 0, cache_read: 0 };
        let root = Path::new(if cfg!(windows) { r"C:\p" } else { "/p" });
        let folder = |name: &str| if cfg!(windows) { format!(r"C:\p\{name}") } else { format!("/p/{name}") };
        let records = [record("s1", &folder("shop"), 100, 100, 10), record("s2", &folder("shop"), 100, 0, 20), record("s3", &folder("blog"), 300, 0, 30), record("s4", "/elsewhere", 100, 0, 40), record("s5", &folder("old"), 999, 0, 600)];
        let breakdown = Breakdown::make(&records, now - Duration::hours(5), root, "Другое");
        assert_eq!(breakdown.projects.iter().map(|row| (row.name.as_str(), row.tokens)).collect::<Vec<_>>(), [("shop", 300), ("blog", 300), ("Другое", 100)]);
        assert!((breakdown.projects[0].share - 700.0 / 1100.0).abs() < 1e-9, "output weighs five times");
        assert_eq!(breakdown.total_tokens, 700);
        let top = breakdown.top_session.unwrap();
        assert_eq!((top.name.as_str(), top.tokens), ("shop", 200));
        assert_eq!(Breakdown::make(&records, now, root, "Другое"), Breakdown::default());
    }

    #[test]
    fn days_of_history() {
        let now = Utc::now();
        let record = |ago_days: i64, input: u64, output: u64| TokenRecord { date: now - Duration::days(ago_days), session_id: "s".into(), cwd: String::new(), input, output, cache_creation: 10, cache_read: 1000 };
        let days = merging(&[], &[record(0, 100, 20), record(0, 50, 5), record(2, 7, 1), record(KEPT_DAYS + 5, 9, 9)], now);
        assert_eq!(days.len(), 2, "what is older than the history keeps is dropped");
        let today = days.last().unwrap();
        assert_eq!((today.day.as_str(), today.input, today.output, today.cache_write, today.cache_read), (day_key(now).as_str(), 150, 25, 20, 2000));
        assert_eq!(today.tokens(), 195);
        // A later scan that holds only a part of the day does not lower it.
        let again = merging(&days, &[record(0, 10, 1)], now);
        assert_eq!(again.last().unwrap().input, 150);
        let noted = noting(&noting(&again, Some(40.0), Some(12.5), now), Some(30.0), None, now);
        assert_eq!((noted.last().unwrap().session_peak, noted.last().unwrap().week_peak), (Some(40.0), Some(12.5)));
        let week = recent(&noted, 7, now);
        assert_eq!(week.len(), 7);
        assert_eq!((week[6].day.as_str(), week[4].tokens(), week[5].tokens()), (day_key(now).as_str(), 18, 0));
        let text = csv(&week[4..]);
        assert!(text.starts_with("date,input,output,cache_write,cache_read,session_peak_percent,week_peak_percent\n"));
        assert!(text.ends_with(&format!("{},150,25,20,2000,40.0,12.5\n", day_key(now))), "{text}");
        assert!(text.contains(&format!("{},0,0,0,0,,\n", day_key(now - Duration::days(1)))));
        // The Mac's file reads, and ours is written with its keys.
        let mac: Vec<UsageDay> = serde_json::from_str(r#"[{"day":"2026-11-20","input":5,"output":6,"cacheWrite":7,"cacheRead":8,"sessionPeak":55.5}]"#).unwrap();
        assert_eq!((mac[0].cache_write, mac[0].session_peak, mac[0].week_peak), (7, Some(55.5), None));
        assert_eq!(serde_json::to_string(&mac).unwrap(), r#"[{"day":"2026-11-20","input":5,"output":6,"cacheWrite":7,"cacheRead":8,"sessionPeak":55.5}]"#);
    }

    #[test]
    fn cost_and_plan() {
        let s = Strings::default();
        let day = UsageDay { day: "2026-11-20".into(), input: 1_000_000, output: 1_000_000, cache_write: 1_000_000, cache_read: 10_000_000, ..UsageDay::default() };
        assert!((day.cost((3.0, 15.0)) - (3.0 * (1.0 + 1.25 + 1.0) + 15.0)).abs() < 1e-9);
        assert_eq!(plan_ratio(64.0, 30, 20.0), Some(3.2));
        assert_eq!(plan_ratio(7.0, 7, 100.0), Some(0.3));
        assert_eq!(plan_ratio(64.0, 30, 0.0), None);
        assert_eq!(plan_ratio(0.0, 30, 20.0), None);
        assert_eq!(plan_verdict(3.2, &s), "Подписка выгоднее API (×3,2)");
        assert_eq!(plan_verdict(0.4, &s), "API был бы дешевле подписки (×2,5)");
        assert_eq!(plan_verdict(12.4, &s), "Подписка выгоднее API (×12)");
    }

    #[test]
    fn tokens_in_words() {
        let s = Strings::default();
        assert_eq!(tokens_text(12_340_000, &s), "12,3 млн");
        assert_eq!(tokens_text(850_999, &s), "850 тыс.");
        assert_eq!(tokens_text(640, &s), "640");
    }
}
