import SwiftUI

/// One line of the «Сессии» block: a hook-tracked session, a background run, or both (same id).
struct SessionRow: Identifiable, Equatable {
    var id: String
    var project: String
    var worktree: String?
    var task: String?
    var startedAt: Date?
    var endedAt: Date?
    var state: Session.State
    var context: Double?
    var message: String?
    var session: Session?
    var run: BackgroundRun?

    /// Sessions from hooks, joined with background runs by id; runs without a session file (hooks off) are added.
    static func rows(sessions: [SessionStore.Item], runs: [BackgroundRun], now: Date = .now) -> [SessionRow] {
        let runsByID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = sessions.map { item -> SessionRow in
            let run = runsByID[item.id]
            let s = item.session
            return SessionRow(
                id: item.id, project: s.displayProject, worktree: s.worktreeName,
                task: run?.task ?? s.task, startedAt: run?.startedAt ?? s.startedAt,
                endedAt: run?.finishedAt ?? (item.state == .ended ? s.updatedAt : nil),
                // A run's own result (error, time limit) is more precise than the hook's «готово».
                state: run.map { $0.state == .running ? item.state : $0.state.sessionState } ?? item.state,
                context: item.context,
                message: item.state == .waiting ? s.message : run?.summary,
                session: s, run: run
            )
        }
        let shown = Set(rows.map(\.id))
        for run in runs where !shown.contains(run.id) {
            let recent = run.finishedAt.map { now.timeIntervalSince($0) < SessionRules.keepEndedFor } ?? true
            guard run.state == .running || recent else { continue }
            rows.append(SessionRow(
                id: run.id, project: run.project,
                worktree: run.worktreeBranch.map { _ in (run.folder as NSString).lastPathComponent },
                task: run.task, startedAt: run.startedAt, endedAt: run.finishedAt,
                state: run.state.sessionState, context: nil, message: run.summary, session: nil, run: run
            ))
        }
        let order: [Session.State: Int] = [.waiting: 0, .running: 1, .error: 2, .done: 3, .unknown: 4, .ended: 5]
        return rows.enumerated().sorted {
            let (a, b) = (order[$0.element.state] ?? 9, order[$1.element.state] ?? 9)
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
    }
}

/// «Сессии» block at the top of the panel (docs/specs/SPEC.md §2.3).
struct SessionsView: View {
    let rows: [SessionRow]
    /// Recent Codex and Copilot conversations (SPEC-ai-services stages 5–6), under Claude's sessions.
    var others: [AgentThread] = []
    /// Finished Claude Code sessions that can be continued.
    var resumable: [Session] = []
    @AppStorage(StorageKey.recentSessionsExpanded) private var showsResumable = false

    private var waiting: Int { rows.filter { $0.state == .waiting }.count }
    private var active: Int { rows.filter { $0.state != .ended }.count }
    @AppStorage(StorageKey.collapsedBlocks) private var collapsedRaw = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                BlockTitle(block: .sessions, title: "Сессии")
                if active > 0 {
                    Text(verbatim: "\(active)")
                        .scaledFont(.caption, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if waiting > 0 {
                    Text("ждут ответа: \(waiting)")
                        .scaledFont(.caption, weight: .medium)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)

            if !PanelBlock.collapsed(in: collapsedRaw).contains(.sessions) {
                ForEach(rows) { row in
                    SessionRowView(row: row)
                }
                ForEach(others) { thread in
                    AgentThreadRow(thread: thread)
                }
                if !resumable.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { showsResumable.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showsResumable ? 90 : 0))
                            Text("Недавно завершённые")
                            Spacer()
                        }
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    if showsResumable {
                        ForEach(resumable) { session in
                            ResumableSessionRow(session: session)
                        }
                    }
                }
            }
        }
        .padding(4)
    }
}

/// A finished Claude Code session: a click continues it in Terminal with `claude --resume`.
private struct ResumableSessionRow: View {
    let session: Session
    @Environment(AppSettings.self) private var settings
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(session.displayProject)
                .fontWeight(.medium)
                .lineLimit(1)
                .layoutPriority(1)
            if let task = session.task {
                Text(task)
                    .scaledFont(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(RelativeTime.ago(session.updatedAt))
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .densityPadding(4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(isHovered ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { SessionActions.resume(session, claudePath: settings.claudePath) }
        .onHover { isHovered = $0 }
        .help(String(localized: "Продолжить в Терминале · \(session.cwd)"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { SessionActions.resume(session, claudePath: settings.claudePath) }
    }
}

/// A recent conversation of another agent: project, title, when it was last updated, its context. A click continues
/// it in Terminal (`codex resume`, `copilot --resume`, `agy --conversation`). No state dot: without hooks the agents
/// don't say whether they wait; Antigravity at least says it is running.
private struct AgentThreadRow: View {
    let thread: AgentThread
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ServiceTab(agent: thread.agent).icon)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(thread.project)
                .fontWeight(.medium)
                .lineLimit(1)
                .layoutPriority(1)
            Text(thread.title.isEmpty ? thread.agent.title : thread.title)
                .scaledFont(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if thread.isWorking {
                Text("работает")
                    .scaledFont(.caption)
                    .foregroundStyle(Session.State.running.color)
            }
            if let context = thread.context, context >= ContextUsage.warnAt {
                Text("контекст \(Int((context * 100).rounded())) %")
                    .scaledFont(.caption)
                    .foregroundStyle(context >= ContextUsage.notifyAt ? .red : .orange)
            }
            Text(RelativeTime.ago(thread.updatedAt))
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        // The same frame as Claude's rows.
        .padding(.horizontal, 8)
        .densityPadding(4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(isHovered ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovered = $0 }
        .help(String(localized: "\(thread.agent.title) · \(thread.folder) — продолжить в Терминале"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(thread.agent.title), \(thread.project): \(thread.title)"))
        .accessibilityAddTraits(.isButton)
    }

    private func open() {
        Task {
            let agent = thread.agent
            guard let path = await Task.detached(operation: { agent.detect() }).value else {
                AppLog.error("Resume: \(agent.binary) not found")
                return
            }
            do {
                try await TerminalLauncher.run(thread.resumeCommandLine(path: path))
                AppLog.info("Resumed \(agent.binary) conversation in Terminal: \(thread.folder)")
            } catch {
                AppLog.error("Resume \(agent.binary) failed: \(error.localizedDescription)")
            }
        }
    }
}

private struct SessionRowView: View {
    let row: SessionRow

    @Environment(RunStore.self) private var runs
    @Environment(SessionStore.self) private var sessions
    @Environment(LaunchController.self) private var launcher
    @Environment(SessionChangesStore.self) private var changesStore
    @Environment(\.openWindow) private var openWindow
    @State private var isHovered = false
    @State private var showsChanges = false

    private var folder: String? { row.session?.cwd ?? row.run?.folder }
    private var changes: SessionChanges? {
        folder.flatMap { changesStore.changes(folder: $0, since: row.startedAt) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private var inBackground: Bool { row.run != nil && row.state == .running }
    private var paused: Bool { row.run?.isPaused == true }
    private var request: ApprovalRequest? { row.state == .waiting ? sessions.approvals[row.id] : nil }
    /// While Claude works, the last tool call says more than the task it was given.
    private var action: String? { row.state == .running ? row.session?.actionText : nil }
    /// Running with no tool call for this long looks stuck.
    static let quietAfter: TimeInterval = 10 * 60
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: paused ? "pause.circle.fill" : inBackground ? "moon.zzz.fill" : row.state.symbol)
                    .foregroundStyle(paused ? Color.orange : row.state.color)
                    .symbolEffect(.pulse, options: .repeating, isActive: row.state == .running && !paused && !reduceMotion)
                    .frame(width: 14)
                    .help(paused ? String(localized: "на паузе до сброса лимита") : inBackground ? String(localized: "в фоне") : row.state.title)
                Text(row.project)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let agent = row.session?.agent, agent != .claudeCode {
                    Image(systemName: ServiceTab(agent: agent).icon)
                        .foregroundStyle(.secondary)
                        .help(agent.title)
                        .accessibilityLabel(agent.title)
                }
                if let worktree = row.worktree {
                    Label(worktree, systemImage: "arrow.triangle.branch")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Отдельная рабочая копия git (worktree)")
                }
                Text(action ?? row.task ?? String(localized: "без задачи"))
                    .scaledFont(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(action == nil && row.task == nil ? .tertiary : .secondary)
                Spacer(minLength: 4)
                if let changes, let folder {
                    Button { showsChanges.toggle() } label: {
                        Text(changes.summary)
                            .scaledFont(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help("Что изменила сессия с начала (git): файлы и строки, включая закоммиченное. Клик — список")
                    .popover(isPresented: $showsChanges, arrowEdge: .bottom) {
                        SessionChangesView(changes: changes, folder: folder)
                    }
                }
                if let context = row.context, context >= ContextUsage.warnAt {
                    Text("контекст \(Int((context * 100).rounded())) %")
                        .scaledFont(.caption)
                        .foregroundStyle(context >= ContextUsage.notifyAt ? .red : .orange)
                        .fixedSize()
                        .help("Насколько заполнен контекст сессии (по журналу Claude Code). Ближе к 100 %, Claude сжимает историю и часть деталей теряется.")
                }
                if isHovered || row.state == .waiting {
                    actions
                } else if let startedAt = row.startedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let quiet = quietMinutes(now: context.date) {
                            Text("тихо \(quiet) мин")
                                .scaledFont(.callout)
                                .foregroundStyle(.orange)
                                .help("Claude давно ничего не делал: возможно, сессия зависла или ждёт чего-то вне AI Hub Bar")
                        } else {
                            Text(DurationText.short(from: startedAt, to: row.endedAt ?? context.date))
                                .scaledFont(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .fixedSize()
                }
            }
            if let request {
                HStack(spacing: 6) {
                    Text(request.text)
                        .scaledFont(.callout, design: .monospaced)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Отклонить") { sessions.decide(requestID: request.id, allow: false) }
                    Button("Разрешить") { sessions.decide(requestID: request.id, allow: true) }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
                .padding(.leading, 20)
            } else if let message = row.message, row.state == .waiting || row.state == .error {
                Text(message)
                    .scaledFont(.callout)
                    .foregroundStyle(row.state == .waiting ? .orange : .red)
                    .lineLimit(2)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 8)
        .densityPadding(4)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(row.state == .waiting ? Color.orange.opacity(0.14) : Color.primary.opacity(isHovered ? 0.06 : 0))
        )
        // The whole row opens the session (or a background run's log), not only the icon on hover.
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        // The buttons appear on hover: this is the way to them without a mouse, and for VoiceOver.
        .contextMenu { menuActions }
        .accessibilityAction(named: Text("Показать"), open)
        .task(id: refreshKey) {
            guard let folder, row.state != .ended else { return }
            await changesStore.refresh(folder: folder, since: row.startedAt)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(helpText)
    }

    /// When the row's changes are read again. Split out of `body`: older compilers (Xcode 26) time out on it.
    private var refreshKey: Date? { row.session?.updatedAt ?? row.run?.finishedAt ?? row.startedAt }

    private var helpText: String {
        var parts: [String] = [inBackground ? String(localized: "в фоне") : row.state.title]
        if action != nil, let task = row.task { parts.append(task) }
        if let folder = row.session?.cwd ?? row.run?.folder { parts.append(folder) }
        if row.session != nil || row.run != nil { parts.append(String(localized: "Клик — открыть")) }
        return parts.joined(separator: " · ")
    }

    /// A session comes to the front (its Terminal tab, the Claude app or the folder); a background run shows its log.
    private func open() {
        // A background run has no window of its own: its log, like the icon on hover.
        if let run = row.run {
            showLog(run)
        } else if let session = row.session {
            SessionActions.show(session)
        }
    }

    private func showLog(_ run: BackgroundRun) {
        runs.selectedLogRunID = run.id
        NSApp.activate()
        openWindow(.runLog)
    }

    private func quietMinutes(now: Date) -> Int? {
        guard row.state == .running, row.run == nil, let session = row.session else { return nil }
        let last = session.lastToolAt ?? session.updatedAt
        let quiet = now.timeIntervalSince(last)
        return quiet > Self.quietAfter ? Int(quiet / 60) : nil
    }

    @ViewBuilder
    private var menuActions: some View {
        if let run = row.run {
            Button("Журнал") { showLog(run) }
            if run.isPaused { Button("Продолжить сейчас") { launcher.resumeNow(run.id) } }
            if run.state == .running { Button("Остановить", role: .destructive) { runs.stop(run.id) } }
        } else if let session = row.session {
            if row.state == .ended, session.agent == .claudeCode {
                Button("Продолжить в Терминале") { SessionActions.resume(session, claudePath: settings.claudePath) }
            } else {
                Button("Показать") { SessionActions.show(session) }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let run = row.run {
                Button { showLog(run) } label: { Label("Журнал", systemImage: "doc.text").labelStyle(.iconOnly) }
                .help("Журнал")
                if run.isPaused {
                    Button { launcher.resumeNow(run.id) } label: { Label("На паузе до сброса лимита. Продолжить сейчас", systemImage: "play.circle").labelStyle(.iconOnly) }
                        .help("На паузе до сброса лимита. Продолжить сейчас")
                }
                if run.state == .running {
                    Button { runs.stop(run.id) } label: { Label("Остановить", systemImage: "stop.circle").labelStyle(.iconOnly) }
                        .foregroundStyle(.red)
                        .help("Остановить")
                }
            } else if let session = row.session {
                Button { SessionActions.show(session) } label: { Label("Показать", systemImage: "macwindow").labelStyle(.iconOnly) }
                    .help("Показать")
            }
        }
        .buttonStyle(.borderless)
        .scaledFont(.callout)
    }
}

/// The files a session changed: click one to open it.
private struct SessionChangesView: View {
    let changes: SessionChanges
    let folder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Изменения сессии").font(.headline)
                Spacer()
                Text(changes.summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(changes.files) { file in
                        Button { open(file) } label: {
                            HStack(spacing: 6) {
                                Text(file.path)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer(minLength: 8)
                                if file.isNew {
                                    Text("новый").foregroundStyle(.green)
                                } else if let added = file.added, let removed = file.removed {
                                    Text("+\(added)").foregroundStyle(.green)
                                    Text("−\(removed)").foregroundStyle(.red)
                                } else {
                                    Text("двоичный").foregroundStyle(.secondary)
                                }
                            }
                            .font(.callout.monospacedDigit())
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Открыть \(file.path)")
                    }
                }
            }
            .frame(maxHeight: 260)
            HStack {
                Button("Показать папку") { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
                Spacer()
                Text(folder).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 380)
    }

    private func open(_ file: SessionChanges.File) {
        let url = URL(fileURLWithPath: folder).appending(path: file.path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }
}

enum DurationText {
    /// «45 с», «12 мин», «2 ч 05 мин», «3 дн».
    static func short(from start: Date, to end: Date) -> String {
        let seconds = Int(max(0, end.timeIntervalSince(start)))
        switch seconds {
        case ..<60: return String(localized: "\(seconds) с")
        case ..<3600: return String(localized: "\(seconds / 60) мин")
        case ..<86_400: return String(format: String(localized: "%d ч %02d мин"), seconds / 3600, seconds % 3600 / 60)
        default: return String(localized: "\(seconds / 86_400) дн")
        }
    }
}

extension Session.State {
    var title: String {
        switch self {
        case .running: String(localized: "работает")
        case .waiting: String(localized: "ждёт ответа")
        case .done: String(localized: "готово")
        case .ended: String(localized: "завершена")
        case .error: String(localized: "ошибка")
        case .unknown: "—"
        }
    }

    var symbol: String {
        switch self {
        case .running: "circle.dotted.circle"
        case .waiting: "hand.raised.fill"
        case .done: "checkmark.circle.fill"
        case .ended: "stop.circle"
        case .error: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .running: .blue
        case .waiting: .orange
        case .done: .green
        case .ended, .unknown: .secondary
        case .error: .red
        }
    }
}
