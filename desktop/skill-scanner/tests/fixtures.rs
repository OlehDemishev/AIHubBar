//! The whole pass over made-up skills in `tests/fixtures`: every bad one is caught, every clean one stays clean.
//! The fixtures are harmless by design (example.com, nothing that does real work) and are only ever read.

use skill_scanner::{scan_folder, Report, Verdict};
use std::path::PathBuf;

fn fixtures(group: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests").join("fixtures").join(group)
}

fn report(group: &str, name: &str) -> Report {
    scan_folder(&fixtures(group).join(name)).unwrap_or_else(|error| panic!("{group}/{name}: {error}")).1
}

fn names(group: &str) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(fixtures(group)).unwrap().flatten().filter(|e| e.path().is_dir()).map(|e| e.file_name().to_string_lossy().into_owned()).collect();
    names.sort();
    names
}

/// The fixture, the rule that must fire, and the verdict.
const BAD: [(&str, &str, Verdict); 15] = [
    ("exfil-curl", "exfil-combo", Verdict::Dangerous),
    ("base64-payload", "decode-exec", Verdict::Dangerous),
    ("zero-width-injection", "pi-hidden-text", Verdict::Dangerous),
    ("malicious-hook", "hook-network", Verdict::Dangerous),
    ("ssh-read", "secret-read", Verdict::Dangerous),
    ("pipe-to-shell", "pipe-to-shell", Verdict::Dangerous),
    ("persistence", "persistence", Verdict::Dangerous),
    ("hidden-comment", "pi-hidden-comment", Verdict::Dangerous),
    ("tag-smuggling", "invisible-tags", Verdict::Dangerous),
    ("agent-permissions", "agent-config", Verdict::Dangerous),
    ("mcp-remote", "mcp-remote-code", Verdict::Dangerous),
    ("webhook-exfil", "exfil-endpoint", Verdict::Dangerous),
    // Orders for the agent and for whoever reviews the skill, in plain words: found by the static check too.
    ("reviewer-bait", "pi-exfil", Verdict::Dangerous),
    ("destructive", "rm-rf-home", Verdict::Dangerous),
    // One typo in a package name is a suspicion, not proof: the finding is there, the verdict stays «review».
    ("typosquat", "typosquat", Verdict::Review),
];

#[test]
fn every_bad_skill_is_caught() {
    assert_eq!(names("bad"), {
        let mut expected: Vec<String> = BAD.iter().map(|(name, _, _)| name.to_string()).collect();
        expected.sort();
        expected
    }, "a fixture without an expectation, or the other way round");
    for (name, rule, verdict) in BAD {
        let report = report("bad", name);
        assert!(report.has(rule), "{name}: {rule} did not fire; found {:?}", report.findings.iter().map(|f| f.rule.as_str()).collect::<Vec<_>>());
        assert_eq!(report.verdict, verdict, "{name}: score {} from {:?}", report.risk_score, report.findings.iter().map(|f| (f.rule.as_str(), f.severity)).collect::<Vec<_>>());
        assert_ne!(report.verdict, Verdict::Safe, "{name}");
    }
}

#[test]
fn every_finding_can_be_explained() {
    for group in ["bad", "clean", "review"] {
        for name in names(group) {
            for finding in report(group, &name).findings {
                assert!(skill_scanner::info_of(&finding.rule).is_some(), "{group}/{name}: {} has no explanation", finding.rule);
                assert!(!finding.excerpt.is_empty(), "{group}/{name}: {} shows nothing", finding.rule);
            }
        }
    }
}

#[test]
fn clean_skills_stay_clean() {
    let clean = names("clean");
    assert!(clean.len() >= 5);
    for name in clean {
        let report = report("clean", &name);
        assert_eq!(report.verdict, Verdict::Safe, "{name}: {:?}", report.findings);
        assert_eq!(report.risk_score, 0, "{name}: {:?}", report.findings);
        assert!(!report.has_scripts, "{name}");
    }
}

#[test]
fn scripts_and_network_alone_are_for_review() {
    let count = report("review", "word-count");
    assert_eq!(count.verdict, Verdict::Review, "{:?}", count.findings);
    assert!(count.has("scripts-present") && count.has_scripts && count.languages == ["python"]);
    let weather = report("review", "weather");
    assert_eq!(weather.verdict, Verdict::Review, "{:?}", weather.findings);
    assert!(weather.has("net-call"));
}

#[test]
fn findings_name_the_file_and_the_line() {
    let report = report("bad", "exfil-curl");
    let finding = report.findings.iter().find(|f| f.rule == "secret-read").expect("secret-read");
    assert_eq!((finding.file.as_str(), finding.line), ("scripts/sync.sh", 3));
    assert!(finding.excerpt.contains("example.com"));
    let hook = self::report("bad", "malicious-hook");
    let finding = hook.findings.iter().find(|f| f.rule == "hook-command").expect("hook-command");
    assert_eq!((finding.file.as_str(), finding.line), ("hooks/hooks.json", 6));
    assert!(finding.excerpt.starts_with("SessionStart:"));
}

#[test]
fn the_same_folder_gives_the_same_hash() {
    assert_eq!(report("clean", "sql-style").content_hash, report("clean", "sql-style").content_hash);
    assert_ne!(report("clean", "sql-style").content_hash, report("clean", "writing-style").content_hash);
}
