import OSLog
import SwiftUI

/// Content of the menu bar panel: limits, sessions, projects, commands — each can be hidden in Settings.
struct MenuPanelView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ProjectStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(HookController.self) private var hooks
    @Environment(RunStore.self) private var runs
    @Environment(AppSettings.self) private var settings
    @Environment(NotificationPermission.self) private var notifications
    @Environment(ModeStore.self) private var modes
    @Environment(FolderProjectStore.self) private var folders
    @Environment(CalendarStore.self) private var calendar

    /// Drives the entrance animation; reset when the panel closes so it replays on every open.
    @State private var isShown = false
    @State private var expanded: Set<String> = []
    @State private var listHeight: CGFloat = 0
    @State private var window: NSWindow?

    /// The project list scrolls; its height leaves room for the other blocks on the current screen.
    private static var maxListHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 1000
        return min(420, max(180, visible - 700))
    }

    private let log = Logger(subsystem: "com.demishev.claudepult", category: "panel")

    /// Reduce Motion or animations switched off in Settings.
    private var calm: Bool { reduceMotion || !settings.panelAnimations }

    var body: some View {
        let scale = settings.panelTextSize.scale
        VStack(alignment: .leading, spacing: 0) {
            header
                .revealed(isShown, step: 0, reduceMotion: calm)

            if modes.enabledModes.count > 1 {
                ModeSwitcher()
                    .revealed(isShown, step: 0, reduceMotion: calm)
            }

            Divider()

            if notifications.state == .denied {
                notificationsHint
                Divider()
            }

            if settings.shows(.limits) {
                LimitsView()
                    .revealed(isShown, step: 1, reduceMotion: calm)
                Divider()
            }

            if settings.shows(.sessions) {
                let sessionRows = SessionRow.rows(sessions: sessions.items, runs: runs.runs)
                if !sessionRows.isEmpty {
                    SessionsView(rows: sessionRows)
                        .revealed(isShown, step: 1, reduceMotion: calm)
                    Divider()
                } else if hooks.status == .notInstalled {
                    hooksHint
                        .revealed(isShown, step: 1, reduceMotion: calm)
                    Divider()
                }
            }

            if settings.shows(.calendar), calendar.isActive {
                UpcomingView()
                    .revealed(isShown, step: 1, reduceMotion: calm)
                Divider()
            }

            if settings.shows(.projects) {
                content
                    .revealed(isShown, step: 1, reduceMotion: calm)
                Divider()
            }

            if settings.shows(.commands) {
                CommandsView()
                    .revealed(isShown, step: 2, reduceMotion: calm)
                Divider()
            }

            VStack(spacing: 2) {
                PanelButton(title: "Настройки…", shortcut: ",") {
                    NSApp.activate()
                    openSettings()
                }
                PanelButton(title: "Помощь", shortcut: nil) {
                    NSApp.activate()
                    openWindow(id: "help")
                }
                PanelButton(title: "Выход", shortcut: "q") {
                    NSApp.terminate(nil)
                }
            }
            .padding(6)
            .revealed(isShown, step: 3, reduceMotion: calm)
        }
        // Larger text needs a wider panel, otherwise most lines would truncate.
        .frame(width: (settings.panelWidth.points * max(1, scale)).rounded())
        .environment(\.panelTextScale, scale)
        .environment(\.panelDensity, settings.panelDensity.spacing)
        .environment(\.font, ScaledFont.font(.body, scale: scale))
        .preferredColorScheme(settings.panelTheme.colorScheme)
        .background(WindowReader { window = $0 })
        .onAppear {
            log.debug("Panel shown")
            isShown = true
            store.refreshIfStale()
            folders.refreshIfStale()
            calendar.refreshIfStale()
            sessions.reload()
            hooks.refresh()
            notifications.refresh()
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
                .scaledFont(.title3)
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, options: .nonRepeating, value: calm ? false : isShown)
            Text("ClaudePult")
                .scaledFont(.headline)
            Spacer()
            if let lastUpdated = store.lastUpdated {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("обновлено \(RelativeTime.ago(lastUpdated, now: context.date))")
                        .scaledFont(.caption)
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

    /// Without permission, «ждёт ответа», background results and limit alerts are silently lost.
    private var notificationsHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.slash.fill")
                .foregroundStyle(.orange)
            Text("Уведомления ClaudePult выключены в macOS — «ждёт ответа», итоги задач и лимиты не приходят.")
                .scaledFont(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Включить…") { NotificationPermission.openSystemSettings() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var hooksHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .foregroundStyle(.secondary)
            Text("Сессии Claude не отслеживаются: hooks не установлены.")
                .scaledFont(.caption)
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
        if folders.isActive {
            scrolling { FolderProjectsView() }
        } else {
            gitContent
        }
    }

    @ViewBuilder
    private var gitContent: some View {
        if let error = store.lastError, store.report != nil {
            Label(error, systemImage: "exclamationmark.triangle")
                .scaledFont(.caption)
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
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
    }

    private var projectList: some View {
        scrolling {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.projects) { project in
                    ProjectRowView(project: project, isExpanded: expandedBinding(project.id))
                }
            }
            .padding(6)
        }
    }

    /// The project list scrolls once it is taller than `maxListHeight`.
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
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
                .scaledFont(size: 28, weight: .light)
                .foregroundStyle(.tertiary)
            Text(title)
                .scaledFont(.headline)
            Text(message)
                .scaledFont(.callout)
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
    let shortcut: Character?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text("⌘\(String(shortcut).uppercased())")
                        .foregroundStyle(.secondary)
                }
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
        .keyboardShortcut(shortcut.map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) })
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// Switcher between enabled modes at the top of the panel (SPEC-modes §2). Limits and sessions stay shared.
private struct ModeSwitcher: View {
    @Environment(ModeStore.self) private var modes

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(modes.enabledModes) { mode in
                    let selected = mode.id == modes.currentID
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { modes.select(mode.id) }
                    } label: {
                        Label(mode.name, systemImage: mode.icon)
                            .scaledFont(.caption, weight: selected ? .semibold : .regular)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06)))
                            .foregroundStyle(selected ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                    .help(selected ? "Текущий режим" : "Переключиться на «\(mode.name)»")
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }
}
