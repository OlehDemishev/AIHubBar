import SwiftUI

@main
struct AIHubBarApp: App {
    @State private var app: AppContainer
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        // Writing to a child that has already exited (`codex app-server` on an old CLI, `security -i`) must fail with
        // an error, not end the app with SIGPIPE and no crash report.
        signal(SIGPIPE, SIG_IGN)
        LanguageFallback.apply()
        _ = InterfaceLanguage.running
        if let code = CommandLineTool.run(CommandLine.arguments) {
            AppLog.flush()
            exit(code)
        }
        _app = State(initialValue: AppContainer())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .appEnvironment(app)
        } label: {
            MenuBarLabel(state: MenuBarState(config: (app.notchIsland.takesMenuBarSummary ? app.modes.menuBar.iconOnly : app.modes.menuBar)
                                                .without(app.modes.silencedModules),
                                             data: app.menuBarData))
                .appEnvironment(app)
        }
        .menuBarExtraStyle(.window)

        // `.handlesExternalEvents(matching: [])` on every window: otherwise SwiftUI opens the first one (this search)
        // for each `aihubbar://` link or `*.claudepult` file, which `AppDelegate` handles itself.
        Window("Поиск", id: WindowID.search.rawValue) {
            QuickSearchWindow()
                .appEnvironment(app)
                .preferredColorScheme(app.settings.panelTheme.colorScheme)
        }
        .handlesExternalEvents(matching: [])
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Быстрый запрос", id: WindowID.quickPrompt.rawValue) {
            QuickPromptWindow()
                .appEnvironment(app)
                .preferredColorScheme(app.settings.panelTheme.colorScheme)
                .debugSnapshot("quick-prompt")
        }
        .handlesExternalEvents(matching: [])
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window(String(localized: "Claude Code: инструкции и MCP"), id: WindowID.claudeConfig.rawValue) {
            ClaudeConfigWindow()
                .appEnvironment(app)
                .preferredColorScheme(app.settings.panelTheme.colorScheme)
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 900, height: 620)

        // A click on the limits widget: the panel's limits block on its own, since the panel can't be opened from code.
        Window("Лимиты", id: WindowID.limits.rawValue) {
            LimitsView()
                .appEnvironment(app)
                .panelCard()
                .padding(.vertical, 10)
                .frame(width: 420)
                .preferredColorScheme(app.settings.panelTheme.colorScheme)
        }
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        Window("Журнал фоновой задачи", id: WindowID.runLog.rawValue) {
            RunLogView()
                .appEnvironment(app)
                .preferredColorScheme(app.settings.panelTheme.colorScheme)
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 640, height: 520)

        Window("Помощник", id: WindowID.assistant.rawValue) {
            AssistantView()
                .appEnvironment(app)
                .preferredColorScheme(app.settings.panelTheme.colorScheme)
        }
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)

        Window("Календарь", id: WindowID.calendar.rawValue) {
            CalendarWindow()
                .appEnvironment(app)
                .preferredColorScheme(app.settings.panelTheme.colorScheme)
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 900, height: 640)

        Window("Сравнение", id: WindowID.compare.rawValue) {
            CompareView()
                .appEnvironment(app)
                .preferredColorScheme(app.settings.panelTheme.colorScheme)
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 980, height: 640)

        Window("История расхода", id: WindowID.usageHistory.rawValue) {
            UsageHistoryWindow()
                .appEnvironment(app)
                .preferredColorScheme(app.settings.panelTheme.colorScheme)
                .debugSnapshot("usage-history")
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 720, height: 520)

        Window("Очистка сборок", id: WindowID.cleanupOutput.rawValue) {
            CleanupOutputView()
                .appEnvironment(app)
                .preferredColorScheme(app.settings.panelTheme.colorScheme)
                .debugSnapshot("cleanup")
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 720, height: 480)

        Window("Остров у чёлки", id: WindowID.notchSetup.rawValue) {
            NotchSetupView()
                .appEnvironment(app)
                .preferredColorScheme(app.settings.panelTheme.colorScheme)
                .debugSnapshot("notch-setup")
        }
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Справка", id: WindowID.help.rawValue) {
            HelpView()
                .appEnvironment(app)
                .preferredColorScheme(app.settings.panelTheme.colorScheme)
                .debugSnapshot("help")
        }
        .defaultSize(width: 960, height: 720)
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView()
                .appEnvironment(app)
        }
        .windowResizability(.contentMinSize)
    }
}

/// The app as the unit tests' host: same code, its own empty settings and profiles folder.
enum TestHost {
    static let isActive = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static var defaults: UserDefaults {
        let name = "com.demishev.claudepult.test-host"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static var modesDirectory: URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "AIHubBar-test-host-\(ProcessInfo.processInfo.processIdentifier)/modes")
        try? FileManager.default.removeItem(at: url)
        return url
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
