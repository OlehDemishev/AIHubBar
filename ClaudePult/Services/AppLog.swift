import Foundation
import OSLog

/// App log: unified logging plus a plain text file in ~/Library/Logs/ClaudePult/ClaudePult.log.
/// Never pass tokens or file contents here.
enum AppLog {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/ClaudePult", directoryHint: .isDirectory)
    static let fileURL = directory.appending(path: "ClaudePult.log")

    private static let maxFileSize = 1_000_000
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

    private static func write(_ level: String, _ message: String) {
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
