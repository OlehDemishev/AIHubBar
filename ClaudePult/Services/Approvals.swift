import Darwin
import Foundation

/// A permission Claude Code asked for, waiting for «Разрешить» / «Отклонить» from a notification or the panel.
/// The hook writes `approvals/<id>.request.json` and waits a few minutes for `<id>.decision`; Claude's own dialog is
/// on screen at the same time (checked live, 2026-10-30), so whichever answer comes first applies.
struct ApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var sessionID: String
    var project: String?
    var tool: String
    /// The command, file or URL the tool wants, cut to 200 characters.
    var summary: String
    /// Seconds since 1970, as the hook writes them.
    var created: Double
    /// The waiting hook: once it is gone (Claude cancelled it), nobody would read an answer.
    var pid: Int32?

    enum CodingKeys: String, CodingKey { case id, sessionID = "session_id", project, tool, summary, created, pid }

    var text: String { summary.isEmpty ? tool : "\(tool): \(summary)" }
}

/// The files shared with the hook. The hook only waits while ClaudePult keeps `alive` fresh (it is touched on every
/// session tick), so with ClaudePult closed or the option off Claude asks as usual.
enum ApprovalFiles {
    static let directory = SessionFiles.supportDirectory.appending(path: "approvals", directoryHint: .isDirectory)
    /// How long the hook waits for an answer; its settings.json timeout is a little longer.
    static let waitSeconds = 290

    nonisolated static func requests(in directory: URL = directory, now: Date = .now) -> [ApprovalRequest] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasSuffix(".request.json") }
            .compactMap { try? JSONDecoder().decode(ApprovalRequest.self, from: Data(contentsOf: $0)) }
            .filter { now.timeIntervalSince1970 - $0.created < Double(waitSeconds) && $0.pid.map(isRunning) != false }
            .sorted { $0.created < $1.created }
    }

    /// The newest open request of each session.
    nonisolated static func bySession(_ requests: [ApprovalRequest]) -> [String: ApprovalRequest] {
        Dictionary(requests.map { ($0.sessionID, $0) }) { older, newer in newer.created >= older.created ? newer : older }
    }

    nonisolated static func isRunning(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    nonisolated static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    nonisolated static func decide(_ id: String, allow: Bool, in directory: URL = directory) {
        guard isValidID(id) else { return }
        try? Data((allow ? "allow" : "deny").utf8).write(to: directory.appending(path: "\(id).decision"), options: .atomic)
    }

    nonisolated static func touchAlive(in directory: URL = directory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("\(Date.now.timeIntervalSince1970)".utf8).write(to: directory.appending(path: "alive"), options: .atomic)
    }

    nonisolated static func stopAlive(in directory: URL = directory) {
        try? FileManager.default.removeItem(at: directory.appending(path: "alive"))
    }
}
