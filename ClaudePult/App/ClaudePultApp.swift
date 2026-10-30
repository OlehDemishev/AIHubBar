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
    @State private var monitor: SystemMonitor
    @State private var keepAwake: KeepAwakeController
    @State private var quickTools: QuickToolsController
    @State private var clipboard: ClipboardHistory
    @State private var notesStore: NotesStore
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
        let requests = AppRequests()
        let commands = CommandStore(settings: settings, store: store, requests: requests)
        _requests = State(initialValue: requests)
        _commands = State(initialValue: commands)
        let sessions = SessionStore()
        _sessions = State(initialValue: sessions)
        _telegramApprovals = State(initialValue: TelegramApprovals(settings: settings, sessions: sessions))
        let usage = UsageStore(settings: settings, sessions: sessions)
        _usage = State(initialValue: usage)
        let monitor = SystemMonitor(settings: settings)
        _monitor = State(initialValue: monitor)
        let keepAwake = KeepAwakeController(settings: settings)
        let clipboard = ClipboardHistory(settings: settings)
        _clipboard = State(initialValue: clipboard)
        let notesStore = NotesStore(settings: settings)
        _notesStore = State(initialValue: notesStore)
        _keepAwake = State(initialValue: keepAwake)
        let runs = RunStore(settings: settings)
        _runs = State(initialValue: runs)
        _engine = State(initialValue: CommandEngine(settings: settings, runs: runs))
        let launcher = LaunchController(settings: settings, store: store, runs: runs, usage: usage)
        _launcher = State(initialValue: launcher)
        let hooks = HookController(settings: settings)
        _hooks = State(initialValue: hooks)
        usage.isActive = { [modes] in modes.installedModules.contains(.limits) }
        monitor.isActive = { [modes] in modes.installedModules.contains(.resources) }
        keepAwake.isActive = { [modes] in modes.installedModules.contains(.keepAwake) }
        clipboard.isActive = { [modes] in modes.installedModules.contains(.clipboard) }
        notesStore.isActive = { [modes] in modes.installedModules.contains(.notes) }
        sessions.approvalsEnabled = { [settings] in settings.approvalsFromClaudePult }
        _widgetStatus = State(initialValue: WidgetStatusWriter { [sessions, runs, store, keepAwake, modes] in
            WidgetStatus(
                waiting: sessions.items.filter { $0.state == .waiting }.map(\.session.displayProject),
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
        AppLog.info("ClaudePult \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") started")
        // Unit tests use the app as their host; keep it from running report.py in the background.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            store.start()
            Updates.start()
            sessions.start()
            telegramApprovals.start()
            widgetStatus.start { [keepAwake, widgetStatus] on in
                AppLog.info("Keep awake \(on ? "on" : "off") from Control Center")
                if on { keepAwake.holdManually(for: nil) } else { keepAwake.stopManual() }
                widgetStatus.update()
            }
            runs.start()
            requests.listen(commands: commands)
            usage.start()
            monitor.start()
            keepAwake.start()
            GlobalHotKey.register(settings.panelHotKey)
            clipboard.start()
            Task { await services.scan() }
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
            NotificationRouter.shared.install { resolution in
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

        Window("Поиск — ClaudePult", id: "search") {
            QuickSearchWindow()
                .environment(settings)
                .environment(store)
                .environment(folders)
                .environment(sessions)
                .environment(runs)
                .environment(modes)
                .environment(quickTools)
                .environment(commands)
                .preferredColorScheme(settings.panelTheme.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Журнал фоновой задачи", id: "run-log") {
            RunLogView()
                .environment(runs)
                .preferredColorScheme(settings.panelTheme.colorScheme)
        }
        .defaultSize(width: 640, height: 520)

        Window("Помощник — ClaudePult", id: "assistant") {
            AssistantView()
                .environment(modes)
                .environment(settings)
                .environment(services)
                .environment(hooks)
                .environment(notifications)
                .environment(loginItem)
                .preferredColorScheme(settings.panelTheme.colorScheme)
        }
        .windowResizability(.contentSize)

        Window("Календарь", id: "calendar") {
            CalendarWindow()
                .environment(calendar)
                .environment(modes)
                .environment(folders)
                .preferredColorScheme(settings.panelTheme.colorScheme)
        }
        .defaultSize(width: 900, height: 640)

        Window("Сравнение", id: "compare") {
            CompareView()
                .environment(engine)
                .preferredColorScheme(settings.panelTheme.colorScheme)
        }
        .defaultSize(width: 980, height: 640)

        Window("Очистка сборок", id: "cleanup-output") {
            CleanupOutputView()
                .environment(commands)
                .preferredColorScheme(settings.panelTheme.colorScheme)
                .debugSnapshot("cleanup")
        }
        .defaultSize(width: 720, height: 480)

        Window("Помощь — ClaudePult", id: "help") {
            HelpView()
                .environment(services)
                .environment(hooks)
                .environment(notifications)
                .environment(loginItem)
                .preferredColorScheme(settings.panelTheme.colorScheme)
                .debugSnapshot("help")
        }
        .defaultSize(width: 720, height: 640)

        Settings {
            SettingsView()
                .environment(loginItem)
                .environment(settings)
                .environment(store)
                .environment(hooks)
                .environment(usage)
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
        }
    }
}

/// Opens `*.claudepult` files double-clicked in Finder (SPEC-modes §12) and lets go of the lid hold on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openFile: ((URL) -> Void)?
    @MainActor static var willTerminate: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.willTerminate?() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where url.pathExtension == "claudepult" { Self.openFile?(url) }
        }
    }
}
