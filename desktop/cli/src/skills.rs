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

/// What the window's commands answer, for trying the page outside the app. It can install and remove, so it only
/// works on a made-up home (`AIHUBBAR_SKILLS_HOME`), never on the person's real folders.
fn call(command: &str, args: &serde_json::Value) -> skill_catalog::Result<serde_json::Value> {
    use skill_catalog::manage;
    if std::env::var("AIHUBBAR_SKILLS_HOME").map_or(true, |home| home.trim().is_empty()) {
        return Err("`skills call` needs AIHUBBAR_SKILLS_HOME: it is for a test home only".into());
    }
    let roots = roots();
    let database = Roots::database(paths::skills_db());
    let backups = database.with_file_name("backups");
    let now = skill_catalog::now();
    let env = skill_catalog::Env { roots: &roots, backups: &backups, now: &now };
    let mut db = skill_catalog::open(&database)?;
    let text = |key: &str| args.get(key).and_then(|value| value.as_str()).unwrap_or_default().to_owned();
    let number = |key: &str| args.get(key).and_then(|value| value.as_i64()).unwrap_or_default();
    let flag = |key: &str| args.get(key).and_then(|value| value.as_bool()).unwrap_or_default();
    Ok(match command {
        "skills_texts" => serde_json::Value::Object(skill_catalog::texts::texts(&text("lang"))),
        "skills_refresh" => serde_json::json!({ "refreshed": skill_catalog::refresh_installed(&mut db, &roots, &now)?, "home": roots.home }),
        "skills_search" => serde_json::to_value(skill_catalog::search(&db, &serde_json::from_value(args.get("filters").cloned().unwrap_or_default())?)?)?,
        "skills_card" => serde_json::to_value(skill_catalog::card(&db, number("id"))?)?,
        "skills_preview" => serde_json::to_value(skill_catalog::preview(&db, number("id"), &text("file"))?)?,
        "skills_add_folder" => serde_json::to_value(manage::import_folder(&mut db, Path::new(&text("path")), &now)?)?,
        "skills_forget" => serde_json::to_value(manage::forget(&db, number("id"))?)?,
        "skills_plan_install" => serde_json::to_value(manage::plan_install(&mut db, env, number("id"), &text("agent"))?)?,
        "skills_install" => serde_json::to_value(manage::install(&mut db, env, number("id"), &text("agent"), &text("contentHash"), flag("acknowledged"))?)?,
        "skills_remove" => serde_json::to_value(manage::remove(&mut db, env, &text("installPath"))?)?,
        "skills_set_enabled" => serde_json::to_value(manage::set_enabled(&mut db, env, &text("installPath"), flag("on"))?)?,
        "skills_journal" => serde_json::to_value(manage::journal(&db, 200)?)?,
        "skills_restore" => serde_json::to_value(manage::restore(&mut db, env, number("journalId"))?)?,
        "skills_updates" => serde_json::to_value(manage::updates(&db)?)?,
        "skills_plan_update" => serde_json::json!({ "plan": manage::plan_update(&db, env, &text("installPath"))?, "changes": manage::diff(&db, &text("installPath"))? }),
        "skills_update" => serde_json::to_value(manage::update(&mut db, env, &text("installPath"), &text("contentHash"), flag("acknowledged"))?)?,
        // The review goes through Claude Code only here, never through a key.
        "skills_review_state" => {
            let (hash, request) = skill_catalog::review::prepare(&db, number("id"), "Russian")?.ok_or("missing")?;
            serde_json::json!({ "review": skill_catalog::review::cached(&db, &hash, "ru")?, "via": claudepult_core::command::find("claude").map(|_| "claude-code"), "tokens": (request.system.len() + request.user.len()) / 4, "incomplete": request.incomplete })
        }
        "skills_review" => {
            use skill_catalog::review;
            let program = claudepult_core::command::find("claude").ok_or("no-reviewer")?;
            let (hash, request) = review::prepare(&db, number("id"), "Russian")?.ok_or("missing")?;
            if !flag("again") {
                if let Some(known) = review::cached(&db, &hash, "ru")? {
                    return Ok(serde_json::to_value(known)?);
                }
            }
            let scratch = database.with_file_name("review-scratch");
            let answer = skill_catalog::reviewer::via_claude(&request, &program, &scratch, skill_catalog::reviewer::DEFAULT_MODEL)?;
            let (verdict, valid, summary, findings) = review::parse_answer(&answer.text, &request);
            let result = review::LlmReview { verdict, valid, incomplete: request.incomplete, summary, findings, model: answer.model, via: "claude-code".into(), language: "ru".into(), input_tokens: answer.input_tokens, output_tokens: answer.output_tokens, reviewed_at: now.clone() };
            review::save(&db, &hash, &result)?;
            serde_json::to_value(result)?
        }
        _ => return Err(format!("no such command: {command}").into()),
    })
}

pub fn run(args: &[String]) -> ExitCode {
    let json = args.iter().any(|arg| arg == "--json");
    let verbose = args.iter().any(|arg| arg == "--findings");
    let plain: Vec<&String> = args.iter().filter(|arg| !arg.starts_with("--")).collect();
    match plain.as_slice() {
        [command] if command.as_str() == "list" => list(json, verbose),
        [command, folder] if command.as_str() == "scan" => scan(Path::new(folder.as_str()), json),
        // What the window asks the catalog, as JSON: a search by words, a skill's card, one of its files.
        [command, rest @ ..] if matches!(command.as_str(), "search" | "card" | "file" | "journal" | "updates") => {
            let answer = (|| -> skill_catalog::Result<serde_json::Value> {
                let db = skill_catalog::open(&Roots::database(paths::skills_db()))?;
                let id = || rest.first().and_then(|id| id.parse::<i64>().ok()).ok_or("an id is needed");
                Ok(match command.as_str() {
                    "search" => serde_json::to_value(skill_catalog::search(&db, &skill_catalog::Filters { query: rest.iter().map(|word| word.as_str()).collect::<Vec<_>>().join(" "), ..Default::default() })?)?,
                    "card" => serde_json::to_value(skill_catalog::card(&db, id()?)?)?,
                    "journal" => serde_json::to_value(skill_catalog::manage::journal(&db, 200)?)?,
                    "updates" => serde_json::to_value(skill_catalog::manage::updates(&db)?)?,
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
        [command, name, rest @ ..] if command.as_str() == "call" => {
            let args = rest.first().and_then(|json| serde_json::from_str(json).ok()).unwrap_or(serde_json::Value::Null);
            match call(name, &args) {
                Ok(value) => {
                    println!("{value}");
                    ExitCode::SUCCESS
                }
                Err(error) => {
                    eprintln!("{error}");
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
            eprintln!("Usage:\n  claudepult skills list [--json] [--findings]\n  claudepult skills scan <folder> [--json]\n  claudepult skills search [words]\n  claudepult skills card <id>\n  claudepult skills file <id> <path>\n  claudepult skills journal\n  claudepult skills updates");
            ExitCode::from(2)
        }
    }
}
