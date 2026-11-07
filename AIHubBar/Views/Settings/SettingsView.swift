import AppKit
import SwiftUI

/// Settings window like System Settings (SPEC-settings §2): a sidebar with search — the app's areas, the modules by
/// section (AI, Работа, Mac) and «Сервисы AI» with a page per AI; the chosen page on the right under its header.
/// One window size for every page.
struct SettingsView: View {
    static let size = CGSize(width: 940, height: 700)
    /// The window can grow; below this the module tiles and the menu bar editor get cramped.
    static let minSize = CGSize(width: 820, height: 560)

    @Environment(AppSettings.self) private var settings
    @Environment(AIServiceStore.self) private var services
    @Environment(HubLimitsStore.self) private var hub
    @Environment(ProfileStore.self) private var modes
    @AppStorage(StorageKey.settingsPage) private var pane: SettingsPane = .general
    /// «Сервисы AI» folded by default: six rows the sidebar rarely needs.
    @AppStorage(StorageKey.servicesExpanded) private var servicesExpanded = false
    @State private var query = ""

    init() {
        SettingsRoute.migrate()
    }

    var body: some View {
        NavigationSplitView {
            ScrollViewReader { sidebar in
            List(selection: Binding(get: { pane }, set: { if let new = $0 { select(new) } })) {
                ForEach(SettingsPane.areas.filter { $0.matches(query) }, id: \.self) { pane in
                    PaneRow(pane: pane)
                }
                ForEach(ModuleGroup.allCases, id: \.self) { group in
                    let found = group.modules.filter(isListed).map(SettingsPane.module).filter { $0.matches(query) }
                    if !found.isEmpty {
                        Section(group.title) {
                            ForEach(found, id: \.self) { pane in
                                PaneRow(pane: pane, isOff: !isOn(pane))
                            }
                        }
                    }
                    if group == .ai {
                        let found = SettingsPane.services.filter { $0.matches(query) }
                        if !found.isEmpty {
                            Section {
                                if servicesOpen {
                                    ForEach(found, id: \.self) { pane in
                                        PaneRow(pane: pane, isSetUp: isSetUp(pane))
                                    }
                                }
                            } header: {
                                servicesHeader
                            }
                        }
                    }
                }
                if nothingFound {
                    Text("Ничего не найдено")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: Text("Поиск"))
            // The list is taller than the window: the chosen page's row stays in sight, also after a link to it.
            .onAppear {
                openServices(for: pane)
                DispatchQueue.main.async { sidebar.scrollTo(pane, anchor: .center) }
            }
            .onChange(of: pane) {
                openServices(for: pane)
                DispatchQueue.main.async { withAnimation { sidebar.scrollTo(pane) } }
            }
            }
            .navigationSplitViewColumnWidth(230)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                PaneHeader(pane: pane, isOn: mainSwitch)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .font(.system(size: 13.5))
                    .labelStyle(SettingsRowLabelStyle())
            }
            .navigationTitle(pane.title)
        }
        .modifier(NoWindowToolbar())
        // The Settings scene makes a fixed-size window; this one may grow (SPEC-settings §2).
        .background(WindowReader { window in
            if let window { ResizableSettingsWindow.keep(window, minSize: Self.minSize, size: Self.size) }
        })
        .frame(minWidth: Self.minSize.width, idealWidth: Self.size.width, maxWidth: .infinity,
               minHeight: Self.minSize.height, idealHeight: Self.size.height, maxHeight: .infinity)
        .task { if services.agents.isEmpty { await services.scan() } }
        .preferredColorScheme(settings.panelTheme.colorScheme)
        .debugSnapshot("settings")
    }

    private var servicesOpen: Bool { servicesExpanded || !query.isEmpty }

    /// The system's own section arrow appears only on hover, and the folded section looked like an empty heading.
    private var servicesHeader: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { servicesExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text("Сервисы AI")
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(servicesOpen ? 90 : 0))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A service's page never sits under a folded section.
    private func openServices(for pane: SettingsPane) {
        if pane.isService, !servicesExpanded { servicesExpanded = true }
    }

    private var nothingFound: Bool {
        guard !query.isEmpty else { return false }
        let modules = ModuleGroup.allCases.flatMap(\.modules).filter(isListed).map(SettingsPane.module)
        return !(SettingsPane.areas + modules + SettingsPane.services).contains { $0.matches(query) }
    }

    @ViewBuilder private var page: some View {
        switch pane {
        case .general: GeneralSettings()
        case .modes: ProfilesSettings()
        case .modules: ModuleCatalog { select(.module($0)) }
        case .panel: PanelBuilder()
        case .appearance: AppearanceSettings()
        case .menuBar: MenuBarSettings()
        case .shortcuts: ShortcutsSettings()
        case let .module(kind): ModulePage(kind: kind).id(kind)
        case let .service(service): ServicePage(service: service).id(service)
        }
    }

    /// The sidebar lists what is in use; the rest is in «Модули» and in the search. A module in beta testing needs
    /// beta builds, and «Отчёты» only exist on a Mac with `_daily-report`.
    private func isListed(_ kind: ModuleKind) -> Bool {
        guard !kind.isBeta || settings.betaUpdates, kind != .reports || modes.hasDailyReport else { return false }
        return modes.isOn(kind) || !query.isEmpty || pane == .module(kind)
    }

    private func isOn(_ pane: SettingsPane) -> Bool {
        guard case let .module(kind) = pane else { return true }
        return modes.isOn(kind)
    }

    private var mainSwitch: Binding<Bool>? {
        guard case let .module(kind) = pane, ModuleSwitch.canSwitch(kind, modes: modes) else { return nil }
        return Binding(get: { modes.isOn(kind) }, set: { modes.setOn(kind, $0) })
    }

    private func select(_ new: SettingsPane) {
        pane = new
    }

    private func isSetUp(_ pane: SettingsPane) -> Bool? {
        guard case let .service(service) = pane else { return nil }
        return service.isSetUp(agents: Set(services.agents.keys), keys: services.hasKey, limits: hub.available.union(hub.savedKeys))
    }
}
