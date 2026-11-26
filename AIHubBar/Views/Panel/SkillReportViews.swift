import AppKit
import SwiftUI

// Complaints and the block list on a skill's card (SkillReports). A complaint is kept on this Mac; the buttons under it
// open a GitHub page with the text filled in, and the person decides there whether to send it.

extension SkillCatalog.ReportReason {
    var title: String {
        switch self {
        case .malicious: String(localized: "Похож на вредоносный")
        case .misleading: String(localized: "Делает не то, что описано")
        case .broken: String(localized: "Не работает")
        case .license: String(localized: "Лицензия или авторство")
        case .falseAlarm: String(localized: "Проверка ошиблась")
        case .other: String(localized: "Другое")
        }
    }
}

/// «В блок-листе» above everything else on the card.
struct SkillBlockBanner: View {
    @Environment(SkillStore.self) private var skills
    let card: SkillCatalog.Card
    @State private var block: SkillCatalog.Block?

    var body: some View {
        Group {
            if card.row.isBlocked {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "nosign").foregroundStyle(.red)
                        Text(block?.isThisVersion == true ? "В блок-листе: эта версия" : "В блок-листе: все версии").scaledFont(.caption, weight: .semibold)
                        Spacer(minLength: 4)
                        Button("Снять блок") { Task { await skills.unblock(card.row.id) } }.controlSize(.small)
                    }
                    if let reason = block?.reason, !reason.isEmpty {
                        Text(verbatim: reason).scaledFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(card.row.isInstalled ? "Каталог не установит и не обновит его. Он всё ещё установлен — выключите или уберите его ниже." : "Каталог не установит и не обновит его.")
                        .scaledFont(.caption2).foregroundStyle(card.row.isInstalled ? Color.red : Color.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.1)))
            }
        }
        .task(id: "\(card.row.id)-\(card.row.isBlocked)") { block = card.row.isBlocked ? await skills.blockOf(card.row.id) : nil }
    }
}

/// «Жалоба и блок»: a complaint with a reason and words, an optional block, and the complaints kept so far.
struct SkillReportBox: View {
    @Environment(SkillStore.self) private var skills
    let card: SkillCatalog.Card
    private enum Form { case report, block }
    private enum BlockChoice: Hashable { case none, thisVersion, everyVersion }
    @State private var form: Form?
    @State private var reason = SkillCatalog.ReportReason.malicious
    @State private var details = ""
    @State private var blockChoice = BlockChoice.none
    @State private var reports: [SkillCatalog.Report] = []
    @State private var copied: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Жалоба и блок").scaledFont(.caption, weight: .semibold).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer(minLength: 4)
                if form == nil {
                    Button("Пожаловаться…") { open(.report) }
                    if !card.row.isBlocked { Button("Заблокировать…") { open(.block) } }
                }
            }
            .controlSize(.small)
            .scaledFont(.caption)
            if let form { formView(form) }
            ForEach(reports) { report in reportRow(report) }
        }
        .task(id: "\(card.row.id)-\(skills.marksVersion)") { reports = await skills.reports(of: card.row) }
        .onChange(of: card.row.id) { form = nil }
    }

    private func open(_ which: Form) {
        form = which
        details = ""
        reason = card.assessment.verdict == .safe ? .misleading : .malicious
        blockChoice = which == .block ? .everyVersion : .none
    }

    @ViewBuilder
    private func formView(_ which: Form) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if which == .report {
                Text("Что не так").scaledFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
                FlowRow(spacing: 4) {
                    ForEach(SkillCatalog.ReportReason.allCases, id: \.self) { item in
                        Button { reason = item } label: {
                            Text(item.title)
                                .scaledFont(.caption2, weight: reason == item ? .semibold : .regular)
                                .foregroundStyle(reason == item ? Color.accentColor : Color.primary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(reason == item ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            TextField(which == .report ? "Что вы заметили: какой файл, что он делает" : "Почему (необязательно)", text: $details, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(which == .report ? 2...6 : 1...3)
                .scaledFont(.caption)
            Picker("Блок", selection: $blockChoice) {
                if which == .report { Text("Не блокировать").tag(BlockChoice.none) }
                Text("Блокировать эту версию").tag(BlockChoice.thisVersion)
                Text("Блокировать все версии").tag(BlockChoice.everyVersion)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            if which == .report {
                Text("Жалоба сохранится только на этом Mac. Отправить её автору или в AI Hub Bar можно потом — на GitHub, где вы сами решите, отправлять ли.")
                    .scaledFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Отмена") { form = nil }
                Button(which == .report ? "Сохранить жалобу" : "Заблокировать") { Task { await save(which) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(which == .block && blockChoice == .none)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func save(_ which: Form) async {
        let (id, text, chosen, why) = (card.row.id, details, blockChoice, reason)
        if which == .report { _ = await skills.report(id, reason: why, details: text) }
        if chosen != .none { await skills.block(id, everyVersion: chosen == .everyVersion, reason: which == .report ? why.title : text) }
        form = nil
    }

    private func reportRow(_ report: SkillCatalog.Report) -> some View {
        let repository = SkillCatalog.githubRepository(card.row.homepage)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble").foregroundStyle(.orange)
                Text(report.reason.title).scaledFont(.caption, weight: .medium)
                Text(verbatim: ISO8601DateFormatter.flexible(report.createdAt)?.formatted(date: .abbreviated, time: .shortened) ?? report.createdAt)
                    .scaledFont(.caption2).foregroundStyle(.secondary)
                if report.contentHash != card.row.contentHash { Text("о прежней версии").scaledFont(.caption2).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                Button { Task { await skills.deleteReport(report.id) } } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Удалить жалобу"))
            }
            if !report.details.isEmpty {
                Text(verbatim: report.details).scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 8) {
                Button(report.sentTo.contains("author") ? "Автору на GitHub ✓" : "Автору на GitHub") {
                    if let repository { send(report, to: "author", url: Self.authorIssue(repository, report: report, card: card)) }
                }
                .disabled(repository == nil)
                .help(repository == nil ? String(localized: "Скилл не указывает свой репозиторий на GitHub") : String(localized: "Откроется страница новой задачи с текстом жалобы — отправите её вы сами"))
                Button(report.sentTo.contains("aihubbar") ? "В AI Hub Bar ✓" : "В AI Hub Bar") {
                    send(report, to: "aihubbar", url: Self.aiHubBarIssue(report, card: card))
                }
                .help(String(localized: "Откроется форма на GitHub AI Hub Bar — отправите её вы сами"))
                Button(copied == report.id ? "Скопировано" : "Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Feedback.redacted(SkillCatalog.reportText(report, card: card)), forType: .string)
                    copied = report.id
                }
            }
            .controlSize(.small)
            .scaledFont(.caption)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.07)))
    }

    private func send(_ report: SkillCatalog.Report, to place: String, url: URL) {
        NSWorkspace.shared.open(url)
        Task { await skills.markSent(report.id, to: place) }
    }

    /// GitHub refuses too long a link (414): the person's words are cut to fit.
    private static func short(_ text: String) -> String { text.count > 1500 ? String(text.prefix(1500)) + "…" : text }

    static func authorIssue(_ repository: URL, report: SkillCatalog.Report, card: SkillCatalog.Card) -> URL {
        var shortened = report
        shortened.details = short(Feedback.redacted(report.details))
        var components = URLComponents(url: repository.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "title", value: "\(card.row.name): \(report.reason.formOption)"),
            URLQueryItem(name: "body", value: SkillCatalog.reportText(shortened, card: card) + "\n\n— found with AI Hub Bar's Skills Catalog"),
        ]
        return components.url!
    }

    static func aiHubBarIssue(_ report: SkillCatalog.Report, card: SkillCatalog.Card) -> URL {
        let facts = SkillCatalog.reportFacts(card)
        return Feedback.issueURL(.skill, title: "Skill: \(card.row.name)", fields: [
            "skill": facts.skill, "hash": facts.hash, "verdict": facts.verdict, "reason": report.reason.formOption,
            "details": short(Feedback.redacted(report.details)), "version": Feedback.appVersion,
        ])
    }
}
