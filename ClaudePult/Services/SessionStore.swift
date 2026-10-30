import AppKit
import Darwin
import Observation

/// Claude Code sessions from the hook's files in Application Support, kept current by watching the folder.
@MainActor
@Observable
final class SessionStore {
    struct Item: Identifiable, Equatable {
        var session: Session
        var state: Session.State
        var id: String { session.id }
    }

    private(set) var items: [Item] = []

    var waitingCount: Int { items.filter { $0.state == .waiting }.count }
    var activeItems: [Item] { items }

    private let directory: URL
    private var watcher: DispatchSourceFileSystemObject?
    private var ticker: Task<Void, Never>?
    private var reloadScheduled = false
    /// Sessions already announced for their current waiting episode (keyed by id + event time).
    private var notified: Set<String> = []

    init(directory: URL = SessionFiles.sessionsDirectory) {
        self.directory = directory
    }

    func start() {
        guard ticker == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        watchDirectory()
        reload()
        // Liveness and age-based hiding change without file events.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.reload()
            }
        }
        Task.detached(priority: .background) { [directory] in
            SessionStore.deleteOldFiles(in: directory, now: .now)
        }
    }

    func reload() {
        let directory = directory
        Task {
            let loaded = await Task.detached(priority: .utility) {
                SessionStore.loadItems(from: directory, now: .now)
            }.value
            apply(loaded)
        }
    }

    private func apply(_ loaded: [Item]) {
        if loaded != items { items = loaded }
        announceWaiting(loaded)
    }

    // MARK: - Loading (off the main actor)

    nonisolated static func loadItems(from directory: URL, now: Date) -> [Item] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        let entries: [(session: Session, state: Session.State)] = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let session = try? decoder.decode(Session.self, from: data) else { return nil }
                let alive = session.claudePID.map(isClaudeProcessAlive)
                guard SessionRules.isVisible(session, isAlive: alive, now: now) else { return nil }
                return (session, SessionRules.effectiveState(session, isAlive: alive))
            }
        return SessionRules.sorted(entries).map { Item(session: $0.session, state: $0.state) }
    }

    /// True when `pid` exists and is still a Claude Code executable (guards against PID reuse).
    nonisolated static func isClaudeProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let name = (path as NSString).lastPathComponent
        return RunningSessions.executableNames.contains(name)
    }

    nonisolated static func deleteOldFiles(in directory: URL, now: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in files {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > SessionRules.deleteAfter {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Watching

    private func watchDirectory() {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            AppLog.error("Cannot watch \(directory.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// Hooks often fire in bursts (Stop right after Notification); coalesce them.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            reloadScheduled = false
            reload()
        }
    }

    // MARK: - Notifications

    private func announceWaiting(_ items: [Item]) {
        let waiting = items.filter { $0.state == .waiting }
        let keys = Set(waiting.map { "\($0.id)|\($0.session.updatedAt.timeIntervalSince1970)" })
        // Forget episodes that are over, so the next wait of the same session notifies again.
        notified.formIntersection(keys)
        for item in waiting {
            let key = "\(item.id)|\(item.session.updatedAt.timeIntervalSince1970)"
            guard !notified.contains(key) else { continue }
            notified.insert(key)
            // Do not replay old waits after an app restart.
            if Date.now.timeIntervalSince(item.session.updatedAt) < 600 {
                post(item.session)
            }
        }
    }

    private func post(_ session: Session) {
        Notifier.post(
            id: "waiting-\(session.id)",
            title: "Claude ждёт ответа — \(session.displayProject)",
            body: session.message ?? session.task ?? "Нужно ваше решение.",
            target: .session(id: session.id)
        )
    }
}

// MARK: - «Показать»

@MainActor
enum SessionActions {
    /// Terminal.app sessions: bring the tab with the session's tty forward. Desktop-app sessions: open Claude.
    /// Otherwise (or if the tab is gone): open the folder in Finder.
    static func show(_ session: Session) {
        Task {
            if session.isInTerminalApp, let tty = session.tty, await focusTerminalTab(tty: tty) {
                return
            }
            if session.entrypoint == "claude-desktop",
               let claude = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
                NSWorkspace.shared.openApplication(at: claude, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                return
            }
            ProjectActions.openInFinder(session.cwd)
        }
    }

    nonisolated static let focusScript = [
        "on run argv",
        "set targetTTY to item 1 of argv",
        "if application \"Terminal\" is not running then return \"missing\"",
        "tell application \"Terminal\"",
        "repeat with w in windows",
        "repeat with t in tabs of w",
        "if tty of t is targetTTY then",
        "set selected tab of w to t",
        "set index of w to 1",
        "activate",
        "return \"found\"",
        "end if",
        "end repeat",
        "end repeat",
        "end tell",
        "return \"missing\"",
        "end run",
    ]

    nonisolated static func focusTerminalTab(tty: String) async -> Bool {
        let args = focusScript.flatMap { ["-e", $0] } + [tty]
        guard let result = try? await ProcessRunner.run("/usr/bin/osascript", args, timeout: .seconds(30)) else { return false }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "found"
    }
}
