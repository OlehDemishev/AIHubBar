import AppKit
import SwiftUI

// «Telegram» (docs/specs/SPEC-telegram.md): what the module is and its Settings page — the bot, the chat and which Mac
// answers it.

extension ModuleDefinition {
    static let telegram = ModuleDefinition(
        kind: .telegram,
        group: .ai,
        symbol: "paperplane",
        title: "Telegram",
        summary: String(localized: "Свой бот в Telegram с меню: лимиты, сессии и фоновые задачи, отчёты, очистка сборок. Отвечает только вашему чату и только с одного Мака."),
        tagline: String(localized: "Бот с меню: отчёты, сессии, Мак"),
        isPanelBlock: false,
        places: [],
        keywords: ["Telegram", String(localized: "Бот"), "@BotFather", "/report"]
    )
}

extension ModuleUI {
    static let telegram = ModuleUI(
        settings: { AnyView(TelegramBotSection()) },
        sketch: nil
    )
}

/// The bot (SPEC-telegram §1, §6): the token, the chat, «Этот Мак отвечает боту». Notifications go out through this bot
/// even while the module is off; the menu and the answers need the module.
struct TelegramBotSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TelegramBotController.self) private var bot
    @State private var token = ""
    @State private var busy = false

    var body: some View {
        @Bindable var bot = bot
        Section {
            IconRow("Токен бота", systemImage: "key") {
                HStack {
                    if bot.hasToken {
                        Text(bot.botName ?? String(localized: "сохранён в связке ключей")).foregroundStyle(.secondary)
                        Button("Удалить", role: .destructive) { Task { await bot.removeToken() } }
                            .help("Удалить токен из связки ключей; бот перестанет отвечать и присылать сообщения")
                    } else {
                        SecureField("", text: $token, prompt: Text(verbatim: "123456:ABC…"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .accessibilityLabel("Токен бота")
                        Button("Сохранить") {
                            let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
                            token = ""
                            Task { await bot.saveToken(value) }
                        }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            if bot.dailyReportBotAvailable {
                LabeledContent {
                    Button("Взять бота из _daily-report") { Task { await bot.adoptDailyReportBot() } }
                        .help("Скопировать токен и чат из _daily-report/config.json в связку ключей")
                } label: {
                    Label("Бот _daily-report", systemImage: "arrow.down.doc")
                }
            }
            IconRow("Чат", systemImage: "person.crop.circle") {
                HStack {
                    if let code = bot.bindingCode {
                        Text("Жду «Start» в Telegram (код \(code))…").foregroundStyle(.secondary)
                        Button("Отмена") { bot.cancelBinding() }
                    } else if !bot.chatID.isEmpty {
                        Text(verbatim: bot.chatID).foregroundStyle(.secondary).textSelection(.enabled)
                        if !settings.telegramChatID.isEmpty {
                            Button("Отвязать") { bot.unbind() }
                                .help("Бот перестанет отвечать этому чату; привяжите другой")
                        }
                    }
                    if bot.bindingCode == nil {
                        Button("Привязать чат") {
                            if let url = bot.startBinding() { NSWorkspace.shared.open(url) }
                        }
                        .disabled(bot.botName == nil)
                        .help("Откроется бот в Telegram — нажмите «Start», и бот будет отвечать только этому чату")
                    }
                }
            }
            Toggle("Этот Мак отвечает боту", systemImage: "desktopcomputer", isOn: $bot.answersHere)
                .help("Только один Мак читает сообщения бота; уведомления присылают все")
            LabeledContent {
                Button("Проверить") {
                    busy = true
                    Task { await bot.test(); busy = false }
                }
                .disabled(!bot.hasToken || busy)
                .help("Прислать в чат главное меню бота")
            } label: {
                Label(stateText, systemImage: bot.isReading ? "checkmark.circle" : "circle.dashed")
                    .foregroundStyle(bot.conflict ? .orange : .secondary)
            }
            if let status = bot.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Бот")
        } footer: {
            Footnote(text: String(localized: "Создайте бота в @BotFather (/newbot) и вставьте токен — он хранится только в связке ключей. «Привязать чат» откроет бота: нажмите «Start». Команды: /menu, /report, /status, /clean, /help; кнопки меняют одно сообщение. Через этого бота приходят и итоги фоновых задач, пороги лимитов, недельная сводка, напоминания — где у модуля включён Telegram. Отчёты report.py присылает бот из _daily-report/config.json."))
        }
    }

    private var stateText: String {
        if bot.conflict { return String(localized: "Бота читает другой Мак") }
        if bot.isReading { return String(localized: "Отвечает") }
        return String(localized: "Не отвечает")
    }
}
