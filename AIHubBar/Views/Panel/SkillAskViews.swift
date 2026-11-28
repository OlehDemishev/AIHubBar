import SwiftUI

/// What the person's model picked for a request in plain words (`SkillAsk`). The picks come from what the catalog and
/// the index already hold; the model's lines on why are untrusted text and say nothing about safety.
struct SkillAskResultsView: View {
    @Environment(SkillStore.self) private var skills
    let question: String
    /// Set for «Скиллы для проекта»: the project's name and what was read from its folder.
    var project: String?
    var stack: SkillProjectStack?
    /// When the model made these picks, and whether they were remembered rather than asked for now.
    var pickedAt: String?
    var remembered = false
    /// «Подобрать заново»: asks the model again for the project.
    var redo: (() -> Void)?
    let picks: [SkillAsk.Pick]
    var openSkill: (Int) -> Void
    var openRepo: (String) -> Void
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                Text(verbatim: project.map { String(localized: "AI подобрал для проекта «\($0)»") } ?? String(localized: "AI подобрал для «\(question)»"))
                    .scaledFont(.caption, weight: .semibold).lineLimit(2)
                Spacer(minLength: 4)
                Button("Обычный поиск", action: close).controlSize(.small).scaledFont(.caption)
            }
            if let stack, !stack.isEmpty {
                Text(verbatim: String(localized: "Что видно в папке: \(Self.stackLine(stack))"))
                    .scaledFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if remembered, let when = pickedAt.flatMap(ISO8601DateFormatter.flexible) {
                HStack(spacing: 6) {
                    Text(verbatim: String(localized: "Подобрано \(when.formatted(date: .abbreviated, time: .shortened)), проект с тех пор не изменился"))
                        .scaledFont(.caption2).foregroundStyle(.secondary)
                    if let redo {
                        Button("Подобрать заново", action: redo).buttonStyle(.borderless).scaledFont(.caption2)
                    }
                    Spacer(minLength: 0)
                }
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

    /// Languages and tools, then up to eight packages: what was sent, in short.
    static func stackLine(_ stack: SkillProjectStack) -> String {
        var parts = stack.languages + stack.tools
        if !stack.packages.isEmpty {
            parts.append(stack.packages.prefix(8).joined(separator: ", ") + (stack.packages.count > 8 ? "…" : ""))
        }
        return parts.joined(separator: ", ")
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
    @AppStorage(StorageKey.skillsAutoTranslate) private var autoTranslate = false
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
            // «Переводить описания сразу»: once per set of texts; a failure waits for a click.
            let missing = skills.untranslated(texts)
            if autoTranslate, available != nil, failure == nil, !missing.isEmpty {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                await translate(missing)
            }
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
        case "empty-project": String(localized: "В папке проекта не нашлось ни кода, ни файлов с зависимостями.")
        default: SkillAIReviewBox.text(refusal)
        }
    }
}

/// «Перевести инструкции»: a skill's SKILL.md into the interface language by the person's model, only on a click.
struct SkillDocumentTranslateBar: View {
    @Environment(SkillStore.self) private var skills
    let text: String
    @State private var available: String?
    @State private var failure: String?

    var body: some View {
        let sent = SkillAsk.documentPart(text)
        let hasTranslation = skills.translated[sent] != nil
        let busy = skills.translating.contains(sent)
        Group {
            if hasTranslation || busy || failure != nil || SkillAsk.needsTranslation(String(text.prefix(2000)), to: SkillReviewer.languageCode) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        if busy {
                            ProgressView().controlSize(.small)
                            Text("Перевожу инструкции…").scaledFont(.caption2).foregroundStyle(.secondary)
                        } else if !hasTranslation {
                            Button {
                                Task { await translate() }
                            } label: {
                                Label("Перевести инструкции", systemImage: "character.bubble")
                            }
                            .buttonStyle(.borderless)
                            .disabled(available == nil)
                            .help(available == nil
                                  ? String(localized: "Нужен Claude Code на этом Mac или ключ Anthropic в Настройках → «Сервисы AI».")
                                  : String(localized: "Текст SKILL.md уйдёт в вашу модель: Claude Code по подписке или Anthropic API с вашим ключом. Перевод запоминается."))
                        } else {
                            Toggle(isOn: Binding(get: { skills.showsOriginals }, set: { skills.showsOriginals = $0 })) { Text("Оригиналы") }
                                .toggleStyle(.checkbox)
                                .help(String(localized: "Показывать описания так, как их написали авторы"))
                            if !skills.showsOriginals { Text("Инструкции переведены AI").scaledFont(.caption2).foregroundStyle(.tertiary) }
                        }
                        Spacer(minLength: 0)
                    }
                    .scaledFont(.caption)
                    if let failure { Text(verbatim: failure).scaledFont(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
        .task(id: sent) {
            failure = nil
            await skills.loadTranslations([sent])
            available = await SkillReviewer.available()
        }
    }

    private func translate() async {
        failure = nil
        if case .failure(let refusal) = await skills.translateDocument(text) { failure = SkillAskText.failure(refusal) }
    }
}

/// The translated SKILL.md, as plain text: the model's words, so the findings' lines are shown on the original only.
struct SkillTranslatedDocumentView: View {
    let text: String
    let isPart: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SKILL.md — перевод AI")
                .scaledFont(.caption, weight: .semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.08))
            ScrollView {
                Text(verbatim: text)
                    .scaledFont(.caption2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
            Text(isPart ? "Переведено только начало файла. Находки проверки отмечены в оригинале." : "Находки проверки отмечены в оригинале.")
                .scaledFont(.caption2).foregroundStyle(.secondary).padding(4)
        }
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
    }
}
