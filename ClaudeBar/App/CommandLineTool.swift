import Foundation

/// Headless commands for scripts and checks, run instead of the UI:
/// `ClaudeBar.app/Contents/MacOS/ClaudeBar --login-item [status|on|off]`.
@MainActor
enum CommandLineTool {
    /// Returns an exit code if the arguments contain a command, `nil` to start the app normally.
    static func run(_ arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: "--login-item") else { return nil }
        let action = arguments.dropFirst(index + 1).first ?? "status"

        let controller = LoginItemController()
        switch action {
        case "status": break
        case "on": controller.setEnabled(true)
        case "off": controller.setEnabled(false)
        default:
            FileHandle.standardError.write(Data("Usage: ClaudeBar --login-item [status|on|off]\n".utf8))
            return 2
        }

        print("login-item: \(controller.state)")
        if let error = controller.lastError {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
        return 0
    }
}
