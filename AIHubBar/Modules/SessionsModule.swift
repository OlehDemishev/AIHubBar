import AppKit
import SwiftUI

// «Сессии агентов» (docs/specs/SPEC-refactor.md §3): what the module is, its Settings sections and its «Панель сейчас» line.

extension ModuleDefinition {
    static let sessions = ModuleDefinition(
        kind: .sessions,
        group: .ai,
        symbol: "bubble.left.and.text.bubble.right",
        title: String(localized: "Сессии агентов"),
        summary: String(localized: "Сессии Claude Code на этом Маке и фоновые задачи. Нужны hooks — «Сервисы AI» → Claude Code."),
        tagline: String(localized: "Claude Code, фоновые задачи, очередь"),
        isBuiltIn: true,
        places: ModulePlace.allCases,
        menuBarKinds: [.waiting, .running, .background, .queued],
        primaryMenuBarKinds: [.waiting],
        notifications: [.waiting, .context, .background],
        island: IslandSlot(ears: [.sessions, .background], left: false),
        telegram: .backgroundResults,
        keywords: ["Hooks", "Telegram", String(localized: "Ответы из Telegram"), String(localized: "Фоновые задачи"), String(localized: "Ночные задачи начинаются в")]
    )
}

extension ModuleUI {
    static let sessions = ModuleUI(
        settings: {
            AnyView(Group {
                SessionSection()
                BackgroundRunsSection()
                TelegramApprovalsSection()
            })
        },
        sketch: { AnyView(SessionsSketch()) }
    )
}

/// «Панель сейчас»: how many sessions wait and work.
private struct SessionsSketch: View {
    @Environment(SessionStore.self) private var sessions

    var body: some View {
        let running = sessions.items.filter { $0.state == .running }.count
        SketchLine(sessions.items.isEmpty ? String(localized: "Нет сессий")
                   : String(localized: "Ждут: \(sessions.waitingCount) · работают: \(running)"))
    }
}

struct SessionSection: View {
    @Environment(HookController.self) private var hooks
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            IconRow("Hooks", systemImage: "link") {
                Text(hooks.status.title)
                    .foregroundStyle(hooks.status == .installed ? .green : hooks.status == .outdated ? .orange : .secondary)
            }
            HStack {
                // «Обновить» only when something is out of date: installed hooks need nothing.
                if hooks.status != .installed {
                    Button(hooks.status == .notInstalled ? String(localized: "Установить hooks") : String(localized: "Обновить hooks")) { hooks.install() }
                }
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
            Toggle("Отвечать на запросы разрешений из уведомлений и панели", systemImage: "hand.raised", isOn: $settings.approvalsFromClaudePult)
            Text("Когда Claude просит разрешение (команда, правка файла), в уведомлении и в строке сессии появляются «Разрешить» и «Отклонить». Диалог Claude при этом тоже на месте — работает тот ответ, что пришёл первым. В режиме auto Claude спрашивает редко. Если у hooks написано «нужно обновить», нажмите «Обновить hooks».")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Сессии Claude Code")
        } footer: {
            Footnote(text: String(localized: "Hooks добавляются в ~/.claude/settings.json (остальные настройки не трогаются, перед изменением рядом сохраняется копия). Они записывают состояние каждой сессии Claude Code на этом Маке — в Терминале, в приложении Claude, фоновых — чтобы AI Hub Bar показывал их в панели."))
        }
        .onAppear { hooks.refresh() }
    }
}

/// «Сессии агентов» → «Фоновые задачи»: `claude -p` runs without a window, their time limit, night start and results.
struct BackgroundRunsSection: View {
    @Environment(AppSettings.self) private var settings
    /// Whether a Telegram bot is set up — read from disk when the page opens or the folder changes, not on every redraw.
    @State private var hasTelegram = true

    var body: some View {
        @Bindable var settings = settings
        Section {
            Stepper(value: $settings.backgroundTimeLimitMinutes, in: 10...600, step: 10) {
                IconRow("Лимит времени", systemImage: "timer", value: String(localized: "\(settings.backgroundTimeLimitMinutes) мин"))
            }
            Toggle("Итог в Telegram", systemImage: "paperplane", isOn: $settings.telegramForBackground)
            Picker("Ночные задачи начинаются в", systemImage: "moon.stars", selection: $settings.nightStartHour) {
                ForEach(NightQueue.hours, id: \.self) { Text(verbatim: String(format: "%02d:00", $0)).tag($0) }
            }
            if settings.telegramForBackground, !hasTelegram {
                Text("Telegram не настроен (Настройки → Основные → Telegram) — будет только уведомление macOS.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Фоновые задачи")
        } footer: {
            Footnote(text: String(localized: "«Фон» запускает claude -p без окна: разрешены чтение и правка файлов проекта, проверки и сборки, git без push в main и без force, gh pr create/view/list; остальное отклоняется. Итог — уведомлением и в Telegram."))
        }
        .task(id: "\(settings.dailyReportDirectory)|\(settings.telegramForBackground)") {
            hasTelegram = Telegram.credentials(dailyReportDirectory: settings.dailyReportDirectory) != nil
        }
    }
}

/// Permission requests answered from the phone, through a bot of AI Hub Bar's own.
struct TelegramApprovalsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TelegramApprovals.self) private var telegram
    @State private var token = ""
    @State private var busy = false

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Присылать запросы разрешений в Telegram", systemImage: "paperplane", isOn: $settings.telegramApprovals)
            IconRow("Токен бота", systemImage: "key") {
                HStack {
                    if telegram.hasToken {
                        Text(telegram.botName ?? String(localized: "сохранён в Связке ключей")).foregroundStyle(.secondary)
                        Button("Удалить") { Task { await telegram.removeToken() } }
                    } else {
                        SecureField("", text: $token, prompt: Text(verbatim: "123456:ABC…"))
                            .frame(width: 200)
                        Button("Сохранить") {
                            busy = true
                            Task {
                                await telegram.saveToken(token)
                                token = ""
                                busy = false
                            }
                        }
                        .disabled(token.isEmpty || busy)
                    }
                }
            }
            TextField("ID чата", text: $settings.telegramApprovalsChatID, prompt: Text("как в «Основные → Telegram»"))
            HStack {
                Button("Проверить") {
                    busy = true
                    Task { await telegram.check(); busy = false }
                }
                .disabled(!telegram.hasToken || busy)
                if let status = telegram.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Ответы из Telegram")
        } footer: {
            Footnote(text: String(localized: "Нужен отдельный бот, не тот, что в «Основные → Telegram»: эти ответы бот получает через свои обновления, а у основного бота их может читать другая программа (например, бот _daily-report), и они забирали бы сообщения друг у друга. Создайте бота в @BotFather (/newbot), вставьте его токен, откройте бота в Telegram и нажмите «Start», затем «Проверить». Кнопки принимаются только из указанного чата."))
        }
    }
}
