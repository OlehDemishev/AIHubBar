import AppKit
import SwiftUI

struct GeneralSettings: View {
    @Environment(ModeStore.self) private var modes
    @Environment(NotificationPermission.self) private var notifications
    @Environment(LoginItemController.self) private var loginItem
    @Environment(AppSettings.self) private var settings
    @Environment(ProjectStore.self) private var store
    @Environment(HookController.self) private var hooks

    var body: some View {
        @Bindable var settings = settings
        SettingsPage {
            Section {
                Toggle("Запускать при входе в систему", systemImage: "power", isOn: Binding(
                    get: { loginItem.state.isOn },
                    set: { loginItem.setEnabled($0) }
                ))
                if let message = loginItem.state.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                if loginItem.state == .requiresApproval {
                    Button("Открыть «Объекты входа»") { loginItem.openSystemSettings() }
                }
                if let error = loginItem.lastError {
                    Text("Ошибка: \(error)").font(.callout).foregroundStyle(.red)
                }
                LanguagePicker()
                Picker("Открывать поиск с клавиатуры", systemImage: "magnifyingglass", selection: $settings.panelHotKey) {
                    ForEach(PanelHotKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.panelHotKey) { GlobalHotKey.register(settings.panelHotKey) }
            }

            Section {
                IconRow("Уведомления", systemImage: "bell") {
                    HStack(spacing: 8) {
                        Text(notificationsText)
                            .foregroundStyle(notifications.state == .allowed ? .green : .orange)
                        if notifications.state == .notAsked {
                            Button("Разрешить") { notifications.request() }
                        } else if notifications.state == .allowed {
                            Button("Проверить") { Notifier.postTest() }
                        } else {
                            Button("Открыть настройки") { NotificationPermission.openSystemSettings() }
                        }
                    }
                }
            } footer: {
                Footnote(text: String(localized: "Нужны для «Claude ждёт ответа», итогов фоновых задач, порогов лимитов и результатов команд. Клик по уведомлению ведёт к сессии, PR, журналу или отчёту."))
            }

            TelegramBotSection()

            Section {
                ImportConfirmation()
                HStack {
                    Button("Экспорт настроек…") { SettingsFiles.save(modes.exportBundle(), suggestedName: "AI Hub Bar") }
                    Button("Импорт…") { SettingsFiles.chooseImport(into: modes) }
                }
            } header: {
                Text("Перенос и обмен")
            } footer: {
                Footnote(text: String(localized: "Один файл .claudepult: все профили, внешний вид, строка меню, пороги. Без ключей, токенов и журналов. Двойной клик по такому файлу открывает импорт. Папки проектов — на вкладке «Профили»."))
            }

            FeedbackSection()

            Section {
                IconRow("Версия", systemImage: "info.circle", value: Self.version)
                UpdatesRow()
                BetaRow()
                IconRow("Журнал", systemImage: "doc.text") {
                    Button("Показать в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL])
                    }
                }
            }
        }
        .onAppear {
            loginItem.refresh()
            notifications.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
            notifications.refresh()
        }
    }

    private var notificationsText: String {
        switch notifications.state {
        case .allowed: String(localized: "включены")
        case .denied: String(localized: "выключены в macOS")
        case .notAsked: String(localized: "ещё не разрешены")
        case .unknown: "—"
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// Settings → Основные → Telegram: the bot results, limits and summaries go to. Without it, a `_daily-report/config.json`
/// bot is used if there is one.
struct TelegramBotSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var token = ""
    @State private var hasToken = false
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        @Bindable var settings = settings
        Section {
            if hasToken {
                IconRow("Токен бота", systemImage: "key") {
                    HStack {
                        Text("сохранён в связке ключей").foregroundStyle(.secondary)
                        Button("Удалить", role: .destructive) {
                            Task {
                                await APIKeyStore.delete(account: Telegram.keychainAccount)
                                hasToken = false
                                await Telegram.loadOwnBot(chatID: settings.telegramChatID)
                            }
                        }
                    }
                }
            } else {
                IconRow("Токен бота", systemImage: "key") {
                    HStack {
                        SecureField("", text: $token, prompt: Text(verbatim: "123456:ABC…"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                        Button("Сохранить", action: saveToken)
                            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            IconRow("ID чата", systemImage: "number") {
                HStack {
                    TextField("", text: $settings.telegramChatID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onSubmit { Task { await Telegram.loadOwnBot(chatID: settings.telegramChatID) } }
                    Button("Определить", action: detectChat)
                        .disabled(!hasToken || busy)
                        .help("Напишите боту любое сообщение, затем нажмите — ID чата подставится сам")
                    Button("Проверить", action: test)
                        .disabled(!hasToken || settings.telegramChatID.isEmpty || busy)
                }
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Telegram")
        } footer: {
            Footnote(text: String(localized: "Сюда приходят итоги фоновых задач, пороги лимитов, недельная сводка, напоминания календаря — где в модуле включён Telegram. Бот создаётся у @BotFather; токен хранится только в связке ключей. Пока здесь пусто, используется бот из _daily-report/config.json, если он есть."))
        }
        .task {
            hasToken = await APIKeyStore.exists(account: Telegram.keychainAccount)
        }
        .onChange(of: settings.telegramChatID) { Task { await Telegram.loadOwnBot(chatID: settings.telegramChatID) } }
    }

    private func saveToken() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await APIKeyStore.save(value, account: Telegram.keychainAccount, label: "Telegram bot")
                token = ""
                hasToken = true
                await Telegram.loadOwnBot(chatID: settings.telegramChatID)
                status = String(localized: "Токен сохранён. Напишите боту любое сообщение и нажмите «Определить».")
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func detectChat() {
        busy = true
        Task {
            defer { busy = false }
            guard let token = await APIKeyStore.read(account: Telegram.keychainAccount),
                  let chat = await Telegram.latestChat(token: token) else {
                status = String(localized: "Сообщений боту не нашлось: напишите ему что-нибудь и попробуйте снова.")
                return
            }
            settings.telegramChatID = chat
            await Telegram.loadOwnBot(chatID: chat)
            status = String(localized: "Чат найден.")
        }
    }

    private func test() {
        busy = true
        Task {
            defer { busy = false }
            await Telegram.loadOwnBot(chatID: settings.telegramChatID)
            guard let bot = Telegram.ownBot else { return }
            let ok = await Telegram.send(html: RunMessage.escape(String(localized: "AI Hub Bar: Telegram работает.")), with: bot)
            status = ok ? String(localized: "Отправлено") : String(localized: "Не отправилось: проверьте токен и ID чата")
        }
    }
}

/// The interface language (SPEC-modes §13): the system's, or one of ClaudePult's translations. macOS reads the
/// per-app `AppleLanguages` at launch, so a change needs a relaunch.
struct LanguagePicker: View {
    @State private var choice = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first.flatMap { language in
        (Bundle.main.localizations + ["ru"]).first { language.hasPrefix($0) }
    } ?? ""
    @State private var changed = false

    /// Translations plus the development language (Russian), which has no `.lproj` of its own.
    private var languages: [String] {
        Set(Bundle.main.localizations + [Bundle.main.developmentLocalization ?? "ru"]).filter { $0 != "Base" }.sorted()
    }

    var body: some View {
        Picker("Язык интерфейса", systemImage: "globe", selection: $choice) {
            Text("Как в системе").tag("")
            ForEach(languages, id: \.self) { code in
                Text(Locale(identifier: code).localizedString(forIdentifier: code)?.capitalized ?? code).tag(code)
            }
        }
        .onChange(of: choice) {
            if choice.isEmpty {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([choice], forKey: "AppleLanguages")
            }
            changed = true
        }
        if changed {
            HStack {
                Text("Язык сменится после перезапуска.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Перезапустить") { Relaunch.now() }
            }
        }
    }
}

@MainActor
enum Relaunch {
    static func now() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Ideas and problems go to the repository's issue forms (Feedback); after a crash the app offers to report it.
struct FeedbackSection: View {
    @AppStorage(CrashReports.askKey) private var asksAfterCrash = true

    var body: some View {
        Section {
            IconRow("Обратная связь", systemImage: "envelope") {
                HStack {
                    Button("Предложить идею…") { Feedback.suggestIdea() }
                    Button("Сообщить о проблеме…") { Feedback.reportProblem() }
                }
            }
            Toggle("После сбоя предлагать отправить отчёт", systemImage: "exclamationmark.bubble", isOn: $asksAfterCrash)
        } footer: {
            Footnote(text: String(localized: "Откроется форма на GitHub, версия и macOS в ней уже заполнены. Сама программа ничего не отправляет: перед отправкой видно всё, что уходит. Нужен аккаунт GitHub."))
        }
    }
}

/// «Проверить обновления» and the daily check (Sparkle, scripts/release.sh).
struct UpdatesRow: View {
    @State private var automatic = Updates.checksAutomatically

    var body: some View {
        IconRow("Обновления", systemImage: "arrow.down.circle") {
            HStack {
                Toggle("Проверять раз в день", systemImage: "clock.arrow.circlepath", isOn: $automatic)
                    .onChange(of: automatic) { Updates.checksAutomatically = automatic }
                Button("Проверить сейчас") { Updates.checkNow() }
            }
        }
    }
}

/// «Бета-версии»: beta builds before everyone else, and the modules still in beta testing.
struct BetaRow: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Toggle(isOn: $settings.betaUpdates) {
            Text("Бета-версии")
            Text("Новые сборки раньше всех и функции на испытании: \(ModuleKind.allCases.filter(\.isBeta).map(\.title).joined(separator: ", ")). Может работать с ошибками; выключите — останетесь на этой версии до следующего обычного выпуска.")
        }
    }
}
