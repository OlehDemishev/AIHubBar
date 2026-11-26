import AppKit
import SwiftUI

// «Порядок» in the «Скиллы» section (SkillHousekeeping): names an agent could mix up, the same skill copied into
// several folders, skills nobody used, and named sets.

struct SkillOrderView: View {
    @Environment(SkillStore.self) private var skills
    /// Opens a skill's card.
    var openSkill: (Int) -> Void
    /// Shows the list narrowed to a set.
    var showSet: (String) -> Void
    @State private var order = SkillStore.Order()
    @State private var confirmsAllUnused = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Конфликты имён", hint: "Разные скиллы под одним именем включены для одного агента: он может взять любой из них.", groups: order.conflicts, empty: "Конфликтов нет.") { group in
                groupView(group, showsVersions: true)
            }
            section("Копии", hint: "Один и тот же скилл лежит в нескольких папках: каждую копию придётся обновлять отдельно.", groups: order.duplicates, empty: "Копий нет.") { group in
                groupView(group, showsVersions: false)
            }
            unusedSection
            setsSection
            if let message { Text(verbatim: message).scaledFont(.caption).foregroundStyle(.secondary) }
        }
        .task(id: "\(skills.lastUpdated?.timeIntervalSince1970 ?? 0)-\(skills.marksVersion)") { order = await skills.order() }
    }

    private func title(_ text: LocalizedStringKey, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(text).scaledFont(.caption, weight: .semibold).foregroundStyle(.secondary).textCase(.uppercase)
            if count > 0 { Text(verbatim: "\(count)").scaledFont(.caption2, weight: .semibold).foregroundStyle(.secondary) }
        }
    }

    private func section(_ name: LocalizedStringKey, hint: LocalizedStringKey, groups: [SkillCatalog.Group], empty: LocalizedStringKey,
                         @ViewBuilder row: @escaping (SkillCatalog.Group) -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            title(name, count: groups.count)
            Text(hint).scaledFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if groups.isEmpty { Text(empty).scaledFont(.caption).foregroundStyle(.secondary) }
            ForEach(groups) { row($0) }
        }
    }

    private func groupView(_ group: SkillCatalog.Group, showsVersions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: group.name).scaledFont(.callout, weight: .medium)
                if showsVersions { Text("версий: \(group.versions)").scaledFont(.caption2).foregroundStyle(.orange) }
            }
            ForEach(group.copies) { copy in copyRow(copy) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func copyRow(_ copy: SkillCatalog.Copy) -> some View {
        HStack(spacing: 6) {
            SkillVerdictBadge(verdict: copy.verdict)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: copy.agents.map(\.title).joined(separator: ", ")).scaledFont(.caption)
                Text(verbatim: PathText.tilde(copy.installPath)).scaledFont(.caption2).monospaced().foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if !copy.isEnabled { Text("выключен").scaledFont(.caption2).foregroundStyle(.orange) }
            if copy.scope == "user", copy.isEnabled {
                Button("Выключить") { Task { await switchOff([copy]) } }.controlSize(.small).scaledFont(.caption)
            }
            Button { openSkill(copy.skillID) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .help(String(localized: "Открыть скилл"))
        }
    }

    private var unusedSection: some View {
        let switchable = order.unused.flatMap(\.copies).filter { $0.scope == "user" }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                title("Не использовались 30 дней", count: order.unused.count)
                Spacer(minLength: 4)
                if !switchable.isEmpty {
                    if confirmsAllUnused {
                        Button("Выключить все: \(switchable.count)", role: .destructive) {
                            confirmsAllUnused = false
                            Task { await switchOff(switchable) }
                        }
                        Button("Отмена") { confirmsAllUnused = false }
                    } else {
                        Button("Выключить все…") { confirmsAllUnused = true }
                    }
                }
            }
            .controlSize(.small)
            .scaledFont(.caption)
            Text("По журналам Claude Code и Codex. Выключенный скилл переезжает в соседнюю папку «.disabled» и возвращается одним нажатием.")
                .scaledFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if order.unused.isEmpty { Text("Все включённые скиллы запускались.").scaledFont(.caption).foregroundStyle(.secondary) }
            ForEach(order.unused) { groupView($0, showsVersions: false) }
        }
    }

    private var setsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            title("Наборы", count: order.sets.count)
            Text("Набор собирает скиллы под одним именем: показать их вместе, включить или выключить разом. Добавить скилл в набор можно из его карточки.")
                .scaledFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if order.sets.isEmpty { Text("Наборов пока нет.").scaledFont(.caption).foregroundStyle(.secondary) }
            ForEach(order.sets.keys.sorted { $0.lowercased() < $1.lowercased() }, id: \.self) { name in
                HStack(spacing: 6) {
                    Image(systemName: "square.stack")
                    Text(verbatim: name).scaledFont(.callout)
                    Text("скиллов: \(order.sets[name] ?? 0)").scaledFont(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Показать") { showSet(name) }
                    Menu {
                        Button("Включить все") { Task { await toggle(set: name, true) } }
                        Button("Выключить все") { Task { await toggle(set: name, false) } }
                        Divider()
                        Button("Удалить набор", role: .destructive) { Task { await skills.deleteSet(name) } }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .controlSize(.small)
                .scaledFont(.caption)
            }
        }
    }

    private func switchOff(_ copies: [SkillCatalog.Copy]) async {
        var done = 0
        for copy in copies {
            if case .success = await skills.setEnabled(copy.installPath, false) { done += 1 }
        }
        message = String(localized: "Выключено: \(done). Вернуть можно в карточке или в журнале.")
    }

    private func toggle(set: String, _ on: Bool) async {
        switch await skills.setEnabled(set: set, on) {
        case .success(let moved): message = on ? String(localized: "Включено: \(moved).") : String(localized: "Выключено: \(moved). Вернуть можно в карточке или в журнале.")
        case .failure(let refusal): message = SkillRefusalText.text(refusal)
        }
    }
}

/// The sets a skill is in, on its card, and «В набор…».
struct SkillSetsRow: View {
    @Environment(SkillStore.self) private var skills
    let card: SkillCatalog.Card
    @State private var sets: [String] = []
    @State private var all: [String] = []
    @State private var newName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Наборы").scaledFont(.caption, weight: .semibold).foregroundStyle(.secondary).textCase(.uppercase)
                FlowRow(spacing: 4) {
                    ForEach(sets, id: \.self) { name in
                        Button { Task { await skills.removeFromSet(name, skill: card.row.id) } } label: {
                            HStack(spacing: 3) {
                                Text(verbatim: name)
                                Image(systemName: "xmark").scaledFont(.caption2)
                            }
                            .scaledFont(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Убрать из набора"))
                    }
                }
                Spacer(minLength: 4)
                Menu {
                    ForEach(all.filter { !sets.contains($0) }, id: \.self) { name in
                        Button { Task { await skills.addToSet(name, skill: card.row.id) } } label: { Text(verbatim: name) }
                    }
                    if !all.filter({ !sets.contains($0) }).isEmpty { Divider() }
                    Button("Новый набор…") { newName = "" }
                } label: {
                    Label("В набор", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .scaledFont(.caption)
                .fixedSize()
            }
            if let name = newName {
                HStack(spacing: 6) {
                    TextField("Название набора", text: Binding(get: { name }, set: { newName = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(create)
                    Button("Добавить", action: create).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Отмена") { newName = nil }
                }
                .controlSize(.small)
                .scaledFont(.caption)
            }
        }
        .task(id: "\(card.row.id)-\(skills.marksVersion)") {
            sets = await skills.setsOf(card.row)
            all = await skills.order().sets.keys.sorted { $0.lowercased() < $1.lowercased() }
        }
    }

    private func create() {
        guard let name = newName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        newName = nil
        Task { await skills.addToSet(name, skill: card.row.id) }
    }
}

/// «Экспорт с хешами» in Settings → Скиллы: a JSON file of every installed skill with its files' SHA-256, and a check
/// of what is installed now against such a file.
struct SkillsExportSection: View {
    @Environment(SkillStore.self) private var skills
    @State private var result: String?

    var body: some View {
        Section {
            Button("Экспортировать список с хешами…", systemImage: "square.and.arrow.up", action: exportList)
            Button("Сверить с экспортом…", systemImage: "checkmark.shield", action: compare)
            if let result { Text(verbatim: result).foregroundStyle(.secondary).textSelection(.enabled) }
        } header: {
            Text("Экспорт с хешами")
        } footer: {
            Footnote(text: String(localized: "В файле — каждый установленный скилл: где он, для каких агентов, оценка и SHA-256 каждого файла. Пути в домашней папке записаны как «~», имени учётной записи там нет. Сверка показывает, какие скиллы с тех пор изменились (и какие файлы), пропали или появились."))
        }
    }

    private func exportList() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "skills-\(Date.now.formatted(.iso8601.year().month().day())).json"
        panel.allowedContentTypes = [.json]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            switch await skills.exportData() {
            case .success(let data):
                do {
                    try data.write(to: url, options: .atomic)
                    result = String(localized: "Сохранено: \(PathText.tilde(url.path)).")
                } catch {
                    result = error.localizedDescription
                }
            case .failure(let refusal): result = SkillRefusalText.text(refusal)
            }
        }
    }

    private func compare() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        Task {
            switch await skills.compare(with: data) {
            case .success(let comparison): result = Self.describe(comparison)
            case .failure: result = String(localized: "Это не файл экспорта скиллов AI Hub Bar.")
            }
        }
    }

    static func describe(_ comparison: SkillCatalog.Comparison) -> String {
        if comparison.changed.isEmpty && comparison.missing.isEmpty && comparison.added.isEmpty {
            return String(localized: "Всё как в файле: скиллов без изменений — \(comparison.unchanged).")
        }
        var lines = [String(localized: "Без изменений: \(comparison.unchanged).")]
        for item in comparison.changed {
            lines.append(String(localized: "Изменился \(item.name) (\(item.installPath)): \(item.files.joined(separator: ", "))"))
        }
        for item in comparison.missing { lines.append(String(localized: "Пропал \(item.name) (\(item.installPath))")) }
        for item in comparison.added { lines.append(String(localized: "Новый \(item.name) (\(item.installPath))")) }
        return lines.joined(separator: "\n")
    }
}
