import Foundation

/// Folders tests need, made fresh in the temporary directory: nothing depends on what this Mac has in its home
/// folder (docs/SPEC-refactor.md §7 — CI machines have no `~/Projects/_daily-report`).
enum TestFolders {
    /// A `_daily-report` folder with a `report.py`: ModeStore then migrates the old setup into the first profile.
    static func dailyReport() -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "claudepult-daily-\(UUID().uuidString)/_daily-report")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? Data("# test\n".utf8).write(to: url.appending(path: "report.py"))
        return url.path
    }
}
