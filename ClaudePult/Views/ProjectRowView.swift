import SwiftUI

/// One project in the panel: a compact summary row that expands into STATUS, attention items and actions.
struct ProjectRowView: View {
    let project: Project
    @Binding var isExpanded: Bool

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                summary
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded {
                ProjectDetailsView(project: project)
                    .padding(.leading, 30)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(isExpanded ? 0.05 : isHovered ? 0.08 : 0))
        )
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "chevron.right")
                .scaledFont(.caption2, weight: .semibold)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    HealthDot(health: project.health)
                    Text(project.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    badges
                }
                HStack(spacing: 6) {
                    if let branch = project.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    if let lastActivity = project.lastActivity {
                        Text(RelativeTime.ago(lastActivity))
                            .fixedSize()
                    }
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 10)
        .densityPadding(6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var badges: some View {
        if project.dirty > 0 {
            // Words, not a bare number: «22» next to a pencil says little at a glance.
            Badge(systemImage: "pencil", text: "\(project.dirty) \(Plural.files(project.dirty))", color: .orange)
                .help("Незакоммиченных файлов: \(project.dirty)")
        }
        if let prs = project.openPRs, !prs.isEmpty {
            Badge(systemImage: "arrow.triangle.pull", text: "\(prs.count) PR", color: project.pullRequestsCI.color)
                .help("Открытых PR: \(prs.count), CI: \(project.pullRequestsCI.title)")
        }
    }
}

private struct ProjectDetailsView: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Actions first: a long STATUS would otherwise push them below the fold.
            ClaudeActionsView(project: project)

            HStack(spacing: 6) {
                ActionButton(title: String(localized: "Терминал"), systemImage: "terminal") {
                    ProjectActions.openInTerminal(project.path)
                }
                ActionButton(title: "Finder", systemImage: "folder") {
                    ProjectActions.openInFinder(project.path)
                }
                if let github = GitRemote.webURL(project.remote) {
                    ActionButton(title: "GitHub", systemImage: "safari") {
                        ProjectActions.open(github)
                    }
                }
            }

            Divider()

            if let summary = project.status?.summary {
                if let stage = summary.stage, !stage.isEmpty {
                    Text(Markdown.inline(stage))
                        .scaledFont(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                BulletSection(title: String(localized: "Сейчас"), items: summary.now)
                BulletSection(title: String(localized: "Дальше"), items: summary.next)
                BulletSection(title: String(localized: "Нужно от Олега"), items: summary.needs, tint: .orange)
            } else {
                Text(project.status == nil ? String(localized: "Нет docs/STATUS.md") : String(localized: "В STATUS.md нет шапки"))
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
            }

            let attention = project.attentionNotInStatus
            if !attention.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(attention, id: \.self) { item in
                        Label {
                            Text(Markdown.inline(item.text)).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: item.level.symbol).foregroundStyle(item.level.color)
                        }
                        .scaledFont(.caption)
                    }
                }
            }

            if let prs = project.openPRs, !prs.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(prs) { pr in
                        PullRequestRow(pr: pr)
                    }
                }
            }

            if !project.worktrees.isEmpty {
                WorktreeListView(project: project)
            }
        }
    }
}

private struct BulletSection: View {
    let title: String
    let items: [String]
    var tint: Color = .secondary

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(.caption, weight: .semibold)
                    .foregroundStyle(tint)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(Markdown.inline(item))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .scaledFont(.caption)
                }
            }
        }
    }

}

private struct PullRequestRow: View {
    let pr: PullRequest

    var body: some View {
        Button {
            if let url = pr.url { ProjectActions.open(url) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(pr.ci.color)
                Text("#\(pr.number)").foregroundStyle(.secondary)
                Text(pr.title).lineLimit(1)
                if pr.isDraft {
                    Text("черновик").foregroundStyle(.tertiary)
                }
            }
            .scaledFont(.caption)
        }
        .buttonStyle(.plain)
        .disabled(pr.url == nil)
        .help("CI: \(pr.ci.title)")
    }
}

struct ActionButton: View {
    let title: String
    let systemImage: String
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .scaledFont(.caption)
        }
        .buttonStyle(.bordered)
        .tint(isProminent ? .orange : nil)
        .controlSize(.small)
    }
}

/// STATUS items and attention texts use inline Markdown (`code`, **bold**, links).
private enum Markdown {
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct HealthDot: View {
    let health: Health

    var body: some View {
        Circle()
            .fill(health.color)
            .frame(width: 8, height: 8)
            .help(health.title)
    }
}

private struct Badge: View {
    let systemImage: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
            Text(text).monospacedDigit()
        }
        .scaledFont(.caption2, weight: .medium)
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

extension Health {
    var color: Color {
        switch self {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .unknown: .gray
        }
    }

    var title: String {
        switch self {
        case .red: String(localized: "Требует внимания")
        case .yellow: String(localized: "Есть что проверить")
        case .green: String(localized: "Всё в порядке")
        case .unknown: String(localized: "Состояние неизвестно")
        }
    }
}

extension CIState {
    var color: Color {
        switch self {
        case .ok: .green
        case .fail: .red
        case .pending: .orange
        case .none, .unknown: .secondary
        }
    }

    var title: String {
        switch self {
        case .ok: String(localized: "пройдено")
        case .fail: String(localized: "упало")
        case .pending: String(localized: "идёт")
        case .none: String(localized: "нет проверок")
        case .unknown: String(localized: "неизвестно")
        }
    }
}

extension Attention.Level {
    var symbol: String {
        switch self {
        case .high: "exclamationmark.triangle.fill"
        case .mid: "exclamationmark.circle"
        case .low, .unknown: "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .high: .red
        case .mid: .orange
        case .low, .unknown: .secondary
        }
    }
}
