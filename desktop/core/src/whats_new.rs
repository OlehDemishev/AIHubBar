//! «Что нового» (the Mac's `WhatsNew`): what changed in the version a person just updated to — a card on top of
//! the panel, once, until «Понятно». The lines are for whoever knew the previous version.

use crate::i18n::Strings;

/// Changes with a release that has something to say; a release without news keeps the old value and shows nothing.
/// The Windows and Linux version has its own line of versions, so its own value and lines.
pub const VERSION: &str = "0.1.11";

pub fn items(s: &Strings) -> Vec<String> {
    [
        s.t("Две задачи пары Claude и Codex можно сравнить в одном окне и оставить лучший вариант."),
        s.t("Итог дня приходит в Telegram и начинается с того, что ждёт вас."),
        s.t("Если агент застрял или ходит по кругу, придёт уведомление."),
        s.t("Календарь выгружается в .ics, у профиля для текстов есть цель по словам, а в проекте видны локальные серверы."),
        s.t("Лимиты показаны полосами, как на Mac; кольца — в Настройках → «Внешний вид». Блоки панели сворачиваются по клику на заголовок."),
    ]
    .map(str::to_owned)
    .to_vec()
}

/// Shown to whoever already had a profile and has not seen this version's card. A new person has nothing to compare
/// with: the first start marks the card seen.
pub fn should_show(seen: Option<&str>, has_profiles: bool) -> bool {
    has_profiles && seen != Some(VERSION)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn who_sees_the_card() {
        assert!(should_show(None, true) && should_show(Some("0.1.10"), true));
        assert!(!should_show(Some(VERSION), true), "closed once");
        assert!(!should_show(None, false), "a new person has nothing to compare with");
        let items = items(&Strings::default());
        assert!((3..=6).contains(&items.len()) && items.iter().all(|line| line.ends_with('.')));
    }
}
