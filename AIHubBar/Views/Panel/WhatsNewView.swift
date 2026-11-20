import SwiftUI

/// What changed in the version a person just updated to: a card on top of the panel, once, until «Понятно».
/// Release 0.10 moved three Settings pages and went out without a word (Oleh, 2026-11-10: the app is on other
/// people's Macs). The lines here are for whoever knew the previous version; the full list is in
/// `docs/release-notes/` and goes to the release page and Sparkle's window (scripts/release.sh).
enum WhatsNew {
    /// Changes with a release that has something to say; a release without news keeps the old value and shows nothing.
    static let version = "0.12"

    static var items: [String] {
        [String(localized: "Codex работает как Claude: «Разрешить» и «Отклонить» на его запросы прямо из панели, и задачи в фоне из «Быстрого запроса»."),
         String(localized: "Одну задачу можно дать Claude и Codex сразу: окно сравнения покажет оба ответа и изменённые файлы, а выбранный вариант вливается в вашу ветку."),
         String(localized: "У готовой фоновой задачи в меню есть «Проверить в Codex», а у остановленной по лимиту — «Передать Codex»."),
         String(localized: "В окне «Claude Code» новая вкладка «Skills и плагины»: выключатель у каждого."),
         String(localized: "«История расхода» открывается сводкой «Сегодня» и сравнивает расход по цене API с ценой плана."),
         String(localized: "Колокольчик в шапке панели выключает уведомления в Telegram, пока не нажмёте снова.")]
    }

    /// Shown to whoever already had a profile and has not seen this version's card. A new person has nothing to compare
    /// with: the assistant marks the card seen.
    static func shouldShow(seen: String, hasProfiles: Bool) -> Bool { hasProfiles && seen != version }
}

struct WhatsNewView: View {
    @AppStorage(StorageKey.whatsNewSeen) private var seen = ""
    @Environment(\.openSettingsPage) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.orange)
                Text("Что нового").scaledFont(.callout, weight: .semibold)
                Spacer(minLength: 0)
            }
            ForEach(WhatsNew.items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "•").foregroundStyle(.secondary)
                    Text(verbatim: item)
                        .scaledFont(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Открыть настройки") {
                    seen = WhatsNew.version
                    openSettings(.show)
                }
                Button("Понятно") { seen = WhatsNew.version }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
