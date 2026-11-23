//! «Что нового» (the Mac's `WhatsNew`): what changed in the version a person just updated to — a card on top of
//! the panel, once, until «Понятно». The lines are for whoever knew the previous version.

use crate::i18n::Strings;

/// Changes with a release that has something to say; a release without news keeps the old value and shows nothing.
/// The Windows and Linux version has its own line of versions, so its own value and lines.
pub const VERSION: &str = "0.1.9";

pub fn items(s: &Strings) -> Vec<String> {
    [
        s.t("Настройки устроены как на Mac: разделы слева, страница справа, сверху поиск."),
        s.t("Фоновую задачу можно отложить на ночь или до сброса лимита."),
        s.t("У лимита фоновые задачи Claude встают на паузу и продолжают после сброса."),
        s.t("Фоновую задачу можно передать Codex, а готовую — проверить другим сервисом."),
        s.t("Инструкции CLAUDE.md, MCP-серверы, skills и плагины собраны в одном окне."),
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
        assert!(should_show(None, true) && should_show(Some("0.1.8"), true));
        assert!(!should_show(Some(VERSION), true), "closed once");
        assert!(!should_show(None, false), "a new person has nothing to compare with");
        let items = items(&Strings::default());
        assert!((3..=6).contains(&items.len()) && items.iter().all(|line| line.ends_with('.')));
    }
}
