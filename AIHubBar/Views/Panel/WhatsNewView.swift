import SwiftUI

/// What changed in the version a person just updated to: a card on top of the panel, once, until «Понятно».
/// Release 0.10 moved three Settings pages and went out without a word (Oleh, 2026-11-10: the app is on other
/// people's Macs). The lines here are for whoever knew the previous version; the full list is in
/// `docs/release-notes/` and goes to the release page and Sparkle's window (scripts/release.sh).
enum WhatsNew {
    /// Changes with a release that has something to say; a release without news keeps the old value and shows nothing.
    static let version = "0.13"

    static var items: [String] {
        [String(localized: "Новый модуль «Версии»: тексты проекта-папки сохраняются перед каждым запуском AI — прежний вариант можно сравнить с текущим и вернуть."),
         String(localized: "«Выбрать» под списком проектов-папок запускает одну команду в нескольких проектах по очереди: сейчас, ночью или после сброса лимита."),
         String(localized: "Придёт уведомление, если агент 20 минут ничего не делает или раз за разом запускает одну и ту же команду."),
         String(localized: "В развёрнутом проекте видны локальные серверы из его папки: порт, программа, кнопки «открыть» и «остановить»."),
         String(localized: "В окно «Быстрого запроса» можно перетащить файлы, а кнопка с микрофоном включает диктовку."),
         String(localized: "Календарь выгружается в файл .ics, а у профиля для текстов появилась цель по словам на день.")]
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
