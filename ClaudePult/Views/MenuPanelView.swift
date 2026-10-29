import OSLog
import SwiftUI

/// Content of the menu bar panel. Sessions and commands are added in later stages.
struct MenuPanelView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ProjectStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(HookController.self) private var hooks

    /// Drives the entrance animation; reset when the panel closes so it replays on every open.
    @State private var isShown = false
    @State private var expanded: Set<String> = []
    @State private var listHeight: CGFloat = 0
    @State private var window: NSWindow?

    private static let maxListHeight: CGFloat = 560

    private let log = Logger(subsystem: "com.demishev.claudepult", category: "panel")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .revealed(isShown, step: 0, reduceMotion: reduceMotion)

            Divider()

            if !sessions.items.isEmpty {
                SessionsView()
                    .revealed(isShown, step: 1, reduceMotion: reduceMotion)
                Divider()
            } else if hooks.status == .notInstalled {
                hooksHint
                    .revealed(isShown, step: 1, reduceMotion: reduceMotion)
                Divider()
            }

            content
                .revealed(isShown, step: 1, reduceMotion: reduceMotion)

            Divider()

            VStack(spacing: 2) {
                PanelButton(title: "Настройки…", shortcut: ",") {
                    NSApp.activate()
                    openSettings()
                }
                PanelButton(title: "Выход", shortcut: "q") {
                    NSApp.terminate(nil)
                }
            }
            .padding(6)
            .revealed(isShown, step: 2, reduceMotion: reduceMotion)
        }
        .frame(width: 420)
        .background(WindowReader { window = $0 })
        .onAppear {
            log.debug("Panel shown")
            isShown = true
            store.refreshIfStale()
            sessions.reload()
            hooks.refresh()
            snapshotIfEnabled()
        }
        .onDisappear {
            isShown = false
        }
        .onChange(of: expanded) { snapshotIfEnabled() }
        .onChange(of: store.lastUpdated) { snapshotIfEnabled() }
    }

    private func snapshotIfEnabled() {
        guard DebugSnapshot.isEnabled else { return }
        if let name = DebugSnapshot.projectToExpand, let project = store.projects.first(where: { $0.name == name }) {
            expanded.insert(project.id)
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            DebugSnapshot.capture(window)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.title3)
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : isShown)
            Text("ClaudePult")
                .font(.headline)
            Spacer()
            if let lastUpdated = store.lastUpdated {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("обновлено \(RelativeTime.ago(lastUpdated, now: context.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .frame(width: 18, height: 18)
            .disabled(store.isRefreshing)
            .help("Обновить")
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var hooksHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .foregroundStyle(.secondary)
            Text("Сессии Claude не отслеживаются: hooks не установлены.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("Настройки…") {
                NSApp.activate()
                openSettings()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.lastError, store.report != nil {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.top, 8)
        }

        if store.report == nil {
            placeholder
        } else if store.projects.isEmpty {
            EmptyStateView(
                systemImage: "tray",
                title: "Проектов нет",
                message: "В папке проектов не найдено git-репозиториев."
            )
        } else {
            projectList
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let error = store.lastError {
            VStack(spacing: 10) {
                EmptyStateView(systemImage: "exclamationmark.triangle", title: "Не удалось загрузить проекты", message: error)
                Button("Повторить") { Task { await store.refresh() } }
                    .disabled(store.isRefreshing)
            }
            .padding(.bottom, 16)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Загружаю проекты…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
    }

    private var projectList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.projects) { project in
                    ProjectRowView(project: project, isExpanded: expandedBinding(project.id))
                }
            }
            .padding(6)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(listHeight, 1), Self.maxListHeight))
        .onPreferenceChange(ContentHeightKey.self) { [$listHeight] height in
            $listHeight.wrappedValue = height
        }
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOn in
                if isOn { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

private extension View {
    /// Staggered entrance: fades in and settles down from just under the menu bar.
    /// With Reduce Motion on, only the fade remains.
    func revealed(_ isShown: Bool, step: Int, reduceMotion: Bool) -> some View {
        self
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : -6)
            .animation(
                isShown
                    ? .spring(duration: 0.35, bounce: 0.15).delay(Double(step) * 0.05)
                    : nil,
                value: isShown
            )
    }
}

/// Full-width menu-like button with a ⌘-shortcut hint.
private struct PanelButton: View {
    let title: String
    let shortcut: Character
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text("⌘\(String(shortcut).uppercased())")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.primary.opacity(0.1) : .clear)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}
