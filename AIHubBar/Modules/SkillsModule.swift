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
        keywords: [String(localized: "Плагины"), String(localized: "Безопасность")]
    )
}

extension ModuleUI {
    static let skills = ModuleUI(
        settings: { AnyView(SkillsSettingsSection()) },
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
