import AppKit
import SwiftUI

// «Скиллы» (docs/specs/SPEC-skills.md): what the module is, its Settings section and its «Панель сейчас» line.

extension ModuleDefinition {
    static let skills = ModuleDefinition(
        kind: .skills,
        group: .ai,
        symbol: "puzzlepiece.extension",
        title: String(localized: "Скиллы"),
        summary: String(localized: "Скиллы и плагины Claude Code, Codex, Cursor и Gemini CLI в одном списке, с проверкой безопасности каждого: что найдено, почему такая оценка и какими скиллами вы пользуетесь."),
        tagline: String(localized: "Проверка безопасности скиллов агентов"),
        places: [.panel, .notifications],
        notifications: [.skills],
        keywords: [String(localized: "Плагины"), String(localized: "Безопасность")]
    )
}

extension ModuleUI {
    static let skills = ModuleUI(
        settings: { AnyView(Group { SkillsSettingsSection(); SkillsSourcesSection(); SkillsPolicySection(); SkillsExportSection() }) },
        sketch: { AnyView(SkillsSketch()) }
    )
}

/// «Панель сейчас»: how many skills, and how many of them are dangerous.
private struct SkillsSketch: View {
    @Environment(SkillStore.self) private var skills

    var body: some View {
        let summary = skills.summary
        if summary.total == 0 {
            SketchLine(ModuleKind.skills.tagline)
        } else {
            SketchLine(String(localized: "Скиллов: \(summary.total) · опасных: \(summary.dangerous.count)"))
        }
    }
}

struct SkillsSettingsSection: View {
    @Environment(SkillStore.self) private var skills
    /// What happened to the folder just added.
    @State private var added: String?

    /// A skill from a download or a colleague: it is checked and listed in the panel's «Скиллы», installed nowhere
    /// until the person installs it from its card.
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Проверить")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            switch await skills.importFolder(url) {
            case .success: added = String(localized: "«\(url.lastPathComponent)» проверен и есть в списке скиллов в панели.")
            case .failure(let refusal): added = SkillRefusalText.text(refusal)
            }
        }
    }

    var body: some View {
        Section {
            LabeledContent("Проверено") {
                if let last = skills.lastUpdated {
                    Text(RelativeTime.ago(last))
                } else {
                    Text("ещё нет")
                }
            }
            Button("Проверить заново", systemImage: "arrow.clockwise") { Task { await skills.refresh() } }
                .disabled(skills.isRefreshing)
            Button("Добавить папку со скиллом…", systemImage: "folder.badge.plus", action: addFolder)
                .help(String(localized: "Папка только проверяется и появляется в списке; установить скилл можно из его карточки."))
            if let added { Text(added).foregroundStyle(.secondary) }
        } header: {
            Text("Проверка скиллов")
        } footer: {
            Footnote(text: String(localized: "Скиллы ищутся в папках Claude Code, Codex, Cursor и Gemini CLI и в ваших проектах, раз в полчаса и при открытии панели. Файлы скилла только читаются — ничего из них не запускается. Какими скиллами вы пользуетесь, видно по журналам сессий агентов на этом Mac. Проверка снижает риск, но не гарантирует безопасность."))
        }
    }
}

/// «Что можно ставить»: the install policy, notifications about changes made outside the catalog, trusted authors.
struct SkillsPolicySection: View {
    @Environment(SkillStore.self) private var skills
    @State private var newAuthor = ""

    var body: some View {
        let policy = skills.policy
        Section {
            Picker("Ставить из каталога", selection: Binding(get: { policy.install }, set: { value in var changed = policy; changed.install = value; Task { await skills.setPolicy(changed) } })) {
                Text("Любые, «Проверить» и «Опасно» — после подтверждения").tag(SkillCatalog.Policy.Install.all)
                Text("Кроме опасных").tag(SkillCatalog.Policy.Install.noDangerous)
                Text("Только безопасные").tag(SkillCatalog.Policy.Install.safeOnly)
            }
            Toggle("Только от доверенных авторов", isOn: Binding(get: { policy.trustedOnly }, set: { value in var changed = policy; changed.trustedOnly = value; Task { await skills.setPolicy(changed) } }))
            Toggle("Сообщать о скиллах, появившихся или изменившихся вне каталога", isOn: Binding(get: { policy.notifyOutside }, set: { value in var changed = policy; changed.notifyOutside = value; Task { await skills.setPolicy(changed) } }))
            ForEach(skills.trusted, id: \.self) { author in
                HStack {
                    Label { Text(verbatim: author) } icon: { Image(systemName: "checkmark.seal") }
                    Spacer()
                    Button("Убрать") { Task { await skills.distrust(author) } }
                }
            }
            HStack {
                TextField("Доверенный автор или владелец на GitHub", text: $newAuthor)
                    .onSubmit(add)
                Button("Добавить", action: add).disabled(newAuthor.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Что можно ставить")
        } footer: {
            Footnote(text: String(localized: "Политика действует на установку и обновление из каталога; скиллы, которые ставят сами агенты, она не трогает — о них приходит уведомление. Автора скилл указывает о себе сам, это не проверено: доверие только приглушает уведомления об изменениях и разрешает установку при «только от доверенных», оценку оно не меняет."))
        }
    }

    private func add() {
        let author = newAuthor
        newAuthor = ""
        Task { await skills.trust(author) }
    }
}
