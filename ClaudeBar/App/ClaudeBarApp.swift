import SwiftUI

@main
struct ClaudeBarApp: App {
    @State private var loginItem = LoginItemController()

    init() {
        if let code = CommandLineTool.run(CommandLine.arguments) {
            exit(code)
        }
    }

    var body: some Scene {
        MenuBarExtra("ClaudeBar", systemImage: "sparkle") {
            MenuPanelView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(loginItem)
        }
    }
}
