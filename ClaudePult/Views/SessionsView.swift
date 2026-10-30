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

/// «Сессии» block at the top of the panel (docs/SPEC.md §2.3).
struct SessionsView: View {
    let rows: [SessionRow]

    private var waiting: Int { rows.filter { $0.state == .waiting }.count }
    @AppStorage("collapsedBlocks") private var collapsedRaw = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                BlockTitle(block: .sessions, title: "Сессии")
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
            }
        }
        .padding(4)
    }
}

private struct SessionRowView: View {
    let row: SessionRow

    @Environment(RunStore.self) private var runs
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    @State private var isHovered = false

    private var inBackground: Bool { row.run != nil && row.state == .running }
    private var request: ApprovalRequest? { row.state == .waiting ? sessions.approvals[row.id] : nil }
    /// While Claude works, the last tool call says more than the task it was given.
    private var action: String? { row.state == .running ? row.session?.actionText : nil }
    /// Running with no tool call for this long looks stuck.
    static let quietAfter: TimeInterval = 10 * 60

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: inBackground ? "moon.zzz.fill" : row.state.symbol)
                    .foregroundStyle(row.state.color)
                    .symbolEffect(.pulse, options: .repeating, isActive: row.state == .running)
                    .frame(width: 14)
                    .help(inBackground ? String(localized: "в фоне") : row.state.title)
                Text(row.project)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .layoutPriority(1)
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
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help([inBackground ? String(localized: "в фоне") : row.state.title, action == nil ? nil : row.task, row.session?.cwd ?? row.run?.folder]
            .compactMap { $0 }.joined(separator: " · "))
    }

    private func quietMinutes(now: Date) -> Int? {
        guard row.state == .running, row.run == nil, let session = row.session else { return nil }
        let last = session.lastToolAt ?? session.updatedAt
        let quiet = now.timeIntervalSince(last)
        return quiet > Self.quietAfter ? Int(quiet / 60) : nil
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let run = row.run {
                Button {
                    runs.selectedLogRunID = run.id
                    NSApp.activate()
                    openWindow(id: "run-log")
                } label: { Image(systemName: "doc.text") }
                .help("Журнал")
                if run.state == .running {
                    Button { runs.stop(run.id) } label: { Image(systemName: "stop.circle") }
                        .foregroundStyle(.red)
                        .help("Остановить")
                }
            } else if let session = row.session {
                Button { SessionActions.show(session) } label: { Image(systemName: "macwindow") }
                    .help("Показать")
            }
        }
        .buttonStyle(.borderless)
        .scaledFont(.callout)
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
