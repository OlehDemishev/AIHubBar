import AppKit
import SwiftUI

struct GeneralSettings: View {
    @Environment(ProfileStore.self) private var modes
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

            Section {
                LabeledContent {
                    Button("Открыть") { SettingsRoute.open(module: .telegram) }
                        .help("Токен бота, чат и какой Mac отвечает — на странице модуля «Telegram»")
                } label: {
                    Label("Бот, чат и меню — модуль «Telegram»", systemImage: "paperplane")
                }
            } header: {
                Text("Telegram")
            }

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

            SupportSection()

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

/// The interface language (SPEC-modes §13): the system's, or one of AI Hub Bar's translations. macOS reads the
/// per-app `AppleLanguages` at launch, so a change needs a relaunch.
struct LanguagePicker: View {
    // The app's own domain: through `standard` the system's list comes back, and «Как в системе» would not show.
    @State private var choice = (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first.flatMap { language in
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

/// A quiet link to site/support.html; the app never asks for a donation by itself.
struct SupportSection: View {
    var body: some View {
        Section {
            IconRow("Поддержать проект", systemImage: "heart") {
                Button("Открыть") { Feedback.supportProject() }
            }
        } footer: {
            Footnote(text: String(localized: "AI Hub Bar бесплатный. Откроется страница на сайте со способами поддержки."))
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
            let testing = ModuleKind.allCases.filter(\.isBeta).map(\.title)
            if testing.isEmpty {
                Text("Новые сборки раньше всех. Может работать с ошибками; выключите — останетесь на этой версии до следующего обычного выпуска.")
            } else {
                Text("Новые сборки раньше всех и функции на испытании: \(testing.joined(separator: ", ")). Может работать с ошибками; выключите — останетесь на этой версии до следующего обычного выпуска.")
            }
        }
    }
}
