//! The Skills Catalog's own texts (`ui/skills-i18n/`): English, with Russian, Ukrainian and German beside it.
//! Every other interface language shows English. A rule's English title and explanation come from the scanner.

use serde_json::{Map, Value};

pub const LANGUAGES: [&str; 4] = ["en", "ru", "uk", "de"];

fn file(code: &str) -> &'static str {
    match code {
        "ru" => include_str!("../../ui/skills-i18n/ru.json"),
        "uk" => include_str!("../../ui/skills-i18n/uk.json"),
        "de" => include_str!("../../ui/skills-i18n/de.json"),
        _ => include_str!("../../ui/skills-i18n/en.json"),
    }
}

fn read(code: &str) -> Map<String, Value> {
    serde_json::from_str(file(code)).unwrap_or_default()
}

/// Every text for an interface language: English first, the language's own on top, and each rule's title and
/// explanation (`rule.<id>.title`, `rule.<id>.why`).
pub fn texts(language: &str) -> Map<String, Value> {
    let mut all = read("en");
    for rule in skill_scanner::RULES {
        all.insert(format!("rule.{}.title", rule.id), rule.title.into());
        all.insert(format!("rule.{}.why", rule.id), rule.why.into());
    }
    if LANGUAGES.contains(&language) && language != "en" {
        all.extend(read(language));
    }
    all
}

pub fn text(language: &str, key: &str) -> String {
    texts(language).get(key).and_then(Value::as_str).unwrap_or(key).to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_language_has_every_text() {
        let english: Vec<String> = read("en").keys().cloned().collect();
        assert!(english.len() > 40);
        for code in LANGUAGES {
            let own = read(code);
            assert!(!own.is_empty(), "{code}.json is not read");
            let interface: Vec<String> = own.keys().filter(|key| !key.starts_with("rule.")).cloned().collect();
            assert_eq!(interface, english, "{code}.json");
            for (key, value) in &own {
                let text = value.as_str().unwrap_or_default();
                assert!(!text.trim().is_empty(), "{code}.json: {key} is empty");
                // The same placeholders as the English text.
                if let Some(original) = read("en").get(key).and_then(Value::as_str) {
                    for place in ["%1", "%2", "%3", "%4"] {
                        assert_eq!(text.contains(place), original.contains(place), "{code}.json: {key} and {place}");
                    }
                }
            }
        }
    }

    #[test]
    fn russian_explains_every_rule() {
        let russian = read("ru");
        for rule in skill_scanner::RULES {
            for part in ["title", "why"] {
                assert!(russian.contains_key(&format!("rule.{}.{part}", rule.id)), "ru.json: rule.{}.{part}", rule.id);
            }
        }
        let known: Vec<String> = skill_scanner::RULES.iter().map(|rule| rule.id.to_owned()).collect();
        for key in russian.keys().filter_map(|key| key.strip_prefix("rule.")) {
            let id = key.rsplit_once('.').map(|(id, _)| id).unwrap_or_default();
            assert!(known.iter().any(|rule| rule == id), "ru.json explains «{id}», which is not a rule");
        }
        assert_eq!(text("ru", "rule.pipe-to-shell.title"), "Скачивает код и сразу запускает");
        assert_eq!(text("de", "rule.pipe-to-shell.title"), "Downloads code and runs it at once");
        assert_eq!(text("ja", "verdict.safe"), "Safe");
    }
}
