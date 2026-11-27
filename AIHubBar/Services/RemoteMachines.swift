import Foundation
import Observation

/// The other computers' sessions (`RemoteMachine`): one `ssh` per computer runs the helper's `watch` and its lines
/// become the sessions and permission requests `SessionStore` shows beside this Mac's. A lost connection is tried
/// again by itself; what that computer showed goes from the list meanwhile, so nothing stale can be answered.
@MainActor
@Observable
final class RemoteMachines {
    enum Link: Equatable {
        case connecting
        case connected
        /// ssh's own words: no route, no key, an unknown host.
        case offline(String)
        /// The helper is not there: «Установить» puts it.
        case needsSetup

        var title: String {
            switch self {
            case .connecting: String(localized: "подключение…")
            case .connected: String(localized: "подключено")
            case .offline: String(localized: "нет связи")
            case .needsSetup: String(localized: "не установлено")
            }
        }
    }

    /// What the last install on a computer did, for Settings.
    struct SetupResult: Equatable {
        var isError: Bool
        var text: String
    }

    private(set) var links: [String: Link] = [:]
    private(set) var setup: [String: SetupResult] = [:]
    private(set) var settingUp: Set<String> = []

    private let settings: AppSettings
    private let sessions: SessionStore
    /// Set by the app: the «Сессии агентов» module is on.
    var isActive: () -> Bool = { true }

    @ObservationIgnored private var streams: [String: RemoteStream] = [:]
    @ObservationIgnored private var snapshots: [String: RemoteSnapshot] = [:]
    /// What each stream was started for: a changed host or answer option starts it again.
    @ObservationIgnored private var started: [String: String] = [:]
    @ObservationIgnored private var retries: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var failures: [String: Int] = [:]
    /// Computers whose older helper was already replaced once in this run: no loop if that does not help.
    @ObservationIgnored private var upgraded: Set<String> = []

    init(settings: AppSettings, sessions: SessionStore) {
        self.settings = settings
        self.sessions = sessions
    }

    func start() {
        sessions.decideRemotely = { [weak self] machineID, requestID, allow in
            self?.decide(machineID: machineID, requestID: requestID, allow: allow)
        }
        follow()
    }

    /// Follows the list in Settings and the answer option; the module's switch calls `sync` itself.
    private func follow() {
        withObservationTracking {
            _ = settings.remoteMachines
            _ = settings.approvalsFromClaudePult
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        sync()
    }

    func sync() {
        let wanted = isActive() ? settings.remoteMachines.filter { $0.isOn && RemoteMachine.isValidHost($0.host) } : []
        let approvals = settings.approvalsFromClaudePult
        for (id, _) in streams where !wanted.contains(where: { $0.id == id && Self.key($0, approvals) == started[id] }) {
            stop(id)
        }
        for id in links.keys where !wanted.contains(where: { $0.id == id }) {
            stop(id)
            links[id] = nil
        }
        for machine in wanted where streams[machine.id] == nil && retries[machine.id] == nil && links[machine.id] != .needsSetup {
            connect(machine, approvals: approvals)
        }
        publish()
    }

    private static func key(_ machine: RemoteMachine, _ approvals: Bool) -> String { "\(machine.host)|\(approvals)" }

    private func connect(_ machine: RemoteMachine, approvals: Bool) {
        let id = machine.id
        if links[id] != .connected { links[id] = .connecting }
        started[id] = Self.key(machine, approvals)
        let remote = SSHCommand.helper(approvals ? "watch --approvals" : "watch")
        let stream = RemoteStream(arguments: SSHCommand.arguments(host: machine.host, remote: remote, keepAlive: true))
        streams[id] = stream
        stream.start(
            onLine: { [weak self] line in Task { @MainActor in self?.received(line, from: id, stream: stream) } },
            onEnd: { [weak self] code, stderr in Task { @MainActor in self?.ended(id, stream: stream, exitCode: code, stderr: stderr) } }
        )
    }

    private func received(_ line: Data, from id: String, stream: RemoteStream) {
        guard streams[id] === stream, let snapshot = RemoteSnapshot.parse(line: line) else { return }
        if snapshot.format != RemoteScript.format, !upgraded.contains(id), let machine = machine(id) {
            // An older helper from before an update of AI Hub Bar: replaced once, then connected again.
            upgraded.insert(id)
            stop(id)
            install(machine)
            return
        }
        failures[id] = 0
        links[id] = .connected
        guard snapshots[id] != snapshot else { return }
        snapshots[id] = snapshot
        publish()
    }

    private func ended(_ id: String, stream: RemoteStream, exitCode: Int32, stderr: String) {
        guard streams[id] === stream else { return }
        streams[id] = nil
        snapshots[id] = nil
        publish()
        guard let machine = machine(id), machine.isOn else { return }
        if SSHCommand.isMissingHelper(stderr: stderr) {
            links[id] = .needsSetup
            return
        }
        let reason = SSHCommand.reason(stderr: stderr, exitCode: exitCode)
        if links[id] != .offline(reason) { AppLog.info("Remote computer \(machine.host): \(reason)") }
        links[id] = .offline(reason)
        // 15 s, 30 s, then every minute: a laptop that went to sleep comes back by itself.
        let count = failures[id, default: 0]
        failures[id] = count + 1
        let wait = [15, 30][safe: count] ?? 60
        retries[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.retries[id] = nil
            self.sync()
        }
    }

    private func stop(_ id: String) {
        streams.removeValue(forKey: id)?.stop()
        retries.removeValue(forKey: id)?.cancel()
        snapshots[id] = nil
        started[id] = nil
    }

    private func machine(_ id: String) -> RemoteMachine? { settings.remoteMachines.first { $0.id == id } }

    private func publish() {
        var entries: [RemoteSnapshot.Entry] = [], requests: [ApprovalRequest] = []
        for machine in settings.remoteMachines {
            guard let snapshot = snapshots[machine.id] else { continue }
            entries += snapshot.entries(on: machine)
            requests += snapshot.requests(on: machine)
        }
        sessions.setRemote(entries: entries, requests: requests)
    }

    // MARK: - Actions

    /// Tries a computer again now: after «Установить», or from Settings.
    func reconnect(_ machine: RemoteMachine) {
        stop(machine.id)
        failures[machine.id] = 0
        links[machine.id] = nil
        sync()
    }

    /// Puts the hook and the helper on the computer (or replaces them) and connects. What it changed there is said
    /// in Settings: the hook in `~/.claude/settings.json`, with a backup beside it.
    func install(_ machine: RemoteMachine) {
        let id = machine.id
        guard RemoteMachine.isValidHost(machine.host), !settingUp.contains(id) else { return }
        settingUp.insert(id)
        setup[id] = nil
        Task {
            let result = await Self.runInstall(host: machine.host)
            settingUp.remove(id)
            setup[id] = result
            if result.isError {
                AppLog.error("Remote install on \(machine.host): \(result.text)")
            } else {
                AppLog.info("Remote install on \(machine.host): \(result.text)")
                reconnect(machine)
            }
        }
    }

    /// Removes what `install` put there. The list entry stays for the caller to drop.
    func uninstall(_ machine: RemoteMachine) async {
        stop(machine.id)
        guard RemoteMachine.isValidHost(machine.host) else { return }
        let arguments = SSHCommand.arguments(host: machine.host, remote: SSHCommand.helper("uninstall"))
        let result = try? await ProcessRunner.run(SSHCommand.executable, arguments, timeout: .seconds(30))
        AppLog.info("Remote uninstall on \(machine.host): \(result.map { "exit \($0.exitCode)" } ?? "no answer")")
    }

    private func decide(machineID: String, requestID: String, allow: Bool) {
        guard let machine = machine(machineID), ApprovalFiles.isValidID(requestID) else { return }
        let remote = SSHCommand.helper("decide \(requestID) \(allow ? "allow" : "deny")")
        let arguments = SSHCommand.arguments(host: machine.host, remote: remote)
        Task {
            let result = try? await ProcessRunner.run(SSHCommand.executable, arguments, timeout: .seconds(20))
            if result?.exitCode != 0 {
                // The request is still open there: the agent's own dialog answers it, as with AI Hub Bar closed.
                AppLog.error("Permission answer not delivered to \(machine.host): \(result.map { SSHCommand.reason(stderr: $0.stderrText, exitCode: $0.exitCode) } ?? "no answer")")
            }
        }
    }

    nonisolated static func runInstall(host: String) async -> SetupResult {
        let arguments = SSHCommand.arguments(host: host, remote: "python3 -")
        do {
            let result = try await ProcessRunner.run(SSHCommand.executable, arguments,
                                                     input: Data(RemoteScript.bootstrap().utf8), timeout: .seconds(60))
            return setupResult(exitCode: result.exitCode, stdout: result.stdoutText, stderr: result.stderrText)
        } catch {
            return SetupResult(isError: true, text: error.localizedDescription)
        }
    }

    /// The bootstrap's one JSON line, in words.
    nonisolated static func setupResult(exitCode: Int32, stdout: String, stderr: String) -> SetupResult {
        struct Reply: Decodable {
            var hook: String?
            var backup: String?
            var error: String?
            var claude: Bool?
        }
        let line = stdout.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        guard exitCode == 0, let reply = try? JSONDecoder().decode(Reply.self, from: Data(line.utf8)) else {
            let reason = SSHCommand.reason(stderr: stderr, exitCode: exitCode)
            return SetupResult(isError: true, text: reason.contains("python3")
                ? String(localized: "На том компьютере нет python3: без него AI Hub Bar там не работает.") : reason)
        }
        if let error = reply.error { return SetupResult(isError: true, text: error) }
        var parts: [String] = [reply.hook == "kept"
            ? String(localized: "Там уже есть отслеживание AI Hub Bar — оставлено как есть.")
            : String(localized: "Отслеживание установлено на том компьютере (записи в ~/.claude/settings.json).")]
        if let backup = reply.backup { parts.append(String(localized: "Резервная копия: ~/.claude/\(backup)")) }
        if reply.claude == false { parts.append(String(localized: "Claude Code там не найден: сессии появятся, когда он будет установлен.")) }
        return SetupResult(isError: false, text: parts.joined(separator: " "))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// One long-running `ssh` whose output is read line by line. The callbacks come on background threads.
final class RemoteStream: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var buffer = Data()
    private var errors = Data()

    init(arguments: [String], executable: String = SSHCommand.executable, environment: [String: String] = [:]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessRunner.environment().merging(environment) { $1 }
        process.standardInput = FileHandle.nullDevice
    }

    func start(onLine: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable (Int32, String) -> Void) {
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in self.lines(adding: chunk) { onLine(line) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.lock.withLock { self.errors = Data((self.errors + chunk).suffix(4000)) }
        }
        process.terminationHandler = { [weak self] process in
            // What ssh said last is often still in the pipe when it exits.
            let rest = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let text = self?.lock.withLock { String(decoding: (self?.errors ?? Data()) + rest, as: UTF8.self) } ?? ""
            onEnd(process.terminationStatus, text)
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            onEnd(-1, error.localizedDescription)
        }
    }

    func stop() {
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
    }

    /// Whole lines out of what has come so far; a line longer than 4 MB is dropped (never a session list).
    private func lines(adding chunk: Data) -> [Data] {
        lock.withLock {
            buffer.append(chunk)
            var lines: [Data] = []
            while let end = buffer.firstIndex(of: 0x0A) {
                lines.append(Data(buffer[buffer.startIndex..<end]))
                buffer = Data(buffer[buffer.index(after: end)...])
            }
            if buffer.count > 4_000_000 { buffer.removeAll() }
            return lines
        }
    }
}
