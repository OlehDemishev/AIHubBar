import SwiftUI

@main
struct ClaudePultApp: App {
    @State private var loginItem = LoginItemController()
    @State private var settings: AppSettings
    @State private var store: ProjectStore

    init() {
        if let code = CommandLineTool.run(CommandLine.arguments) {
            exit(code)
        }
        let settings = AppSettings()
        let store = ProjectStore(settings: settings)
        _settings = State(initialValue: settings)
        _store = State(initialValue: store)
        AppLog.info("ClaudePult \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") started")
        // Unit tests use the app as their host; keep it from running report.py in the background.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            store.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environment(store)
        } label: {
            MenuBarIcon(showsAlert: store.report?.hasRedProject ?? false)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(loginItem)
                .environment(settings)
                .environment(store)
        }
    }
}
