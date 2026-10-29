import SwiftUI

/// «Сессии» block at the top of the panel (docs/SPEC.md §2.3).
struct SessionsView: View {
    @Environment(SessionStore.self) private var sessions

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Сессии")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if sessions.waitingCount > 0 {
                    Text("ждут ответа: \(sessions.waitingCount)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)

            ForEach(sessions.items) { item in
                SessionRowView(item: item)
            }
        }
        .padding(6)
    }
}

private struct SessionRowView: View {
    let item: SessionStore.Item

    @State private var isHovered = false

    private var session: Session { item.session }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.state.symbol)
                .foregroundStyle(item.state.color)
                .symbolEffect(.pulse, options: .repeating, isActive: item.state == .running)
                .frame(width: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayProject)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let worktree = session.worktreeName {
                        Label(worktree, systemImage: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    Text(item.state.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(item.state.color)
                        .fixedSize()
                }
                HStack(spacing: 6) {
                    Text(session.task ?? "без задачи")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(session.task == nil ? .tertiary : .secondary)
                    Spacer(minLength: 6)
                    if let startedAt = session.startedAt {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(DurationText.short(from: startedAt, to: item.state == .ended ? session.updatedAt : context.date))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                }
                .font(.caption)
                if item.state == .waiting, let message = session.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }

            Button("Показать") { SessionActions.show(session) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .opacity(isHovered || item.state == .waiting ? 1 : 0.6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(item.state == .waiting ? Color.orange.opacity(0.14) : Color.primary.opacity(isHovered ? 0.06 : 0))
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(session.cwd)
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
