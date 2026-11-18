//! Folder projects (docs/specs/SPEC-modes.md §3, docs/specs/SPEC-windows.md §4.7): a project that is just a folder —
//! a video, an article, a research topic — as the Mac's `FolderScanner` reads it. Its card is `проект.md` (or the
//! content language's name): plain Markdown with lines `Ключ: значение` the person can edit by hand; only the known
//! keys are read, and writing a value back keeps everything else, the line endings included.

use crate::i18n::Strings;
use crate::profiles::{self, Source};
use chrono::{DateTime, Datelike, Local, NaiveDate, NaiveDateTime, NaiveTime, Utc};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use unicode_segmentation::UnicodeSegmentation;

// MARK: - The card's words in every content language

fn content() -> &'static Value {
    static TABLE: OnceLock<Value> = OnceLock::new();
    TABLE.get_or_init(|| serde_json::from_str(include_str!("../../ui/i18n/content.json")).unwrap_or_default())
}

fn languages() -> impl Iterator<Item = (&'static str, &'static Value)> {
    content().as_object().into_iter().flatten().map(|(code, entry)| (code.as_str(), entry))
}

/// Every content language's table (`ui/i18n/content.json`): `(code, entry)`.
pub fn content_languages() -> impl Iterator<Item = (&'static str, &'static Value)> {
    languages()
}

fn entry(language: &str) -> &'static Value {
    let table = content();
    table.get(language).or_else(|| table.get("en")).unwrap_or(&Value::Null)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Key {
    Stage,
    Deadline,
    Publish,
    Format,
    MainFile,
    Platform,
}

impl Key {
    pub const ALL: [Key; 6] = [Key::Stage, Key::Deadline, Key::Publish, Key::Format, Key::MainFile, Key::Platform];

    fn name(self) -> &'static str {
        match self {
            Key::Stage => "stage",
            Key::Deadline => "deadline",
            Key::Publish => "publish",
            Key::Format => "format",
            Key::MainFile => "mainFile",
            Key::Platform => "platform",
        }
    }

    /// The label written into a card in that language.
    pub fn label(self, language: &str) -> String {
        entry(language)["cardLabels"][self.name()].as_str().unwrap_or(self.name()).to_owned()
    }

    /// Every language's label plus synonyms, lowercased: all are read.
    fn labels(self) -> Vec<String> {
        let synonyms: &[&str] = match self {
            Key::Deadline => &["срок"],
            Key::Publish => &["дата публикации", "publication"],
            _ => &[],
        };
        languages()
            .filter_map(|(_, entry)| entry["cardLabels"][self.name()].as_str())
            .chain(synonyms.iter().copied())
            .map(str::to_lowercase)
            .collect()
    }
}

/// One of the content language's texts (`ui/i18n/content.json`): `agentPrompt`, `notSet`, `projectWord`…
pub fn content_text(language: &str, key: &str) -> String {
    entry(language)[key].as_str().unwrap_or_default().to_owned()
}

/// The card's file name in the content language: `проект.md`, `project.md`…
pub fn card_file_name(language: &str) -> String {
    entry(language)["cardFile"].as_str().unwrap_or("project.md").to_owned()
}

/// Every language's card file name: a card is found under any of them.
pub fn card_file_names() -> Vec<String> {
    let mut names: Vec<String> = languages().filter_map(|(_, entry)| entry["cardFile"].as_str().map(str::to_owned)).collect();
    names.dedup();
    names
}

/// The project's card: the existing one under any name, else where a new one goes.
pub fn card_path(folder: &Path, language: &str) -> PathBuf {
    card_file_names().iter().map(|name| folder.join(name)).find(|path| path.is_file()).unwrap_or_else(|| folder.join(card_file_name(language)))
}

// MARK: - The card

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Card {
    pub values: BTreeMap<Key, String>,
}

impl Card {
    pub fn parse(text: &str) -> Card {
        let mut card = Card::default();
        for line in text.lines() {
            if let Some((key, value)) = field(line) {
                if !value.is_empty() {
                    card.values.entry(key).or_insert(value);
                }
            }
        }
        card
    }

    pub fn get(&self, key: Key) -> Option<&str> {
        self.values.get(&key).map(String::as_str)
    }

    pub fn stage(&self) -> Option<&str> {
        self.get(Key::Stage)
    }

    pub fn deadline(&self) -> Option<NaiveDateTime> {
        self.get(Key::Deadline).and_then(date)
    }

    pub fn publish(&self) -> Option<NaiveDateTime> {
        self.get(Key::Publish).and_then(date)
    }
}

/// A line without its list marker and bold: `- **Этап:** сценарий` → `Этап: сценарий`.
fn clean(line: &str) -> String {
    let mut text = line.trim();
    for marker in ["- ", "* ", "+ "] {
        if let Some(rest) = text.strip_prefix(marker) {
            text = rest;
            break;
        }
    }
    text.replace("**", "").replace("__", "")
}

/// The key and value of one line, in any content language.
pub fn field(line: &str) -> Option<(Key, String)> {
    let text = clean(line);
    let (label, value) = text.split_once(':')?;
    let label = label.trim().to_lowercase();
    let key = Key::ALL.into_iter().find(|key| key.labels().contains(&label))?;
    Some((key, value.trim().to_owned()))
}

/// The language whose labels the card already uses (the current one first: German and Polish share «Format»).
fn language_of(lines: &[&str], current: &str) -> String {
    let used: Vec<String> = lines
        .iter()
        .filter(|line| field(line).is_some())
        .filter_map(|line| clean(line).split(':').next().map(|label| label.trim().to_lowercase()))
        .collect();
    if used.is_empty() {
        return current.to_owned();
    }
    std::iter::once(current)
        .chain(languages().map(|(code, _)| code))
        .find(|code| {
            let own: Vec<String> = Key::ALL.iter().map(|key| key.label(code).to_lowercase()).collect();
            used.iter().all(|label| own.contains(label))
        })
        .unwrap_or(current)
        .to_owned()
}

/// Writes one value back: replaces the first line with that key (keeping its list marker), or adds a line after
/// the title. The card keeps its language and its line endings.
pub fn setting(key: Key, value: &str, text: &str, current_language: &str) -> String {
    let crlf = text.contains("\r\n");
    let mut lines: Vec<String> = text.split('\n').map(|line| line.strip_suffix('\r').unwrap_or(line).to_owned()).collect();
    let refs: Vec<&str> = lines.iter().map(String::as_str).collect();
    let new_line = format!("{}: {value}", key.label(&language_of(&refs, current_language)));
    if let Some(index) = lines.iter().position(|line| field(line).is_some_and(|(k, _)| k == key)) {
        let trimmed = lines[index].trim_start();
        let marker = ["- ", "* ", "+ "].into_iter().find(|m| trimmed.starts_with(m)).unwrap_or("");
        lines[index] = format!("{marker}{new_line}");
    } else if let Some(title) = lines.iter().position(|line| line.starts_with("# ")) {
        // After the title and the blank line under it; a blank line before the text that follows.
        let mut position = title + 1;
        if position < lines.len() && lines[position].trim().is_empty() {
            position += 1;
        } else {
            lines.insert(position, String::new());
            position += 1;
        }
        lines.insert(position, new_line);
        let next = position + 1;
        if next < lines.len() && !lines[next].trim().is_empty() && field(&lines[next]).is_none() {
            lines.insert(next, String::new());
        }
    } else {
        lines.insert(0, new_line);
    }
    lines.join(if crlf { "\r\n" } else { "\n" })
}

/// A new card: title, stage and the empty fields to fill in.
pub fn template(name: &str, stage: Option<&str>, language: &str) -> String {
    let mut lines = vec![format!("# {name}"), String::new()];
    if let Some(stage) = stage {
        lines.push(format!("{}: {stage}", Key::Stage.label(language)));
    }
    for key in [Key::Deadline, Key::Publish, Key::Format, Key::MainFile, Key::Platform] {
        lines.push(format!("{}: ", key.label(language)));
    }
    let notes = entry(language)["notesHeading"].as_str().unwrap_or("## Notes");
    lines.extend([String::new(), notes.to_owned(), String::new()]);
    lines.join("\n")
}

/// `2026-11-05`, `2026-11-05 18:00`, `05.11.2026`, `05.11.2026 18:00`.
pub fn date(text: &str) -> Option<NaiveDateTime> {
    let text = text.trim();
    for format in ["%Y-%m-%d %H:%M", "%d.%m.%Y %H:%M"] {
        if let Ok(date) = NaiveDateTime::parse_from_str(text, format) {
            return Some(date);
        }
    }
    ["%Y-%m-%d", "%d.%m.%Y"].iter().find_map(|format| NaiveDate::parse_from_str(text, format).ok()).map(|day| day.and_time(NaiveTime::MIN))
}

// MARK: - Scanning

const TEXT_EXTENSIONS: [&str; 6] = ["md", "markdown", "txt", "rtf", "docx", "fountain"];
const SOURCE_FOLDERS: [&str; 3] = ["источники", "sources", "материалы"];
const MAX_FILES: usize = 2000;

#[derive(Debug, Clone, PartialEq)]
pub struct FolderProject {
    pub name: String,
    pub path: PathBuf,
    pub card: Card,
    pub has_card_file: bool,
    /// Relative to the project, with `/`: «Главный файл» from the card, else the newest text that isn't a command's
    /// result.
    pub main_file: Option<String>,
    pub words: Option<usize>,
    /// PDFs, and files in a sources folder (`источники`, `sources`, `материалы`).
    pub sources: usize,
    pub last_activity: Option<DateTime<Utc>>,
}

/// `Folders`: every visible subfolder whose name doesn't start with `_`, newest work first; `Inbox`: the folder itself.
pub fn scan(source: &Source, home: &Path, result_patterns: &[String], language: &str) -> Vec<FolderProject> {
    match source {
        Source::Folders(path) => {
            let root = profiles::expand(path, home);
            let mut projects: Vec<FolderProject> = std::fs::read_dir(&root)
                .into_iter()
                .flatten()
                .flatten()
                .filter(|entry| entry.file_type().is_ok_and(|t| t.is_dir()) && !is_hidden(entry) && !entry.file_name().to_string_lossy().starts_with('_'))
                .map(|entry| project(&entry.path(), result_patterns, language))
                .collect();
            projects.sort_by(|a, b| b.last_activity.cmp(&a.last_activity).then_with(|| a.name.cmp(&b.name)));
            projects
        }
        Source::Inbox(path) => {
            let folder = profiles::expand(path, home);
            if folder.is_dir() { vec![project(&folder, result_patterns, language)] } else { Vec::new() }
        }
        _ => Vec::new(),
    }
}

pub fn project(folder: &Path, result_patterns: &[String], language: &str) -> FolderProject {
    let card_file = card_path(folder, language);
    let card_text = read_text(&card_file);
    let card = card_text.as_deref().map(Card::parse).unwrap_or_default();
    let files = files(folder);
    let card_names = card_file_names();
    let is_text = |path: &Path| {
        let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        TEXT_EXTENSIONS.contains(&ext.as_str()) && !card_names.contains(&name)
    };
    let texts: Vec<&(PathBuf, DateTime<Utc>)> = files.iter().filter(|(path, _)| is_text(path)).collect();
    // A command's result is newer than its source, but the next command must still run on the source.
    let own: Vec<&&(PathBuf, DateTime<Utc>)> = texts.iter().filter(|(path, _)| !is_result(&relative(path, folder), result_patterns)).collect();
    let from_card = card.get(Key::MainFile).map(|file| folder.join(file)).filter(|path| path.is_file());
    let newest = if own.is_empty() {
        texts.iter().max_by_key(|(_, modified)| *modified).map(|(path, _)| path.clone())
    } else {
        own.iter().max_by_key(|(_, modified)| *modified).map(|(path, _)| path.clone())
    };
    let main = from_card.or(newest);
    let sources = files
        .iter()
        .filter(|(path, _)| {
            path.extension().is_some_and(|e| e.eq_ignore_ascii_case("pdf"))
                || Path::new(&relative(path, folder)).components().any(|c| SOURCE_FOLDERS.contains(&c.as_os_str().to_string_lossy().to_lowercase().as_str()))
        })
        .count();
    FolderProject {
        name: folder.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
        path: folder.to_path_buf(),
        card,
        has_card_file: card_text.is_some(),
        main_file: main.as_deref().map(|path| relative(path, folder)),
        words: main.as_deref().and_then(text_of).map(|text| words(&text)),
        sources,
        last_activity: files.iter().map(|(_, modified)| *modified).max(),
    }
}

/// Hidden: a dot name, or (on Windows) the hidden attribute.
fn is_hidden(entry: &std::fs::DirEntry) -> bool {
    if entry.file_name().to_string_lossy().starts_with('.') {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
        if entry.metadata().is_ok_and(|m| m.file_attributes() & FILE_ATTRIBUTE_HIDDEN != 0) {
            return true;
        }
    }
    false
}

/// Files up to three levels deep, without hidden ones and build folders, at most 2000.
pub fn files(folder: &Path) -> Vec<(PathBuf, DateTime<Utc>)> {
    let mut result = Vec::new();
    let mut stack = vec![(folder.to_path_buf(), 1)];
    while let Some((dir, level)) = stack.pop() {
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if is_hidden(&entry) || name == "node_modules" || name == "build" {
                continue;
            }
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_dir() {
                if level < 3 {
                    stack.push((entry.path(), level + 1));
                }
            } else if kind.is_file() {
                let modified = entry.metadata().and_then(|m| m.modified()).map(DateTime::<Utc>::from).unwrap_or_default();
                result.push((entry.path(), modified));
                if result.len() >= MAX_FILES {
                    return result;
                }
            }
        }
    }
    result
}

/// Relative to the project, with `/` between parts.
pub fn relative(path: &Path, folder: &Path) -> String {
    match path.strip_prefix(folder) {
        Ok(rest) => rest.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect::<Vec<_>>().join("/"),
        Err(_) => path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
    }
}

/// Whether a file is what one of these `output` patterns writes (`{…}` and `<…>` are any text), also with the `-2` a
/// repeated name gets and the ` (Claude)` of a comparison (the Mac's `CommandText.isResult`).
pub fn is_result(name: &str, patterns: &[String]) -> bool {
    patterns.iter().any(|pattern| {
        let (base, ext) = match pattern.rsplit_once('.') {
            Some((base, ext)) if !base.is_empty() && !ext.contains('/') => (base, ext),
            _ => (pattern.as_str(), "md"),
        };
        let mut stem = String::new();
        let mut rest = base;
        while let Some(start) = rest.find(['{', '<']) {
            let close = if rest[start..].starts_with('{') { '}' } else { '>' };
            let Some(end) = rest[start..].find(close) else { break };
            stem.push_str(&regex::escape(&rest[..start]));
            stem.push_str(".+");
            rest = &rest[start + end + 1..];
        }
        stem.push_str(&regex::escape(rest));
        let expression = format!(r"(?i)^{stem}( \(.+\))?(-[0-9]+)?\.{}$", regex::escape(ext));
        regex::Regex::new(&expression).is_ok_and(|re| re.is_match(name))
    })
}

fn read_text(path: &Path) -> Option<String> {
    let bytes = std::fs::read(path).ok()?;
    let text = String::from_utf8_lossy(&bytes).into_owned();
    Some(text.strip_prefix('\u{feff}').map(str::to_owned).unwrap_or(text))
}

/// The text a file's words are counted on: plain text, the visible text of `.rtf` and `.docx`.
pub fn text_of(path: &Path) -> Option<String> {
    match path.extension().map(|e| e.to_string_lossy().to_lowercase()).as_deref() {
        Some("docx") => crate::docx::text(path),
        Some("rtf") => read_text(path).map(|rtf| rtf_text(&rtf)),
        _ => read_text(path),
    }
}

/// The visible text of an RTF file: control words, hidden groups (`{\*…}`, font and colour tables, pictures) and braces
/// dropped; `\'hh` and `\uN` become a letter, which is all a word count needs.
fn rtf_text(rtf: &str) -> String {
    const HIDDEN: [&str; 8] = ["fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer", "listtable"];
    let mut out = String::new();
    let mut skip_depth: Option<usize> = None;
    let mut depth = 0usize;
    let mut chars = rtf.chars().peekable();
    let mut group_start = false;
    while let Some(c) = chars.next() {
        match c {
            '{' => {
                depth += 1;
                group_start = true;
                continue;
            }
            '}' => {
                if skip_depth == Some(depth) {
                    skip_depth = None;
                }
                depth = depth.saturating_sub(1);
            }
            '\\' => {
                let Some(&next) = chars.peek() else { break };
                if next.is_ascii_alphabetic() {
                    let mut word = String::new();
                    while let Some(&l) = chars.peek().filter(|l| l.is_ascii_alphabetic()) {
                        word.push(l);
                        chars.next();
                    }
                    let mut number = String::new();
                    while let Some(&d) = chars.peek().filter(|d| d.is_ascii_digit() || **d == '-') {
                        number.push(d);
                        chars.next();
                    }
                    if chars.peek() == Some(&' ') {
                        chars.next();
                    }
                    if group_start && skip_depth.is_none() && HIDDEN.contains(&word.as_str()) {
                        skip_depth = Some(depth);
                    }
                    if skip_depth.is_none() {
                        match word.as_str() {
                            "par" | "line" | "tab" | "sect" | "page" => out.push(' '),
                            "u" => out.push('x'),
                            _ => {}
                        }
                    }
                } else {
                    chars.next();
                    if next == '*' && group_start && skip_depth.is_none() {
                        skip_depth = Some(depth);
                    } else if skip_depth.is_none() {
                        match next {
                            '\'' => {
                                chars.next();
                                chars.next();
                                out.push('x');
                            }
                            '\\' | '{' | '}' => out.push(next),
                            _ => out.push(' '),
                        }
                    }
                }
            }
            '\r' | '\n' => {}
            _ if skip_depth.is_none() => out.push(c),
            _ => {}
        }
        group_start = false;
    }
    out
}

/// Words of the text without Markdown link addresses: `[text](https://…)` counts `text` only.
pub fn words(text: &str) -> usize {
    static LINKS: OnceLock<regex::Regex> = OnceLock::new();
    let links = LINKS.get_or_init(|| regex::Regex::new(r"\]\([^)]*\)").expect("valid"));
    links.replace_all(text, "]").unicode_words().count()
}

// MARK: - Changes

#[derive(Debug, PartialEq)]
pub enum CreateError {
    BadName,
    Exists,
    Io(String),
}

/// Characters a folder name can't have on Windows (and `/` anywhere); no leading dot, no trailing dot or space.
pub fn is_folder_name(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with('.')
        && !name.ends_with(['.', ' '])
        && !name.chars().any(|c| "<>:\"/\\|?*".contains(c) || c.is_control())
}

/// A new project: its folder and a card with the first stage.
pub fn create_project(root: &Path, name: &str, first_stage: Option<&str>, language: &str) -> Result<PathBuf, CreateError> {
    let name = name.trim();
    if !is_folder_name(name) {
        return Err(CreateError::BadName);
    }
    let folder = root.join(name);
    if folder.exists() {
        return Err(CreateError::Exists);
    }
    std::fs::create_dir_all(&folder).map_err(|e| CreateError::Io(e.to_string()))?;
    std::fs::write(folder.join(card_file_name(language)), template(name, first_stage, language)).map_err(|e| CreateError::Io(e.to_string()))?;
    Ok(folder)
}

/// «Создать проект.md» for a project without a card. Nothing when there is one.
pub fn create_card(project: &Path, first_stage: Option<&str>, language: &str) -> std::io::Result<()> {
    let path = card_path(project, language);
    if path.exists() {
        return Ok(());
    }
    let name = project.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    std::fs::write(path, template(&name, first_stage, language))
}

/// Sets «Этап:» in the card, creating the card if there is none. Returns the card's file name.
pub fn set_stage(project: &Path, stage: &str, language: &str) -> std::io::Result<PathBuf> {
    let path = card_path(project, language);
    let name = project.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let current = read_text(&path).unwrap_or_else(|| template(&name, None, language));
    std::fs::write(&path, setting(Key::Stage, stage, &current, language))?;
    Ok(path)
}

// MARK: - Words in the row

/// A metric of the row (`words`, `duration`, `readingTime`, `pages`, `sources`, `deadline`, `publishDate`,
/// `lastActivity`); None when there is nothing to show.
pub fn metric_text(metric: &str, project: &FolderProject, words_per_minute: u64, s: &Strings, language: &str, now: DateTime<Local>) -> Option<String> {
    let count = |n: usize| n.to_string();
    let words = project.words.filter(|&n| n > 0);
    match metric {
        "words" => project.words.map(|n| s.format("%lld сл.", &[&count(n)])),
        "duration" => words.map(|n| {
            let seconds = (n as f64 / words_per_minute.max(1) as f64 * 60.0).round() as u64;
            format!("{}:{:02}", seconds / 60, seconds % 60)
        }),
        "readingTime" => words.map(|n| s.format("%lld мин чтения", &[&count(((n as f64 / 200.0).round() as usize).max(1))])),
        "pages" => words.map(|n| s.format("%lld стр.", &[&count(n.div_ceil(250).max(1))])),
        "sources" => (project.sources > 0).then(|| s.format("%lld ист.", &[&count(project.sources)])),
        "deadline" => project.card.deadline().map(|d| s.t("до ").to_owned() + &short_date(d.date(), now.date_naive(), s, language)),
        "publishDate" => project.card.publish().map(|d| s.t("публ. ").to_owned() + &short_date(d.date(), now.date_naive(), s, language)),
        "lastActivity" => project.last_activity.map(|at| crate::projects::ago(s, at, now.with_timezone(&Utc))),
        _ => None,
    }
}

/// «сегодня», «завтра», else the day and month as numbers in the language's order, with the year when it isn't this one.
pub fn short_date(day: NaiveDate, today: NaiveDate, s: &Strings, language: &str) -> String {
    match (day - today).num_days() {
        0 => s.t("сегодня").to_owned(),
        1 => s.t("завтра").to_owned(),
        _ => {
            let (d, m, y) = (day.day(), day.month(), day.year());
            let same_year = y == today.year();
            match language {
                "en" | "ja" => if same_year { format!("{m}/{d}") } else { format!("{m}/{d}/{y}") },
                "ko" => if same_year { format!("{m}. {d}.") } else { format!("{y}. {m}. {d}.") },
                "ru" | "uk" | "de" | "pl" => if same_year { format!("{d:02}.{m:02}") } else { format!("{d:02}.{m:02}.{y}") },
                _ => if same_year { format!("{d:02}/{m:02}") } else { format!("{d:02}/{m:02}/{y}") },
            }
        }
    }
}

/// «просрочено 2 дн» when the deadline is behind and the work isn't at its last stage.
pub fn overdue(project: &FolderProject, done_stage: Option<&str>, s: &Strings, today: NaiveDate) -> Option<String> {
    let deadline = project.card.deadline()?.date();
    if deadline >= today || (done_stage.is_some() && project.card.stage() == done_stage) {
        return None;
    }
    Some(s.format("просрочено %lld дн", &[&(today - deadline).num_days().to_string()]))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("claudepult-folders-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn card_in_any_language() {
        let card = Card::parse("# Ролик\n\n- **Этап:** сценарий\nДедлайн: 05.11.2026 18:00\nСрок: 2027-01-01\nFormat: 16:9\nPlatform: YouTube\nЗаметка: что угодно\nЭтап: другой\n");
        assert_eq!(card.stage(), Some("сценарий"), "the first line with a key wins");
        assert_eq!(card.deadline(), NaiveDateTime::parse_from_str("2026-11-05 18:00", "%Y-%m-%d %H:%M").ok());
        assert_eq!(card.get(Key::Format), Some("16:9"));
        assert_eq!(card.get(Key::Platform), Some("YouTube"));
        assert_eq!(card.values.len(), 4);
        assert_eq!(Card::parse("Phase: Skript\nFrist: 2026-12-01").stage(), Some("Skript"));
        assert_eq!(date("2026-11-05"), NaiveDate::from_ymd_opt(2026, 11, 5).map(|d| d.and_time(NaiveTime::MIN)));
        assert_eq!(date("завтра"), None);
    }

    #[test]
    fn writing_a_value_keeps_the_rest() {
        let text = "# Ролик\r\n\r\n- **Этап:** идея\r\nДедлайн: \r\n\r\n## Заметки\r\nтекст\r\n";
        let changed = setting(Key::Stage, "монтаж", text, "en");
        assert_eq!(changed, "# Ролик\r\n\r\n- Этап: монтаж\r\nДедлайн: \r\n\r\n## Заметки\r\nтекст\r\n", "Russian labels and CRLF stay");
        assert_eq!(setting(Key::Stage, "draft", "# Post\n\nSome text\n", "en"), "# Post\n\nStage: draft\n\nSome text\n");
        assert_eq!(setting(Key::Stage, "x", "plain\n", "en"), "Stage: x\nplain\n");
        let fresh = template("Новый", Some("идея"), "ru");
        assert!(fresh.starts_with("# Новый\n\nЭтап: идея\nДедлайн: \nПубликация: "));
        assert!(fresh.ends_with("## Заметки\n"));
        assert_eq!(Card::parse(&fresh).stage(), Some("идея"));
    }

    #[test]
    fn results_are_recognised() {
        let patterns = vec!["сценарий-<время>.md".to_owned(), "{проект} — тезисы.txt".to_owned(), "результат-<время>.md".to_owned()];
        assert!(is_result("сценарий-2026-11-18 10.00.md", &patterns));
        assert!(is_result("сценарий-2026-11-18 10.00-2.md", &patterns));
        assert!(is_result("сценарий-2026-11-18 10.00 (Claude).md", &patterns));
        assert!(is_result("Ролик — тезисы.txt", &patterns));
        assert!(!is_result("сценарий.md", &patterns));
        assert!(!is_result("черновик.md", &patterns));
    }

    #[test]
    fn words_and_rtf() {
        assert_eq!(words("# Заголовок\n\nДва слова, и [ссылка](https://example.com/a-b-c) — 2026 год."), 7);
        let rtf = r"{\rtf1\ansi{\fonttbl{\f0 Helvetica;}}{\colortbl;\red0\green0\blue0;}{\*\generator Word;}\f0 Hello \b world\b0\par Second line \'e9t\'e9}";
        assert_eq!(words(&rtf_text(rtf)), 5);
    }

    #[test]
    fn words_of_a_word_file() {
        use crate::docx::tests::{zip_of, DOCUMENT};
        let root = temp("docx");
        std::fs::create_dir_all(&root).unwrap();
        let file = root.join("Сценарий.docx");
        std::fs::write(&file, zip_of(&[("word/document.xml", DOCUMENT.as_bytes(), true)])).unwrap();
        assert_eq!(text_of(&file).map(|t| words(&t)), Some(6), "Сценарий, Привет, мир, Tom, Jerry, 1");
        assert_eq!(crate::commands::inline_text(&file).as_deref(), Some("Сценарий\nПривет, мир\tTom & Jerry — №1\n"), "goes into the prompt, as on the Mac");
        std::fs::write(&file, "not a zip").unwrap();
        assert_eq!(text_of(&file), None);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn scanning_folders() {
        let root = temp("scan");
        let video = root.join("Ролик");
        std::fs::create_dir_all(video.join("источники")).unwrap();
        std::fs::write(video.join("проект.md"), "# Ролик\n\nЭтап: сценарий\nДедлайн: 2020-01-01\n").unwrap();
        std::fs::write(video.join("источники").join("заметка.pdf"), "x").unwrap();
        std::fs::write(video.join("статья.pdf"), "x").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1100));
        std::fs::write(video.join("текст.md"), "один два три").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1100));
        std::fs::write(video.join("сценарий-2026-11-18.md"), "результат команды тут").unwrap();
        std::fs::create_dir_all(video.join("node_modules")).unwrap();
        std::fs::write(video.join("node_modules").join("x.md"), "x").unwrap();
        std::fs::create_dir_all(root.join("_архив")).unwrap();
        std::fs::create_dir_all(root.join(".скрытая")).unwrap();
        std::fs::create_dir_all(root.join("Пустой")).unwrap();

        let source = Source::Folders(root.to_string_lossy().into_owned());
        let projects = scan(&source, Path::new("/nowhere"), &["сценарий-<время>.md".to_owned()], "ru");
        let names: Vec<&str> = projects.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(names, ["Ролик", "Пустой"], "newest work first; `_` and hidden folders skipped");
        let p = &projects[0];
        assert!(p.has_card_file);
        assert_eq!(p.card.stage(), Some("сценарий"));
        assert_eq!(p.main_file.as_deref(), Some("текст.md"), "a command's newer result isn't the main file");
        assert_eq!(p.words, Some(3));
        assert_eq!(p.sources, 2);
        assert!(!projects[1].has_card_file && projects[1].main_file.is_none() && projects[1].last_activity.is_none());

        let inbox = scan(&Source::Inbox(video.to_string_lossy().into_owned()), Path::new("/"), &[], "ru");
        assert_eq!(inbox.len(), 1);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn creating_and_stages() {
        let root = temp("create");
        let folder = create_project(&root, " Новый ролик ", Some("идея"), "ru").unwrap();
        assert_eq!(folder, root.join("Новый ролик"));
        assert_eq!(create_project(&root, "Новый ролик", None, "ru"), Err(CreateError::Exists));
        for bad in ["", ".x", "a/b", "a:b", "a?", "a."] {
            assert_eq!(create_project(&root, bad, None, "ru"), Err(CreateError::BadName), "{bad:?}");
        }
        set_stage(&folder, "монтаж", "en").unwrap();
        let text = std::fs::read_to_string(folder.join("проект.md")).unwrap();
        assert!(text.contains("Этап: монтаж") && !text.contains("идея"), "the card keeps its Russian labels");

        let bare = root.join("Без карточки");
        std::fs::create_dir_all(&bare).unwrap();
        create_card(&bare, Some("идея"), "en").unwrap();
        assert!(bare.join("project.md").is_file());
        set_stage(&bare, "draft", "ru").unwrap();
        assert_eq!(Card::parse(&std::fs::read_to_string(bare.join("project.md")).unwrap()).stage(), Some("draft"));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn row_words() {
        let s = Strings::from_json("{}");
        let today = NaiveDate::from_ymd_opt(2026, 11, 18).unwrap();
        let mut project = FolderProject { name: "x".into(), path: PathBuf::new(), card: Card::default(), has_card_file: true, main_file: None, words: Some(450), sources: 0, last_activity: None };
        let now = Local::now();
        assert_eq!(metric_text("words", &project, 150, &s, "ru", now).as_deref(), Some("450 сл."));
        assert_eq!(metric_text("duration", &project, 150, &s, "ru", now).as_deref(), Some("3:00"));
        assert_eq!(metric_text("readingTime", &project, 150, &s, "ru", now).as_deref(), Some("2 мин чтения"));
        assert_eq!(metric_text("pages", &project, 150, &s, "ru", now).as_deref(), Some("2 стр."));
        assert_eq!(metric_text("sources", &project, 150, &s, "ru", now), None);
        assert_eq!(short_date(today, today, &s, "ru"), "сегодня");
        assert_eq!(short_date(today.succ_opt().unwrap(), today, &s, "ru"), "завтра");
        assert_eq!(short_date(NaiveDate::from_ymd_opt(2026, 12, 5).unwrap(), today, &s, "ru"), "05.12");
        assert_eq!(short_date(NaiveDate::from_ymd_opt(2027, 1, 5).unwrap(), today, &s, "en"), "1/5/2027");
        project.card = Card::parse("Этап: монтаж\nДедлайн: 2026-11-16");
        assert_eq!(overdue(&project, Some("опубликовано"), &s, today).as_deref(), Some("просрочено 2 дн"));
        project.card = Card::parse("Этап: опубликовано\nДедлайн: 2026-11-16");
        assert_eq!(overdue(&project, Some("опубликовано"), &s, today), None, "finished work isn't late");
    }
}
