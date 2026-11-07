import AppKit
import SwiftUI

/// A module's background service: it works only while `isActive` says so.
@MainActor
protocol ModuleService: AnyObject {
    var isActive: () -> Bool { get set }
}

extension UsageStore: ModuleService {}
extension HubLimitsStore: ModuleService {}
extension SystemMonitor: ModuleService {}
extension KeepAwakeController: ModuleService {}
extension ClipboardHistory: ModuleService {}
extension NotesStore: ModuleService {}
extension NotchIsland: ModuleService {}
extension LayoutSwitcher: ModuleService {}
extension QuickPromptController: ModuleService {}
extension TelegramBotController: ModuleService {}

/// «Claude is working», counted one way for the menu bar, the widget and «Не спать».
@MainActor
struct ClaudeActivity {
    let sessions: SessionStore
    let runs: RunStore

    var runningSessions: Int { sessions.items.filter { $0.state == .running }.count }
    /// Sessions working plus background runs.
    var working: Int { runningSessions + runs.running.count }
    var isWorking: Bool { !runs.running.isEmpty || sessions.items.contains { $0.state == .running } }
}

/// Everything the app is made of, created and wired once at launch (docs/specs/SPEC-refactor.md §6): the stores and
/// controllers, the hooks between them, and what starts in the background. `AIHubBarApp` only lays out the scenes
/// and gives every window the same environment (`appEnvironment`).
@MainActor
final class AppContainer {
    let loginItem = LoginItemController()
    let settings: AppSettings
    let store: ProjectStore
    let launcher: LaunchController
    let sessions: SessionStore
    let telegramApprovals: TelegramApprovals
    let telegramBot: TelegramBotController
    let widgetStatus: WidgetStatusWriter
    let hooks: HookController
    let runs: RunStore
    let commands: CommandStore
    let requests: AppRequests
    let usage: UsageStore
    let hub: HubLimitsStore
    let claudeAccounts: ClaudeAccountsStore
    let sessionChanges = SessionChangesStore()
    let claudeConfig: ClaudeConfigStore
    let weeklySummary: WeeklySummarySender
    let monitor: SystemMonitor
    let keepAwake: KeepAwakeController
    let quickTools: QuickToolsController
    let commandHotKeys: CommandHotKeys
    let clipboard: ClipboardHistory
    let notesStore: NotesStore
    let notchIsland: NotchIsland
    let layoutSwitcher: LayoutSwitcher
    let quickPrompt: QuickPromptController
    let notifications = NotificationPermission()
    let modes: ProfileStore
    let services: AIServiceStore
    let folders: FolderProjectStore
    let engine: CommandEngine
    let calendar: CalendarStore

    init() {
        // «Панель» edits the current profile after a start; «Профили» points it at another one for a while.
        UserDefaults.standard.removeObject(forKey: StorageKey.panelProfile)
        // Unit tests run inside this app: it gets throwaway settings and profiles, never the person's own
        // (docs/specs/SPEC-refactor.md §2.4).
        let settings = AppSettings(defaults: TestHost.isActive ? TestHost.defaults : .standard)
        // Applies the current mode to the settings before anything reads them.
        let modes = TestHost.isActive ? ProfileStore(settings: settings, directory: TestHost.modesDirectory) : ProfileStore(settings: settings)
        self.modes = modes
        let services = AIServiceStore(settings: settings)
        self.services = services
        let folders = FolderProjectStore(settings: settings)
        self.folders = folders
        let calendar = CalendarStore(settings: settings, modes: modes)
        self.calendar = calendar
        let store = ProjectStore(settings: settings)
        self.settings = settings
        self.store = store
        self.claudeConfig = ClaudeConfigStore(settings: settings, projects: store)
        let requests = AppRequests()
        let commands = CommandStore(settings: settings, store: store, requests: requests)
        self.requests = requests
        self.commands = commands
        let sessions = SessionStore()
        self.sessions = sessions
        let telegramApprovals = TelegramApprovals(settings: settings, sessions: sessions)
        self.telegramApprovals = telegramApprovals
        let usage = UsageStore(settings: settings, sessions: sessions)
        self.usage = usage
        let hub = HubLimitsStore(settings: settings)
        self.hub = hub
        let claudeAccounts = ClaudeAccountsStore(settings: settings)
        self.claudeAccounts = claudeAccounts
        claudeAccounts.isActive = { [modes] in modes.isOn(.limits) }
        let monitor = SystemMonitor(settings: settings)
        self.monitor = monitor
        let keepAwake = KeepAwakeController(settings: settings)
        let clipboard = ClipboardHistory(settings: settings)
        self.clipboard = clipboard
        let notesStore = NotesStore(settings: settings)
        self.notesStore = notesStore
        self.keepAwake = keepAwake
        let notchIsland = NotchIsland(settings: settings)
        self.notchIsland = notchIsland
        let layoutSwitcher = LayoutSwitcher(settings: settings)
        self.layoutSwitcher = layoutSwitcher
        let runs = RunStore(settings: settings)
        self.runs = runs
        let engine = CommandEngine(settings: settings, runs: runs)
        self.engine = engine
        let launcher = LaunchController(settings: settings, store: store, runs: runs, usage: usage)
        let telegramBot = TelegramBotController(settings: settings, sessions: sessions, runs: runs, usage: usage, approvals: telegramApprovals)
        self.telegramBot = telegramBot
        telegramApprovals.botReads = { [telegramBot] token in telegramBot.reads(token) }
        self.weeklySummary = WeeklySummarySender(settings: settings, usage: usage, runs: runs, hub: hub)
        self.launcher = launcher
        let quickPrompt = QuickPromptController(settings: settings, launcher: launcher, services: services)
        self.quickPrompt = quickPrompt
        let hooks = HookController(settings: settings)
        self.hooks = hooks
        // Each module's service works only while its module does (SPEC-settings §1): one table, not a closure each.
        let moduleServices: [(ModuleKind, any ModuleService)] = [
            (.limits, usage), (.limits, hub), (.resources, monitor), (.keepAwake, keepAwake), (.clipboard, clipboard),
            (.notes, notesStore), (.notch, notchIsland), (.layout, layoutSwitcher), (.quickPrompt, quickPrompt),
            (.telegram, telegramBot),
        ]
        for (kind, service) in moduleServices {
            service.isActive = { [modes] in modes.isOn(kind) }
        }
        Notifier.frequency = { [settings, modes] kind in
            if let module = kind.module, modes.isSilenced(module) { return .off }
            return settings.frequency(kind)
        }
        notchIsland.openRequests = { [sessions] in
            sessions.approvals.values.sorted { $0.created < $1.created }.map { request in
                let project = sessions.items.first { $0.id == request.sessionID }?.session.displayProject ?? request.project ?? "Claude"
                return NotchEvent.request(request, project: project, now: Date(timeIntervalSince1970: request.created))
            }
        }
        notchIsland.sessionItems = { [sessions] in sessions.items }
        notchIsland.hasEarContent = { [usage, hub, sessions, runs] ear in
            switch ear {
            case .sessionLimit: usage.snapshot?.session != nil
            case .weekLimit: usage.snapshot?.week != nil
            case .otherAI: NotchText.fullestOther(hub.percents) != nil
            case .sessions: sessions.items.contains { $0.state == .waiting || $0.state == .running }
            case .background: !runs.running.isEmpty
            case .none: false
            }
        }
        Notifier.island = { [notchIsland] id, kind, title, body, target in
            notchIsland.notification(id: id, kind: kind, title: title, body: body, target: target)
        }
        sessions.approvalsEnabled = { [settings] in settings.approvalsFromClaudePult }
        self.widgetStatus = WidgetStatusWriter { [sessions, runs, store, keepAwake, modes] in
            WidgetStatus(
                waiting: sessions.items.filter { $0.state == .waiting }.map(\.session.displayProject),
                waitingSessions: sessions.items.filter { $0.state == .waiting }
                    .map { WidgetStatus.Session(id: $0.id, project: $0.session.displayProject) },
                running: ClaudeActivity(sessions: sessions, runs: runs).working,
                problems: store.projects.filter { $0.health == .red }.map(\.name),
                keepAwake: keepAwake.reason != nil,
                keepAwakeInstalled: modes.isOn(.keepAwake)
            )
        }
        keepAwake.claudeWorking = { [sessions, runs] in
            ClaudeActivity(sessions: sessions, runs: runs).isWorking
        }
        modes.didApply = { [telegramBot] in
            telegramBot.profileChanged()
            // A first profile turns the limits on: the loop would otherwise wait out its 5 minutes.
            if usage.snapshot == nil { Task { await usage.refresh() } }
            if hub.limits.isEmpty { Task { await hub.refresh() } }
            Task { await store.refresh() }
            Task { await folders.refresh() }
            Task { await calendar.refresh() }
            hooks.refresh()
        }
        AppDelegate.willTerminate = { keepAwake.releaseOnQuit() }
        GlobalHotKey.action = { QuickSearch.show() }
        QuickSearch.open = { [requests] in requests.openWindow(.search) }
        quickPrompt.openWindow = { [requests] in requests.openWindow(.quickPrompt) }
        quickPrompt.openSettings = { [requests] in
            SettingsRoute.open(module: .quickPrompt)
            requests.openWindow(.settings)
        }
        let quickTools = QuickToolsController(settings: settings)
        self.quickTools = quickTools
        telegramBot.runCommand = { [quickTools] command in await quickTools.runForBot(command) }
        telegramBot.currentProfile = { [modes] in modes.current.map { ($0.id, $0.name) } }
        telegramApprovals.handledElsewhere = { [telegramBot] in telegramBot.handlesRequests }
        telegramBot.launcher = launcher
        // The panel's switch (#251): the manual hold, not any rule that keeps the Mac awake.
        telegramBot.keepAwakeState = { [modes, keepAwake] in modes.isOn(.keepAwake) ? keepAwake.manualUntil != nil : nil }
        telegramBot.setKeepAwake = { [keepAwake] on in
            if on { keepAwake.holdManually(for: 3600) } else { keepAwake.stopManual() }
        }
        telegramBot.projectList = { [store] in store.projects }
        telegramBot.limitServices = { [usage, hub] in
            (usage.snapshot.map { [ServiceUsage.claude($0, forecast: usage.forecast, week: usage.weekUsage, error: usage.lastError)] } ?? []) + hub.usages
        }
        self.commandHotKeys = CommandHotKeys(settings: settings) { [modes] in modes.isOn(.quickCommands) }
        commandHotKeys.quickPromptOn = { [modes] in modes.isOn(.quickPrompt) }
        IntentBridge.settings = settings
        IntentBridge.quickTools = quickTools
        layoutSwitcher.openSettings = { [requests] in
            SettingsRoute.open(module: .layout)
            requests.openWindow(.settings)
        }
        AppDelegate.openFile = { url in
            modes.prepareImport(from: url)
            SettingsRoute.open(.modes)
            requests.openWindow(.settings)
        }
        AppLog.info("AI Hub Bar \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") started")
        // Unit tests use the app as their host; keep it from running report.py in the background.
        if !TestHost.isActive {
            store.start()
            followBetaUpdates()
            Updates.start()
            sessions.start()
            telegramApprovals.start()
            widgetStatus.start { [keepAwake, widgetStatus] on in
                AppLog.info("Keep awake \(on ? "on" : "off") from the widget or Control Center")
                if on { keepAwake.holdManually(for: nil) } else { keepAwake.stopManual() }
                widgetStatus.update()
            } onRefreshLimits: { [usage, hub] in
                AppLog.info("Limits refresh from the widget")
                Task { await usage.refresh() }
                Task { await hub.refresh() }
            }
            runs.start()
            requests.listen(commands: commands)
            usage.start()
            hub.start()
            claudeAccounts.start()
            telegramBot.start()
            weeklySummary.start()
            monitor.start()
            keepAwake.start()
            GlobalHotKey.register(settings.panelHotKey)
            GlobalHotKey.registerOpenPanel(settings.openPanelHotKey)
            PanelOpener.otherItemWindow = { [layoutSwitcher] in layoutSwitcher.statusWindow }
            Task {
                try? await Task.sleep(for: .seconds(5))
                PanelOpener.logItem()
            }
            GlobalHotKey.registerIsland(settings.notch.hotKeys)
            GlobalHotKey.islandAction = { [notchIsland] allow in notchIsland.answerByKey(allow: allow) }
            quickPrompt.start()
            commandHotKeys.start { [quickTools] command in quickTools.runFromHotKey(command) }
            clipboard.start()
            layoutSwitcher.start()
            // Windows can only be made once the app has finished launching.
            DispatchQueue.main.async { [unowned self] in
                notchIsland.start { [unowned self] index in
                    AnyView(NotchIslandView(index: index).appEnvironment(self))
                }
            }
            // The shell lookup first: the scan reports which agents it found.
            Task {
                await AgentLocator.refreshShellPaths()
                await services.scan()
            }
            folders.start()
            // A first start without `_daily-report`: the assistant sets up the first mode (SPEC-modes §5).
            // The menu bar label, which opens windows, has to be on screen first.
            if modes.needsAssistant {
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    requests.openWindow(.assistant)
                }
            }
            calendar.start()
            launcher.start()
            // After the menu bar item is up, so the alert is not the first thing of a login.
            Task {
                try? await Task.sleep(for: .seconds(3))
                CrashReports.checkAtLaunch()
            }
            // A click on a notification and on the island's banner do the same.
            let handle: (NotificationAction.Resolution) -> Void = { resolution in
                switch resolution {
                case let .showSession(id):
                    let items = SessionStore.loadItems(from: SessionFiles.sessionsDirectory, now: .now)
                    if let session = items.first(where: { $0.id == id })?.session { SessionActions.show(session) }
                case let .decide(requestID, allow):
                    sessions.decide(requestID: requestID, allow: allow)
                case let .openURL(url):
                    NSWorkspace.shared.open(url)
                case let .openRunLog(id):
                    runs.selectedLogRunID = id
                    requests.openWindow(.runLog)
                case let .openFile(path):
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                case let .openWindow(id):
                    // The id comes from a notification or a widget link, stored as text.
                    if let window = WindowID(rawValue: id) { requests.openWindow(window) }
                case .nothing:
                    break
                }
            }
            NotificationRouter.shared.install(handle)
            notchIsland.perform = handle
            notchIsland.needsSetup = { [requests] in
                NSApp.activate()
                requests.openWindow(.notchSetup)
            }
            AppDelegate.openLink = { url in
                guard let resolution = WidgetLink.resolve(url) else {
                    AppLog.error("Unknown link \(url.absoluteString)")
                    return
                }
                AppLog.info("Widget link \(url.absoluteString)")
                // A session that has ended since the widget drew it: the search lists what runs now.
                if case let .showSession(id) = resolution,
                   !SessionStore.loadItems(from: SessionFiles.sessionsDirectory, now: .now).contains(where: { $0.id == id }) {
                    handle(.openWindow(id: WindowID.search.rawValue))
                } else {
                    handle(resolution)
                }
            }
        }
    }

    /// What the menu bar item shows now.
    var menuBarData: MenuBarData {
        var data = MenuBarData()
        data.showsAlert = store.report?.hasRedProject ?? false
        data.waiting = sessions.waitingCount
        data.running = ClaudeActivity(sessions: sessions, runs: runs).runningSessions
        data.background = runs.running.count
        data.queued = launcher.queued.count
        data.session = usage.snapshot?.session?.utilization
        data.week = usage.snapshot?.week?.utilization
        data.modelWeeks = Dictionary((usage.snapshot?.otherWindows ?? []).map { ($0.key, $0.utilization) }) { first, _ in first }
        data.sessionResetsAt = usage.snapshot?.session?.resetsAt
        if case let .runsOutAt(date) = usage.forecast { data.forecastRunsOut = date }
        if modes.menuBar.element(.disk).enabled {
            data.diskFreeBytes = monitor.snapshot?.diskFree ?? DiskSpace.freeBytes()
        }
        data.deadline = calendar.nearest().map { CalendarText.menuBar($0) }
        data.cpu = monitor.snapshot?.cpu
        data.memory = monitor.snapshot?.memoryPercent
        data.keepingAwake = keepAwake.reason != nil
        data.keepAwakeSwitchedOn = keepAwake.manualUntil != nil
        data.otherAI = hub.percents
        data.modeName = modes.current?.name
        data.modeIcon = modes.current?.icon
        return data
    }

    /// Sparkle's channel follows «Бета-версии» wherever it changes (Settings, an import), not from a `didSet` in
    /// `AppSettings`.
    private func followBetaUpdates() {
        Updates.beta = withObservationTracking { settings.betaUpdates } onChange: { [weak self] in
            Task { @MainActor in self?.followBetaUpdates() }
        }
    }
}

extension View {
    /// Every store and controller, for any window or view the app shows — nothing can be forgotten in one scene.
    func appEnvironment(_ app: AppContainer) -> some View {
        modifier(AppEnvironment(app: app))
    }
}

private struct AppEnvironment: ViewModifier {
    let app: AppContainer

    func body(content: Content) -> some View {
        content
            .environment(app.loginItem)
            .environment(app.settings)
            .environment(app.store)
            .environment(app.launcher)
            .environment(app.sessions)
            .environment(app.notchIsland)
            .environment(app.telegramApprovals)
            .environment(app.telegramBot)
            .environment(app.hooks)
            .environment(app.runs)
            .environment(app.commands)
            .environment(app.requests)
            .environment(app.usage)
            .environment(app.hub)
            .environment(app.claudeAccounts)
            .environment(app.sessionChanges)
            .environment(app.claudeConfig)
            .environment(app.weeklySummary)
            .environment(app.monitor)
            .environment(app.keepAwake)
            .environment(app.quickTools)
            .environment(app.commandHotKeys)
            .environment(app.clipboard)
            .environment(app.notesStore)
            .environment(app.notchIsland)
            .environment(app.layoutSwitcher)
            .environment(app.quickPrompt)
            .environment(app.notifications)
            .environment(app.modes)
            .environment(app.services)
            .environment(app.folders)
            .environment(app.engine)
            .environment(app.calendar)
    }
}
