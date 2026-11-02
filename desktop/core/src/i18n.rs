//! The 13 interface languages (SPEC-modes §13). Texts come from the Mac app's String Catalog: the key is the
//! Russian text, `desktop/scripts/strings.py` writes `ui/i18n/<code>.json` with the keys this version uses.

use std::collections::HashMap;

/// Language codes as the Mac app has them; Russian is the source.
pub const LANGUAGES: [&str; 13] = ["ru", "en", "es", "pt-BR", "fr", "de", "ja", "id", "ko", "it", "ar", "pl", "uk"];

/// When none of the person's languages is one of ours. The Mac app falls back to Russian, its development
/// language; for people on Windows and Linux English is the better guess.
pub const FALLBACK: &str = "en";

/// Each language's own name, for the language menu.
pub fn native_name(code: &str) -> &'static str {
    match code {
        "ru" => "Русский",
        "en" => "English",
        "es" => "Español",
        "pt-BR" => "Português (Brasil)",
        "fr" => "Français",
        "de" => "Deutsch",
        "ja" => "日本語",
        "id" => "Bahasa Indonesia",
        "ko" => "한국어",
        "it" => "Italiano",
        "ar" => "العربية",
        "pl" => "Polski",
        "uk" => "Українська",
        _ => "",
    }
}

/// Ours for one system locale (`pt-PT` and `pt` count as `pt-BR`, `uk-UA` as `uk`), or None.
pub fn supported(locale: &str) -> Option<&'static str> {
    let locale = locale.replace('_', "-");
    let lower = locale.to_ascii_lowercase();
    if let Some(exact) = LANGUAGES.iter().find(|code| code.to_ascii_lowercase() == lower) {
        return Some(exact);
    }
    let base = lower.split('-').next().unwrap_or("");
    if base == "pt" {
        return Some("pt-BR");
    }
    LANGUAGES.iter().copied().find(|code| *code == base)
}

/// The first of the person's languages that we have, else the fallback.
pub fn pick<S: AsRef<str>>(preferred: &[S]) -> &'static str {
    preferred.iter().find_map(|locale| supported(locale.as_ref())).unwrap_or(FALLBACK)
}

/// The language to show: the one chosen in Settings, or the system's («как в системе»).
pub fn resolve(choice: Option<&str>) -> &'static str {
    if let Some(code) = choice.and_then(supported) {
        return code;
    }
    let system: Vec<String> = sys_locale::get_locales().collect();
    pick(&system)
}

/// Right to left.
pub fn is_rtl(code: &str) -> bool {
    code == "ar"
}

/// One language's texts. A missing key shows the Russian source text, as the String Catalog does.
#[derive(Debug, Default, Clone)]
pub struct Strings {
    map: HashMap<String, String>,
}

impl Strings {
    pub fn from_json(json: &str) -> Self {
        Strings { map: serde_json::from_str(json).unwrap_or_default() }
    }

    pub fn t<'a>(&'a self, key: &'a str) -> &'a str {
        self.map.get(key).map(String::as_str).filter(|text| !text.is_empty()).unwrap_or(key)
    }

    /// `%@` and `%lld` filled in order (the String Catalog's placeholders; `%1$@` positional ones too).
    pub fn format(&self, key: &str, args: &[&str]) -> String {
        fill(self.t(key), args)
    }
}

/// Fills `%@`, `%lld`, `%d` in order and `%N$@` / `%N$lld` by position.
pub fn fill(template: &str, args: &[&str]) -> String {
    let mut out = String::new();
    let mut next = 0;
    let mut rest = template;
    while let Some(start) = rest.find('%') {
        out.push_str(&rest[..start]);
        let tail = &rest[start + 1..];
        let (index, after_position) = match tail.find('$') {
            Some(dollar) if dollar > 0 && tail[..dollar].chars().all(|c| c.is_ascii_digit()) => {
                (tail[..dollar].parse::<usize>().ok().map(|n| n.saturating_sub(1)), &tail[dollar + 1..])
            }
            _ => (None, tail),
        };
        let spec = ["@", "lld", "ld", "d"].into_iter().find(|spec| after_position.starts_with(spec));
        match spec {
            Some(spec) => {
                let position = index.unwrap_or_else(|| {
                    next += 1;
                    next - 1
                });
                out.push_str(args.get(position).copied().unwrap_or(""));
                rest = &after_position[spec.len()..];
            }
            None if tail.starts_with('%') => {
                out.push('%');
                rest = &tail[1..];
            }
            None => {
                out.push('%');
                rest = tail;
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn system_languages() {
        assert_eq!(supported("en-US"), Some("en"));
        assert_eq!(supported("pt_PT"), Some("pt-BR"));
        assert_eq!(supported("pt-BR"), Some("pt-BR"));
        assert_eq!(supported("uk-UA"), Some("uk"));
        assert_eq!(supported("zh-CN"), None);
        assert_eq!(pick(&["nl-NL", "de-AT", "en"]), "de", "the first one we have");
        assert_eq!(pick(&["nl-NL"]), FALLBACK);
        assert_eq!(pick::<&str>(&[]), FALLBACK);
        assert_eq!(resolve(Some("ja")), "ja", "a chosen language wins");
        assert!(LANGUAGES.iter().all(|code| !native_name(code).is_empty()));
        assert!(is_rtl("ar") && !is_rtl("ru"));
    }

    #[test]
    fn texts() {
        let strings = Strings::from_json(r#"{"Настройки…": "Settings…", "Пусто": ""}"#);
        assert_eq!(strings.t("Настройки…"), "Settings…");
        assert_eq!(strings.t("Нет такого"), "Нет такого", "the Russian source when missing");
        assert_eq!(strings.t("Пусто"), "Пусто");
        assert_eq!(Strings::from_json("not json").t("x"), "x");
    }

    #[test]
    fn placeholders() {
        assert_eq!(fill("Готово: %@", &["ClaudePult"]), "Готово: ClaudePult");
        assert_eq!(fill("%lld of %lld done", &["3", "7"]), "3 of 7 done");
        assert_eq!(fill("%2$lld 件中 %1$lld 件完了", &["3", "7"]), "7 件中 3 件完了");
        assert_eq!(fill("100 % sure", &[]), "100 % sure");
        assert_eq!(fill("50%% off", &[]), "50% off");
    }
}
