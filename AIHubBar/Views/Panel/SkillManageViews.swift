import AppKit
import SwiftUI

// Installing, removing, switching, putting back and updating skills from the panel (SkillManage): what a step will do
// is shown first, a «Проверить» or «Опасно» skill needs a ticked box, and every step lands in the journal.

/// The words for a refused step.
enum SkillRefusalText {
    static func text(_ refusal: SkillCatalog.Refusal) -> String {
        switch refusal.code {
        case "missing": String(localized: "Папки скилла нет или её не удаётся прочитать.")
        case "changed": String(localized: "Скилл изменился после проверки и проверен заново — посмотрите ещё раз.")
        case "confirmation": String(localized: "Сначала подтвердите, что прочитали находки.")
        case "exists": String(localized: "В папке агента уже есть папка с таким именем. Её не тронули.")
        case "not-yours": String(localized: "Это не скилл из ваших папок агентов: каталог его не трогает.")
        case "state": String(localized: "Это уже сделано.")
        case "path": String(localized: "В скилле есть файл с недопустимым путём.")
        case "plugin": String(localized: "Плагины ставятся через сам агент: каталог копирует только скиллы.")
        case "no-skill-md": String(localized: "В папке нет SKILL.md: это не скилл.")
        case "too-large": String(localized: "Скилл слишком большой: проверены не все его файлы.")
        case "already": String(localized: "Уже установлен для этого агента.")
        case "name": String(localized: "У скилла нет имени, годного для папки.")
        case "blocked": String(localized: "Скилл в вашем блок-листе: каталог его не ставит.")
        case "policy-dangerous": String(localized: "Ваша политика не позволяет ставить опасные скиллы (Настройки → Скиллы).")
        case "policy-review": String(localized: "Ваша политика разрешает ставить только безопасные скиллы (Настройки → Скиллы).")
        case "policy-trusted": String(localized: "Ваша политика разрешает ставить скиллы только доверенных авторов (Настройки → Скиллы).")
        default: String(localized: "Не получилось: \(refusal.code)")
        }
    }
}

extension SkillCatalog.LogRow {
    var actionTitle: String {
        switch action {
        case "install": String(localized: "Установлен")
        case "update": String(localized: "Обновлён")
        case "remove": String(localized: "Убран")
        case "restore": String(localized: "Возвращён")
        case "on": String(localized: "Включён")
        case "off": String(localized: "Выключен")
        default: action
        }
    }

    var symbol: String {
        switch action {
        case "install": "plus.circle"
        case "update": "arrow.up.circle"
        case "remove": "minus.circle"
        case "restore": "arrow.uturn.backward.circle"
        case "on": "checkmark.circle"
        default: "pause.circle"
        }
    }
}

/// «Где установлен» with what can be done there, «Установить для…», and a newer version when there is one.
struct SkillManageBox: View {
    @Environment(SkillStore.self) private var skills
    let card: SkillCatalog.Card
    @State private var plan: SkillCatalog.Plan?
    @State private var message: String?
    @State private var failure: String?
    /// The place whose «Убрать» waits for a second click.
    @State private var removing: String?
    @State private var busy = false

    private var update: SkillCatalog.Update? {
        skills.summary.updates.first { update in card.places.contains { $0.installPath == update.installPath } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(card.places.isEmpty ? "Не установлен" : "Где установлен")
                    .scaledFont(.caption, weight: .semibold).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer(minLength: 4)
                if card.row.kind == "skill" {
                    Menu {
                        ForEach(SkillAgent.allCases, id: \.self) { agent in
                            Button(agent.title) { Task { await planInstall(agent) } }
                        }
                    } label: {
                        Label("Установить для…", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .scaledFont(.caption)
                    .fixedSize()
                    .disabled(busy || card.isMissing)
                }
            }
            ForEach(Array(card.places.enumerated()), id: \.offset) { index, place in
                placeRow(place, isFirstOfFolder: !card.places.prefix(index).contains { $0.installPath == place.installPath })
            }
            if let update, plan == nil { updateBox(update) }
            if let plan { SkillPlanView(plan: plan, busy: busy, confirm: { acknowledged in Task { await carryOut(plan, acknowledged) } }, cancel: { self.plan = nil }) }
            if let message { Text(verbatim: message).scaledFont(.caption).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true) }
            if let failure { Text(verbatim: failure).scaledFont(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .onChange(of: card.row.id) {
            plan = nil
            removing = nil
        }
    }

    @ViewBuilder
    private func placeRow(_ place: SkillPlace, isFirstOfFolder: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: place.agent.title).scaledFont(.caption, weight: .medium)
                Text(place.scope == "project" ? String(localized: "проект \(place.project ?? "")") : SkillCardView.scope(place.scope))
                    .scaledFont(.caption2).foregroundStyle(.secondary)
                if !place.isEnabled { Text("выключен").scaledFont(.caption2).foregroundStyle(.orange) }
                Spacer(minLength: 4)
                // Several agents reading one folder share it: its switches are shown once.
                if place.scope == "user", isFirstOfFolder {
                    Toggle("Включён", isOn: Binding(get: { place.isEnabled }, set: { on in Task { await run { await skills.setEnabled(place.installPath, on) } } }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(busy)
                        .help(place.isEnabled ? String(localized: "Выключить: папка переедет рядом, в «.disabled»") : String(localized: "Включить"))
                    Button { removing = place.installPath } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                        .help(String(localized: "Убрать из папки агента"))
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: place.installPath)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Показать в Finder"))
            }
            if removing == place.installPath, isFirstOfFolder {
                HStack(spacing: 6) {
                    Text("Папка уйдёт в резервные копии каталога, вернуть её можно из журнала.")
                        .scaledFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Убрать", role: .destructive) {
                        removing = nil
                        Task { await run { await skills.remove(place.installPath) } }
                    }
                    Button("Отмена") { removing = nil }
                }
                .controlSize(.small)
                .scaledFont(.caption)
            }
        }
    }

    private func updateBox(_ update: SkillCatalog.Update) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(Color.accentColor)
                Text("Есть новая версия").scaledFont(.caption, weight: .semibold)
                SkillVerdictBadge(verdict: update.verdict)
                Spacer(minLength: 4)
                Button("Обновить…") { Task { await planUpdate(update) } }
                    .controlSize(.small)
                    .disabled(busy)
            }
            Text("Источник: \(PathText.tilde(update.origin))").scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if update.edited {
                Text("Установленную копию меняли вручную: обновление заменит эти правки (прежняя копия останется в резервных).")
                    .scaledFont(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            SkillDiffView(installPath: update.installPath)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.08)))
    }

    private func planInstall(_ agent: SkillAgent) async {
        (message, failure) = (nil, nil)
        busy = true
        defer { busy = false }
        switch await skills.planInstall(card.row.id, for: agent) {
        case .success(let value): plan = value
        case .failure(let refusal): failure = SkillRefusalText.text(refusal)
        }
    }

    private func planUpdate(_ update: SkillCatalog.Update) async {
        (message, failure) = (nil, nil)
        busy = true
        defer { busy = false }
        switch await skills.planUpdate(update.installPath) {
        case .success(let value): plan = value
        case .failure(let refusal): failure = SkillRefusalText.text(refusal)
        }
    }

    private func carryOut(_ plan: SkillCatalog.Plan, _ acknowledged: Bool) async {
        await run {
            if plan.replaces {
                await skills.update(plan.target, contentHash: plan.contentHash, acknowledged: acknowledged)
            } else if let agent = plan.agent {
                await skills.install(plan.skillID, for: agent, contentHash: plan.contentHash, acknowledged: acknowledged)
            } else {
                .failure(.missing)
            }
        }
        if failure == nil { self.plan = nil }
    }

    /// Runs a step; says where it went or why it didn't.
    private func run(_ step: () async -> SkillStore.Outcome<SkillCatalog.Done>) async {
        (message, failure) = (nil, nil)
        busy = true
        defer { busy = false }
        switch await step() {
        case .success(let done): message = String(localized: "Готово: \(PathText.tilde(done.installPath)). Шаг записан в журнал.")
        case .failure(let refusal): failure = SkillRefusalText.text(refusal)
        }
    }
}

/// What a step will do, shown before anything is written: where the copy goes, who else reads that folder, the
/// verdict and the findings, what is left out — and, for a skill that is not safe, a box to tick.
struct SkillPlanView: View {
    let plan: SkillCatalog.Plan
    var busy = false
    let confirm: (Bool) -> Void
    let cancel: () -> Void
    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).scaledFont(.callout, weight: .semibold).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: PathText.tilde(plan.target)).scaledFont(.caption2).monospaced().foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            if !plan.alsoSeenBy.isEmpty {
                Text("Эту папку читают и: \(plan.alsoSeenBy.map(\.title).joined(separator: ", "))").scaledFont(.caption2).foregroundStyle(.secondary)
            }
            if plan.changed {
                Text("Папка изменилась после прошлой проверки — ниже результат новой.").scaledFont(.caption2).foregroundStyle(.orange)
            }
            HStack(spacing: 6) {
                SkillVerdictBadge(verdict: plan.verdict)
                Text("Риск \(plan.riskScore) из 100").scaledFont(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(plan.findings.prefix(5).enumerated()), id: \.offset) { _, finding in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Circle().fill(finding.severity.color).frame(width: 6, height: 6)
                    Text(SkillRuleText.title(finding.rule)).scaledFont(.caption)
                    if !finding.file.isEmpty { Text(verbatim: SkillCardView.place(finding)).scaledFont(.caption2).monospaced().foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            if plan.findings.count > 5 {
                Text("и ещё \(plan.findings.count - 5)").scaledFont(.caption2).foregroundStyle(.secondary)
            }
            if !plan.leftOut.isEmpty {
                Text("Не копируются (ссылки и папки зависимостей): \(plan.leftOut.joined(separator: ", "))")
                    .scaledFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let blocked = plan.blocked {
                Text(SkillRefusalText.text(SkillCatalog.Refusal(code: blocked))).scaledFont(.caption).foregroundStyle(.orange)
                HStack { Spacer(); Button("Закрыть", action: cancel) }.controlSize(.small)
            } else {
                if plan.needsAck {
                    Toggle(isOn: $acknowledged) {
                        Text(plan.verdict == .dangerous ? "Находки прочитаны: понимаю, что скилл похож на атаку" : "Находки прочитаны")
                            .scaledFont(.caption)
                    }
                    .toggleStyle(.checkbox)
                }
                HStack(spacing: 8) {
                    if plan.replaces { Text("Прежняя копия останется в резервных.").scaledFont(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Отмена", action: cancel)
                    Button(plan.replaces ? "Обновить" : "Установить") { confirm(acknowledged) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || (plan.needsAck && !acknowledged))
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(plan.verdict.color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(plan.verdict.color.opacity(0.3)))
    }

    private var title: String {
        if plan.replaces { return String(localized: "Обновить «\(plan.name)»") }
        return String(localized: "Установить «\(plan.name)» для \(plan.agent?.title ?? "")")
    }
}

/// What an update would change, file by file, folded until asked for.
struct SkillDiffView: View {
    @Environment(SkillStore.self) private var skills
    let installPath: String
    @State private var shows = false
    @State private var files: [SkillCatalog.FileDiff]?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                shows.toggle()
                if shows, files == nil { Task { files = await skills.diff(installPath) } }
            } label: {
                HStack(spacing: 3) {
                    Text("Что изменится").scaledFont(.caption, weight: .medium)
                    Image(systemName: shows ? "chevron.up" : "chevron.down").scaledFont(.caption2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if shows {
                if let files {
                    ForEach(files) { file in fileView(file) }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private func fileView(_ file: SkillCatalog.FileDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(verbatim: file.path).scaledFont(.caption, weight: .semibold).monospaced()
                Text(Self.status(file.status)).scaledFont(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.08))
            if file.notShown {
                Text("Не текст или слишком длинный, чтобы сравнить построчно.").scaledFont(.caption2).foregroundStyle(.secondary).padding(4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: Self.mark(line.kind) + " " + (line.text.isEmpty ? " " : line.text))
                                .scaledFont(.caption2)
                                .monospaced()
                                .foregroundStyle(line.kind == .gap ? Color.secondary : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(line.kind == .added ? Color.green.opacity(0.15) : line.kind == .removed ? Color.red.opacity(0.15) : .clear)
                        }
                    }
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
    }

    static func mark(_ kind: SkillCatalog.DiffLine.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        case .same: " "
        case .gap: "…"
        }
    }

    static func status(_ status: SkillCatalog.FileDiff.Status) -> String {
        switch status {
        case .added: String(localized: "новый")
        case .removed: String(localized: "удалён")
        case .changed: String(localized: "изменён")
        }
    }
}

/// Everything the catalog did in the agents' folders, newest first, with «Вернуть» where it can be undone.
struct SkillJournalView: View {
    @Environment(SkillStore.self) private var skills
    var openSkill: (Int) -> Void = { _ in }
    @State private var rows: [SkillCatalog.LogRow] = []
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkillChangesView(openSkill: openSkill)
            journal
        }
    }

    private var journal: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Журнал").scaledFont(.caption, weight: .semibold).foregroundStyle(.secondary).textCase(.uppercase)
            if rows.isEmpty {
                Text("Каталог ещё ничего не менял в папках агентов.").scaledFont(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: row.symbol).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(row.actionTitle).scaledFont(.caption, weight: .medium)
                            Text(verbatim: row.name).scaledFont(.caption)
                            if let verdict = row.verdict { SkillVerdictBadge(verdict: verdict) }
                            if row.acknowledged { Image(systemName: "checkmark.seal").scaledFont(.caption2).foregroundStyle(.orange).help(String(localized: "Установлен после прочтения находок")) }
                        }
                        Text(verbatim: Self.line(row)).scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if row.canRestore {
                        Button("Вернуть") {
                            Task {
                                if case .failure(let refusal) = await skills.restore(row.id) { failure = SkillRefusalText.text(refusal) } else { failure = nil }
                                rows = await skills.journal()
                            }
                        }
                        .controlSize(.small)
                    } else if row.restored {
                        Text("возвращено").scaledFont(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let failure { Text(verbatim: failure).scaledFont(.caption).foregroundStyle(.red) }
        }
        .task(id: skills.marksVersion) { rows = await skills.journal() }
    }


    static func line(_ row: SkillCatalog.LogRow) -> String {
        let when = ISO8601DateFormatter.flexible(row.at).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? row.at
        let agents = (row.agent ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.map { SkillAgent(rawValue: $0)?.title ?? $0 }.joined(separator: ", ")
        return [when, agents, PathText.tilde(row.installPath)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// «Замечено вне каталога»: skills that appeared, changed or left without the catalog, newest first.
struct SkillChangesView: View {
    @Environment(SkillStore.self) private var skills
    /// Opens a skill's card in the «Скиллы» section.
    var openSkill: (Int) -> Void = { _ in }
    @State private var events: [SkillCatalog.Event] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Замечено вне каталога").scaledFont(.caption, weight: .semibold).foregroundStyle(.secondary).textCase(.uppercase)
            if events.isEmpty {
                Text("Пока ничего: скиллы появлялись и менялись только через каталог.").scaledFont(.caption).foregroundStyle(.secondary)
            }
            ForEach(events.prefix(30)) { event in
                Button { if let id = event.skillID { openSkill(id) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: Self.symbol(event.event)).foregroundStyle(event.verdict == .dangerous ? Color.red : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(Self.title(event.event)).scaledFont(.caption, weight: event.seen ? .regular : .semibold)
                                Text(verbatim: event.name).scaledFont(.caption)
                                if let verdict = event.verdict { SkillVerdictBadge(verdict: verdict) }
                                if event.isTrusted { Image(systemName: "checkmark.seal").scaledFont(.caption2).foregroundStyle(.secondary) }
                            }
                            Text(verbatim: ISO8601DateFormatter.flexible(event.at)?.formatted(date: .abbreviated, time: .shortened) ?? event.at)
                                .scaledFont(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(event.skillID == nil)
            }
        }
        .task(id: skills.lastUpdated) {
            events = await skills.events()
            if events.contains(where: { !$0.seen }) { await skills.markEventsSeen() }
        }
    }

    static func title(_ event: String) -> String {
        switch event {
        case "appeared": String(localized: "Появился")
        case "changed": String(localized: "Изменился")
        default: String(localized: "Исчез")
        }
    }

    static func symbol(_ event: String) -> String {
        switch event {
        case "appeared": "plus.circle"
        case "changed": "pencil.circle"
        default: "minus.circle"
        }
    }
}

/// «Доверять автору»: trust quiets notifications about the author's skills and lets «только доверенные» install them.
/// The author is what the skill says about itself, so the button says so.
struct SkillTrustButton: View {
    @Environment(SkillStore.self) private var skills
    let row: SkillCatalog.Row

    var body: some View {
        if let author = SkillCatalog.authorToTrust(row) {
            if row.isTrusted {
                Button { Task { await skills.distrust(author) } } label: {
                    Label("Доверенный", systemImage: "checkmark.seal.fill")
                }
                .help(String(localized: "Нажмите, чтобы больше не доверять «\(author)»"))
                .buttonStyle(.borderless)
                .scaledFont(.caption2)
            } else {
                Button { Task { await skills.trust(author) } } label: {
                    Label("Доверять «\(author)»", systemImage: "checkmark.seal")
                }
                .help(String(localized: "Автор указан в самом скилле и не проверен. Доверие только приглушает уведомления и не меняет оценку."))
                .buttonStyle(.borderless)
                .scaledFont(.caption2)
            }
        }
    }
}
