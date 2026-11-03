import AppKit
import SwiftUI

/// Claude Code in one tab (it was three small ones): where it is, its sessions, the subscription limits, background runs.
/// Settings → «Сервисы AI» → Claude Code: all of Claude Code's options, as sections of that tab's form.
struct ClaudeSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    /// Where `claude` was found: looked up once, not on every keystroke in the path field (SPEC-refactor §2.8).
    @State private var detected: String??

    var body: some View {
        @Bindable var settings = settings
        Group {
            Section {
                IconRow("Путь к claude", systemImage: "folder") {
                    TextField("", text: $settings.claudePath,
                              prompt: Text(detectedText))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
            } footer: {
                Footnote(text: String(localized: "Путь пустой — искать в /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, ~/.claude/local. Где запускать команды (Терминал / Фон / спрашивать) — у каждого профиля на вкладке «Профили»."))
            }

            SavedPromptsSection()

            Section {
                Button("Открыть инструкции и MCP-серверы…") {
                    NSApp.activate()
                    openWindow(.claudeConfig)
                }
            } header: {
                Text("CLAUDE.md и MCP")
            } footer: {
                Footnote(text: String(localized: "Отдельное окно: все CLAUDE.md и AGENTS.md (общие и проектов) с поиском и правкой, и MCP-серверы Claude Code с выключателем. То же окно — значок в низу панели."))
            }

            Section {
                Button("Сессии, hooks и фоновые задачи — «Сессии агентов»…") { SettingsRoute.open(module: .sessions) }
                    .buttonStyle(.link)
            }
        }
        .task { if detected == nil { detected = ClaudeLocator.detect() } }
    }

    private var detectedText: String {
        switch detected {
        case .none: String(localized: "авто: …")
        case .some(.none): String(localized: "авто: не найден")
        case let .some(.some(path)): String(localized: "авто: \(path)")
        }
    }
}

/// Settings → «Сервисы AI» → Claude Code → «Свои промпты»: title and text; the search (⌃⌥C) offers them by title.
struct SavedPromptsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            ForEach($settings.savedPrompts) { $prompt in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Название", text: $prompt.title)
                            .textFieldStyle(.roundedBorder)
                        Button(role: .destructive) {
                            settings.savedPrompts.removeAll { $0.id == prompt.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Удалить промпт")
                    }
                    TextField("Текст", text: $prompt.text, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.vertical, 2)
            }
            Button("Добавить промпт") {
                settings.savedPrompts.append(SavedPrompt(title: String(localized: "Новый промпт"), text: ""))
            }
        } header: {
            Text("Свои промпты")
        } footer: {
            Footnote(text: String(localized: "Наберите название в поиске (⌃⌥C), выберите проект — Claude запустится с этим текстом. Подстановки: {проект}, {ветка}, {файл} — файл, выделенный в Finder (macOS один раз спросит разрешение)."))
        }
    }
}
