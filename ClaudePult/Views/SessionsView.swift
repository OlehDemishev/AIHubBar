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
                state: run.state.sessionState, message: run.summary, session: nil, run: run
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Сессии")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if waiting > 0 {
                    Text("ждут ответа: \(waiting)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)

            ForEach(rows) { row in
                SessionRowView(row: row)
            }
        }
        .padding(6)
    }
}

private struct SessionRowView: View {
    let row: SessionRow

    @Environment(RunStore.self) private var runs
    @Environment(\.openWindow) private var openWindow
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.run != nil && row.state == .running ? "moon.zzz.fill" : row.state.symbol)
                .foregroundStyle(row.state.color)
                .symbolEffect(.pulse, options: .repeating, isActive: row.state == .running)
                .frame(width: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.project)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let worktree = row.worktree {
                        Label(worktree, systemImage: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    Text(row.run != nil && row.state == .running ? "в фоне" : row.state.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(row.state.color)
                        .fixedSize()
                }
                HStack(spacing: 6) {
                    Text(row.task ?? "без задачи")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(row.task == nil ? .tertiary : .secondary)
                    Spacer(minLength: 6)
                    if let startedAt = row.startedAt {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(DurationText.short(from: startedAt, to: row.endedAt ?? context.date))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                }
                .font(.caption)
                if let message = row.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(row.state == .waiting ? .orange : row.state == .error ? .red : .secondary)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .trailing, spacing: 4) {
                if let run = row.run {
                    Button("Журнал") {
                        runs.selectedLogRunID = run.id
                        NSApp.activate()
                        openWindow(id: "run-log")
                    }
                    if run.state == .running {
                        Button("Остановить") { runs.stop(run.id) }
                            .tint(.red)
                    }
                } else if let session = row.session {
                    Button("Показать") { SessionActions.show(session) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .opacity(isHovered || row.state == .waiting ? 1 : 0.6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(row.state == .waiting ? Color.orange.opacity(0.14) : Color.primary.opacity(isHovered ? 0.06 : 0))
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(row.session?.cwd ?? row.run?.folder ?? "")
    }
}

enum DurationText {
    /// «45 с», «12 мин», «2 ч 05 мин», «3 дн».
    static func short(from start: Date, to end: Date) -> String {
        let seconds = Int(max(0, end.timeIntervalSince(start)))
        switch seconds {
        case ..<60: return "\(seconds) с"
        case ..<3600: return "\(seconds / 60) мин"
        case ..<86_400: return String(format: "%d ч %02d мин", seconds / 3600, seconds % 3600 / 60)
        default: return "\(seconds / 86_400) дн"
        }
    }
}

extension Session.State {
    var title: String {
        switch self {
        case .running: "работает"
        case .waiting: "ждёт ответа"
        case .done: "готово"
        case .ended: "завершена"
        case .error: "ошибка"
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
