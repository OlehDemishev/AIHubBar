import Foundation
import OSLog

/// App log: unified logging plus a plain text file in ~/Library/Logs/ClaudePult/ClaudePult.log.
/// Never pass tokens or file contents here.
enum AppLog {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/ClaudePult", directoryHint: .isDirectory)
    static let fileURL = directory.appending(path: "ClaudePult.log")

    private static let maxFileSize = 1_000_000
    /// Unit tests run inside the app; keep their git sandboxes and launches out of the real log.
    private static let writesFile = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    private static let queue = DispatchQueue(label: "com.demishev.claudepult.log")
    private static let logger = Logger(subsystem: "com.demishev.claudepult", category: "app")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("ERROR", message)
    }

    /// Waits for pending writes; call before `exit()` in command-line mode.
    static func flush() {
        queue.sync {}
    }

    private static func write(_ level: String, _ message: String) {
        guard writesFile else { return }
        let line = "\(Date.now.ISO8601Format(.iso8601(timeZone: .current))) \(level) \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > maxFileSize {
                let old = directory.appending(path: "ClaudePult.1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: fileURL, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }
}
