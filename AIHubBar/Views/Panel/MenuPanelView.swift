import OSLog
import SwiftUI

/// Content of the menu bar panel: limits, sessions, projects, commands — each can be hidden in Settings.
struct MenuPanelView: View {
    @Environment(\.openSettingsPage) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(ProjectStore.self) private var store
    @Environment(UsageStore.self) private var usage
    @Environment(SystemMonitor.self) private var monitor
    @Environment(KeepAwakeController.self) private var keepAwake
    @AppStorage(StorageKey.collapsedBlocks) private var collapsedRaw = ""
    @Environment(SessionStore.self) private var sessions
    @Environment(HookController.self) private var hooks
    @Environment(RunStore.self) private var runs
    @Environment(AppSettings.self) private var settings
    @Environment(NotificationPermission.self) private var notifications
    @Environment(ProfileStore.self) private var modes
    @Environment(FolderProjectStore.self) private var folders
    @Environment(CalendarStore.self) private var calendar
    @Environment(QuickToolsController.self) private var quickTools
    @Environment(CommandStore.self) private var commands
    @Environment(AIServiceStore.self) private var services
    @Environment(LaunchController.self) private var launcher
    @Environment(LayoutSwitcher.self) private var layoutSwitcher

    /// Drives the entrance animation; reset when the panel closes so it replays on every open.
    @State private var isShown = false
    @State private var expanded: Set<String> = []
    @State private var window: NSWindow?
    /// The panel draws its own glass instead of the system background.
    @State private var drawsGlass = false
    @State private var query = ""
    @State private var searchSelection = 0
    /// A project picked in the search: scrolled to when the blocks are back.
    @State private var scrollTarget: String?
    @State private var folderExpanded: Set<String> = []
    /// Recent Codex and Copilot conversations for «Сессии», read when the panel opens.
    @State private var agentThreads: [AgentThread] = []
    /// The Claude account's name and plan for the header, read when the panel opens.
    @State private var identity: ClaudeIdentity?
    /// The blocks besides limits, sessions and projects wait under one «Ещё» row until it is opened; the choice is kept.
    @AppStorage(StorageKey.panelMoreExpanded) private var moreExpanded = false
    @AppStorage(StorageKey.whatsNewSeen) private var whatsNewSeen = ""
    @FocusState private var searchFocused: Bool

    /// Header, search and a margin under the panel, at the normal text size.
    private static let pinnedHeight: CGFloat = 76
    /// Most of the 8 pt above the first card (the search keeps 2), where scrolled cards fade out.
    private static let scrollFade: CGFloat = 6
    /// Under the header and the search on glass: the cards' own colour (white in light, dark grey in dark).
    private static let headerTint = Color(nsColor: .controlBackgroundColor).opacity(0.55)

    /// The blocks scroll once the panel would pass the bottom of its screen; header and search stay.
    private var blocksMaxHeight: CGFloat {
        let visible = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        return max(240, visible - Self.pinnedHeight * max(1, settings.panelTextSize.scale))
    }

    private let log = Logger(subsystem: "com.demishev.claudepult", category: "panel")

    /// Reduce Motion or animations switched off in Settings.
    private var calm: Bool { reduceMotion || !settings.panelAnimations }

    /// «Стекло» chosen, macOS 26+ and «Уменьшить прозрачность» off; otherwise the system background.
    private var wantsGlass: Bool {
        settings.panelBackground == .glass && PanelGlass.isAvailable(reduceTransparency: reduceTransparency)
    }

    var body: some View {
        let scale = settings.panelTextSize.scale
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .revealed(isShown, step: 0, reduceMotion: calm)

                PanelSearchField(query: $query, focused: $searchFocused, onCancel: { PanelOpener.close() }, onMove: moveSelection) {
                    let results = searchResults
                    if results.indices.contains(searchSelection) { activate(results[searchSelection]) }
                }
                .onChange(of: query) { searchSelection = 0 }
                .padding(.bottom, query.isEmpty ? 2 : 8)
                .revealed(isShown, step: 0, reduceMotion: calm)
            }
            // Clear glass under dark text or light text over the opposite window can't be read: the cards' tint here too.
            // The colour of the cards rather than the window's grey, fading out at the bottom: no slab with an edge.
            .background {
                if drawsGlass {
                    UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous)
                        .fill(LinearGradient(stops: [
                            .init(color: Self.headerTint, location: 0),
                            .init(color: Self.headerTint, location: 0.6),
                            .init(color: Self.headerTint.opacity(0), location: 1),
                        ], startPoint: .top, endPoint: .bottom))
                }
            }

            if !query.isEmpty {
                PanelSearchResults(results: searchResults, selected: searchSelection, activate: activate)
                    .panelCard()
                    .panelGlassGroup()
                    .padding(.bottom, 8)
            } else {
                // Hugs its content up to `blocksMaxHeight`; a window of its own size can't scroll otherwise.
                ScrollViewReader { reader in
                    // The glass group goes inside: around the scroll view its glass is drawn past the clip, over the header.
                    ScrollView {
                        blocks
                            .panelGlassGroup()
                            .padding(.top, Self.scrollFade)
                    }
                    // With the search's 2 pt, the same 8 pt above the first card as between cards; scrolled cards fade out
                    // there instead of being cut at a hard line.
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: Self.scrollFade)
                            Color.black
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: blocksMaxHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .onAppear {
                        guard let target = scrollTarget else { return }
                        scrollTarget = nil
                        DispatchQueue.main.async { withAnimation(calm ? nil : .default) { reader.scrollTo(target, anchor: .top) } }
                    }
                }
            }
        }
        // Larger text needs a wider panel, otherwise most lines would truncate.
        .frame(width: (settings.panelWidth.points * max(1, scale)).rounded())
        .environment(\.panelTextScale, scale)
        .environment(\.panelDensity, settings.panelDensity.spacing)
        .environment(\.font, ScaledFont.font(.body, scale: scale))
        .environment(\.panelGlass, drawsGlass)
        .environment(\.panelIsShown, isShown)
        .environment(\.panelCalm, calm)
        .preferredColorScheme(settings.panelTheme.colorScheme)
        .background(WindowReader { found in
            // Called on every update: state and appearance change only when they differ (each write is another
            // render pass). The glass is reapplied every time on purpose — SwiftUI can bring its backdrop back, and
            // `PanelGlass.apply` only hides what is new (SPEC-refactor §5).
            if window !== found { window = found }
            if let found, found.appearance != settings.panelTheme.appearance { found.appearance = settings.panelTheme.appearance }
            updateGlass()
        })
        .onChange(of: wantsGlass) { updateGlass() }
        .onChange(of: settings.panelTheme) { window?.appearance = settings.panelTheme.appearance }
        .onAppear {
            log.debug("Panel shown")
            isShown = true
            monitor.isPanelOpen = true
            StatusItemTooltip.panelIsOpen = true
            keepAwake.evaluate()
            store.refreshIfStale()
            folders.refreshIfStale()
            calendar.refreshIfStale()
            sessions.reload()
            hooks.refresh()
            notifications.refresh()
            snapshotIfEnabled()
            // Typing right after the click finds things; ↑ ↓ ↵ work from here.
            searchFocused = true
            Task { agentThreads = await Task.detached(priority: .utility) { AgentThread.recent() }.value }
            Task { identity = await Task.detached(priority: .utility) { ClaudeIdentity.read() }.value }
            // Whoever had the panel before the «Ещё» row keeps every block in sight.
            if UserDefaults.standard.object(forKey: StorageKey.panelMoreExpanded) == nil { moreExpanded = !modes.modes.isEmpty }
        }
        .onDisappear {
            isShown = false
            query = ""
            monitor.isPanelOpen = false
            StatusItemTooltip.panelIsOpen = false
        }
        .onChange(of: expanded) { snapshotIfEnabled() }
        .onChange(of: store.lastUpdated) { snapshotIfEnabled() }
    }

    private var blocks: some View {
        VStack(alignment: .leading, spacing: 8) {
            if notifications.state == .denied {
                notificationsHint
                    .panelCard()
            }

            if WhatsNew.shouldShow(seen: whatsNewSeen, hasProfiles: !modes.modes.isEmpty) {
                WhatsNewView()
                    .panelCard()
                    .revealed(isShown, step: 1, reduceMotion: calm)
            }

            if modes.modes.isEmpty {
                noProfile
                    .panelCard()
                    .revealed(isShown, step: 1, reduceMotion: calm)
            }

            // The current profile's modules, in its order (SPEC-profiles §9.2), each on its card.
            let folded = PanelFold.split(modes.panelModules)
            ForEach(moreExpanded ? modes.panelModules : folded.main, id: \.self) { kind in
                module(kind)
            }
            if !folded.more.isEmpty {
                moreRow(folded.more)
                    .panelCard()
                    .revealed(isShown, step: 2, reduceMotion: calm)
            }

            // macOS is asked once by itself (`LayoutSwitcher`); after that this quiet line is all that says so.
            if modes.isOn(.layout), !layoutSwitcher.trusted {
                HStack(spacing: 8) {
                    Text("Нужно разрешение «Универсальный доступ»")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Дать доступ к клавиатуре…") { layoutSwitcher.requestAccess() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .panelCard()
            }

            if !modes.modes.isEmpty, modes.panelModules.isEmpty {
                HStack(spacing: 8) {
                    Text("Панель пуста")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Настройки…") { openSettings(.show) }
                        .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .panelCard()
            }
        }
        .padding(.bottom, 8)
    }

    private func updateGlass() {
        let glass = PanelGlass.apply(wantsGlass, to: window)
        if glass != drawsGlass { drawsGlass = glass }
    }

    // MARK: Search

    private var searchResults: [PanelSearch.Result] {
        let sessionItems = SessionRow.rows(sessions: sessions.items, runs: runs.runs).map {
            PanelSearch.Item(id: $0.id, name: $0.project, detail: $0.task ?? "")
        }
        // A project found must have a place to open in.
        let projectItems = !modes.panelModules.contains(.projects) ? [] : folders.isActive
            ? folders.projects.map { PanelSearch.Item(id: $0.path, name: $0.name, detail: "") }
            : store.projects.map { PanelSearch.Item(id: $0.id, name: $0.name, detail: $0.branch ?? "") }
        let quick = modes.isOn(.quickCommands)
            ? settings.quickCommands.map { PanelSearch.Item(id: $0.id, name: $0.title, detail: "") } : []
        let common = modes.panelModules.contains(.reports) ? CommonCommand.allCases : []
        return PanelSearch.results(query, sessions: sessionItems, projects: projectItems, quickCommands: quick, commands: common)
    }

    private func moveSelection(_ step: Int) {
        let count = searchResults.count
        guard count > 0 else { return }
        searchSelection = min(max(searchSelection + step, 0), count - 1)
    }

    private func activate(_ result: PanelSearch.Result) {
        query = ""
        switch result {
        case let .session(id, _, _):
            // Like a click on the row: a background run shows its log.
            if runs.runs.contains(where: { $0.id == id }) {
                runs.selectedLogRunID = id
                NSApp.activate()
                openWindow(.runLog)
            } else if let session = sessions.items.first(where: { $0.id == id })?.session {
                SessionActions.show(session)
            }
        case let .project(id, _, _):
            if folders.isActive { folderExpanded.insert(id) } else { expanded.insert(id) }
            moreExpanded = true
            scrollTarget = id
            collapsedRaw = PanelBlock.collapsed(in: collapsedRaw).contains(.projects)
                ? PanelBlock.toggling(.projects, in: collapsedRaw) : collapsedRaw
        case let .quickCommand(id, _):
            if let command = settings.quickCommands.first(where: { $0.id == id }) { quickTools.run(command) }
        case let .command(command):
            commands.run(command)
        case .prompt:
            // Prompts are offered in the ⌃⌥C search window, where a project is picked next.
            break
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
            Text(verbatim: accountName ?? "AI Hub Bar")
                .scaledFont(.headline)
                .lineLimit(1)
                .help(accountName == nil ? "" : String(localized: "Аккаунт Claude Code"))
            if let plan = accountPlan {
                Text(verbatim: plan)
                    .scaledFont(.caption, weight: .medium)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
                    .help(String(localized: "Тариф Claude"))
            }
            profileChip
            Spacer(minLength: 4)
            HStack(spacing: 8) { headerButtons }
                .buttonStyle(.borderless)
                // Grey disappears on clear glass over a bright window.
                .foregroundStyle(drawsGlass ? AnyShapeStyle(Color.primary.opacity(0.75)) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The account and its plan stand in the header while the limits are shown: they say whose limits these are.
    private var accountName: String? { modes.panelModules.contains(.limits) ? identity?.name : nil }
    private var accountPlan: String? { modes.panelModules.contains(.limits) ? identity?.plan : nil }

    /// One quiet row for the blocks that are not about AI: their names, and a click opens or folds them.
    private func moreRow(_ kinds: [ModuleKind]) -> some View {
        Button {
            withAnimation(calm ? nil : .snappy(duration: 0.2)) { moreExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(moreExpanded ? String(localized: "Свернуть") : String(localized: "Ещё"))
                    .scaledFont(.caption, weight: .semibold)
                if !moreExpanded {
                    Text(verbatim: kinds.map(\.title).joined(separator: " · "))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: moreExpanded ? "chevron.up" : "chevron.down")
                    .scaledFont(.caption2, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(moreExpanded ? String(localized: "Свернуть") : String(localized: "Показать остальные блоки"))
        .accessibilityLabel(moreExpanded ? String(localized: "Свернуть") : String(localized: "Ещё") + ": " + kinds.map(\.title).joined(separator: ", "))
    }

    @ViewBuilder
    private var headerButtons: some View {
        // One refresh for the whole panel: projects and limits (the limits keep their own schedule and pauses).
        Button {
            Task { await store.refresh() }
            Task { await usage.refresh() }
            if folders.isActive { Task { await folders.refresh() } }
            if calendar.isActive { Task { await calendar.refresh() } }
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
        .accessibilityLabel("Обновить")
        .keyboardShortcut("r", modifiers: .command)
        // «Скрыть остров» for a screen recording or a demo (SPEC-notch §5), while the island is installed.
        if modes.isOn(.notch) {
            Button { settings.notch.hidden.toggle() } label: {
                Image(systemName: settings.notch.hidden ? "laptopcomputer.slash" : "laptopcomputer")
            }
            .help(settings.notch.hidden ? String(localized: "Показать остров у чёлки") : String(localized: "Скрыть остров у чёлки"))
            .accessibilityLabel(settings.notch.hidden ? String(localized: "Показать остров у чёлки") : String(localized: "Скрыть остров у чёлки"))
        }
        // Settings, help and quit were three menu-like rows at the bottom; as icons they no longer outweigh the content.
        Button { openSettings() } label: { Label("Настройки… (⌘,)", systemImage: "gearshape").labelStyle(.iconOnly) }
        .help("Настройки… (⌘,)")
        .keyboardShortcut(",", modifiers: .command)
        // What is rarely needed waits in a menu, quit included: one click beside help was too easy.
        Menu {
            Button("Claude Code: все CLAUDE.md и MCP-серверы", systemImage: "doc.badge.gearshape") {
                NSApp.activate()
                openWindow(.claudeConfig)
            }
            Button("Справка", systemImage: "questionmark.circle") {
                NSApp.activate()
                openWindow(.help)
            }
            Divider()
            Button("Выйти из AI Hub Bar (⌘Q)", systemImage: "power") { NSApp.terminate(nil) }
        } label: {
            Label("Ещё", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Ещё")
        // ⌘Q works without opening the menu.
        Button("") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
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
                            withAnimation(calm ? nil : .snappy(duration: 0.2)) { modes.select(mode.id) }
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

    /// The block stays in its place when nothing is running, so it doesn't look lost.
    private var noSessions: some View {
        HStack(spacing: 6) {
            BlockTitle(block: .sessions, title: "Сессии агентов", foldable: false)
            Text("нет активных")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var hooksHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .foregroundStyle(.secondary)
            Text("Включите отслеживание, чтобы видеть сессии Claude.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("Настройки…") { openSettings(.module(.sessions)) }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
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
                    openWindow(.assistant)
                }
                .buttonStyle(.borderedProminent)
                Button("Импортировать файл…") {
                    SettingsFiles.chooseImport(into: modes)
                    // «Заменить» / «Добавить» are asked in Settings → «Профили».
                    guard modes.pendingImport != nil else { return }
                    openSettings(.modes)
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
            // A Copilot or Codex session with the hook is already a row of its own, with its state.
            let others = AgentThread.without(agentThreads, sessionIDs: Set(sessions.items.map(\.id)))
            if !sessionRows.isEmpty || !others.isEmpty || !sessions.resumable.isEmpty || !launcher.queued.isEmpty {
                SessionsView(rows: sessionRows, others: others, resumable: sessions.resumable)
                    .panelCard()
                    .revealed(isShown, step: 1, reduceMotion: calm)
            } else if hooks.status == .installed {
                noSessions
                    .panelCard()
                    .revealed(isShown, step: 1, reduceMotion: calm)
            } else if services.agents[.claudeCode] != nil {
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
            VStack(alignment: .leading, spacing: 0) {
                projectsHeader
                if !PanelBlock.collapsed(in: collapsedRaw).contains(.projects) {
                    content
                        .padding(.top, -6)
                        .padding(.bottom, 6)
                }
            }
            .panelCard()
            .revealed(isShown, step: 1, reduceMotion: calm)
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
        case .notch, .layout, .quickPrompt, .telegram:
            EmptyView()
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
                    .foregroundStyle(.secondary)
            }
            if red > 0 {
                Text("с проблемами: \(red)")
                    .scaledFont(.caption, weight: .medium)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if folders.isActive {
            FolderProjectsView(expanded: $folderExpanded)
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
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.projects) { project in
                ProjectRowView(project: project, isExpanded: expandedBinding(project.id))
                    .id(project.id)
            }
        }
        .padding(4)
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

/// Which blocks stay in sight and which wait under «Ещё»: the AI ones (limits, sessions) and the projects stay — a
/// profile made for projects must show them (Oleh, 2026-11-10). Nothing is folded when there is nothing to keep or
/// only one other block — a row instead of one block saves nothing.
enum PanelFold {
    static func split(_ modules: [ModuleKind]) -> (main: [ModuleKind], more: [ModuleKind]) {
        let main = modules.filter(staysInSight)
        let more = modules.filter { !staysInSight($0) }
        return main.isEmpty || more.count < 2 ? (modules, []) : (main, more)
    }

    static func staysInSight(_ kind: ModuleKind) -> Bool { kind.group == .ai || kind == .projects }
}
