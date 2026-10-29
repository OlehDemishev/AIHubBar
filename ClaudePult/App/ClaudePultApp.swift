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

    init() {
        if let code = CommandLineTool.run(CommandLine.arguments) {
            AppLog.flush()
            exit(code)
        }
        let settings = AppSettings()
        let store = ProjectStore(settings: settings)
        _settings = State(initialValue: settings)
        _store = State(initialValue: store)
        let runs = RunStore(settings: settings)
        _runs = State(initialValue: runs)
        _launcher = State(initialValue: LaunchController(settings: settings, store: store, runs: runs))
        let requests = AppRequests()
        let commands = CommandStore(settings: settings, store: store, requests: requests)
        _requests = State(initialValue: requests)
        _commands = State(initialValue: commands)
        let sessions = SessionStore()
        _sessions = State(initialValue: sessions)
        _hooks = State(initialValue: HookController(settings: settings))
        AppLog.info("ClaudePult \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") started")
        // Unit tests use the app as their host; keep it from running report.py in the background.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            store.start()
            sessions.start()
            runs.start()
            requests.listen(commands: commands)
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
        } label: {
            MenuBarLabel(showsAlert: store.report?.hasRedProject ?? false, waitingCount: sessions.waitingCount)
                .environment(requests)
        }
        .menuBarExtraStyle(.window)

        Window("Журнал фоновой задачи", id: "run-log") {
            RunLogView()
                .environment(runs)
        }
        .defaultSize(width: 640, height: 520)

        Window("Очистка сборок", id: "cleanup-output") {
            CleanupOutputView()
                .environment(commands)
                .debugSnapshot("cleanup")
        }
        .defaultSize(width: 720, height: 480)

        Window("Помощь — ClaudePult", id: "help") {
            HelpView()
                .debugSnapshot("help")
        }
        .defaultSize(width: 720, height: 640)

        Settings {
            SettingsView()
                .environment(loginItem)
                .environment(settings)
                .environment(store)
                .environment(hooks)
        }
    }
}
