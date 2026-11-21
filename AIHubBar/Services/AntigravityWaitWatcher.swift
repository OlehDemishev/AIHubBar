import Foundation

/// Says when an Antigravity conversation starts waiting for an answer («Run this command?»). Antigravity has no hook
/// for that: its status line command (`AntigravityStatusLine`) keeps the last status in a file, and this watches the
/// file's folder — so the notification comes while the panel is closed, where the row in «Сессии» is read only when
/// the panel opens.
@MainActor
final class AntigravityWaitWatcher {
    private let line: AntigravityStatusLine
    private let isOpen: () -> Bool
    /// The conversation's row, for its project and title.
    private let thread: (String) -> AgentThread?
    var post: (_ id: String, _ title: String, _ body: String) -> Void = { Notifier.post(id: $0, title: $1, body: $2) }
    /// The «Сессии» module works: its notifications are its own.
    var isActive: () -> Bool = { true }

    /// A wait older than this was not asked just now — the app was started in the middle of it.
    static let recent: TimeInterval = 10 * 60

    private var announced: String?
    private var seen: Date?
    private var source: DispatchSourceFileSystemObject?

    init(line: AntigravityStatusLine = .live, isOpen: @escaping () -> Bool = AntigravityStatusLine.isAgyOpen,
         thread: @escaping (String) -> AgentThread? = { id in AntigravityConversations.recent(waiting: id).first { $0.id == id } }) {
        self.line = line
        self.isOpen = isOpen
        self.thread = thread
    }

    /// Watches the folder the status file is rewritten in (the script replaces the file, so the file itself can't be watched).
    func start() {
        guard source == nil else { return }
        let folder = line.statusURL.deletingLastPathComponent()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            AppLog.error("Cannot watch \(folder.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        check()
    }

    /// One look at the file. Other files change in that folder all the time, so an unchanged status costs one `stat`.
    func check(now: Date = .now) {
        let modified = HubFetch.modified(line.statusURL)
        guard modified != seen else { return }
        seen = modified
        guard isActive(), let modified, let data = try? Data(contentsOf: line.statusURL), let id = HubParse.antigravityWaiting(data) else {
            // Answered, or the file is gone: the next question of the same conversation is a new wait.
            announced = nil
            return
        }
        // The status line is run again while the question stands: once per wait.
        guard id != announced else { return }
        announced = id
        guard now.timeIntervalSince(modified) < Self.recent, isOpen() else { return }
        let thread = thread(id)
        let name = "Antigravity"
        let title = thread.map { String(localized: "\(name) ждёт ответа — \($0.project)") } ?? name
        post("waiting-agy-\(id)", title, thread.flatMap { $0.title.isEmpty ? nil : $0.title } ?? String(localized: "Нужно ваше решение."))
    }
}
