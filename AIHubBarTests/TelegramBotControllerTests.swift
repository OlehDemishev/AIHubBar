import Foundation
import Testing
@testable import AIHubBar

/// What the bot does with what comes from Telegram (docs/specs/SPEC-telegram.md). Telegram is a fake here: nothing leaves
/// the Mac, and answers to permission requests go to a temporary folder.
@MainActor
struct TelegramBotControllerTests {
    /// The controller on fake Telegram, bound to chat 42 with its own bot.
    @MainActor
    final class Bot {
        let settings: AppSettings
        let sessions: SessionStore
        let controller: TelegramBotController
        let approvalsFolder: URL
        var calls: [(method: String, parameters: [String: Any])] = []
        var failSends = false
        var nextUpdates: (code: Int, data: Data?) = (200, Data(#"{"ok":true,"result":[]}"#.utf8))
        var ranCommands: [String] = []
        private var nextMessage = 100

        init(chat: String = "42") {
            let name = "telegram-controller-\(UUID().uuidString)"
            settings = AppSettings(defaults: UserDefaults(suiteName: name)!)
            let folder = FileManager.default.temporaryDirectory.appending(path: name)
            approvalsFolder = folder.appending(path: "approvals")
            // An empty folder: no `_daily-report` of this Mac, whose config could bind a chat.
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            settings.dailyReportDirectory = folder.path
            settings.telegramChatID = chat
            settings.telegramApprovals = true
            settings.telegramBot.shared = false
            settings.telegramBot.answersHere = true
            sessions = SessionStore(directory: folder.appending(path: "sessions"), approvalsDirectory: approvalsFolder)
            let runs = RunStore(settings: settings)
            controller = TelegramBotController(
                settings: settings, sessions: sessions, runs: runs, usage: UsageStore(settings: settings, sessions: sessions),
                approvals: TelegramApprovals(settings: settings, sessions: sessions)
            )
            controller.token = "not-a-token"
            controller.reloadOwnBot = { _ in }
            controller.transport = { [self] method, parameters, _ in
                calls.append((method, parameters))
                switch method {
                case "getMe":
                    return (200, Data(#"{"ok":true,"result":{"username":"test_bot"}}"#.utf8))
                case "getUpdates":
                    return nextUpdates
                case "sendMessage" where failSends:
                    return (0, nil)
                case "sendMessage":
                    nextMessage += 1
                    return (200, Data(#"{"ok":true,"result":{"message_id":\#(nextMessage)}}"#.utf8))
                default:
                    return (200, Data("{}".utf8))
                }
            }
            controller.runCommand = { [self] command in
                ranCommands.append(command.id)
                return (true, "готово")
            }
        }

        var methods: [String] { calls.map(\.method) }
        var sent: [String] { calls.filter { $0.method == "sendMessage" }.compactMap { $0.parameters["text"] as? String } }
        func count(_ method: String) -> Int { calls.filter { $0.method == method }.count }

        /// The answer the waiting hook would read; nil when nothing was decided.
        func decision(_ id: String) -> String? {
            try? String(contentsOf: approvalsFolder.appending(path: "\(id).decision"), encoding: .utf8)
        }

        func addRequest(_ id: String = "req1", session: String = "s1") {
            sessions.approvals[session] = ApprovalRequest(id: id, sessionID: session, project: "Ambo", tool: "Bash", summary: "ls",
                                                          created: Date.now.timeIntervalSince1970, pid: nil)
        }

        /// The shared bot, paired with the same chat: its switches are what's left to say no.
        func useSharedBot() {
            settings.telegramBot.shared = true
            controller.relay.chat = "42"
        }

        /// A quick command, also in the menu at the bottom; returns it with the text its button sends.
        func addMenuCommand(confirm: Bool = false) -> (command: QuickCommand, text: String) {
            let command = addCommand(confirm: confirm)
            var menu = settings.telegramBot.menu(for: nil)
            menu.toggle(.command(command.id))
            settings.telegramBot.setMenu(menu, for: nil)
            let text = controller.currentMenu.entries.first { $0.item == .command(command.id) }?.title ?? ""
            return (command, text)
        }

        func addCommand(confirm: Bool = false) -> QuickCommand {
            var command = QuickCommand(title: "Сборка", kind: .script, value: "true")
            command.confirm = confirm
            settings.quickCommands = [command]
            return command
        }

        func project(_ path: String = "/tmp/ambo") throws -> Project {
            try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: ["name": "Ambo", "path": path]))
        }

        func reply(_ call: String, _ parameters: [String: Any] = [:]) async throws -> [String: Any] {
            let data = await controller.handleApp(call, try JSONSerialization.data(withJSONObject: parameters))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    private func message(_ text: String, chat: String = "42", from: String = "42", isPrivate: Bool = true, age: TimeInterval = 0) -> BotUpdate {
        BotUpdate(updateID: 1, chatID: chat, fromID: from, isPrivate: isPrivate, date: Date.now.addingTimeInterval(-age),
                  kind: .message(text: text, messageID: 7))
    }

    private func press(_ route: BotRoute, chat: String = "42", from: String = "42") -> BotUpdate {
        press(data: route.data, chat: chat, from: from)
    }

    private func press(data: String, chat: String = "42", from: String = "42") -> BotUpdate {
        BotUpdate(updateID: 2, chatID: chat, fromID: from, isPrivate: true, date: nil,
                  kind: .press(callbackID: "c1", data: data, messageID: 9))
    }

    /// Lets the tasks a press started (a quick command) finish.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: Who the bot answers

    @Test func strangersGetNothingBack() async {
        let bot = Bot()
        bot.addRequest()
        await bot.controller.handle(message("/menu", chat: "99", from: "99"), afterGap: false)
        await bot.controller.handle(press(.answer(requestID: "req1", allow: true), chat: "99", from: "99"), afterGap: false)
        // In our chat's id but someone else's, or a group that has the same id.
        await bot.controller.handle(message("/menu", from: "99"), afterGap: false)
        await bot.controller.handle(message("/menu", isPrivate: false), afterGap: false)
        #expect(bot.calls.isEmpty)
        #expect(bot.decision("req1") == nil)
    }

    @Test func noBoundChatAnswersNobody() async {
        let bot = Bot(chat: "")
        await bot.controller.handle(message("/menu"), afterGap: false)
        await bot.controller.handle(press(.show(.home)), afterGap: false)
        #expect(bot.calls.isEmpty)
    }

    @Test func oldMessagesAreSkipped() async {
        let bot = Bot()
        await bot.controller.handle(message("/menu", age: BotUpdate.maxAge + 60), afterGap: false)
        #expect(bot.calls.isEmpty)
        await bot.controller.handle(message("/menu"), afterGap: false)
        #expect(bot.count("sendMessage") == 1)
    }

    // MARK: Binding a chat

    @Test func onlyTheCodeBindsAChat() async throws {
        let bot = Bot(chat: "")
        await bot.controller.loadName()
        let link = try #require(bot.controller.startBinding())
        let code = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)

        await bot.controller.handle(message("/start 000000", chat: "7", from: "7"), afterGap: false)
        await bot.controller.handle(message("/start \(code)", chat: "7", from: "7", isPrivate: false), afterGap: false)
        await bot.controller.handle(message("/start \(code)", chat: "7", from: "7", age: BotUpdate.maxAge + 60), afterGap: false)
        #expect(bot.settings.telegramChatID.isEmpty)
        #expect(bot.count("sendMessage") == 0)

        await bot.controller.handle(message("/start \(code)", chat: "7", from: "7"), afterGap: false)
        #expect(bot.settings.telegramChatID == "7")
        #expect(bot.controller.bindingCode == nil)
        #expect(bot.count("sendMessage") == 2) // «Чат привязан» and 🏠

        // Used once: another person with the same link stays out.
        await bot.controller.handle(message("/start \(code)", chat: "8", from: "8"), afterGap: false)
        #expect(bot.settings.telegramChatID == "7")
    }

    @Test func cancelledBindingBindsNothing() async throws {
        let bot = Bot(chat: "")
        await bot.controller.loadName()
        let link = try #require(bot.controller.startBinding())
        let code = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        bot.controller.cancelBinding()
        await bot.controller.handle(message("/start \(code)", chat: "7", from: "7"), afterGap: false)
        #expect(bot.settings.telegramChatID.isEmpty)
    }

    // MARK: Presses

    /// After a gap (the Mac slept) a press may be hours old: it can open a screen but can't act (§4).
    @Test func afterAGapPressesOnlyNavigate() async {
        let bot = Bot()
        bot.addRequest()
        await bot.controller.handle(press(.answer(requestID: "req1", allow: true)), afterGap: true)
        await bot.controller.handle(press(.cleanupRun), afterGap: true)
        #expect(bot.decision("req1") == nil)
        #expect(bot.controller.job == nil)
        #expect(bot.methods == ["answerCallbackQuery", "answerCallbackQuery"])
        #expect(bot.calls.allSatisfy { $0.parameters["text"] != nil })

        bot.calls = []
        await bot.controller.handle(press(.show(.mac)), afterGap: true)
        #expect(bot.methods == ["answerCallbackQuery", "editMessageText"])
    }

    @Test func aButtonNobodyKnowsLeadsHome() async {
        let bot = Bot()
        await bot.controller.handle(press(data: "drop:everything"), afterGap: false)
        #expect(bot.methods == ["answerCallbackQuery", "editMessageText"])
        #expect(bot.calls[0].parameters["text"] != nil)
    }

    @Test func settingsChangeFromThePress() async {
        let bot = Bot()
        bot.settings.limitAlertsToTelegram = false
        await bot.controller.handle(press(.event(.limitAlerts)), afterGap: false)
        #expect(bot.settings.limitAlertsToTelegram)
        await bot.controller.handle(press(.mute(true)), afterGap: false)
        #expect(bot.settings.telegramBot.mutedUntil != nil)
        var awake: Bool?
        bot.controller.setKeepAwake = { awake = $0 }
        await bot.controller.handle(press(.keepAwake(true)), afterGap: false)
        #expect(awake == true)
    }

    /// Cleaning takes the confirmation's own button.
    @Test func cleanupAsksFirst() async {
        let bot = Bot()
        await bot.controller.handle(message("/clean"), afterGap: false)
        await bot.controller.handle(press(.cleanupAsk), afterGap: false)
        #expect(bot.controller.job == nil)
        #expect(bot.count("sendMessage") == 1)
        #expect(bot.count("editMessageText") == 1)
    }

    // MARK: Permission requests

    @Test func aRequestIsSentOnce() async {
        let bot = Bot()
        bot.addRequest()
        await bot.controller.syncRequests()
        await bot.controller.syncRequests()
        #expect(bot.count("sendMessage") == 1)
    }

    @Test func aFailedRequestWaitsBeforeTheNextTry() async {
        let bot = Bot()
        bot.addRequest()
        bot.failSends = true
        await bot.controller.syncRequests()
        bot.failSends = false
        await bot.controller.syncRequests()
        #expect(bot.count("sendMessage") == 1)
    }

    @Test func aClosedRequestLosesItsButtons() async throws {
        let bot = Bot()
        bot.addRequest()
        await bot.controller.syncRequests()
        bot.sessions.approvals = [:]
        await bot.controller.syncRequests()
        await bot.controller.syncRequests()
        #expect(bot.count("editMessageText") == 1)
        let edit = try #require(bot.calls.first { $0.method == "editMessageText" })
        #expect(edit.parameters["message_id"] as? Int == 101)
    }

    @Test func requestsWaitForASetUpBot() async {
        let bot = Bot()
        bot.addRequest()
        bot.settings.telegramApprovals = false
        await bot.controller.syncRequests()
        bot.settings.telegramApprovals = true
        bot.controller.token = nil
        await bot.controller.syncRequests()
        bot.controller.token = "not-a-token"
        bot.controller.isActive = { false }
        await bot.controller.syncRequests()
        #expect(bot.calls.isEmpty)
    }

    @Test func anAnswerReachesTheHookOnce() async {
        let bot = Bot()
        bot.addRequest()
        await bot.controller.handle(press(.answer(requestID: "req1", allow: true)), afterGap: false)
        #expect(bot.decision("req1") == "allow")
        #expect(bot.sessions.approvals.isEmpty)
    }

    @Test func aDenyIsADeny() async {
        let bot = Bot()
        bot.addRequest()
        await bot.controller.handle(press(.answer(requestID: "req1", allow: false)), afterGap: false)
        #expect(bot.decision("req1") == "deny")
    }

    @Test func aRequestThatIsGoneTakesNoAnswer() async {
        let bot = Bot()
        bot.addRequest()
        await bot.controller.handle(press(.answer(requestID: "other", allow: true)), afterGap: false)
        #expect(bot.decision("other") == nil)
        #expect(bot.decision("req1") == nil)
    }

    /// Own bot: only the Mac that reads the bot answers.
    @Test func aMacThatDoesntAnswerTakesNoAnswer() async {
        let bot = Bot()
        bot.addRequest()
        bot.settings.telegramBot.answersHere = false
        await bot.controller.handle(press(.answer(requestID: "req1", allow: true)), afterGap: false)
        #expect(bot.decision("req1") == nil)
    }

    // MARK: The shared bot's switches (§7)

    @Test func answersOverTheSharedBotNeedTheirSwitch() async throws {
        let bot = Bot()
        bot.addRequest()
        bot.useSharedBot()
        let refused = try await bot.reply("answer", ["id": "req1", "allow": true])
        #expect(refused["ok"] as? Bool == false)
        #expect(bot.decision("req1") == nil)

        bot.settings.telegramBot.answersOverShared = true
        let allowed = try await bot.reply("answer", ["id": "req1", "allow": true])
        #expect(allowed["ok"] as? Bool == true)
        #expect(bot.decision("req1") == "allow")
    }

    @Test func commandsOverTheSharedBotNeedTheirSwitch() async throws {
        let bot = Bot()
        let command = bot.addCommand()
        bot.useSharedBot()

        await bot.controller.handle(press(.runCommand(command.id)), afterGap: false)
        await settle()
        // The press was read (it isn't a stranger's), and still ran nothing.
        #expect(bot.count("answerCallbackQuery") == 1)
        let refused = try await bot.reply("command", ["id": command.id])
        #expect(refused["ok"] as? Bool == false)
        #expect(bot.ranCommands.isEmpty)

        bot.settings.telegramBot.commandsOverShared = true
        let allowed = try await bot.reply("command", ["id": command.id])
        #expect(allowed["ok"] as? Bool == true)
        #expect(bot.ranCommands == [command.id])

        await bot.controller.handle(press(.runCommand(command.id)), afterGap: false)
        for _ in 0..<200 where bot.ranCommands.count < 2 { await Task.yield() }
        #expect(bot.ranCommands.count == 2)
    }

    /// From the menu at the bottom: over the shared bot a command is always asked first.
    @Test func aMenuCommandOverTheSharedBotAsksFirst() async {
        let bot = Bot()
        let (_, text) = bot.addMenuCommand()
        bot.useSharedBot()

        // The switch is off: a note, and nothing runs.
        await bot.controller.handle(message(text), afterGap: false)
        await settle()
        #expect(bot.ranCommands.isEmpty)
        #expect(bot.count("sendMessage") == 1)

        bot.settings.telegramBot.commandsOverShared = true
        await bot.controller.handle(message(text), afterGap: false)
        await settle()
        #expect(bot.ranCommands.isEmpty)
        #expect(bot.count("sendMessage") == 2)
    }

    @Test func aMenuCommandFollowsItsConfirmSwitch() async {
        let bot = Bot()
        let (command, text) = bot.addMenuCommand(confirm: true)

        await bot.controller.handle(message(text), afterGap: false)
        await settle()
        #expect(bot.ranCommands.isEmpty)
        #expect(bot.count("sendMessage") == 1)

        bot.settings.quickCommands[0].confirm = false
        await bot.controller.handle(message(text), afterGap: false)
        for _ in 0..<200 where bot.ranCommands.isEmpty { await Task.yield() }
        #expect(bot.ranCommands == [command.id])
    }

    @Test func tasksOverTheSharedBotNeedTheirSwitch() async throws {
        let bot = Bot()
        let project = try bot.project()
        bot.controller.projectList = { [project] }
        bot.useSharedBot()
        let key = BotRoute.projectKey(project.path)

        await bot.controller.handle(press(.taskProject(key)), afterGap: false)
        #expect(bot.count("answerCallbackQuery") == 1)
        #expect(bot.controller.taskDraft == nil)
        let refused = try await bot.reply("task", ["project": key, "text": "Почини сборку"])
        #expect(refused["ok"] as? Bool == false)

        bot.settings.telegramBot.tasksOverShared = true
        await bot.controller.handle(press(.taskProject(key)), afterGap: false)
        #expect(bot.controller.taskDraft?.path == project.path)
    }

    // MARK: 🚀 A task

    @Test func aMessageBecomesTheTask() async throws {
        let bot = Bot()
        let project = try bot.project()
        bot.controller.projectList = { [project] }
        await bot.controller.handle(press(.taskProject(BotRoute.projectKey(project.path))), afterGap: false)
        #expect(bot.controller.taskDraft?.text == nil)

        await bot.controller.handle(message("  Почини сборку  "), afterGap: false)
        #expect(bot.controller.taskDraft?.text == "Почини сборку")
        #expect(bot.sent.last?.contains("Почини сборку") == true)
    }

    @Test func commandsArentTakenForATask() async throws {
        let bot = Bot()
        let project = try bot.project()
        bot.controller.projectList = { [project] }
        await bot.controller.handle(press(.taskProject(BotRoute.projectKey(project.path))), afterGap: false)
        await bot.controller.handle(message("/menu"), afterGap: false)
        #expect(bot.controller.taskDraft?.text == nil)
    }

    @Test func aDraftLapses() async {
        let bot = Bot()
        bot.controller.taskDraft = ("/tmp/ambo", "Ambo", nil, .now.addingTimeInterval(-1))
        await bot.controller.handle(message("Почини сборку"), afterGap: false)
        #expect(bot.controller.taskDraft == nil)
    }

    @Test func cancelDropsTheDraft() async {
        let bot = Bot()
        bot.controller.taskDraft = ("/tmp/ambo", "Ambo", nil, .now.addingTimeInterval(60))
        await bot.controller.handle(message("/cancel"), afterGap: false)
        #expect(bot.controller.taskDraft == nil)
    }

    /// No launcher, no draft: «Запустить» starts nothing and shows the list again.
    @Test func goWithoutADraftStartsNothing() async {
        let bot = Bot()
        await bot.controller.handle(press(.taskGo), afterGap: false)
        #expect(bot.methods == ["answerCallbackQuery", "editMessageText"])
        #expect(bot.controller.taskDraft == nil)
    }

    // MARK: The Mini App

    @Test func theMiniAppRefusesBadCalls() async throws {
        let bot = Bot()
        let bad = try await bot.reply("rm")
        #expect(bad["ok"] as? Bool == false)
        let badID = try await bot.reply("answer", ["id": "../x", "allow": true])
        #expect(badID["ok"] as? Bool == false)
        let state = try await bot.reply("state")
        #expect(state["ok"] as? Bool == true)
    }

    @Test func theMiniAppSkipsAnsweredRequests() async {
        let bot = Bot()
        bot.addRequest()
        #expect(bot.controller.miniAppState.requests.map(\.id) == ["req1"])
        await bot.controller.handle(press(.answer(requestID: "req1", allow: true)), afterGap: false)
        #expect(bot.controller.miniAppState.requests.isEmpty)
    }

    // MARK: Reading the bot

    @Test func anotherReaderOfTheBotIsAConflict() async {
        let bot = Bot()
        bot.nextUpdates = (409, nil)
        #expect(await bot.controller.tick() == 60)
        #expect(bot.controller.conflict)
        #expect(!bot.controller.isReading)

        bot.nextUpdates = (200, Data(#"{"ok":true,"result":[]}"#.utf8))
        _ = await bot.controller.tick()
        #expect(!bot.controller.conflict)
        #expect(bot.controller.isReading)
    }

    @Test func aRefusedTokenStopsReading() async {
        let bot = Bot()
        bot.nextUpdates = (401, nil)
        #expect(await bot.controller.tick() == 60)
        #expect(!bot.controller.isReading)
        #expect(bot.controller.status != nil)
    }

    @Test func noNetworkTriesAgainSoon() async {
        let bot = Bot()
        bot.nextUpdates = (0, nil)
        #expect(await bot.controller.tick() == 10)
    }

    @Test func updatesAreConfirmedByOffset() async throws {
        let bot = Bot()
        bot.nextUpdates = (200, Data(#"{"ok":true,"result":[{"update_id":5,"edited_message":{"text":"x"}}]}"#.utf8))
        _ = await bot.controller.tick()
        _ = await bot.controller.tick()
        let reads = bot.calls.filter { $0.method == "getUpdates" }
        #expect(reads[0].parameters["offset"] == nil)
        #expect(reads[1].parameters["offset"] as? Int == 6)
    }

    @Test func theCommandListIsSetOncePerToken() async {
        let bot = Bot()
        _ = await bot.controller.tick()
        _ = await bot.controller.tick()
        #expect(bot.count("setMyCommands") == 1)
    }

    /// A press read right after a start can be old: the first read counts as a gap.
    @Test func theFirstReadIsAGap() async throws {
        let bot = Bot()
        bot.addRequest()
        let update: [String: Any] = ["update_id": 5, "callback_query": ["id": "c1", "data": "allow:req1", "from": ["id": 42]]]
        bot.nextUpdates = (200, try JSONSerialization.data(withJSONObject: ["ok": true, "result": [update]]))
        _ = await bot.controller.tick()
        #expect(bot.decision("req1") == nil)
        _ = await bot.controller.tick()
        #expect(bot.decision("req1") == "allow")
    }

    @Test func aSwitchedOffBotReadsNothing() async {
        let bot = Bot()
        bot.controller.isActive = { false }
        #expect(await bot.controller.tick() == 5)
        bot.controller.isActive = { true }
        bot.settings.telegramBot.answersHere = false
        #expect(await bot.controller.tick() == 5)
        bot.settings.telegramBot.answersHere = true
        bot.controller.token = nil
        #expect(await bot.controller.tick() == 5)
        #expect(bot.calls.isEmpty)
    }
}
