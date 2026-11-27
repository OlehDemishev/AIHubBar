import SwiftUI

/// What changed in the version a person just updated to: a card on top of the panel, once, until «Понятно».
/// Release 0.10 moved three Settings pages and went out without a word (Oleh, 2026-11-10: the app is on other
/// people's Macs). The lines here are for whoever knew the previous version; the full list is in
/// `docs/release-notes/` and goes to the release page and Sparkle's window (scripts/release.sh).
enum WhatsNew {
    /// Changes with a release that has something to say; a release without news keeps the old value and shows nothing.
    static let version = "0.15"

    static var items: [String] {
        [String(localized: "Скиллы можно искать своими словами: «Найти по смыслу с AI» под поиском, а кнопка «Скиллы» в карточке проекта подбирает их под проект."),
         String(localized: "«Открытые источники» (глобус в разделе «Скиллы»): около 900 репозиториев со скиллами, поиск без скачивания."),
         String(localized: "Описания скиллов переводятся на ваш язык вашей моделью — по кнопке или сразу (Настройки → «Скиллы»)."),
         String(localized: "«Экономика AI»: цены моделей рядом и сколько стоили бы ваши 30 дней — в меню «Ещё» и под лимитами."),
         String(localized: "«Остановить все» для фоновых задач и сессии на других компьютерах по SSH (бета, Настройки → «Сессии агентов»).")]
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
