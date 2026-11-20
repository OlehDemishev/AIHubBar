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
    fn tokens_in_words() {
        let s = Strings::default();
        assert_eq!(tokens_text(12_340_000, &s), "12,3 млн");
        assert_eq!(tokens_text(850_999, &s), "850 тыс.");
        assert_eq!(tokens_text(640, &s), "640");
    }
}
