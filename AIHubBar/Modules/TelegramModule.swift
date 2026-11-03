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
        settings: {
            AnyView(Group {
                TelegramBotSection()
                TelegramMenuSection()
            })
        },
        sketch: nil
    )
}

/// The bot (SPEC-telegram §1, §6, §7): shared or own, the chat, «Этот Мак отвечает боту». Notifications go out through this bot
/// even while the module is off; the menu and the answers need the module.
struct TelegramBotSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TelegramBotController.self) private var bot
    @State private var token = ""
    @State private var busy = false

    var body: some View {
        @Bindable var bot = bot
        @Bindable var settings = settings
        Section {
            if bot.relay.baseURL != nil {
                Picker("Как подключаться", systemImage: "point.3.connected.trianglepath.dotted", selection: $bot.usesSharedBot) {
                    Text("Общий бот (быстро)").tag(true)
                    Text("Свой бот (приватно)").tag(false)
                }
                .help("Общий бот — ничего создавать не нужно; свой бот — из @BotFather, без сервера AI Hub Bar между вами")
            }
            if bot.usesSharedBot {
                sharedRows
            } else {
                ownRows
            }
            if !bot.chatID.isEmpty {
                Toggle("Этот Мак отвечает боту", systemImage: "desktopcomputer", isOn: $bot.answersHere)
                    .help(bot.usesSharedBot
                          ? String(localized: "Отвечает один Мак этого чата; переключить можно и командой /macs в боте")
                          : String(localized: "Только один Мак читает сообщения бота; уведомления присылают все"))
            }
            Toggle("Запросы разрешений в этот бот", systemImage: "hand.raised", isOn: $settings.telegramApprovals)
                .help("Когда Claude просит разрешение, бот присылает запрос с кнопками «Разрешить», «Отклонить», «Подробнее»")
            if bot.usesSharedBot, settings.telegramApprovals {
                Toggle("Ответы на запросы через общий бот", systemImage: "lock.open", isOn: Binding(
                    get: { settings.telegramBot.answersOverShared == true },
                    set: { settings.telegramBot.answersOverShared = $0 }
                ))
                .help("Выключено — запросы приходят без кнопок, ответить можно только на Маке")
            }
            LabeledContent {
                Button("Проверить") {
                    busy = true
                    Task { await bot.test(); busy = false }
                }
                .disabled((!bot.usesSharedBot && !bot.hasToken) || bot.chatID.isEmpty || busy)
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
            Footnote(text: bot.usesSharedBot
                     ? String(localized: "Общий бот AI Hub Bar: создавать ничего не нужно — «Подключить Telegram», затем «Start» в Telegram. Сообщения идут через сервер AI Hub Bar (Cloudflare), который их не хранит; без посредника — «Свой бот». Команды: /menu, /report, /status, /clean, /macs, /help.")
                     : String(localized: "Создайте бота в @BotFather (/newbot) и вставьте токен — он хранится только в связке ключей. «Привязать чат» откроет бота: нажмите «Start». Команды: /menu, /report, /status, /clean, /help; кнопки меняют одно сообщение. Через этого бота приходят и итоги фоновых задач, пороги лимитов, недельная сводка, напоминания — где у модуля включён Telegram. Отчёты report.py присылает бот из _daily-report/config.json."))
        }
    }

    /// The shared bot: nothing to create, one button to pair.
    @ViewBuilder private var sharedRows: some View {
        IconRow("Бот", systemImage: "paperplane") {
            Text(bot.botName ?? String(localized: "подключаюсь…")).foregroundStyle(.secondary)
        }
        IconRow("Чат", systemImage: "person.crop.circle") {
            HStack {
                if bot.relay.chat != nil {
                    Text("подключён").foregroundStyle(.secondary)
                    Button("Отключить") { bot.disconnectShared() }
                        .help("Этот Мак больше не будет связан с чатом; другие Маки останутся")
                } else {
                    Button("Подключить Telegram") { Task { await bot.connectShared() } }
                        .disabled(!bot.relay.connected)
                        .help("Откроется бот в Telegram — нажмите «Start», и он будет отвечать с этого Мака")
                }
            }
        }
    }

    /// The person's own bot from @BotFather.
    @ViewBuilder private var ownRows: some View {
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
    }

    private var stateText: String {
        if bot.conflict { return String(localized: "Бота читает другой Мак") }
        if bot.usesSharedBot, !bot.relay.answering, bot.relay.chat != nil { return String(localized: "Отвечает другой Мак") }
        if bot.isReading { return String(localized: "Отвечает") }
        return String(localized: "Не отвечает")
    }
}

/// «Меню в боте» (SPEC-telegram §2): which buttons the menu at the bottom of the chat has, in what order, how many in a
/// row; a profile can have its own. The same switches are in the bot: ❓ → ⚙️ «Настроить меню».
struct TelegramMenuSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TelegramBotController.self) private var bot
    @Environment(ProfileStore.self) private var modes
    @State private var forProfile = false
    @State private var busy = false

    var body: some View {
        Section {
            if let profile = modes.current {
                Picker("Меню для", systemImage: "square.stack.3d.up", selection: $forProfile) {
                    Text("всех профилей").tag(false)
                    Text("профиля «\(profile.name)»").tag(true)
                }
                if forProfile {
                    Toggle("Своё меню у этого профиля", systemImage: "person.crop.square", isOn: Binding(
                        get: { settings.telegramBot.hasOwnMenu(profile.id) },
                        set: { settings.telegramBot.setOwnMenu($0, for: profile.id) }
                    ))
                    .help("Выключено — у профиля общее меню")
                }
            }
            Group {
                ForEach(items, id: \.self) { item in
                    row(item)
                }
                Picker("Кнопок в ряд", systemImage: "rectangle.split.3x1", selection: Binding(
                    get: { config.columns },
                    set: { columns in edit { $0.columns = columns } }
                )) {
                    Text(verbatim: "2").tag(2)
                    Text(verbatim: "3").tag(3)
                }
            }
            .disabled(isProfileWithoutOwnMenu)
            if bot.usesSharedBot {
                Toggle("Быстрые команды через общий бот", systemImage: "lock.open", isOn: Binding(
                    get: { settings.telegramBot.commandsOverShared == true },
                    set: { settings.telegramBot.commandsOverShared = $0 }
                ))
                .help("Выключено — команды из меню не запускаются через общий бот; включено — каждая спрашивает «Запустить?»")
            }
            LabeledContent {
                Button("Обновить меню в Telegram") {
                    busy = true
                    Task { await bot.refreshMenu(); busy = false }
                }
                .disabled(bot.chatID.isEmpty || busy)
                .help("Прислать 🏠 с новым меню; иначе оно обновится при следующем нажатии 🏠")
            } label: {
                Text(bot.currentMenu.entries.map(\.title).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } header: {
            Text("Меню в боте")
        } footer: {
            Footnote(text: String(localized: "Кнопки внизу чата: разделы бота и ваши быстрые команды (Модули → «Быстрые команды»). 🏠 есть всегда. Команда из меню выполняется на этом Маке, итог приходит в чат; «Спрашивать перед запуском» спрашивает и там. Удобно 6–9 кнопок."))
        }
    }

    private var target: String? { forProfile ? modes.current?.id : nil }
    private var config: BotMenuConfig { settings.telegramBot.menu(for: target) }

    private var isProfileWithoutOwnMenu: Bool {
        guard forProfile, let profile = modes.current else { return false }
        return !settings.telegramBot.hasOwnMenu(profile.id)
    }

    /// The chosen ones in their order, then the rest.
    private var items: [BotMenuItem] {
        let all = BotScreen.menuScreens.map(BotMenuItem.screen) + settings.quickCommands.map { BotMenuItem.command($0.id) }
        let chosen = config.items.compactMap(BotMenuItem.init(id:)).filter(all.contains)
        return (chosen.contains(.screen(.home)) ? [] : [.screen(.home)]) + chosen + all.filter { !chosen.contains($0) && $0 != .screen(.home) }
    }

    private func row(_ item: BotMenuItem) -> some View {
        let title = BotMenu.title(item, commands: settings.quickCommands)
        let chosen = config.contains(item)
        return HStack {
            Toggle(title, isOn: Binding(get: { chosen }, set: { _ in edit { $0.toggle(item) } }))
                .disabled(item == .screen(.home))
            Spacer()
            if chosen, item != .screen(.home) {
                Button { edit { $0.move(item, by: -1) } } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .help("Выше")
                    .accessibilityLabel(String(localized: "Выше: \(title)"))
                Button { edit { $0.move(item, by: 1) } } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .help("Ниже")
                    .accessibilityLabel(String(localized: "Ниже: \(title)"))
            }
        }
    }

    private func edit(_ change: (inout BotMenuConfig) -> Void) {
        var config = config
        change(&config)
        settings.telegramBot.setMenu(config, for: target)
    }
}
