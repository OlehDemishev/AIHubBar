import AppKit

/// "Open in …" actions for a project folder.
@MainActor
enum ProjectActions {
    static func openInTerminal(_ path: String) {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            AppLog.error("Terminal.app not found")
            return
        }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { AppLog.error("Open in Terminal failed: \(error.localizedDescription)") }
        }
    }

    static func openInFinder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
