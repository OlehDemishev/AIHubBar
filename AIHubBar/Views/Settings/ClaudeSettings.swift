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
                if case .some(.none) = detected {
                    IconRow("Claude Code не установлен", systemImage: "arrow.down.circle") {
                        Button("Установить Claude Code") { ClaudeSignIn.openInstallPage() }
                    }
                }
            } footer: {
                Footnote(text: String(localized: "Путь пустой — искать в /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, ~/.claude/local."))
            }

            ClaudeAccountsSection()

            SavedPromptsSection()

            Section {
                Button("Открыть инструкции и MCP-серверы…") {
                    NSApp.activate()
                    openWindow(.claudeConfig)
                }
            } header: {
                Text("CLAUDE.md и MCP")
            } footer: {
                Footnote(text: String(localized: "Отдельное окно: все CLAUDE.md и AGENTS.md (общие и проектов) с поиском и правкой, и MCP-серверы Claude Code с выключателем."))
            }

            Section {
                Button("Сессии и фоновые задачи — «Сессии агентов»…") { SettingsRoute.open(module: .sessions) }
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
                        FormField(Text("Название"), text: $prompt.title)
                        ConfirmedButton(title: "Удалить промпт", message: prompt.title) {
                            let id = prompt.id
                            settings.savedPrompts.removeAll { $0.id == id }
                        } label: { Label("Удалить промпт", systemImage: "trash").labelStyle(.iconOnly) }
                        .buttonStyle(.borderless)
                        .help("Удалить промпт")
                    }
                    FormField(Text("Текст"), text: $prompt.text, axis: .vertical)
                        .lineLimit(2...6)
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

/// Extra Claude accounts: each in its own config folder, signed in from here, with its limits in the panel.
private struct ClaudeAccountsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ClaudeAccountsStore.self) private var accounts

    var body: some View {
        @Bindable var settings = settings
        Section {
            ForEach($settings.claudeAccounts) { $account in
                HStack {
                    TextField("Название", text: $account.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Text(account.configDir)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Войти") { signIn(account) }
                    ConfirmedButton(title: "Убрать аккаунт", message: account.name, confirm: "Убрать", role: nil) {
                        // The id is read first: read inside the closure, it goes through the binding into the array
                        // being changed, and Swift ends the app for overlapping access (seen on this button, 2026-11-10).
                        let id = account.id
                        settings.claudeAccounts.removeAll { $0.id == id }
                    } label: {
                        Label("Убрать аккаунт", systemImage: "minus.circle").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Убрать аккаунт")
                }
            }
            Button("Добавить аккаунт…", action: add)
        } header: {
            Text("Другие аккаунты Claude")
        } footer: {
            Footnote(text: String(localized: "Основной аккаунт настраивать не нужно. Для другого выберите его папку настроек (CLAUDE_CONFIG_DIR) и нажмите «Войти»: его лимиты появятся в панели. Прогноза и истории у таких аккаунтов нет."))
        }
        .onChange(of: settings.claudeAccounts.map(\.id)) { Task { await accounts.refresh() } }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = String(localized: "Выбрать")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.claudeAccounts.append(ClaudeAccount(name: url.lastPathComponent, configDir: PathText.tilde(url.path)))
    }

    private func signIn(_ account: ClaudeAccount) {
        let commandLine = account.signInCommandLine(claude: ClaudeLocator.resolve(configured: settings.claudePath))
        Task {
            do {
                try await TerminalLauncher.run(commandLine)
            } catch {
                AppLog.error("Claude account sign-in: \(error.localizedDescription)")
                NSAlert(error: error).runModal()
            }
        }
    }
}
