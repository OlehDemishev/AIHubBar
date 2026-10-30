import SwiftUI

@main
struct ClaudePultApp: App {
    @State private var loginItem = LoginItemController()
    @State private var settings: AppSettings
    @State private var store: ProjectStore
    @State private var launcher: LaunchController
    @State private var sessions: SessionStore
    @State private var hooks: HookController
    @State private var runs: RunStore
    @State private var commands: CommandStore
    @State private var requests: AppRequests
    @State private var usage: UsageStore
    @State private var notifications = NotificationPermission()
    @State private var modes: ModeStore
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
        let store = ProjectStore(settings: settings)
        _settings = State(initialValue: settings)
        _store = State(initialValue: store)
        let requests = AppRequests()
        let commands = CommandStore(settings: settings, store: store, requests: requests)
        _requests = State(initialValue: requests)
        _commands = State(initialValue: commands)
        let sessions = SessionStore()
        _sessions = State(initialValue: sessions)
        let usage = UsageStore(settings: settings, sessions: sessions)
        _usage = State(initialValue: usage)
        let runs = RunStore(settings: settings)
        _runs = State(initialValue: runs)
        let launcher = LaunchController(settings: settings, store: store, runs: runs, usage: usage)
        _launcher = State(initialValue: launcher)
        let hooks = HookController(settings: settings)
        _hooks = State(initialValue: hooks)
        modes.didApply = {
            Task { await store.refresh() }
            hooks.refresh()
        }
        AppDelegate.openFile = { url in
            modes.prepareImport(from: url)
            UserDefaults.standard.set(SettingsView.Tab.modes.rawValue, forKey: "settingsTab")
            requests.openWindow("settings")
        }
        AppLog.info("ClaudePult \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") started")
        // Unit tests use the app as their host; keep it from running report.py in the background.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            store.start()
            sessions.start()
            runs.start()
            requests.listen(commands: commands)
            usage.start()
            launcher.start()
            NotificationRouter.shared.install { resolution in
                switch resolution {
                case let .showSession(id):
                    let items = SessionStore.loadItems(from: SessionFiles.sessionsDirectory, now: .now)
                    if let session = items.first(where: { $0.id == id })?.session { SessionActions.show(session) }
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
                .environment(settings)
                .environment(notifications)
                .environment(modes)
        } label: {
            MenuBarLabel(state: MenuBarState(
                showsAlert: store.report?.hasRedProject ?? false,
                waitingCount: sessions.waitingCount,
                mode: settings.menuBarUsageMode,
                session: usage.snapshot?.session?.utilization,
                week: usage.snapshot?.week?.utilization
            ))
            .environment(requests)
        }
        .menuBarExtraStyle(.window)

        Window("Журнал фоновой задачи", id: "run-log") {
            RunLogView()
                .environment(runs)
                .preferredColorScheme(settings.panelTheme.colorScheme)
        }
        .defaultSize(width: 640, height: 520)

        Window("Очистка сборок", id: "cleanup-output") {
            CleanupOutputView()
                .environment(commands)
                .preferredColorScheme(settings.panelTheme.colorScheme)
                .debugSnapshot("cleanup")
        }
        .defaultSize(width: 720, height: 480)

        Window("Помощь — ClaudePult", id: "help") {
            HelpView()
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
                .environment(notifications)
                .environment(modes)
        }
    }
}

/// Opens `*.claudepult` files double-clicked in Finder (SPEC-modes §12).
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openFile: ((URL) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where url.pathExtension == "claudepult" { Self.openFile?(url) }
        }
    }
}
