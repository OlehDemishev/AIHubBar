import SwiftUI

@main
struct ClaudePultApp: App {
    @State private var loginItem = LoginItemController()
    @State private var settings: AppSettings
    @State private var store: ProjectStore
    @State private var launcher: LaunchController
    @State private var sessions: SessionStore
    @State private var telegramApprovals: TelegramApprovals
    @State private var widgetStatus: WidgetStatusWriter
    @State private var hooks: HookController
    @State private var runs: RunStore
    @State private var commands: CommandStore
    @State private var requests: AppRequests
    @State private var usage: UsageStore
    @State private var hub: HubLimitsStore
    @State private var sessionChanges = SessionChangesStore()
    @State private var claudeConfig: ClaudeConfigStore
    @State private var weeklySummary: WeeklySummarySender
    @State private var monitor: SystemMonitor
    @State private var keepAwake: KeepAwakeController
    @State private var quickTools: QuickToolsController
    @State private var clipboard: ClipboardHistory
    @State private var notesStore: NotesStore
    @State private var notchIsland: NotchIsland
    @State private var notifications = NotificationPermission()
    @State private var modes: ModeStore
    @State private var services: AIServiceStore
    @State private var folders: FolderProjectStore
    @State private var engine: CommandEngine
    @State private var calendar: CalendarStore
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        if let code = CommandLineTool.run(CommandLine.arguments) {
            AppLog.flush()
            exit(code)
        }
        let settings = AppSettings()
        // Applies the current mode to the settings before anything reads them.
        let modes = ModeStore(settings: settings)
        _modes = State(initialValue: modes)
        let services = AIServiceStore(settings: settings)
        _services = State(initialValue: services)
        let folders = FolderProjectStore(settings: settings)
        _folders = State(initialValue: folders)
        let calendar = CalendarStore(settings: settings, modes: modes)
        _calendar = State(initialValue: calendar)
        let store = ProjectStore(settings: settings)
        _settings = State(initialValue: settings)
        _store = State(initialValue: store)
        _claudeConfig = State(initialValue: ClaudeConfigStore(settings: settings, projects: store))
        let requests = AppRequests()
        let commands = CommandStore(settings: settings, store: store, requests: requests)
        _requests = State(initialValue: requests)
        _commands = State(initialValue: commands)
        let sessions = SessionStore()
        _sessions = State(initialValue: sessions)
        _telegramApprovals = State(initialValue: TelegramApprovals(settings: settings, sessions: sessions))
        let usage = UsageStore(settings: settings, sessions: sessions)
        _usage = State(initialValue: usage)
        let hub = HubLimitsStore(settings: settings)
        _hub = State(initialValue: hub)
        let monitor = SystemMonitor(settings: settings)
        _monitor = State(initialValue: monitor)
        let keepAwake = KeepAwakeController(settings: settings)
        let clipboard = ClipboardHistory(settings: settings)
        _clipboard = State(initialValue: clipboard)
        let notesStore = NotesStore(settings: settings)
        _notesStore = State(initialValue: notesStore)
        _keepAwake = State(initialValue: keepAwake)
        let notchIsland = NotchIsland(settings: settings)
        _notchIsland = State(initialValue: notchIsland)
        let runs = RunStore(settings: settings)
        _runs = State(initialValue: runs)
        _engine = State(initialValue: CommandEngine(settings: settings, runs: runs))
        let launcher = LaunchController(settings: settings, store: store, runs: runs, usage: usage)
        _weeklySummary = State(initialValue: WeeklySummarySender(settings: settings, usage: usage, runs: runs))
        _launcher = State(initialValue: launcher)
        let hooks = HookController(settings: settings)
        _hooks = State(initialValue: hooks)
        usage.isActive = { [modes] in modes.installedModules.contains(.limits) }
        hub.isActive = { [modes] in modes.installedModules.contains(.limits) }
        Notifier.frequency = { [settings] in settings.frequency($0) }
        monitor.isActive = { [modes] in modes.installedModules.contains(.resources) }
        keepAwake.isActive = { [modes] in modes.installedModules.contains(.keepAwake) }
        clipboard.isActive = { [modes] in modes.installedModules.contains(.clipboard) }
        notesStore.isActive = { [modes] in modes.installedModules.contains(.notes) }
        notchIsland.isActive = { [modes] in modes.installedModules.contains(.notch) }
        notchIsland.openRequests = { [sessions] in
            sessions.approvals.values.sorted { $0.created < $1.created }.map { request in
                let project = sessions.items.first { $0.id == request.sessionID }?.session.displayProject ?? request.project ?? "Claude"
                return NotchEvent.request(request, project: project, now: Date(timeIntervalSince1970: request.created))
            }
        }
        notchIsland.sessionItems = { [sessions] in sessions.items }
        Notifier.island = { [notchIsland] id, kind, title, body, target in
            notchIsland.notification(id: id, kind: kind, title: title, body: body, target: target)
        }
        sessions.approvalsEnabled = { [settings] in settings.approvalsFromClaudePult }
        _widgetStatus = State(initialValue: WidgetStatusWriter { [sessions, runs, store, keepAwake, modes] in
            WidgetStatus(
                waiting: sessions.items.filter { $0.state == .waiting }.map(\.session.displayProject),
                waitingSessions: sessions.items.filter { $0.state == .waiting }
                    .map { WidgetStatus.Session(id: $0.id, project: $0.session.displayProject) },
                running: sessions.items.filter { $0.state == .running }.count + runs.running.count,
                problems: store.projects.filter { $0.health == .red }.map(\.name),
                keepAwake: keepAwake.reason != nil,
                keepAwakeInstalled: modes.installedModules.contains(.keepAwake)
            )
        })
        keepAwake.claudeWorking = { [sessions, runs] in
            !runs.running.isEmpty || sessions.items.contains { $0.state == .running }
        }
        modes.didApply = {
            Task { await store.refresh() }
            Task { await folders.refresh() }
            Task { await calendar.refresh() }
            hooks.refresh()
        }
        AppDelegate.willTerminate = { keepAwake.releaseOnQuit() }
        GlobalHotKey.action = { QuickSearch.show() }
        QuickSearch.open = { [requests] in requests.openWindow("search") }
        let quickTools = QuickToolsController()
        _quickTools = State(initialValue: quickTools)
        IntentBridge.settings = settings
        IntentBridge.quickTools = quickTools
        AppDelegate.openFile = { url in
            modes.prepareImport(from: url)
            UserDefaults.standard.set(SettingsView.Tab.modes.rawValue, forKey: "settingsTab")
            requests.openWindow("settings")
        }
        AppLog.info("AI Hub Bar \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") started")
        // Unit tests use the app as their host; keep it from running report.py in the background.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            store.start()
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
            Task { await Telegram.loadOwnBot(chatID: settings.telegramChatID) }
            weeklySummary.start()
            monitor.start()
            keepAwake.start()
            GlobalHotKey.register(settings.panelHotKey)
            clipboard.start()
            // Windows can only be made once the app has finished launching.
            DispatchQueue.main.async {
                notchIsland.start { [notchIsland, settings, usage, sessions, runs] in
                    AnyView(NotchIslandView()
                        .environment(notchIsland)
                        .environment(settings)
                        .environment(usage)
                        .environment(sessions)
                        .environment(runs))
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
                    requests.openWindow("assistant")
                }
            }
            calendar.start()
            launcher.start()
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
                    requests.openWindow("run-log")
                case let .openFile(path):
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                case let .openWindow(id):
                    requests.openWindow(id)
                case .nothing:
                    break
                }
            }
            NotificationRouter.shared.install(handle)
            notchIsland.perform = handle
            AppDelegate.openLink = { url in
                guard let resolution = WidgetLink.resolve(url) else {
                    AppLog.error("Unknown link \(url.absoluteString)")
                    return
                }
                AppLog.info("Widget link \(url.absoluteString)")
                // A session that has ended since the widget drew it: the search lists what runs now.
                if case let .showSession(id) = resolution,
                   !SessionStore.loadItems(from: SessionFiles.sessionsDirectory, now: .now).contains(where: { $0.id == id }) {
                    handle(.openWindow(id: "search"))
                } else {
                    handle(resolution)
                }
            }
        }
    }

    private var menuBarData: MenuBarData {
        var data = MenuBarData()
        data.showsAlert = store.report?.hasRedProject ?? false
        data.waiting = sessions.waitingCount
        data.running = sessions.items.filter { $0.state == .running }.count
        data.background = runs.running.count
        data.queued = launcher.queued.count
        data.session = usage.snapshot?.session?.utilization
        data.week = usage.snapshot?.week?.utilization
        data.modelWeeks = Dictionary((usage.snapshot?.otherWindows ?? []).map { ($0.key, $0.utilization) }) { first, _ in first }
        data.sessionResetsAt = usage.snapshot?.session?.resetsAt
        if case let .runsOutAt(date) = usage.forecast { data.forecastRunsOut = date }
        if settings.menuBarConfig.element(.disk).enabled {
            data.diskFreeBytes = store.report?.diskFreeBytes ?? DiskSpace.freeBytes()
        }
        data.deadline = calendar.nearest().map { CalendarText.menuBar($0) }
        data.cpu = monitor.snapshot?.cpu
        data.memory = monitor.snapshot?.memoryPercent
        data.keepingAwake = keepAwake.reason != nil
        data.otherAI = hub.percents
        data.modeName = modes.current?.name
        data.modeIcon = modes.current?.icon
        return data
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environment(store)
                .environment(launcher)
                .environment(sessions)
                .environment(hooks)
                .environment(runs)
                .environment(commands)
                .environment(usage)
                .environment(hub)
                .environment(sessionChanges)
                .environment(monitor)
                .environment(keepAwake)
                .environment(quickTools)
                .environment(clipboard)
                .environment(notesStore)
                .environment(settings)
                .environment(notifications)
                .environment(modes)
                .environment(services)
                .environment(folders)
                .environment(engine)
                .environment(calendar)
        } label: {
            MenuBarLabel(state: MenuBarState(config: settings.menuBarConfig, data: menuBarData))
                .environment(requests)
        }
        .menuBarExtraStyle(.window)

        // `.handlesExternalEvents(matching: [])` on every window: otherwise SwiftUI opens the first one (this search)
        // for each `aihubbar://` link or `*.claudepult` file, which `AppDelegate` handles itself.
        Window("Поиск — AI Hub Bar", id: "search") {
            QuickSearchWindow()
                .environment(settings)
                .environment(launcher)
                .environment(store)
                .environment(folders)
                .environment(sessions)
                .environment(runs)
                .environment(modes)
                .environment(quickTools)
                .environment(commands)
                .preferredColorScheme(settings.panelTheme.colorScheme)
        }
        .handlesExternalEvents(matching: [])
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window(String(localized: "Claude Code: инструкции и MCP"), id: "claude-config") {
            ClaudeConfigWindow()
                .environment(claudeConfig)
                .preferredColorScheme(settings.panelTheme.colorScheme)
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 900, height: 620)

        // A click on the limits widget: the panel's limits block on its own, since the panel can't be opened from code.
        Window("Лимиты — AI Hub Bar", id: "limits") {
            LimitsView()
                .panelCard()
                .padding(.vertical, 10)
                .frame(width: 420)
                .environment(usage)
                .environment(hub)
                .environment(launcher)
                .environment(engine)
                .preferredColorScheme(settings.panelTheme.colorScheme)
        }
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        Window("Журнал фоновой задачи", id: "run-log") {
            RunLogView()
                .environment(runs)
                .preferredColorScheme(settings.panelTheme.colorScheme)
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 640, height: 520)

        Window("Помощник — AI Hub Bar", id: "assistant") {
            AssistantView()
                .environment(modes)
                .environment(settings)
                .environment(services)
                .environment(hooks)
                .environment(notifications)
                .environment(loginItem)
                .preferredColorScheme(settings.panelTheme.colorScheme)
        }
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)

        Window("Календарь", id: "calendar") {
            CalendarWindow()
                .environment(calendar)
                .environment(modes)
                .environment(folders)
                .preferredColorScheme(settings.panelTheme.colorScheme)
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 900, height: 640)

        Window("Сравнение", id: "compare") {
            CompareView()
                .environment(engine)
                .preferredColorScheme(settings.panelTheme.colorScheme)
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 980, height: 640)

        Window("Очистка сборок", id: "cleanup-output") {
            CleanupOutputView()
                .environment(commands)
                .preferredColorScheme(settings.panelTheme.colorScheme)
                .debugSnapshot("cleanup")
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 720, height: 480)

        Window("Помощь — AI Hub Bar", id: "help") {
            HelpView()
                .environment(services)
                .environment(hooks)
                .environment(notifications)
                .environment(loginItem)
                .preferredColorScheme(settings.panelTheme.colorScheme)
                .debugSnapshot("help")
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 720, height: 640)

        Settings {
            SettingsView()
                .environment(loginItem)
                .environment(settings)
                .environment(store)
                .environment(hooks)
                .environment(usage)
                .environment(hub)
                .environment(sessionChanges)
                .environment(monitor)
                .environment(keepAwake)
                .environment(quickTools)
                .environment(clipboard)
                .environment(notesStore)
                .environment(notifications)
                .environment(modes)
                .environment(services)
                .environment(engine)
                .environment(calendar)
                .environment(telegramApprovals)
                .environment(weeklySummary)
        }
    }
}

/// Opens `*.claudepult` files double-clicked in Finder (SPEC-modes §12) and the widgets' `aihubbar://` links, and lets
/// go of the lid hold on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openFile: ((URL) -> Void)?
    @MainActor static var openLink: ((URL) -> Void)?
    @MainActor static var willTerminate: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.willTerminate?() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                if url.scheme?.lowercased() == WidgetLink.scheme {
                    Self.openLink?(url)
                } else if url.pathExtension == "claudepult" {
                    Self.openFile?(url)
                }
            }
        }
    }
}
