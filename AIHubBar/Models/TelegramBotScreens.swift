import Foundation

/// The screens' texts and buttons.
enum BotScreens {
    static func home(_ state: BotHomeState, now: Date) -> BotMessage {
        var lines = ["🏠 <b>AI Hub Bar</b> · " + RunMessage.escape(state.macName)]
        var limits: [String] = []
        if let session = state.session {
            var text = String(localized: "сессия \(percent(session.utilization))")
            if let resets = session.resetsAt, resets > now {
                text += " (" + String(localized: "сброс через \(MenuBarComposer.countdown(to: resets, now: now, long: true))") + ")"
            }
            limits.append(text)
        }
        if let week = state.week { limits.append(String(localized: "неделя \(percent(week.utilization))")) }
        lines.append("⏳ Claude: " + (limits.isEmpty ? String(localized: "лимиты ещё не загружены") : limits.joined(separator: ", ")))
        lines.append("🤖 " + String(localized: "Сессии: \(state.working) работают, \(state.waiting) ждут"))
        lines.append("🚀 " + String(localized: "Фоновые задачи: \(state.runs)"))
        return BotMessage(html: lines.joined(separator: "\n"), buttons: [
            [button("🤖", String(localized: "Сессии"), .show(.sessions)), button("🚀", String(localized: "Задача"), .show(.task))],
            [button("⏳", String(localized: "Лимиты"), .show(.limits)), button("📊", String(localized: "Отчёты"), .show(.reports))],
            [button("🧹", String(localized: "Мак"), .show(.mac))],
            [button("🔄", String(localized: "Обновить"), .show(.home)), button("❓", String(localized: "Команды"), .show(.help))],
        ])
    }

    // MARK: 🤖 Sessions and requests (stage 2)

    /// 🤖: waiting sessions first, then working ones; open permission requests numbered, with ✅ / ❌ when this chat
    /// may answer them (`canAnswer`), and «ℹ️» always.
    static func sessions(_ lines: [BotSessionLine], requests: [BotRequestLine], canAnswer: Bool, now: Date) -> BotMessage {
        var text = ["🤖 <b>" + RunMessage.escape(String(localized: "Сессии")) + "</b>"]
        let ordered = lines.filter(\.waiting) + lines.filter { !$0.waiting }
        if ordered.isEmpty { text.append(RunMessage.escape(String(localized: "Сессий сейчас нет."))) }
        for line in ordered.prefix(15) {
            var row = (line.waiting ? "✋ " : "⚙️ ") + "<b>" + RunMessage.escape(line.project) + "</b> · " + RunMessage.escape(line.agent)
            if let since = line.since { row += " · " + RunMessage.escape(RelativeTime.ago(since, now: now)) }
            if let detail = line.detail, !detail.isEmpty { row += "\n    " + RunMessage.escape(String(detail.prefix(120))) }
            text.append(row)
        }
        if ordered.count > 15 { text.append(RunMessage.escape(String(localized: "… и ещё \(ordered.count - 15)"))) }
        var rows: [[BotMessage.Button]] = []
        if !requests.isEmpty {
            text.append("")
            text.append("✋ <b>" + RunMessage.escape(String(localized: "Запросы разрешений")) + "</b>")
            for (index, request) in requests.prefix(8).enumerated() {
                let number = index + 1
                text.append("\(number). <b>" + RunMessage.escape(request.project) + "</b>: " + RunMessage.escape(request.tool)
                            + (request.summary.isEmpty ? "" : " — <code>" + RunMessage.escape(String(request.summary.prefix(80))) + "</code>"))
                var row = [BotMessage.Button(title: "ℹ️ \(number)", route: .requestDetails(request.id))]
                if canAnswer {
                    row.insert(BotMessage.Button(title: "❌ \(number)", route: .answer(requestID: request.id, allow: false)), at: 0)
                    row.insert(BotMessage.Button(title: "✅ \(number)", route: .answer(requestID: request.id, allow: true)), at: 0)
                }
                rows.append(row)
            }
            if !canAnswer { text.append("🔒 " + RunMessage.escape(String(localized: "Отвечать отсюда нельзя — включите на Mac «Ответы на запросы через общий бот»."))) }
        }
        rows.append([button("🔄", String(localized: "Обновить"), .show(.sessions)), back])
        return BotMessage(html: text.joined(separator: "\n"), buttons: rows)
    }

    /// A new permission request, sent by the Mac where Claude asks.
    static func request(_ request: ApprovalRequest, project: String, canAnswer: Bool) -> BotMessage {
        var html = TelegramApprovalText.html(ApprovalRequest(id: request.id, sessionID: request.sessionID, project: project,
                                                              tool: request.tool, summary: request.summary, created: request.created, pid: request.pid))
        var row = [button("ℹ️", String(localized: "Подробнее"), .requestDetails(request.id))]
        if canAnswer {
            row.insert(button("❌", String(localized: "Отклонить"), .answer(requestID: request.id, allow: false)), at: 0)
            row.insert(button("✅", String(localized: "Разрешить"), .answer(requestID: request.id, allow: true)), at: 0)
        } else {
            html += "\n🔒 " + RunMessage.escape(String(localized: "Ответить можно на Mac или с включёнными «Ответами на запросы через общий бот»."))
        }
        return BotMessage(html: html, buttons: [row])
    }

    /// The request message once it is answered (here, on the Mac or by Claude itself): no more buttons.
    static func requestClosed(_ request: ApprovalRequest, project: String, outcome: Bool?) -> BotMessage {
        let base = TelegramApprovalText.html(ApprovalRequest(id: request.id, sessionID: request.sessionID, project: project,
                                                              tool: request.tool, summary: request.summary, created: request.created, pid: request.pid))
        let note = switch outcome {
        case true?: "✅ " + RunMessage.escape(String(localized: "Разрешено"))
        case false?: "❌ " + RunMessage.escape(String(localized: "Отклонено"))
        case nil: "☑️ " + RunMessage.escape(String(localized: "Ответ уже дан"))
        }
        return BotMessage(html: base + "\n" + note)
    }

    /// «Подробнее»: the whole request and what the session was asked to do.
    static func requestDetails(_ request: ApprovalRequest, project: String, task: String?, folder: String?, canAnswer: Bool) -> BotMessage {
        var lines = ["✋ <b>" + RunMessage.escape(project) + "</b> — " + RunMessage.escape(request.tool)]
        if !request.summary.isEmpty { lines.append("<pre>" + RunMessage.escape(request.summary) + "</pre>") }
        if let task, !task.isEmpty { lines.append(RunMessage.escape(String(localized: "Задача сессии:")) + " " + RunMessage.escape(String(task.prefix(300)))) }
        if let folder { lines.append("📁 <code>" + RunMessage.escape(PathText.tilde(folder)) + "</code>") }
        var rows: [[BotMessage.Button]] = [[button("🤖", String(localized: "Сессии"), .show(.sessions))]]
        if canAnswer {
            rows.insert([button("✅", String(localized: "Разрешить"), .answer(requestID: request.id, allow: true)),
                         button("❌", String(localized: "Отклонить"), .answer(requestID: request.id, allow: false))], at: 0)
        }
        return BotMessage(html: lines.joined(separator: "\n"), buttons: rows)
    }

    // MARK: ⏳ Limits (stage 2)

    /// ⏳: every AI service's windows with a bar, the reset and the forecast; the Telegram alerts switch.
    static func limits(_ services: [BotLimitService], alertsOn: Bool, thresholds: [Int], now: Date) -> BotMessage {
        var lines = ["⏳ <b>" + RunMessage.escape(String(localized: "Лимиты")) + "</b>"]
        if services.isEmpty { lines.append(RunMessage.escape(String(localized: "лимиты ещё не загружены"))) }
        for service in services {
            lines.append("")
            lines.append("<b>" + RunMessage.escape(service.title) + "</b>" + (service.isStale ? " · " + RunMessage.escape(String(localized: "устарело")) : ""))
            if let error = service.error, service.windows.isEmpty { lines.append("⚠️ " + RunMessage.escape(error)) }
            for window in service.windows.prefix(5) {
                var line = RunMessage.escape(window.title) + " "
                if let percent = window.percent {
                    line += "<code>" + bar(percent) + "</code> " + "\(Int(percent.rounded())) %"
                } else if let detail = window.detail {
                    line += RunMessage.escape(detail)
                }
                if let resets = window.resetsAt, resets > now {
                    line += " · " + RunMessage.escape(String(localized: "сброс через \(MenuBarComposer.countdown(to: resets, now: now, long: true))"))
                }
                if let runsOut = window.runsOutAt, runsOut > now {
                    line += "\n    ⚠️ " + RunMessage.escape(String(localized: "при этом темпе кончится к \(runsOut.formatted(date: .omitted, time: .shortened))"))
                }
                lines.append(line)
            }
        }
        lines.append("")
        let levels = thresholds.map { "\($0)" }.joined(separator: "/")
        lines.append("🔔 " + RunMessage.escape(alertsOn
            ? String(localized: "Уведомления в Telegram: при \(levels) %")
            : String(localized: "Уведомления о лимитах в Telegram выключены")))
        return BotMessage(html: lines.joined(separator: "\n"), buttons: [
            [button(alertsOn ? "🔕" : "🔔", alertsOn ? String(localized: "Выключить уведомления") : String(localized: "Включить уведомления"), .limitAlerts(!alertsOn))],
            [button("🔄", String(localized: "Обновить"), .show(.limits)), back],
        ])
    }

    // MARK: 🚀 Tasks and runs (stage 3)

    /// 🚀: projects to start a task in (`locked` — over the shared bot without its switch), then the runs: running ones
    /// with 📜 / ⏹, the last finished ones with their PR link (a link only — PRs are merged in GitHub).
    static func task(projects: [BotTaskProject], runs: [BotRunLine], locked: Bool, now: Date) -> BotMessage {
        var lines = ["🚀 <b>" + RunMessage.escape(String(localized: "Задача")) + "</b>"]
        var rows: [[BotMessage.Button]] = []
        if locked {
            lines.append("🔒 " + RunMessage.escape(String(localized: "Задачи через общий бот выключены. На Mac: Настройки → Модули → Telegram → «Задачи через общий бот».")))
        } else if projects.isEmpty {
            lines.append(RunMessage.escape(String(localized: "Проектов нет: у профиля нет папки с git-проектами.")))
        } else {
            lines.append(RunMessage.escape(String(localized: "Выберите проект, затем напишите задачу. Её выполнит Claude Code в фоне.")))
            let buttons = projects.prefix(12).map { BotMessage.Button(title: "📁 " + String($0.name.prefix(24)), route: .taskProject($0.key)) }
            rows += stride(from: 0, to: buttons.count, by: 2).map { Array(buttons[$0..<min($0 + 2, buttons.count)]) }
        }
        let running = runs.filter { $0.state == .running }
        let finished = runs.filter { $0.state != .running }.prefix(3)
        if !running.isEmpty || !finished.isEmpty {
            lines.append("")
            lines.append("<b>" + RunMessage.escape(String(localized: "Фоновые задачи")) + "</b>")
        }
        for (index, run) in running.prefix(6).enumerated() {
            let number = index + 1
            let minutes = max(0, Int(now.timeIntervalSince(run.startedAt) / 60))
            lines.append("\(number). " + (run.paused ? "⏸ " : "⚙️ ") + "<b>" + RunMessage.escape(run.project) + "</b>: "
                         + RunMessage.escape(RunMessage.taskStart(run.task)) + " · " + RunMessage.escape(String(localized: "\(minutes) мин")))
            var row = [BotMessage.Button(title: "📜 \(number)", route: .runLog(run.id))]
            if !locked { row.append(BotMessage.Button(title: "⏹ \(number)", route: .runStopAsk(run.id))) }
            rows.append(row)
        }
        for run in finished {
            var line = RunMessage.icon(run.state) + " <b>" + RunMessage.escape(run.project) + "</b>: " + RunMessage.escape(RunMessage.taskStart(run.task))
            if let url = run.pullRequestURL {
                let number = url.split(separator: "/").last.map { " #\($0)" } ?? ""
                line += " — <a href=\"" + RunMessage.escape(url) + "\">PR" + number + "</a>"
            }
            lines.append(line)
        }
        rows.append([button("🔄", String(localized: "Обновить"), .show(.task)), back])
        return BotMessage(html: lines.joined(separator: "\n"), buttons: rows)
    }

    static func taskAskText(project: String) -> BotMessage {
        BotMessage(html: "🚀 <b>" + RunMessage.escape(project) + "</b>\n"
                   + RunMessage.escape(String(localized: "Напишите задачу одним сообщением. /cancel — отмена.")),
                   buttons: [[button("✖️", String(localized: "Отмена"), .taskCancel)]])
    }

    /// The task shown back before it starts (§4).
    static func taskConfirm(project: String, text: String) -> BotMessage {
        BotMessage(html: "🚀 " + RunMessage.escape(String(localized: "Запустить в фоне в «\(project)»?")) + "\n<blockquote>"
                   + RunMessage.escape(String(text.prefix(1500))) + "</blockquote>",
                   buttons: [[button("▶️", String(localized: "Запустить"), .taskGo), button("✖️", String(localized: "Отмена"), .taskCancel)]])
    }

    /// The launch stopped to ask: the session is above 90 %, or Claude already works in the folder.
    static func taskQuestion(_ text: String, limit: Bool) -> BotMessage {
        let rows: [[BotMessage.Button]] = limit
            ? [[button("▶️", String(localized: "Всё равно"), .taskForce), button("⏰", String(localized: "После сброса"), .taskAfterReset)],
               [button("✖️", String(localized: "Отмена"), .taskCancel)]]
            : [[button("✅", String(localized: "Да, в worktree"), .taskWorktree), button("✖️", String(localized: "Отмена"), .taskCancel)]]
        return BotMessage(html: "⚠️ " + RunMessage.escape(text), buttons: rows)
    }

    /// The last steps of a run's log.
    static func runLog(_ run: BotRunLine, entries: [StreamJSON.Entry]) -> BotMessage {
        var lines = ["📜 <b>" + RunMessage.escape(run.project) + "</b>: " + RunMessage.escape(RunMessage.taskStart(run.task))]
        let tail = entries.suffix(12).map { entry -> String in
            let icon = switch entry.kind {
            case .text: "💬"
            case .tool: "🔧"
            case .result: "✅"
            case .error: "❌"
            }
            let flat = entry.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            return icon + " " + String(flat.prefix(160))
        }
        lines.append(tail.isEmpty ? RunMessage.escape(String(localized: "В журнале пока пусто.")) : "<pre>" + RunMessage.escape(tail.joined(separator: "\n")) + "</pre>")
        var row = [button("🔄", String(localized: "Обновить"), .runLog(run.id))]
        if run.state == .running { row.append(button("⏹", String(localized: "Остановить"), .runStopAsk(run.id))) }
        return BotMessage(html: lines.joined(separator: "\n"), buttons: [row, [button("🚀", String(localized: "Задача"), .show(.task))]])
    }

    static func runStopConfirm(_ run: BotRunLine) -> BotMessage {
        BotMessage(html: "⏹ " + RunMessage.escape(String(localized: "Остановить «\(RunMessage.taskStart(run.task))» в «\(run.project)»?")),
                   buttons: [[button("⏹", String(localized: "Остановить"), .runStop(run.id)), button("✖️", String(localized: "Отмена"), .show(.task))]])
    }

    /// `▓▓▓▓░░░░░░` for 0…100 %.
    static func bar(_ percent: Double) -> String {
        let filled = min(10, max(0, Int((percent / 10).rounded())))
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: 10 - filled)
    }

    /// `job` — what is running now, if anything; `otherBot` — `report.py` sends through another bot.
    static func reports(job: String?, otherBot: Bool) -> BotMessage {
        var lines = ["📊 <b>" + RunMessage.escape(String(localized: "Отчёты")) + "</b>",
                     RunMessage.escape(String(localized: "С AI — 1–3 минуты, с HTML-файлом; быстрая сводка — за секунды, без AI."))]
        if otherBot { lines.append("ℹ️ " + RunMessage.escape(String(localized: "Отчёт пришлёт бот из _daily-report/config.json."))) }
        if let job { lines.append("⏳ " + RunMessage.escape(job)) }
        return BotMessage(html: lines.joined(separator: "\n"), buttons: [
            [button("✨", String(localized: "С AI с утра"), .report(ai: true, hours: nil)),
             button("⚡", String(localized: "Быстрая сводка"), .report(ai: false, hours: nil))],
            BotRoute.reportHours.map { hours in
                button("✨", String(localized: "\(hours) ч"), .report(ai: true, hours: hours))
            },
            [back],
        ])
    }

    /// `keepAwake` — «Не спать» holds the Mac now; nil when that module isn't installed.
    static func mac(freeBytes: Int64?, job: String?, keepAwake: Bool? = nil) -> BotMessage {
        var lines = ["🧹 <b>" + RunMessage.escape(String(localized: "Мак")) + "</b>"]
        if let freeBytes { lines.append("💾 " + RunMessage.escape(String(localized: "Свободно \(CommandStore.diskText(freeBytes))"))) }
        if let keepAwake {
            lines.append("☕ " + RunMessage.escape(keepAwake ? String(localized: "«Не спать» включено") : String(localized: "«Не спать» выключено")))
        }
        if let job { lines.append("⏳ " + RunMessage.escape(job)) }
        var rows = [[button("🔍", String(localized: "Что удалит очистка"), .cleanupCheck), button("🧹", String(localized: "Очистить"), .cleanupAsk)]]
        if let keepAwake {
            rows.append([keepAwake ? button("☕", String(localized: "Выключить «Не спать»"), .keepAwake(false))
                                   : button("☕", String(localized: "Не спать 1 ч"), .keepAwake(true))])
        }
        rows.append([back])
        return BotMessage(html: lines.joined(separator: "\n"), buttons: rows)
    }

    // MARK: ⚙️ Settings (stage 4)

    /// ⚙️: which notifications come, the quiet hours, an hour of silence, the morning report time (read only:
    /// it belongs to `_daily-report`), and the way to the menu set-up.
    static func settings(events: [(BotEvent, Bool)], quiet: QuietHours?, mutedUntil: Date?, morningHour: Int?, now: Date) -> BotMessage {
        var lines = ["⚙️ <b>" + RunMessage.escape(String(localized: "Настройки")) + "</b>",
                     RunMessage.escape(String(localized: "Что приходит в Telegram — нажмите, чтобы включить или выключить."))]
        lines.append("🌙 " + RunMessage.escape(String(localized: "Тихие часы: \(quiet?.title ?? String(localized: "нет"))")))
        if let mutedUntil, mutedUntil > now {
            lines.append("🔕 " + RunMessage.escape(String(localized: "Тишина до \(mutedUntil.formatted(date: .omitted, time: .shortened))")))
        }
        if let morningHour { lines.append("🌅 " + RunMessage.escape(String(localized: "Утренний отчёт: \(String(format: "%02d:00", morningHour)) (меняется в _daily-report)"))) }
        var rows = events.map { event, on in
            [BotMessage.Button(title: (on ? "✅ " : "☐ ") + event.title, route: .event(event))]
        }
        rows.append([BotMessage.Button(title: (quiet == nil ? "● " : "○ ") + String(localized: "Без тихих часов"), route: .quiet(nil))]
                    + QuietHours.presets.map { BotMessage.Button(title: (quiet == $0 ? "● " : "○ ") + String(format: "%02d–%02d", $0.from, $0.to), route: .quiet($0)) })
        rows.append([(mutedUntil ?? .distantPast) > now
            ? button("🔔", String(localized: "Снять тишину"), .mute(false))
            : button("🔕", String(localized: "Тишина на 1 ч"), .mute(true))])
        rows.append([button("⚙️", String(localized: "Настроить меню"), .show(.menu)), back])
        return BotMessage(html: lines.joined(separator: "\n"), buttons: rows)
    }

    static var cleanupConfirm: BotMessage {
        BotMessage(html: "⚠️ " + RunMessage.escape(String(localized: "Удалить сборки, кэши и сбросить симуляторы? Не во время сборки.")), buttons: [
            [button("✅", String(localized: "Да, очистить"), .cleanupRun), button("✖️", String(localized: "Отмена"), .show(.mac))],
        ])
    }

    static func help(hasAllCommands: Bool) -> BotMessage {
        let lines = ["❓ <b>" + RunMessage.escape(String(localized: "Команды")) + "</b>"]
            + BotCommand.menuList.map { "/\($0.command) — " + RunMessage.escape($0.description) }
        var rows = [[button("⚙️", String(localized: "Настроить меню"), .show(.menu))], [back]]
        if hasAllCommands { rows.insert([button("📖", String(localized: "Все команды Mac"), .allCommands)], at: 0) }
        return BotMessage(html: lines.joined(separator: "\n"), buttons: rows)
    }

    /// ⚙️ «Меню»: a switch per screen and quick command (🏠 always stays), the buttons in a row. `profile` — the
    /// current profile's name when it has a menu of its own.
    static func menuSetup(_ config: BotMenuConfig, commands: [QuickCommand], profile: String?) -> BotMessage {
        var lines = ["⚙️ <b>" + RunMessage.escape(String(localized: "Меню внизу чата")) + "</b>"]
        if let profile { lines.append(RunMessage.escape(String(localized: "Своё меню профиля «\(profile)»."))) }
        lines.append(RunMessage.escape(String(localized: "Нажмите, чтобы добавить или убрать кнопку; порядок — в Настройках на Mac.")))
        let candidates = BotScreen.menuScreens.filter { $0 != .home }.map(BotMenuItem.screen) + commands.map { BotMenuItem.command($0.id) }
        var rows = candidates.map { item in
            [BotMessage.Button(title: (config.contains(item) ? "✅ " : "☐ ") + BotMenu.title(item, commands: commands), route: .menuToggle(item))]
        }
        rows.append([2, 3].map { columns in
            BotMessage.Button(title: (config.columns == columns ? "● " : "○ ") + String(localized: "\(columns) в ряд"), route: .menuColumns(columns))
        })
        rows.append([button("✅", String(localized: "Готово"), .menuDone)])
        return BotMessage(html: lines.joined(separator: "\n"), buttons: rows)
    }

    /// «Запустить?» for a quick command marked to ask first, and for any over the shared bot.
    static func confirmCommand(_ command: QuickCommand) -> BotMessage {
        BotMessage(html: "▶️ " + RunMessage.escape(String(localized: "Запустить «\(command.title)» на Mac?")), buttons: [[
            button("✅", String(localized: "Запустить"), .runCommand(command.id)), button("✖️", String(localized: "Отмена"), .show(.home)),
        ]])
    }

    /// A quick command's result.
    static func commandResult(_ command: QuickCommand, ok: Bool, text: String) -> String {
        (ok ? "✅" : "❌") + " <b>" + RunMessage.escape(command.title) + "</b>" + (text.isEmpty ? "" : "\n<code>" + RunMessage.escape(String(text.prefix(3000))) + "</code>")
    }

    /// The cleanup output: its first line and up to 24 more, as `bot.py` sent it.
    static func cleanupOutput(_ output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var body = lines.prefix(25).joined(separator: "\n")
        if lines.count > 25 { body += "\n" + String(localized: "… ещё \(lines.count - 25) строк в logs/cleanup.jsonl") }
        return "<pre>" + RunMessage.escape(body.isEmpty ? String(localized: "нет вывода") : body) + "</pre>"
    }

    /// A failed script: its last lines.
    static func failure(_ title: String, output: String) -> String {
        let tail = output.split(separator: "\n").suffix(6).joined(separator: "\n")
        return "❌ " + RunMessage.escape(title) + (tail.isEmpty ? "" : "\n<code>" + RunMessage.escape(tail) + "</code>")
    }

    /// Hours since the morning report, as `bot.py` counted: from today's report hour, or yesterday's in the first
    /// 5 minutes after it and before it.
    static func hoursSinceMorning(now: Date, hour: Int = 10, calendar: Calendar = .current) -> Double {
        var anchor = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        if now < anchor.addingTimeInterval(5 * 60) {
            anchor = calendar.date(byAdding: .day, value: -1, to: anchor) ?? anchor
        }
        return max(0.25, now.timeIntervalSince(anchor) / 3600)
    }

    /// «45 мин», «3 ч», «1,5 ч».
    static func hoursText(_ hours: Double) -> String {
        if hours < 1 { return String(localized: "\(Int((hours * 60).rounded())) мин") }
        if abs(hours - hours.rounded()) < 0.05 { return String(localized: "\(Int(hours.rounded())) ч") }
        return String(localized: "\(hours.formatted(.number.precision(.fractionLength(1)))) ч")
    }

    private static var back: BotMessage.Button { button("⬅️", String(localized: "Главная"), .show(.home)) }

    private static func button(_ icon: String, _ title: String, _ route: BotRoute) -> BotMessage.Button {
        BotMessage.Button(title: icon + " " + title, route: route)
    }

    private static func percent(_ value: Double) -> String { "\(Int(value.rounded())) %" }
}
