import SwiftUI

/// What changed in the version a person just updated to: a card on top of the panel, once, until «Понятно».
/// Release 0.10 moved three Settings pages and went out without a word (Oleh, 2026-11-10: the app is on other
/// people's Macs). The lines here are for whoever knew the previous version; the full list is in
/// `docs/release-notes/` and goes to the release page and Sparkle's window (scripts/release.sh).
enum WhatsNew {
    /// Changes with a release that has something to say; a release without news keeps the old value and shows nothing.
    static let version = "0.11"

    static var items: [String] {
        [String(localized: "Настройки стали короче: «Модули», «Панель» и «Строка меню» теперь на одной странице «Что показывать»."),
         String(localized: "Лимиты — крупное число и полоса с темпом; кольца возвращаются в настройках блока «Лимиты AI»."),
         String(localized: "У недели видно, быстрее или медленнее ровного расхода вы тратите лимит: отметка на полосе и строка под ней."),
         String(localized: "Строка «Свернуть» внизу панели оставляет лимиты, сессии и проекты; «Ещё» возвращает остальные блоки."),
         String(localized: "Кнопка «стоп» у фоновой задачи останавливает со второго клика."),
         String(localized: "Главным может быть не только Claude: без него первыми идут лимиты другого сервиса. Выбор — на странице «Лимиты AI».")]
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
