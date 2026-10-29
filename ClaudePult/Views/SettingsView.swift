import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(LoginItemController.self) private var loginItem
    @Environment(AppSettings.self) private var settings
    @Environment(ProjectStore.self) private var store
    @Environment(HookController.self) private var hooks

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Общие") {
                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { loginItem.state.isOn },
                    set: { loginItem.setEnabled($0) }
                ))

                if let message = loginItem.state.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if loginItem.state == .requiresApproval {
                    Button("Открыть «Объекты входа»") {
                        loginItem.openSystemSettings()
                    }
                }
                if let error = loginItem.lastError {
                    Text("Ошибка: \(error)")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section {
                FolderField(
                    title: "Папка проектов",
                    path: $settings.projectsDirectory,
                    defaultPath: AppSettings.defaultProjectsDirectory
                )
                FolderField(
                    title: "Папка _daily-report",
                    path: $settings.dailyReportDirectory,
                    defaultPath: AppSettings.defaultDailyReportDirectory
                )
            } header: {
                Text("Пути")
            } footer: {
                Text("Данные о проектах берутся из report.py в папке _daily-report.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Путь к claude") {
                    TextField("", text: $settings.claudePath, prompt: Text(ClaudeLocator.detect().map { "авто: \($0)" } ?? "авто: не найден"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                Picker("Режим запуска", selection: $settings.defaultLaunchMode) {
                    Text("Спрашивать").tag(LaunchMode?.none)
                    ForEach(LaunchMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(LaunchMode?.some(mode))
                    }
                }
                Stepper(value: $settings.backgroundTimeLimitMinutes, in: 10...600, step: 10) {
                    LabeledContent("Лимит фоновой задачи", value: "\(settings.backgroundTimeLimitMinutes) мин")
                }
                Toggle("Итог фоновой задачи в Telegram", isOn: $settings.telegramForBackground)
                if settings.telegramForBackground,
                   Telegram.credentials(dailyReportDirectory: settings.dailyReportDirectory) == nil {
                    Text("В _daily-report/config.json нет telegram.bot_token / chat_id — будет только уведомление macOS.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("Путь к claude: пусто — искать в /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, ~/.claude/local. «Терминал» открывает новое окно (при первом запуске macOS спросит разрешение на управление Терминалом). «Фон» запускает claude -p без окна: разрешены чтение и правка файлов проекта, проверки и сборки, git без push в main и без force, gh pr create/view/list; остальное отклоняется. Итог — уведомлением и в Telegram.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Состояние") {
                    Text(hooks.status.title)
                        .foregroundStyle(hooks.status == .installed ? .green : hooks.status == .outdated ? .orange : .secondary)
                }
                HStack {
                    Button(hooks.status == .notInstalled ? "Установить hooks" : "Обновить hooks") { hooks.install() }
                    if hooks.status != .notInstalled {
                        Button("Снять hooks") { hooks.uninstall() }
                    }
                }
                if let message = hooks.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(hooks.isError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Сессии Claude Code")
            } footer: {
                Text("Hooks добавляются в ~/.claude/settings.json (остальные настройки не трогаются, перед изменением рядом сохраняется копия). Они записывают состояние каждой сессии Claude Code на этом Маке — в Терминале, в приложении Claude, фоновых — чтобы ClaudePult показывал их в панели.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Версия", value: Self.version)
                LabeledContent("Журнал") {
                    Button("Показать в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            loginItem.refresh()
            hooks.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
        .onChange(of: settings.projectsDirectory) {
            Task { await store.refresh() }
            hooks.refresh()
        }
        .onChange(of: settings.dailyReportDirectory) { Task { await store.refresh() } }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// A folder path with «Выбрать…» (NSOpenPanel) and a reset to the default.
private struct FolderField: View {
    let title: String
    @Binding var path: String
    let defaultPath: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(FileManager.default.fileExists(atPath: path) ? .primary : Color.red)
                    .help(path)
                Button("Выбрать…", action: choose)
                if path != defaultPath {
                    Button {
                        path = defaultPath
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("По умолчанию: \((defaultPath as NSString).abbreviatingWithTildeInPath)")
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path)
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}
