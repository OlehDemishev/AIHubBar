import SwiftUI

/// What changed in the version a person just updated to: a card on top of the panel, once, until «Понятно».
/// Release 0.10 moved three Settings pages and went out without a word (Oleh, 2026-11-10: the app is on other
/// people's Macs). The lines here are for whoever knew the previous version; the full list is in
/// `docs/release-notes/` and goes to the release page and Sparkle's window (scripts/release.sh).
enum WhatsNew {
    /// Changes with a release that has something to say; a release without news keeps the old value and shows nothing.
    static let version = "0.14"

    static var items: [String] {
        [String(localized: "Новый модуль «Скиллы»: все скиллы и плагины Claude Code, Codex, Cursor и Gemini CLI с проверкой безопасности и объяснением оценки. Включите его в Настройках → «Что показывать»."),
         String(localized: "Скилл можно поставить другому агенту, выключить, убрать и вернуть из журнала, а новую версию — сравнить построчно перед обновлением."),
         String(localized: "Скиллы из репозиториев GitHub: добавьте источник или найдите его через «Найти источники…» — скиллы скачиваются, проверяются и обновляются вместе с источником."),
         String(localized: "Жалобы, блок-лист, политика установки, AI-проверка по кнопке и уведомления о скиллах, изменённых не через каталог."),
         String(localized: "Уведомление «агент мог застрять» не приходит, пока сессия ждёт одну долгую команду: на неё даётся час.")]
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
