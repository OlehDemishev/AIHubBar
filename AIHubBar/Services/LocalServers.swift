import Darwin
import Foundation

/// A process that listens on a TCP port and runs inside a project folder: a dev server, a preview, a database started
/// from the project.
struct LocalServer: Equatable, Identifiable, Sendable {
    var pid: Int32
    var command: String
    var port: Int
    /// The process's working folder.
    var folder: String

    var id: String { "\(pid):\(port)" }
    var url: URL? { URL(string: "http://localhost:\(port)") }
}

/// Listening processes by `lsof` (no permission needed: only the person's own processes are seen).
enum LocalServers {
    struct Listener: Equatable, Sendable {
        var pid: Int32
        var command: String
        var port: Int
    }

    /// Every listening process of the person with a working folder.
    static func scan() async -> [LocalServer] {
        guard let listening = try? await ProcessRunner.run(
            "/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"], timeout: .seconds(10)
        ) else { return [] }
        let listeners = parseListeners(listening.stdoutText)
        guard !listeners.isEmpty else { return [] }
        let pids = Set(listeners.map(\.pid)).sorted().map(String.init).joined(separator: ",")
        // lsof exits 1 when some PIDs have gone away; whatever it printed is still valid.
        guard let folders = try? await ProcessRunner.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", pids, "-Fpn"], timeout: .seconds(10))
        else { return [] }
        let directories = parseDirectories(folders.stdoutText)
        return listeners.compactMap { listener in
            directories[listener.pid].map { LocalServer(pid: listener.pid, command: listener.command, port: listener.port, folder: $0) }
        }
    }

    /// `lsof -Fpcn` output: `p<pid>`, `c<command>`, then `n<address>:<port>` per listening socket. A process that
    /// listens on IPv4 and IPv6 names the port twice; it is kept once.
    static func parseListeners(_ output: String) -> [Listener] {
        var result: [Listener] = []
        var pid: Int32?
        var command = ""
        for line in output.split(separator: "\n") {
            guard let kind = line.first else { continue }
            let value = line.dropFirst()
            switch kind {
            case "p":
                pid = Int32(value)
                command = ""
            case "c":
                command = String(value)
            case "n":
                guard let pid, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let listener = Listener(pid: pid, command: command, port: port)
                if !result.contains(listener) { result.append(listener) }
            default:
                continue
            }
        }
        return result.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// `lsof -d cwd -Fpn` output: `p<pid>` and its `n<folder>`.
    static func parseDirectories(_ output: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("n/"), let pid {
                result[pid] = String(line.dropFirst())
            }
        }
        return result
    }

    /// The servers that run in a project's folder or below it (its worktrees too).
    static func servers(_ all: [LocalServer], in projectPath: String) -> [LocalServer] {
        let root = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
        return all.filter { $0.folder == root || $0.folder.hasPrefix(root + "/") }
    }

    /// Asks the process to quit (SIGTERM) — only if it still listens on that port from that folder, so a process id
    /// that has passed to another program is left alone.
    @discardableResult
    static func stop(_ server: LocalServer) async -> Bool {
        guard await scan().contains(server) else { return false }
        let done = kill(server.pid, SIGTERM) == 0
        AppLog.info("Local server \(server.command) :\(server.port) (pid \(server.pid)) asked to quit: \(done)")
        return done
    }
}
