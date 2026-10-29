import SwiftUI

@main
struct ClaudePultApp: App {
    @State private var loginItem = LoginItemController()

    init() {
        if let code = CommandLineTool.run(CommandLine.arguments) {
            exit(code)
        }
    }

    var body: some Scene {
        MenuBarExtra("ClaudePult", systemImage: "sparkle") {
            MenuPanelView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(loginItem)
        }
    }
}
