import SwiftUI

/// What the person's model picked for a request in plain words (`SkillAsk`). The picks come from what the catalog and
/// the index already hold; the model's lines on why are untrusted text and say nothing about safety.
struct SkillAskResultsView: View {
    @Environment(SkillStore.self) private var skills
    let question: String
    let picks: [SkillAsk.Pick]
    var openSkill: (Int) -> Void
    var openRepo: (String) -> Void
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                Text(verbatim: String(localized: "AI подобрал для «\(question)»")).scaledFont(.caption, weight: .semibold).lineLimit(2)
                Spacer(minLength: 4)
                Button("Обычный поиск", action: close).controlSize(.small).scaledFont(.caption)
            }
            SkillTranslateBar(texts: picks.map(\.item.description))
            if picks.isEmpty {
                Text("Модель не нашла ничего подходящего в каталоге и открытых источниках.").scaledFont(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(picks) { pick in row(pick) }
                }
            }
            Text("Подобрано моделью из того, что уже есть в каталоге и индексе. Её пояснения — недоверенный текст: они не влияют на оценку безопасности.")
                .scaledFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ pick: SkillAsk.Pick) -> some View {
        Button {
            switch pick.item.kind {
            case .skill(let id): openSkill(id)
            case .repo(let slug): openRepo(slug)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let verdict = pick.item.verdict {
                        SkillVerdictBadge(verdict: verdict)
                    } else {
                        Image(systemName: "globe").scaledFont(.caption2).foregroundStyle(.secondary)
                    }
                    Text(verbatim: pick.item.name).scaledFont(.callout, weight: .medium).lineLimit(1).truncationMode(.middle)
                    if isRepo(pick) { Text("открытый источник").scaledFont(.caption2).foregroundStyle(.secondary) }
                }
                if !pick.item.description.isEmpty {
                    Text(verbatim: skills.shown(pick.item.description)).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !pick.why.isEmpty {
                    Label { Text(verbatim: pick.why) } icon: { Image(systemName: "sparkles") }
                        .scaledFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isRepo(_ pick: SkillAsk.Pick) -> Bool {
        if case .repo = pick.item.kind { return true }
        return false
    }
}

/// «Перевести описания»: the person's model translates the descriptions shown into the interface language, on request.
/// Translations are remembered; «Оригиналы» shows the texts as their authors wrote them.
struct SkillTranslateBar: View {
    @Environment(SkillStore.self) private var skills
    let texts: [String]
    @State private var available: String?
    @State private var failure: String?

    var body: some View {
        let missing = skills.untranslated(texts)
        let hasTranslations = texts.contains { skills.translated[$0] != nil }
        let busy = texts.contains { skills.translating.contains($0) }
        Group {
            if !missing.isEmpty || hasTranslations || busy || failure != nil {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        if busy {
                            ProgressView().controlSize(.small)
                            Text("Перевожу…").scaledFont(.caption2).foregroundStyle(.secondary)
                        } else if !missing.isEmpty {
                            Button {
                                Task { await translate(missing) }
                            } label: {
                                Label(texts.count == 1 ? String(localized: "Перевести") : String(localized: "Перевести описания: \(min(missing.count, SkillAsk.maxTexts))"),
                                      systemImage: "character.bubble")
                            }
                            .buttonStyle(.borderless)
                            .disabled(available == nil)
                            .help(available == nil
                                  ? String(localized: "Нужен Claude Code на этом Mac или ключ Anthropic в Настройках → «Сервисы AI».")
                                  : String(localized: "Описания уйдут в вашу модель: Claude Code по подписке или Anthropic API с вашим ключом"))
                        }
                        if hasTranslations {
                            Toggle(isOn: Binding(get: { skills.showsOriginals }, set: { skills.showsOriginals = $0 })) { Text("Оригиналы") }
                                .toggleStyle(.checkbox)
                                .help(String(localized: "Показывать описания так, как их написали авторы"))
                            if !skills.showsOriginals { Text("Переведено AI").scaledFont(.caption2).foregroundStyle(.tertiary) }
                        }
                        Spacer(minLength: 0)
                    }
                    .scaledFont(.caption)
                    if let failure { Text(verbatim: failure).scaledFont(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
        .task(id: texts) {
            await skills.loadTranslations(texts)
            available = await SkillReviewer.available()
        }
    }

    private func translate(_ texts: [String]) async {
        failure = nil
        if case .failure(let refusal) = await skills.translate(texts) { failure = SkillAskText.failure(refusal) }
    }
}

@MainActor
enum SkillAskText {
    static func failure(_ refusal: SkillCatalog.Refusal) -> String {
        switch refusal.code {
        case "refusal": String(localized: "Модель отказалась отвечать на этот запрос.")
        case "timeout": String(localized: "Модель не ответила вовремя.")
        default: SkillAIReviewBox.text(refusal)
        }
    }
}
