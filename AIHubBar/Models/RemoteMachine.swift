import Foundation

/// Another computer whose agent sessions the panel shows, reached with the person's own `ssh` (their keys, their
/// `~/.ssh/config`): a Mac, a Linux server or a VM. AI Hub Bar keeps no password and opens no port.
struct RemoteMachine: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    /// Shown beside its sessions; empty — the host.
    var name: String
    /// What `ssh` is given: a host from `~/.ssh/config`, or `user@host`.
    var host: String
    var isOn = true

    var title: String {
        let name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? host : name
    }

    /// A host `ssh` can take as one plain word: nothing that reads as an option, a space or shell syntax.
    static func isValidHost(_ host: String) -> Bool {
        host.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}(@[A-Za-z0-9][A-Za-z0-9_.:-]{0,252})?/) != nil
            || host.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.:-]{0,252}/) != nil
    }
}

/// Where a session runs when it is not this Mac (`Session.machine`).
struct SessionMachine: Equatable, Sendable {
    var id: String
    var name: String
    var host: String
}

/// The `ssh` command lines AI Hub Bar uses. Never a password prompt (`BatchMode`): a computer that needs one, or
/// whose key this Mac has not seen, fails with ssh's own words and the person connects once in Terminal.
enum SSHCommand {
    static let executable = "/usr/bin/ssh"

    /// `ssh <options> -- <host> <remote command>`; the remote command is one word for the other computer's shell.
    static func arguments(host: String, remote: String, keepAlive: Bool = false) -> [String] {
        var arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        if keepAlive { arguments += ["-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"] }
        return arguments + ["--", host, remote]
    }

    static func helper(_ command: String) -> String { "python3 \(RemoteScript.helperPath) \(command)" }

    /// Single quotes for the other computer's shell (sh, bash, zsh, fish alike).
    static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The line typed into Terminal here: an interactive `ssh` into the session's folder, optionally running a
    /// command there through the person's login shell (so `claude` is on its PATH).
    static func terminalCommandLine(host: String, folder: String, run command: String? = nil) -> String {
        let shell = command.map { "exec \"$SHELL\" -lic \(quote($0))" } ?? "exec \"$SHELL\" -l"
        let remote = folder.isEmpty ? shell : "cd \(quote(folder)) && \(shell)"
        return "ssh -t -- \(ShellQuote.quote(host)) \(ShellQuote.quote(remote))"
    }

    /// What ssh said, as one line for the person: its last line, without the «ssh: » prefix.
    static func reason(stderr: String, exitCode: Int32) -> String {
        let line = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") } ?? ""
        let text = line.hasPrefix("ssh: ") ? String(line.dropFirst(5)) : line
        return text.isEmpty ? "ssh: \(exitCode)" : String(text.prefix(200))
    }

    /// The helper is not on the other computer (yet, or any more).
    static func isMissingHelper(stderr: String) -> Bool {
        stderr.contains("remote.py") && (stderr.contains("No such file") || stderr.contains("can't open file"))
    }
}

/// One line of the helper's `watch`: everything the other computer has to show right now.
struct RemoteSnapshot: Decodable, Equatable, Sendable {
    struct Entry: Decodable, Equatable, Sendable {
        var session: Session
        /// Whether the agent's process is still there, as the helper saw it; nil when the hook recorded none.
        var alive: Bool?

        private enum CodingKeys: String, CodingKey { case alive }

        init(session: Session, alive: Bool?) {
            self.session = session
            self.alive = alive
        }

        init(from decoder: Decoder) throws {
            session = try Session(from: decoder)
            alive = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Bool.self, forKey: .alive)
        }
    }

    var format: Int
    var sessions: [Entry]
    var requests: [ApprovalRequest]

    private enum CodingKeys: String, CodingKey { case format, sessions, requests }

    init(format: Int = RemoteScript.format, sessions: [Entry] = [], requests: [ApprovalRequest] = []) {
        self.format = format
        self.sessions = sessions
        self.requests = requests
    }

    /// A record the helper could not have written well (a half-written file, a newer hook) is skipped, not fatal.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(Int.self, forKey: .format)
        sessions = ((try? c.decodeIfPresent([Lossy<Entry>].self, forKey: .sessions)) ?? []).compactMap(\.value)
        requests = ((try? c.decodeIfPresent([Lossy<ApprovalRequest>].self, forKey: .requests)) ?? []).compactMap(\.value)
    }

    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    static func parse(line: Data) -> RemoteSnapshot? {
        try? JSONDecoder().decode(RemoteSnapshot.self, from: line)
    }

    /// The sessions as this Mac shows them, each marked with its computer.
    func entries(on machine: RemoteMachine) -> [RemoteSnapshot.Entry] {
        let place = SessionMachine(id: machine.id, name: machine.title, host: machine.host)
        return sessions.map { entry in
            var entry = entry
            entry.session.machine = place
            return entry
        }
    }

    /// Only for sessions this same computer reported: it cannot ask in the name of another one's session.
    func requests(on machine: RemoteMachine) -> [ApprovalRequest] {
        let own = Set(sessions.map(\.session.id))
        return requests.filter { own.contains($0.sessionID) }.map { request in
            var request = request
            request.machineID = machine.id
            return request
        }
    }
}
