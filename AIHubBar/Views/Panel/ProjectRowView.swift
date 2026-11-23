import SwiftUI

/// One project in the panel: a compact summary row that expands into STATUS, attention items and actions.
struct ProjectRowView: View {
    @Environment(\.panelCalm) private var panelCalm
    let project: Project
    @Binding var isExpanded: Bool

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(panelCalm ? nil : .snappy(duration: 0.25)) { isExpanded.toggle() }
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
        HStack(spacing: 6) {
            HealthDot(health: project.health)
            Text(project.name)
                .fontWeight(.medium)
                .lineLimit(1)
                .layoutPriority(1)
            if let branch = project.branch, !["main", "master"].contains(branch) {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            badges
            if let lastActivity = project.lastActivity {
                Text(RelativeTime.ago(lastActivity))
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .densityPadding(4)
        .contentShape(Rectangle())
        .help(isExpanded ? String(localized: "Свернуть") : String(localized: "Подробнее и действия"))
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
    /// What listens on a port from this project's folder, read while the row is open.
    @State private var servers: [LocalServer] = []

    private func readServers() async {
        // The demo copy lists made-up servers: nothing of the Mac it runs on is shown, and «stop» finds nothing to stop.
        guard !DemoMode.isActive else {
            servers = DemoData.servers(in: project.path)
            return
        }
        let all = await LocalServers.scan()
        servers = LocalServers.servers(all, in: project.path)
    }

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
                BulletSection(title: String(localized: "Нужно от вас"), items: summary.needs, tint: .orange)
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

            if !servers.isEmpty {
                LocalServersView(servers: servers) { await readServers() }
            }
        }
        .task(id: project.path) {
            // Only while the row is open: the task ends with the view.
            while !Task.isCancelled {
                await readServers()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

/// «Локальные серверы»: a port, the program, a link and a stop button with a second press to confirm.
private struct LocalServersView: View {
    let servers: [LocalServer]
    let reload: () async -> Void
    /// The server whose stop button was pressed once: the second press within a few seconds stops it.
    @State private var confirming: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Локальные серверы")
                .scaledFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
            ForEach(servers) { server in
                serverRow(server)
            }
        }
    }

    private func serverRow(_ server: LocalServer) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "network").foregroundStyle(.secondary)
            Text(verbatim: ":\(server.port)").monospacedDigit()
            Text(verbatim: server.command).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                // On the name, not on the row: a row's hint would replace the buttons' own.
                .help(server.folder)
            Spacer(minLength: 4)
            if confirming == server.id {
                Button("Остановить?") { stop(server) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            } else {
                if let url = server.url {
                    Button {
                        ProjectActions.open(url)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.borderless)
                    .help("Открыть в браузере")
                    .accessibilityLabel("Открыть в браузере")
                }
                Button {
                    ask(server)
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help("Остановить процесс")
                .accessibilityLabel("Остановить процесс")
            }
        }
        .scaledFont(.caption)
    }

    private func ask(_ server: LocalServer) {
        confirming = server.id
        Task {
            try? await Task.sleep(for: .seconds(4))
            if confirming == server.id { confirming = nil }
        }
    }

    private func stop(_ server: LocalServer) {
        confirming = nil
        Task {
            await LocalServers.stop(server)
            try? await Task.sleep(for: .seconds(1))
            await reload()
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
                    Text("черновик").foregroundStyle(.secondary)
                }
            }
            .scaledFont(.caption)
        }
        .buttonStyle(.plain)
        .disabled(pr.url == nil)
        .help(pr.title + " · CI: " + pr.ci.title)
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
            .accessibilityLabel(health.title)
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
