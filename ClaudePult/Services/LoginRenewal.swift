import Foundation

/// Claude Code renews its sign-in only while `claude` runs. Working in the Claude app leaves the token in
/// «Claude Code-credentials» expired, and the limits stop updating. A one-word request through `claude` renews it
/// for about 8 hours (checked live): no tools, no MCP servers, no settings (so no hooks), nothing saved to the
/// session history. ClaudePult never touches the token itself. The request costs a sliver of the subscription.
enum LoginRenewal {
    /// At most one attempt an hour, whether it worked or not.
    static let minInterval: TimeInterval = 3600

    static let arguments = [
        "-p", "OK", "--model", "haiku", "--max-turns", "1", "--tools", "",
        "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "",
    ]

    static func shouldTry(lastAttempt: Date?, now: Date) -> Bool {
        lastAttempt.map { now.timeIntervalSince($0) >= minInterval } ?? true
    }

    /// Runs the request in a fixed folder (Claude Code keeps one empty folder per working directory).
    static func run(claudePath: String) async -> Bool {
        let folder = FileManager.default.temporaryDirectory.appending(path: "claudepult-renew")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = try? await ProcessRunner.run(claudePath, arguments, currentDirectory: folder, timeout: .seconds(60))
        let ok = result?.exitCode == 0
        AppLog.info("Claude Code sign-in renewal: " + (ok ? "done" : "failed (exit \(result.map { "\($0.exitCode)" } ?? "none"))"))
        return ok
    }
}
