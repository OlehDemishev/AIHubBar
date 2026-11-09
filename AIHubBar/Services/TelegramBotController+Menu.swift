import Foundation

/// The menu at the bottom, quick commands, reports and cleanup.
extension TelegramBotController {
    // MARK: - The menu and quick commands

    /// The menu at the bottom for the current profile.
    var currentMenu: BotMenu {
        BotMenu(settings.telegramBot.menu(for: currentProfile()?.id), commands: settings.quickCommands)
    }

    /// The menu the bot's ⚙️ edits: the current profile's own, if it has one, else the common one.
    private var editedProfile: String? {
        currentProfile().flatMap { settings.telegramBot.hasOwnMenu($0.id) ? $0.id : nil }
    }

    func editMenu(_ change: (inout BotMenuConfig) -> Void) {
        var config = settings.telegramBot.menu(for: editedProfile)
        change(&config)
        settings.telegramBot.setMenu(config, for: editedProfile)
    }

    var menuScreen: BotMessage {
        let profile = editedProfile.flatMap { _ in currentProfile()?.name }
        return BotScreens.menuSetup(settings.telegramBot.menu(for: editedProfile), commands: settings.quickCommands, profile: profile)
    }

    /// The profile changed: if its menu differs from the one in the chat, 🏠 brings the new one.
    func profileChanged() {
        guard isActive(), answersHere, !chatID.isEmpty, let sentMenu, sentMenu != currentMenu.entries.map(\.item) else { return }
        Task { await show(.home, tapID: nil) }
    }

    /// «Где меню» changed: the keyboard at the bottom comes back with 🏠, or goes away with a note where the menu is.
    func applyMenuPlacement() async {
        guard !chatID.isEmpty else { return }
        if settings.telegramBot.bottomMenu == false {
            var note = BotMessage(html: "☰ " + RunMessage.escape(usesSharedBot
                ? String(localized: "Меню — в кнопке «Меню» слева от поля ввода: там всё приложение.")
                : String(localized: "Меню — в кнопке «Меню» слева от поля ввода.")))
            note.removesMenu = true
            _ = await send(note)
            sentMenu = nil
        } else {
            await show(.home, tapID: nil)
        }
    }

    /// «Обновить меню в Telegram» in Settings.
    func refreshMenu() async {
        guard !chatID.isEmpty else { status = String(localized: "Сначала привяжите чат"); return }
        status = await show(.home, tapID: nil) ? String(localized: "Отправлено") : String(localized: "Не отправилось: проверьте токен и ID чата")
    }

    /// A quick command from the menu: over the shared bot only with its switch on, and then always asked first (§7);
    /// otherwise asked first when the command says so.
    func askOrRun(_ id: String) async {
        guard let command = settings.quickCommands.first(where: { $0.id == id }) else { return }
        if usesSharedBot, settings.telegramBot.commandsOverShared != true {
            _ = await send(BotMessage(html: "🔒 " + RunMessage.escape(String(localized: "Быстрые команды через общий бот выключены. На Mac: Настройки → Модули → Telegram → «Быстрые команды через общий бот»."))))
            return
        }
        if command.confirm || usesSharedBot {
            _ = await send(BotScreens.confirmCommand(command))
        } else {
            await run(commandID: id)
        }
    }

    func run(commandID id: String) async {
        guard let command = settings.quickCommands.first(where: { $0.id == id }) else { return }
        if usesSharedBot, settings.telegramBot.commandsOverShared != true { return }
        AppLog.info("Telegram: quick command started")
        Task {
            let result = await runCommand(command)
            _ = await send(BotMessage(html: BotScreens.commandResult(command, ok: result.ok, text: result.text)))
        }
    }

    // MARK: - Reports and cleanup

    func startReport(ai: Bool, hours: Double, messageID: Int?) {
        let period = BotScreens.hoursText(hours)
        guard job == nil else {
            Task { _ = await send(BotMessage(html: "⏳ " + RunMessage.escape(String(localized: "Сейчас идёт другая задача, подождите.")))) }
            return
        }
        let title = ai ? String(localized: "Готовлю отчёт за \(period), 1–3 минуты…") : String(localized: "Готовлю быструю сводку за \(period)…")
        job = title
        let directory = settings.dailyReportDirectory
        var arguments = ["--since-hours", String(format: "%.2f", hours), "--no-open"]
        if !ai { arguments += ["--no-ai", "--no-document"] }
        Task {
            if let messageID { await edit(messageID, reportsScreen(job: title)) }
            let result = await Self.runScript("report.py", arguments, in: directory, timeout: .seconds(ai ? 900 : 180))
            job = nil
            let command: CommonCommand = ai ? .reportNow : .quickSummary
            let line = result.map { command.summary(of: $0.output) ?? "" } ?? ""
            let failed = result.map { command.isFailure(exitCode: $0.exitCode, summary: line) } ?? true
            AppLog.info("Telegram report finished\(failed ? " with error" : "")")
            let text = failed
                ? BotScreens.failure(String(localized: "Отчёт не получился"), output: result?.output ?? String(localized: "Не найден report.py в \(directory)"))
                : "✅ " + RunMessage.escape(String(localized: "Отчёт за \(period) отправлен"))
            var screen = reportsScreen(job: nil)
            screen.html = text + "\n\n" + screen.html
            if let messageID { await edit(messageID, screen) } else { _ = await send(screen) }
        }
    }

    func startCleanup(dryRun: Bool, messageID: Int?) {
        guard job == nil else {
            Task { _ = await send(BotMessage(html: "⏳ " + RunMessage.escape(String(localized: "Сейчас идёт другая задача, подождите.")))) }
            return
        }
        let title = dryRun ? String(localized: "Считаю, что можно удалить…") : String(localized: "Чищу сборки…")
        job = title
        let directory = settings.dailyReportDirectory
        Task {
            if let messageID { await edit(messageID, macScreen) }
            let result = await Self.runScript("cleanup.py", [dryRun ? "--dry-run" : "--now"], in: directory, timeout: .seconds(dryRun ? 300 : 1800))
            job = nil
            AppLog.info("Telegram cleanup \(dryRun ? "check" : "run") finished")
            let text = result.map { $0.exitCode == 0 ? BotScreens.cleanupOutput($0.output) : BotScreens.failure(String(localized: "Очистка не получилась"), output: $0.output) }
                ?? BotScreens.failure(String(localized: "Очистка не получилась"), output: String(localized: "Не найден cleanup.py в \(directory)"))
            _ = await send(BotMessage(html: text))
            if let messageID { await edit(messageID, macScreen) }
        }
    }

    func sendAllCommands() async {
        let url = URL(fileURLWithPath: settings.dailyReportDirectory).appending(path: "help.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return }
        // help.txt is Telegram HTML already (≤ 4000 characters, ~/Projects/CLAUDE.md).
        _ = await send(BotMessage(html: String(text.prefix(4000))))
    }

    /// `python3 <script>` in the `_daily-report` folder; the output without bot tokens. Nil when the script is missing.
    nonisolated private static func runScript(_ name: String, _ arguments: [String], in directory: String, timeout: Duration) async -> (exitCode: Int32, output: String)? {
        let path = (directory as NSString).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let result = try? await ProcessRunner.run("/usr/bin/env", ["python3", path] + arguments,
                                                         currentDirectory: URL(fileURLWithPath: directory), timeout: timeout) else {
            return (1, "")
        }
        return (result.exitCode, CommonCommand.redactingTokens(result.stdoutText + result.stderrText))
    }
}
