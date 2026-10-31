import AppKit
import Darwin
import Observation
import UserNotifications

/// Claude Code sessions from the hook's files in Application Support, kept current by watching the folder.
@MainActor
@Observable
final class SessionStore {
    struct Item: Identifiable, Equatable {
        var session: Session
        var state: Session.State
        /// How full the context is (0…1), for sessions that aren't over.
        var context: Double?
        var id: String { session.id }
    }

    private(set) var items: [Item] = []
    /// Open permission requests, by session id (`ApprovalFiles`).
    private(set) var approvals: [String: ApprovalRequest] = [:]
    /// Set by the app: whether permissions may be answered from ClaudePult («Отвечать из уведомлений»).
    var approvalsEnabled: () -> Bool = { true }

    var waitingCount: Int { items.filter { $0.state == .waiting }.count }
    var activeItems: [Item] { items }

    private let directory: URL
    private var watcher: DispatchSourceFileSystemObject?
    private var ticker: Task<Void, Never>?
    private var reloadScheduled = false
    /// Sessions already announced for their current waiting episode (keyed by id + event time).
    private var notified: Set<String> = []
    private var contextNotified: Set<String> = []

    init(directory: URL = SessionFiles.sessionsDirectory) {
        self.directory = directory
    }

    func start() {
        guard ticker == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        watchDirectory()
        reload()
        // Liveness and age-based hiding change without file events.
        keepApprovalsAlive()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.keepApprovalsAlive()
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
            let (loaded, requests) = await Task.detached(priority: .utility) {
                (SessionStore.loadItems(from: directory, now: .now), ApprovalFiles.bySession(ApprovalFiles.requests()))
            }.value
            apply(loaded, requests: requests)
        }
    }

    private func apply(_ loaded: [Item], requests: [String: ApprovalRequest]) {
        if loaded != items { items = loaded }
        // A request only counts while its session still waits; answered in Claude, it is over.
        let open = requests.filter { id, _ in loaded.contains { $0.id == id && $0.state == .waiting } }
        if open != approvals { approvals = open }
        announceWaiting(loaded)
        announceFullContext(loaded)
    }

    /// «Разрешить» / «Отклонить» from the panel or a notification.
    func decide(requestID: String, allow: Bool) {
        ApprovalFiles.decide(requestID, allow: allow)
        if let request = approvals.values.first(where: { $0.id == requestID }) {
            approvals[request.sessionID] = nil
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["waiting-\(request.sessionID)"])
        }
        AppLog.info("Permission \(allow ? "allowed" : "denied") from AI Hub Bar")
    }

    private func keepApprovalsAlive() {
        if approvalsEnabled() { ApprovalFiles.touchAlive() } else { ApprovalFiles.stopAlive() }
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
        return SessionRules.sorted(entries).map { entry in
            let context = entry.state == .ended ? nil : entry.session.transcriptPath
                .flatMap { ContextUsage.lastRecord(transcript: URL(fileURLWithPath: $0)) }
                .map(ContextUsage.fraction)
            return Item(session: entry.session, state: entry.state, context: context)
        }
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

    /// Once per wait: a permission request comes as two hook events (PermissionRequest, then Claude's own
    /// «needs your permission» notification) and an idle reminder rewrites the file again — none of that is a new wait.
    private func announceWaiting(_ items: [Item]) {
        let waiting = items.filter { $0.state == .waiting }
        let keys = Set(waiting.map(\.id))
        // Forget waits that are over, so the next wait of the same session notifies again.
        notified.formIntersection(keys)
        for item in waiting {
            let key = item.id
            guard !notified.contains(key) else { continue }
            notified.insert(key)
            // Do not replay old waits after an app restart.
            if Date.now.timeIntervalSince(item.session.updatedAt) < 600 {
                post(item.session)
            }
        }
    }

    /// Once per session: the context is nearly full, Claude will soon compact the conversation.
    private func announceFullContext(_ items: [Item]) {
        for item in items where (item.context ?? 0) >= ContextUsage.notifyAt && !contextNotified.contains(item.id) {
            contextNotified.insert(item.id)
            Notifier.post(
                id: "context-\(item.id)",
                title: String(localized: "Контекст почти заполнен — \(item.session.displayProject)"),
                body: String(localized: "≈ \(Int(((item.context ?? 0) * 100).rounded())) %: скоро Claude сожмёт историю. Если задача большая — лучше начать новую сессию с кратким итогом."),
                target: .session(id: item.id)
            )
        }
    }

    private func post(_ session: Session) {
        if let request = approvals[session.id] {
            Notifier.post(
                id: "waiting-\(session.id)",
                title: String(localized: "Claude просит разрешение — \(session.displayProject)"),
                body: request.text,
                target: .approval(sessionID: session.id, requestID: request.id)
            )
            return
        }
        Notifier.post(
            id: "waiting-\(session.id)",
            title: String(localized: "Claude ждёт ответа — \(session.displayProject)"),
            body: session.message ?? session.task ?? String(localized: "Нужно ваше решение."),
            target: .session(id: session.id)
        )
    }
}

// MARK: - «Показать»

@MainActor
enum SessionActions {
    /// Terminal.app sessions: bring the tab with the session's tty forward. Desktop-app sessions: open that session
    /// in Claude (just Claude if the app has no record of it); `claude` started in the Claude app's own terminal
    /// lives in Claude too, so Claude comes forward rather than Finder. Otherwise (or if the tab is gone): the folder.
    static func show(_ session: Session) {
        AppLog.info("Show session \(session.id) (\(session.entrypoint ?? "-"))")
        Task {
            if session.isInTerminalApp, let tty = session.tty, await focusTerminalTab(tty: tty) {
                return
            }
            if session.entrypoint == "claude-desktop" || session.termProgram == "claude-desktop",
               let claude = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
                if let link = desktopLink(cliSessionID: session.id) {
                    AppLog.info("Show session: Claude app link \(link.absoluteString)")
                    NSWorkspace.shared.open([link], withApplicationAt: claude, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                } else {
                    AppLog.info("Show session: no Claude app record for \(session.id), opening Claude")
                    NSWorkspace.shared.openApplication(at: claude, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                }
                return
            }
            ProjectActions.openInFinder(session.cwd)
        }
    }

    /// Where the Claude desktop app keeps its Code sessions: `<account>/<org>/local_<id>.json`, each with the CLI's `cliSessionId`.
    nonisolated static let desktopSessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Claude/claude-code-sessions")

    /// `claude://code/continue?session=local_…` for the desktop session that runs this CLI session, if the app knows it.
    nonisolated static func desktopLink(cliSessionID: String, in directory: URL = desktopSessionsDirectory) -> URL? {
        guard let id = desktopSessionID(cliSessionID: cliSessionID, in: directory) else { return nil }
        var link = URLComponents(string: "claude://code/continue")!
        link.queryItems = [URLQueryItem(name: "session", value: id)]
        return link.url
    }

    nonisolated static func desktopSessionID(cliSessionID: String, in directory: URL) -> String? {
        struct Record: Decodable {
            var sessionId: String
            var cliSessionId: String?
            var previousCliSessionIds: [String]?
            var isArchived: Bool?
        }
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.isArchived != true,
                  record.cliSessionId == cliSessionID || record.previousCliSessionIds?.contains(cliSessionID) == true
            else { continue }
            return record.sessionId
        }
        return nil
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
