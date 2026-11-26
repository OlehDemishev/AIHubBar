//! `claudepult skills …`: the Skills Catalog from the console. Reading only: a skill's files are never run, and
//! nothing is written into an agent's folders.

use claudepult_core::paths;
use skill_catalog::Roots;
use skill_scanner::{info_of, Finding, Verdict};
use std::path::Path;
use std::process::ExitCode;

fn mark(verdict: &str) -> &'static str {
    match verdict {
        "safe" => "SAFE     ",
        "dangerous" => "DANGEROUS",
        _ => "REVIEW   ",
    }
}

fn print_findings(findings: &[Finding]) {
    for finding in findings {
        let place = match (finding.file.is_empty(), finding.line) {
            (true, _) => String::new(),
            (false, 0) => format!("{}: ", finding.file),
            (false, line) => format!("{}:{line}: ", finding.file),
        };
        let title = info_of(&finding.rule).map(|rule| rule.title).unwrap_or(&finding.rule);
        println!("    [{:<8}] {place}{title} ({})", finding.severity.name(), finding.rule);
        println!("               {}", finding.excerpt);
    }
}

fn scan(folder: &Path, json: bool) -> ExitCode {
    let (_, report) = match skill_scanner::scan_folder(folder) {
        Ok(found) => found,
        Err(error) => {
            eprintln!("error: {}: {error}", folder.display());
            return ExitCode::FAILURE;
        }
    };
    if json {
        println!("{}", serde_json::to_string_pretty(&report).unwrap_or_default());
    } else {
        println!("{} risk {:>3}  {}", mark(report.verdict.as_str()), report.risk_score, folder.display());
        print_findings(&report.findings);
        println!("\nA check lowers the risk but can't guarantee that a skill is safe.");
    }
    // 0 safe, 1 an error, 3 to review, 4 dangerous: a script can stop on the verdict.
    match report.verdict {
        Verdict::Safe => ExitCode::SUCCESS,
        Verdict::Review => ExitCode::from(3),
        Verdict::Dangerous => ExitCode::from(4),
    }
}

/// The folders the app would look in: the real ones, with the projects folder from its settings.
pub(crate) fn roots() -> Roots {
    let home = dirs::home_dir().unwrap_or_else(std::env::temp_dir);
    let settings = claudepult_core::settings::Settings::load(&paths::settings_file());
    Roots { home, claude_dir: paths::claude_dir(), codex_dir: paths::codex_dir(), projects_dir: settings.projects_dir().or_else(|| Some(paths::default_projects_dir())) }.or_test_home()
}

fn list(json: bool, verbose: bool) -> ExitCode {
    let result = (|| -> skill_catalog::Result<_> {
        let mut db = skill_catalog::open(&Roots::database(paths::skills_db()))?;
        let stats = skill_catalog::refresh_installed(&mut db, &roots(), &skill_catalog::now())?;
        Ok((stats, skill_catalog::installed(&db, None)?))
    })();
    let (stats, rows) = match result {
        Ok(found) => found,
        Err(error) => {
            eprintln!("error: {error}");
            return ExitCode::FAILURE;
        }
    };
    if json {
        println!("{}", serde_json::to_string_pretty(&rows).unwrap_or_default());
        return ExitCode::SUCCESS;
    }
    for row in &rows {
        let kind = if row.kind == "plugin" { " (plugin)" } else { "" };
        println!("{} risk {:>3}  {}{kind}  [{}]", mark(&row.verdict), row.risk_score, row.name, row.agents.join(", "));
        println!("    {}", row.path);
        if verbose {
            print_findings(&row.findings);
        }
    }
    let count = |verdict: &str| rows.iter().filter(|row| row.verdict == verdict).count();
    println!("\n{} installed: {} dangerous, {} to review, {} safe ({} checked now)", rows.len(), count("dangerous"), count("review"), count("safe"), stats.scanned);
    for failed in &stats.failed {
        eprintln!("could not read {failed}");
    }
    println!("A check lowers the risk but can't guarantee that a skill is safe.");
    ExitCode::SUCCESS
}

pub fn run(args: &[String]) -> ExitCode {
    let json = args.iter().any(|arg| arg == "--json");
    let verbose = args.iter().any(|arg| arg == "--findings");
    let plain: Vec<&String> = args.iter().filter(|arg| !arg.starts_with("--")).collect();
    match plain.as_slice() {
        [command] if command.as_str() == "list" => list(json, verbose),
        [command, folder] if command.as_str() == "scan" => scan(Path::new(folder.as_str()), json),
        // What the window asks the catalog, as JSON: a search by words, a skill's card, one of its files.
        [command, rest @ ..] if matches!(command.as_str(), "search" | "card" | "file") => {
            let answer = (|| -> skill_catalog::Result<serde_json::Value> {
                let db = skill_catalog::open(&Roots::database(paths::skills_db()))?;
                let id = || rest.first().and_then(|id| id.parse::<i64>().ok()).ok_or("an id is needed");
                Ok(match command.as_str() {
                    "search" => serde_json::to_value(skill_catalog::search(&db, &skill_catalog::Filters { query: rest.iter().map(|word| word.as_str()).collect::<Vec<_>>().join(" "), ..Default::default() })?)?,
                    "card" => serde_json::to_value(skill_catalog::card(&db, id()?)?)?,
                    _ => serde_json::to_value(skill_catalog::preview(&db, id()?, rest.get(1).map(|file| file.as_str()).unwrap_or_default())?)?,
                })
            })();
            match answer {
                Ok(value) => {
                    println!("{}", serde_json::to_string_pretty(&value).unwrap_or_default());
                    ExitCode::SUCCESS
                }
                Err(error) => {
                    eprintln!("error: {error}");
                    ExitCode::FAILURE
                }
            }
        }
        // The window's texts for a language, as the app hands them to the page.
        [command, language] if command.as_str() == "texts" => {
            println!("{}", serde_json::to_string_pretty(&skill_catalog::texts::texts(language)).unwrap_or_default());
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!("Usage:\n  claudepult skills list [--json] [--findings]\n  claudepult skills scan <folder> [--json]\n  claudepult skills search [words]\n  claudepult skills card <id>\n  claudepult skills file <id> <path>");
            ExitCode::from(2)
        }
    }
}
