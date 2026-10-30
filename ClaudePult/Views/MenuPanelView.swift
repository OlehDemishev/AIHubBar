import OSLog
import SwiftUI

/// Content of the menu bar panel: limits, sessions, projects, commands — each can be hidden in Settings.
struct MenuPanelView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ProjectStore.self) private var store
    @Environment(UsageStore.self) private var usage
    @Environment(SystemMonitor.self) private var monitor
    @Environment(KeepAwakeController.self) private var keepAwake
    @AppStorage("collapsedBlocks") private var collapsedRaw = ""
    @Environment(SessionStore.self) private var sessions
    @Environment(HookController.self) private var hooks
    @Environment(RunStore.self) private var runs
    @Environment(AppSettings.self) private var settings
    @Environment(NotificationPermission.self) private var notifications
    @Environment(ModeStore.self) private var modes
    @Environment(FolderProjectStore.self) private var folders
    @Environment(CalendarStore.self) private var calendar
    @Environment(QuickToolsController.self) private var quickTools
    @Environment(CommandStore.self) private var commands

    /// Drives the entrance animation; reset when the panel closes so it replays on every open.
    @State private var isShown = false
    @State private var expanded: Set<String> = []
    @State private var listHeight: CGFloat = 0
    @State private var window: NSWindow?
    @State private var query = ""
    @FocusState private var searchFocused: Bool

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

            PanelSearchField(query: $query, focused: $searchFocused) {
                if let first = searchResults.first { activate(first) }
            }
            .padding(.bottom, 8)
            .revealed(isShown, step: 0, reduceMotion: calm)

            if !query.isEmpty {
                PanelSearchResults(results: searchResults, activate: activate)
                    .panelCard()
                    .padding(.bottom, 8)
            } else {
            VStack(alignment: .leading, spacing: 8) {
                if notifications.state == .denied {
                    notificationsHint
                        .panelCard()
                }

                if modes.modes.isEmpty {
                    noProfile
                        .panelCard()
                        .revealed(isShown, step: 1, reduceMotion: calm)
                }

                // The current profile's modules, in its order (SPEC-profiles §9.2), each on its card.
                ForEach(modes.panelModules, id: \.self) { kind in
                    module(kind)
                }
            }
            .padding(.bottom, 8)
            }
        }
        // Larger text needs a wider panel, otherwise most lines would truncate.
        .frame(width: (settings.panelWidth.points * max(1, scale)).rounded())
        .environment(\.panelTextScale, scale)
        .environment(\.panelDensity, settings.panelDensity.spacing)
        .environment(\.font, ScaledFont.font(.body, scale: scale))
        .preferredColorScheme(settings.panelTheme.colorScheme)
        .background(WindowReader { window = $0; $0?.appearance = settings.panelTheme.appearance })
        .onChange(of: settings.panelTheme) { window?.appearance = settings.panelTheme.appearance }
        .onAppear {
            log.debug("Panel shown")
            isShown = true
            monitor.isPanelOpen = true
            keepAwake.evaluate()
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
            query = ""
            monitor.isPanelOpen = false
        }
        .onChange(of: expanded) { snapshotIfEnabled() }
        .onChange(of: store.lastUpdated) { snapshotIfEnabled() }
    }

    // MARK: Search

    private var searchResults: [PanelSearch.Result] {
        let sessionItems = SessionRow.rows(sessions: sessions.items, runs: runs.runs).map {
            PanelSearch.Item(id: $0.id, name: $0.project, detail: $0.task ?? "")
        }
        let projectItems = folders.isActive
            ? folders.projects.map { PanelSearch.Item(id: $0.path, name: $0.name, detail: "") }
            : store.projects.map { PanelSearch.Item(id: $0.id, name: $0.name, detail: $0.branch ?? "") }
        let quick = modes.installedModules.contains(.quickCommands)
            ? settings.quickCommands.map { PanelSearch.Item(id: $0.id, name: $0.title, detail: "") } : []
        let common = modes.panelModules.contains(.reports) ? CommonCommand.allCases : []
        return PanelSearch.results(query, sessions: sessionItems, projects: projectItems, quickCommands: quick, commands: common)
    }

    private func activate(_ result: PanelSearch.Result) {
        query = ""
        switch result {
        case let .session(id, _, _):
            if let session = sessions.items.first(where: { $0.id == id })?.session { SessionActions.show(session) }
        case let .project(id, _, _):
            expanded.insert(id)
            collapsedRaw = PanelBlock.collapsed(in: collapsedRaw).contains(.projects)
                ? PanelBlock.toggling(.projects, in: collapsedRaw) : collapsedRaw
        case let .quickCommand(id, _):
            if let command = settings.quickCommands.first(where: { $0.id == id }) { quickTools.run(command) }
        case let .command(command):
            commands.run(command)
        }
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
            Text("AI Hub Bar")
                .scaledFont(.headline)
            profileChip
            Spacer(minLength: 4)
            HStack(spacing: 8) { headerButtons }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var headerButtons: some View {
        // One refresh for the whole panel: projects and limits (the limits keep their own schedule and pauses).
        Button {
            Task { await store.refresh() }
            Task { await usage.refresh() }
        } label: {
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .frame(width: 18, height: 18)
        .disabled(store.isRefreshing)
        .help(store.lastUpdated.map { String(localized: "Обновить · обновлено \(RelativeTime.ago($0))") } ?? String(localized: "Обновить"))
        .keyboardShortcut("r", modifiers: .command)
        // Settings, help and quit were three menu-like rows at the bottom; as icons they no longer outweigh the content.
        Button {
            NSApp.activate()
            openSettings()
        } label: { Image(systemName: "gearshape") }
        .help("Настройки… (⌘,)")
        .keyboardShortcut(",", modifiers: .command)
        Button {
            NSApp.activate()
            openWindow(id: "help")
        } label: { Image(systemName: "questionmark.circle") }
        .help("Помощь")
        Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
            .help("Выйти из AI Hub Bar (⌘Q)")
            .keyboardShortcut("q", modifiers: .command)
    }

    /// The current profile; with several enabled it is the switcher (it replaces the row of chips).
    @ViewBuilder
    private var profileChip: some View {
        if let current = modes.current {
            let label = Label(current.name, systemImage: current.icon)
                .scaledFont(.caption)
                .lineLimit(1)
            if modes.enabledModes.count > 1 {
                Menu {
                    ForEach(modes.enabledModes) { mode in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { modes.select(mode.id) }
                        } label: {
                            Label(mode.name, systemImage: mode.id == modes.currentID ? "checkmark" : mode.icon)
                        }
                    }
                } label: {
                    label
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .help("Сменить профиль")
            } else {
                label
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .help("Текущий профиль")
            }
        }
    }

    /// Without permission, «ждёт ответа», background results and limit alerts are silently lost.
    private var notificationsHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.slash.fill")
                .foregroundStyle(.orange)
            Text("Уведомления AI Hub Bar выключены в macOS — «ждёт ответа», итоги задач и лимиты не приходят.")
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

    /// An empty start (SPEC-profiles §2): nothing is set up yet, so the panel only offers to.
    private var noProfile: some View {
        VStack(spacing: 10) {
            EmptyStateView(
                systemImage: "square.stack.3d.up",
                title: String(localized: "Создайте первый профиль"),
                message: String(localized: "Профиль — это то, что будет в панели: лимиты AI, сессии, проекты с командами, календарь. Помощник соберёт его за пару минут.")
            )
            HStack(spacing: 8) {
                Button("Помощник…") {
                    NSApp.activate()
                    openWindow(id: "assistant")
                }
                .buttonStyle(.borderedProminent)
                Button("Импортировать файл…") {
                    SettingsFiles.chooseImport(into: modes)
                    // «Заменить» / «Добавить» are asked in Settings → «Профили».
                    guard modes.pendingImport != nil else { return }
                    UserDefaults.standard.set(SettingsView.Tab.modes.rawValue, forKey: "settingsTab")
                    openSettings()
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func module(_ kind: ModuleKind) -> some View {
        switch kind {
        case .limits:
            LimitsView()
                .panelCard()
                .revealed(isShown, step: 1, reduceMotion: calm)
        case .sessions:
            let sessionRows = SessionRow.rows(sessions: sessions.items, runs: runs.runs)
            if !sessionRows.isEmpty {
                SessionsView(rows: sessionRows)
                    .panelCard()
                    .revealed(isShown, step: 1, reduceMotion: calm)
            } else if hooks.status == .notInstalled {
                hooksHint
                    .panelCard()
                    .revealed(isShown, step: 1, reduceMotion: calm)
            }
        case .upcoming:
            if calendar.isActive {
                UpcomingView()
                    .panelCard()
                    .revealed(isShown, step: 1, reduceMotion: calm)
            }
        case .projects:
            if settings.shows(.projects) {
                VStack(alignment: .leading, spacing: 0) {
                    projectsHeader
                    if !PanelBlock.collapsed(in: collapsedRaw).contains(.projects) {
                        content
                    }
                }
                .padding(.bottom, 6)
                .panelCard()
                .revealed(isShown, step: 1, reduceMotion: calm)
            }
        case .clipboard:
            ClipboardView()
                .panelCard()
                .revealed(isShown, step: 1, reduceMotion: calm)
        case .notes:
            NotesView()
                .panelCard()
                .revealed(isShown, step: 1, reduceMotion: calm)
        case .quickCommands:
            QuickCommandsView()
                .panelCard()
                .revealed(isShown, step: 1, reduceMotion: calm)
        case .toggles:
            QuickTogglesView()
                .panelCard()
                .revealed(isShown, step: 1, reduceMotion: calm)
        case .keepAwake:
            KeepAwakeView()
                .panelCard()
                .revealed(isShown, step: 1, reduceMotion: calm)
        case .resources:
            ResourcesView()
                .panelCard()
                .revealed(isShown, step: 1, reduceMotion: calm)
        case .reports:
            CommandsView()
                .panelCard()
                .revealed(isShown, step: 2, reduceMotion: calm)
        }
    }

    /// Like the other blocks, the projects get a title: how many, and how many need attention.
    private var projectsHeader: some View {
        let count = folders.isActive ? folders.projects.count : store.projects.count
        let red = folders.isActive ? 0 : store.projects.filter { $0.health == .red }.count
        return HStack(spacing: 6) {
            BlockTitle(block: .projects, title: "Проекты")
            if count > 0 {
                Text(verbatim: "\(count)")
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
            }
            if red > 0 {
                Text("с проблемами: \(red)")
                    .scaledFont(.caption, weight: .medium)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
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
                .padding(.horizontal, 10)
                .padding(.top, 8)
        }

        if store.report == nil {
            placeholder
        } else if store.projects.isEmpty {
            EmptyStateView(
                systemImage: "tray",
                title: String(localized: "Проектов нет"),
                message: String(localized: "В папке проектов не найдено git-репозиториев.")
            )
        } else {
            projectList
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let error = store.lastError {
            VStack(spacing: 10) {
                EmptyStateView(systemImage: "exclamationmark.triangle", title: String(localized: "Не удалось загрузить проекты"), message: error)
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
            .padding(4)
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
