import SwiftUI

/// «AI-проверка» on a skill's card: a language model reads the skill on request (SkillReview). Its answer is untrusted
/// text too: it is shown as plain text and can only make the verdict stricter.
struct SkillAIReviewBox: View {
    @Environment(SkillStore.self) private var skills
    let card: SkillCatalog.Card
    @State private var review: SkillReview.Result?
    @State private var available: String?
    @State private var failure: String?
    @State private var confirming = false

    private var isReviewing: Bool { skills.reviewing.contains(card.row.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("AI-проверка").scaledFont(.caption, weight: .semibold).foregroundStyle(.secondary).textCase(.uppercase)
                if let review { SkillVerdictBadge(verdict: review.verdict) }
                Spacer(minLength: 4)
                if review != nil, !isReviewing, !confirming {
                    Button("Проверить заново") { confirming = true }.controlSize(.small).scaledFont(.caption).disabled(available == nil)
                }
            }
            if isReviewing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Claude читает скилл. Это может занять несколько минут.").scaledFont(.caption).foregroundStyle(.secondary)
                }
            } else if confirming || review == nil {
                ask
            }
            if let review, !isReviewing { result(review) }
            if let failure { Text(verbatim: failure).scaledFont(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        .task(id: "\(card.row.id)-\(card.row.contentHash)-\(skills.marksVersion)") {
            review = await skills.review(of: card.row)
            available = await SkillReviewer.available()
        }
        .onChange(of: card.row.id) {
            failure = nil
            confirming = false
        }
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(available == "api"
                 ? "Файлы скилла уйдут в Anthropic API с вашим ключом из Настроек → «Сервисы AI». Модель не получает никаких инструментов, из скилла ничего не запускается."
                 : "Файлы скилла уйдут в Claude через Claude Code по вашей подписке — без инструментов, настроек и MCP. Из скилла ничего не запускается.")
                .scaledFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if available == nil {
                Text("Нужен Claude Code на этом Mac или ключ Anthropic в Настройках → «Сервисы AI».")
                    .scaledFont(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                if confirming { Button("Отмена") { confirming = false } }
                Button("Попросить Claude проверить") { Task { await start() } }
                    .disabled(available == nil || card.isChanged || card.isMissing)
            }
            .controlSize(.small)
            .scaledFont(.caption)
        }
    }

    private func result(_ review: SkillReview.Result) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: Self.meta(review)).scaledFont(.caption2).foregroundStyle(.secondary)
            if !review.valid {
                Text("Ответ модели не удалось прочитать, поэтому он считается «Проверить».").scaledFont(.caption2).foregroundStyle(.orange)
            }
            if review.incomplete {
                Text("Модель видела не все файлы: часть не текст или не поместилась.").scaledFont(.caption2).foregroundStyle(.secondary)
            }
            if !review.summary.isEmpty {
                Text(verbatim: review.summary).scaledFont(.caption).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(review.findings.enumerated()), id: \.offset) { _, finding in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Circle().fill(finding.severity.color).frame(width: 6, height: 6)
                        Text(verbatim: finding.title).scaledFont(.caption, weight: .semibold)
                    }
                    if !finding.explanation.isEmpty {
                        Text(verbatim: finding.explanation).scaledFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if !finding.file.isEmpty {
                        Text(verbatim: finding.line > 0 ? "\(finding.file):\(finding.line)" : finding.file).scaledFont(.caption2).monospaced().foregroundStyle(.secondary)
                    }
                }
            }
            Text("Ответ модели — тоже недоверенный текст: он может только сделать оценку строже, но не мягче.")
                .scaledFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func meta(_ review: SkillReview.Result) -> String {
        let when = ISO8601DateFormatter.flexible(review.reviewedAt)?.formatted(date: .abbreviated, time: .shortened) ?? review.reviewedAt
        let via = review.via == "api" ? "Anthropic API" : "Claude Code"
        return "\(review.model) · \(via) · \(when)"
    }

    private func start() async {
        confirming = false
        failure = nil
        switch await skills.requestReview(card.row.id) {
        case .success(let value): review = value
        case .failure(let refusal): failure = Self.text(refusal)
        }
    }

    static func text(_ refusal: SkillCatalog.Refusal) -> String {
        switch refusal.code {
        case "no-reviewer": String(localized: "Нужен Claude Code на этом Mac или ключ Anthropic в Настройках → «Сервисы AI».")
        case "no-claude": String(localized: "Не удалось запустить Claude Code.")
        case "timeout": String(localized: "Claude не ответил за 10 минут.")
        case "refusal": String(localized: "Модель отказалась отвечать на этот скилл. Это само по себе повод присмотреться к нему.")
        case "too-long": String(localized: "Ответ модели оборвался: он вышел слишком длинным.")
        case "bad-key": String(localized: "Ключ Anthropic не подошёл: проверьте его в Настройках → «Сервисы AI».")
        case "network": String(localized: "Нет связи с Anthropic API.")
        case "unreadable": String(localized: "Ответ не удалось прочитать.")
        case "changed": String(localized: "Скилл изменился после проверки. Обновите список и попробуйте снова.")
        default: SkillRefusalText.text(refusal)
        }
    }
}
