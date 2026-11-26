//! Static safety checks for Agent Skills and Claude Code plugins.
//!
//! The one rule that is never broken: nothing from a skill is ever run. Its files are bytes to read — no process is
//! started, no script is loaded, no link is followed, and nothing written in them is taken as an instruction.
//!
//! `read_folder` loads a folder, `scan` returns the findings, a 0–100 risk score and a verdict. A check lowers the
//! risk; it can't prove a skill is safe.

pub mod files;
pub mod rules;
mod structured;
pub mod text;

pub use files::{classify, content_hash, read_folder, FileEntry, Kind, Limits, SkillFiles};
pub use rules::{info_of, RuleInfo, Severity, RULES};

use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::OnceLock;

/// Raised whenever the rules or the scoring change: stored results of an older version are checked again.
pub const SCANNER_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Finding {
    pub rule: String,
    pub category: String,
    pub severity: Severity,
    pub file: String,
    /// 1-based; 0 when the finding is about the whole file.
    pub line: usize,
    /// The line itself (or what was found), shortened.
    pub excerpt: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Verdict {
    /// Instructions only: no scripts, no network, nothing to look at.
    Safe,
    /// Scripts, network or settings: read the findings first.
    Review,
    /// Looks like an attack: data sent out, hidden code or instructions, staying in the system.
    Dangerous,
}

impl Verdict {
    pub fn as_str(self) -> &'static str {
        match self {
            Verdict::Safe => "safe",
            Verdict::Review => "review",
            Verdict::Dangerous => "dangerous",
        }
    }

    pub fn parse(text: &str) -> Verdict {
        match text {
            "safe" => Verdict::Safe,
            "dangerous" => Verdict::Dangerous,
            _ => Verdict::Review,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Report {
    pub scanner_version: u32,
    pub content_hash: String,
    pub risk_score: u8,
    pub verdict: Verdict,
    pub findings: Vec<Finding>,
    pub has_scripts: bool,
    pub languages: Vec<String>,
    pub file_count: usize,
    pub total_bytes: u64,
}

impl Report {
    pub fn has(&self, rule: &str) -> bool {
        self.findings.iter().any(|finding| finding.rule == rule)
    }
}

/// At most this many findings of one rule in one file are kept: the first ones tell the story.
const PER_RULE_AND_FILE: usize = 8;

#[derive(Default)]
pub(crate) struct Findings {
    list: Vec<Finding>,
}

impl Findings {
    pub(crate) fn push(&mut self, rule: &'static str, severity: Severity, file: &str, line: usize, excerpt: &str) {
        let category = info_of(rule).map(|info| info.category).unwrap_or(rules::category::METADATA);
        if self.list.iter().any(|f| f.rule == rule && f.file == file && f.line == line) {
            return;
        }
        if self.list.iter().filter(|f| f.rule == rule && f.file == file).count() >= PER_RULE_AND_FILE {
            return;
        }
        self.list.push(Finding { rule: rule.to_owned(), category: category.to_owned(), severity, file: file.to_owned(), line, excerpt: text::excerpt(excerpt) });
    }
}

/// When the first rule matched a line, the second says nothing new about it.
const COVERS: [(&str, &str); 9] = [
    ("secret-read", "sensitive-path"),
    ("rm-rf-home", "rm-rf"),
    ("pkg-remote", "pkg-install"),
    ("net-upload", "net-call"),
    ("pipe-to-shell", "net-call"),
    ("pipe-to-shell", "dynamic-exec"),
    ("decode-exec", "dynamic-exec"),
    ("decode-exec", "long-base64"),
    ("shell-rc", "sensitive-path"),
];

fn after(line: &str, end: usize) -> &str {
    line.get(end..).unwrap_or_default()
}

/// A match that is known to be harmless: a public key, an example file, a picture written as text.
fn harmless(rule: &str, path: &str, line: &str, found: regex::Match) -> bool {
    let rest = after(line, found.end()).to_ascii_lowercase();
    match rule {
        "secret-read" | "sensitive-path" => rest.starts_with(".pub") || (rest.starts_with("/id_") || rest.starts_with("\\id_")) && rest.split(|c: char| c.is_whitespace() || c == '"' || c == '\'').next().is_some_and(|word| word.ends_with(".pub")) || rest.starts_with("/known_hosts") || rest.starts_with("\\known_hosts") || rest.starts_with("/authorized_keys") || rest.starts_with("/config"),
        "dotenv-read" => [".example", ".sample", ".template", ".dist", ".defaults"].iter().any(|suffix| rest.starts_with(suffix)),
        "long-base64" => {
            let text = found.as_str();
            let lower = line.to_ascii_lowercase();
            let slashes = text.bytes().filter(|b| *b == b'/').count();
            lower.contains("data:image/") || lower.contains("data:font/") || lower.contains("data:application/font") || lower.contains("sha512-") || lower.contains("sha256-") || lower.contains("integrity")
                || path.ends_with(".lock") || path.ends_with("-lock.json") || path.ends_with(".svg")
                // A long path or a row of one letter is not an encoded block.
                || slashes * 12 > text.len() || !text.bytes().any(|b| b.is_ascii_digit()) || !text.bytes().any(|b| b.is_ascii_lowercase()) || !text.bytes().any(|b| b.is_ascii_uppercase())
        }
        "long-hex" => path.ends_with(".lock") || path.ends_with("-lock.json"),
        _ => false,
    }
}

/// Whether the text at `start` opens right after a quotation mark.
fn quoted(line: &str, start: usize) -> bool {
    line.get(..start).unwrap_or_default().trim_end().ends_with(['"', '\'', '`', '“', '«', '‘', '„'])
}

const PIP: [&str; 34] = ["requests", "numpy", "pandas", "urllib3", "boto3", "setuptools", "pyyaml", "cryptography", "pillow", "django", "flask", "scipy", "matplotlib", "beautifulsoup4", "selenium", "pytest", "openai", "anthropic", "tensorflow", "torch", "httpx", "aiohttp", "pydantic", "fastapi", "colorama", "jinja2", "click", "sqlalchemy", "paramiko", "playwright", "python-dotenv", "tqdm", "pypdf", "openpyxl"];
const NPM: [&str; 26] = ["react", "lodash", "express", "axios", "chalk", "commander", "typescript", "webpack", "eslint", "prettier", "moment", "request", "puppeteer", "playwright", "dotenv", "electron", "jquery", "yargs", "openai", "cross-env", "node-fetch", "sharp", "nodemon", "mongoose", "vite", "react-dom"];

/// Package names in an install command that are one typo away from a well-known package.
fn typosquats(line: &str) -> Vec<(String, &'static str)> {
    static INSTALL: OnceLock<Regex> = OnceLock::new();
    let install = rules::regex(&INSTALL, r"(?i)\b(pip\d?|pipx|uv\s+pip|uv\s+add|uvx|npm|npx|pnpm|yarn|bunx?)\s+(?:install|i|add|dlx|x)?\s*([^\n;&|#`]*)");
    let mut found = Vec::new();
    for captures in install.captures_iter(line) {
        let tool = captures[1].to_ascii_lowercase();
        let known: &[&'static str] = if tool.starts_with("pip") || tool.starts_with("uv") { &PIP } else { &NPM };
        for word in captures[2].split_whitespace() {
            if word.starts_with('-') || word.contains("://") || word.contains('/') && !word.starts_with('@') {
                continue;
            }
            let name: String = word.trim_matches(|c| matches!(c, '"' | '\'' | ',' | ')' | '(')).to_ascii_lowercase();
            let name = name.split(['=', '<', '>', '~', '[', '!']).next().unwrap_or_default();
            let name = match name.rfind('@') {
                Some(at) if at > 0 => &name[..at],
                _ => name,
            };
            if name.len() < 5 || known.contains(&name) {
                continue;
            }
            if let Some(popular) = known.iter().find(|popular| text::one_typo_apart(name, popular)) {
                found.push((name.to_owned(), *popular));
            }
        }
    }
    found
}

/// Checks a text line by line. `fixed_line` is for text that came out of another file (a hook's command): every
/// finding points at that line. Returns the rules that matched.
pub(crate) fn scan_text(path: &str, text: &str, is_doc: bool, fixed_line: Option<usize>, out: &mut Findings) -> BTreeSet<&'static str> {
    let mut matched: BTreeSet<&'static str> = BTreeSet::new();
    let mut lines_of: BTreeMap<&'static str, Vec<usize>> = BTreeMap::new();
    for (index, raw) in text.lines().enumerate() {
        let number = fixed_line.unwrap_or(index + 1);
        if raw.trim().is_empty() {
            continue;
        }
        let cleaned;
        let hidden = text::has_hidden(raw);
        let line: &str = if hidden {
            cleaned = text::without_hidden(raw);
            &cleaned
        } else {
            raw
        };
        let mut here: Vec<(&rules::LineRule, Severity)> = Vec::new();
        for (rule, regex) in rules::compiled() {
            if is_doc && rule.in_docs == rules::InDocs::Skip {
                continue;
            }
            let Some(found) = regex.find_iter(line).find(|found| !harmless(rule.id, path, line, *found)) else { continue };
            let mut severity = if is_doc && rule.in_docs == rules::InDocs::Lower { rule.severity.lowered() } else { rule.severity };
            // A phrase in quotes is talked about, not said: a skill that warns about «"ignore previous
            // instructions"» is not an attack. It still counts, a step lower, so quotes are no way around the rule.
            if rule.id.starts_with("pi-") && quoted(line, found.start()) {
                severity = severity.lowered();
            }
            here.push((rule, severity));
            // Words that only come together once the invisible characters are taken out were split on purpose.
            if hidden && rule.id.starts_with("pi-") && !regex.is_match(raw) {
                out.push("pi-hidden-text", Severity::Critical, path, number, raw);
                matched.insert("pi-hidden-text");
            }
        }
        let ids: Vec<&str> = here.iter().map(|(rule, _)| rule.id).collect();
        for (rule, severity) in &here {
            if COVERS.iter().any(|(stronger, weaker)| *weaker == rule.id && ids.contains(stronger)) {
                continue;
            }
            out.push(rule.id, *severity, path, number, raw);
            matched.insert(rule.id);
            lines_of.entry(rule.id).or_default().push(index);
        }
        if ids.contains(&"pkg-install") || ids.contains(&"pkg-remote") {
            for (name, popular) in typosquats(line) {
                out.push("typosquat", if is_doc { Severity::Medium } else { Severity::High }, path, number, &format!("{name} (did you mean {popular}?)"));
                matched.insert("typosquat");
            }
        }
    }

    // Reaching for secrets and sending data out, together.
    let lines = |ids: &[&'static str]| -> Vec<usize> { ids.iter().flat_map(|id| lines_of.get(id).cloned().unwrap_or_default()).collect() };
    let sends = lines(&["net-upload", "exfil-endpoint"]);
    let calls = lines(&["net-call"]);
    let reads = lines(&["secret-read", "env-dump"]);
    let mentions = lines(&["sensitive-path"]);
    let combo = if is_doc {
        // In a document only when they stand next to each other: an AWS skill may mention both a page apart.
        sends.iter().find(|send| reads.iter().chain(&mentions).any(|read| send.abs_diff(*read) <= 3)).map(|line| (*line, Severity::High))
    } else if !reads.is_empty() && (!sends.is_empty() || !calls.is_empty()) {
        sends.first().or(calls.first()).map(|line| (*line, Severity::Critical))
    } else if !mentions.is_empty() && !sends.is_empty() {
        sends.first().map(|line| (*line, Severity::Critical))
    } else {
        None
    };
    if let Some((index, severity)) = combo {
        let shown = text.lines().nth(index).unwrap_or_default();
        out.push("exfil-combo", severity, path, fixed_line.unwrap_or(index + 1), shown);
        matched.insert("exfil-combo");
    }
    matched
}

fn hidden_characters(path: &str, text: &str, out: &mut Findings) {
    // A zero-width space before a code fence is how Markdown shows a fence inside a fence.
    let report = text::hidden_report(&text.replace("\u{200b}```", "```"));
    if report.tags.count > 0 {
        out.push("invisible-tags", Severity::Critical, path, report.tags.first_line, &format!("{} hidden characters: «{}»", report.tags.count, report.tag_text));
    }
    if report.bidi.count > 0 {
        out.push("invisible-bidi", Severity::High, path, report.bidi.first_line, &format!("{} text direction controls", report.bidi.count));
    }
    if report.zero_width.count > 0 {
        // A few are usually a copy-paste accident; many are there on purpose.
        let severity = if report.zero_width.count >= 10 { Severity::High } else { Severity::Medium };
        out.push("invisible-chars", severity, path, report.zero_width.first_line, &format!("{} zero-width characters", report.zero_width.count));
    }
}

fn line_at(text: &str, byte: usize) -> usize {
    text[..byte.min(text.len())].bytes().filter(|b| *b == b'\n').count() + 1
}

fn hidden_comments(path: &str, text: &str, out: &mut Findings) {
    static COMMENT: OnceLock<Regex> = OnceLock::new();
    static ORDER: OnceLock<Regex> = OnceLock::new();
    let comment = rules::regex(&COMMENT, r"(?s)<!--(.*?)-->");
    let order = rules::regex(&ORDER, rules::COMMENT_ORDER);
    for captures in comment.captures_iter(text) {
        let body = captures.get(1).map(|m| m.as_str()).unwrap_or_default();
        if order.is_match(&text::without_hidden(body)) {
            let start = captures.get(0).map(|m| m.start()).unwrap_or_default();
            out.push("pi-hidden-comment", Severity::High, path, line_at(text, start), &body.split_whitespace().collect::<Vec<_>>().join(" "));
        }
    }
}

/// The `key: value` lines between the first two `---` lines, each with its 1-based line number. Nested keys and
/// list items are left out: only what the standard puts at the top level.
pub fn frontmatter(text: &str) -> Vec<(String, String, usize)> {
    let mut lines = text.trim_start_matches('\u{feff}').lines().enumerate();
    let mut values = Vec::new();
    if lines.next().map(|(_, line)| line.trim()) != Some("---") {
        return values;
    }
    for (index, line) in lines {
        if line.trim() == "---" {
            break;
        }
        if line.starts_with([' ', '\t', '#', '-']) {
            continue;
        }
        let Some((key, value)) = line.split_once(':') else { continue };
        let mut value = value.trim();
        if value.len() >= 2 && (value.starts_with('"') && value.ends_with('"') || value.starts_with('\'') && value.ends_with('\'')) {
            value = &value[1..value.len() - 1];
        }
        values.push((key.trim().to_owned(), value.to_owned(), index + 1));
    }
    values
}

fn frontmatter_end(text: &str) -> usize {
    let mut seen = 0;
    for (index, line) in text.lines().enumerate() {
        if line.trim() == "---" {
            seen += 1;
            if seen == 2 {
                return index + 1;
            }
        }
    }
    0
}

fn valid_name(name: &str) -> bool {
    !name.is_empty() && name.chars().count() <= 64 && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') && !name.starts_with('-') && !name.ends_with('-') && !name.contains("--")
}

/// Tools a skill or a slash command approves in advance; the shell with no limits is the one that matters.
fn allowed_tools(path: &str, meta: &[(String, String, usize)], out: &mut Findings) {
    for (key, value, line) in meta {
        if key != "allowed-tools" && key != "allowed_tools" {
            continue;
        }
        let unlimited = value.split([',', ' ']).map(|tool| tool.trim_matches(|c| matches!(c, '[' | ']' | '"' | '\''))).any(|tool| matches!(tool, "Bash" | "Bash(*)" | "Bash(*:*)" | "*" | "PowerShell" | "PowerShell(*)" | "Shell"));
        if unlimited {
            out.push("allowed-tools-shell", Severity::Medium, path, *line, value);
        }
    }
}

fn skill_md(path: &str, text: &str, out: &mut Findings) -> bool {
    let meta = frontmatter(text);
    let value = |key: &str| meta.iter().find(|(k, _, _)| k == key).map(|(_, v, _)| v.as_str());
    let (name, description) = (value("name").unwrap_or_default(), value("description").unwrap_or_default());
    // A long description is written on the following lines (`description: >`): then the key is there with no value.
    let has_description = meta.iter().any(|(k, _, _)| k == "description");
    if name.is_empty() || !has_description {
        out.push("frontmatter", Severity::Low, path, 1, if name.is_empty() { "name is missing" } else { "description is missing" });
    } else if !valid_name(name) {
        out.push("frontmatter", Severity::Info, path, 1, &format!("name «{name}»: lowercase letters, digits and hyphens, up to 64"));
    } else if description.chars().count() > 1024 {
        out.push("frontmatter", Severity::Info, path, 1, "description is longer than 1024 characters");
    }
    allowed_tools(path, &meta, out);
    // Claude Code lets a skill bring its own hooks in the frontmatter.
    let end = frontmatter_end(text);
    let mut in_hooks = false;
    for (index, line) in text.lines().enumerate().take(end) {
        if line.starts_with("hooks:") {
            in_hooks = true;
            continue;
        }
        if in_hooks && !line.starts_with([' ', '\t']) && !line.trim().is_empty() {
            in_hooks = false;
        }
        if in_hooks {
            if let Some((_, command)) = line.split_once("command:") {
                let command = command.trim().trim_matches(|c| c == '"' || c == '\'');
                structured::hook(path, index + 1, "frontmatter", command, out);
            }
        }
    }
    value("license").is_some_and(|license| !license.is_empty())
}

fn slash_command(path: &str, text: &str, out: &mut Findings) {
    static INLINE: OnceLock<Regex> = OnceLock::new();
    allowed_tools(path, &frontmatter(text), out);
    let inline = rules::regex(&INLINE, r"(?:^|\s)!`([^`\n]+)`");
    for (index, line) in text.lines().enumerate() {
        for captures in inline.captures_iter(line) {
            out.push("command-inline-exec", Severity::Medium, path, index + 1, &captures[1]);
            scan_text(path, &captures[1], false, Some(index + 1), out);
        }
    }
}

fn minified(text: &str) -> bool {
    let mut longest = 0;
    let mut count = 0usize;
    for line in text.lines() {
        longest = longest.max(line.len());
        count += 1;
    }
    longest > 3000 || text.len() > 4000 && count > 0 && text.len() / count > 500
}

fn file_name(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// Checks a loaded skill or plugin. Nothing is run and nothing outside `files` is read.
pub fn scan(files: &SkillFiles) -> Report {
    let mut out = Findings::default();
    let mut languages: BTreeSet<&'static str> = BTreeSet::new();
    let mut has_scripts = false;
    let mut has_skill_md = false;
    let mut has_license = false;
    let is_plugin = files.files.iter().any(|file| file.path.ends_with(".claude-plugin/plugin.json") || file.path.ends_with("gemini-extension.json"));

    for file in &files.files {
        let path = file.path.as_str();
        let name = file_name(path);
        if let Some(target) = &file.symlink {
            let outside = target.starts_with(['/', '~', '\\']) || target.contains("..") || target.contains(':');
            out.push("symlink", if outside { Severity::High } else { Severity::Medium }, path, 0, &format!("→ {target}"));
            continue;
        }
        let kind = classify(file);
        match kind {
            Kind::Media => continue,
            Kind::Executable => {
                has_scripts = true;
                out.push("executable-binary", Severity::High, path, 0, name);
                continue;
            }
            Kind::Archive => {
                out.push("archive", Severity::Medium, path, 0, name);
                continue;
            }
            Kind::UnknownBinary => {
                out.push("unknown-binary", Severity::Low, path, 0, name);
                continue;
            }
            Kind::Script(language) => {
                has_scripts = true;
                languages.insert(language);
                out.push("scripts-present", Severity::Low, path, 0, language);
            }
            Kind::Doc | Kind::Config | Kind::OtherText => {}
        }
        if file.unread {
            out.push("large-file", Severity::Low, path, 0, &format!("{} KB", file.size / 1024));
            continue;
        }
        let text = String::from_utf8_lossy(&file.bytes);
        let is_doc = kind == Kind::Doc;
        if matches!(kind, Kind::Script(_)) && minified(&text) {
            out.push("minified", Severity::Medium, path, 0, name);
        }
        hidden_characters(path, &text, &mut out);
        scan_text(path, &text, is_doc, None, &mut out);
        if is_doc {
            hidden_comments(path, &text, &mut out);
        }
        let upper = name.to_ascii_uppercase();
        if upper.starts_with("LICENSE") || upper.starts_with("LICENCE") || upper == "COPYING" || upper == "NOTICE" {
            has_license = true;
        }
        if name == "SKILL.md" {
            has_skill_md = true;
            has_license |= skill_md(path, &text, &mut out);
        } else if is_doc && (path.starts_with("commands/") || path.contains("/commands/")) {
            slash_command(path, &text, &mut out);
        }
        if name.ends_with(".json") {
            has_license |= structured::scan_json(path, &text, &mut out);
        }
    }

    for folder in &files.skipped {
        out.push("not-walked", Severity::Medium, folder, 0, folder);
    }
    if files.truncated {
        out.push("truncated", Severity::Medium, "", 0, "the size limits were reached");
    }
    if !has_skill_md && !is_plugin {
        out.push("no-skill-md", Severity::Low, "SKILL.md", 0, "SKILL.md is missing");
    }
    if !has_license {
        out.push("no-license", Severity::Info, "", 0, "no LICENSE file and no license in SKILL.md");
    }

    let mut findings = out.list;
    findings.sort_by(|a, b| b.severity.cmp(&a.severity).then_with(|| a.file.cmp(&b.file)).then_with(|| a.line.cmp(&b.line)));
    let (risk_score, verdict) = score(&findings);
    Report {
        scanner_version: SCANNER_VERSION,
        content_hash: content_hash(files),
        risk_score,
        verdict,
        findings,
        has_scripts,
        languages: languages.into_iter().map(str::to_owned).collect(),
        file_count: files.files.len(),
        total_bytes: files.total_bytes(),
    }
}

/// A rule counts once at its worst severity; up to three more findings of the same rule add a fifth each. One
/// critical finding, or two serious ones, is enough for «dangerous»; anything worth reading makes it «review».
pub fn score(findings: &[Finding]) -> (u8, Verdict) {
    let mut by_rule: BTreeMap<&str, (Severity, u32)> = BTreeMap::new();
    for finding in findings {
        let entry = by_rule.entry(finding.rule.as_str()).or_insert((finding.severity, 0));
        entry.0 = entry.0.max(finding.severity);
        entry.1 += 1;
    }
    let total: u32 = by_rule.values().map(|(severity, count)| severity.weight() + (count - 1).min(3) * severity.weight() / 5).sum();
    let risk = total.min(100) as u8;
    let critical = findings.iter().any(|finding| finding.severity == Severity::Critical);
    let verdict = if critical || risk >= 70 {
        Verdict::Dangerous
    } else if risk >= 5 {
        Verdict::Review
    } else {
        Verdict::Safe
    };
    (risk, verdict)
}

/// Loads and checks a folder.
pub fn scan_folder(root: &std::path::Path) -> std::io::Result<(SkillFiles, Report)> {
    let files = read_folder(root, Limits::default())?;
    let report = scan(&files);
    Ok((files, report))
}
