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
    @Environment(ModeStore.self) private var modes
    @AppStorage(StorageKey.settingsPage) private var pane: SettingsPane = .general
    /// «Сервисы AI» folded by default: six rows the sidebar rarely needs.
    @AppStorage(StorageKey.servicesExpanded) private var servicesExpanded = false
    @State private var query = ""

    init() {
        SettingsRoute.migrate()
    }

    var body: some View {
        NavigationSplitView {
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
                            Section("Сервисы AI", isExpanded: Binding(
                                // Open while searching or while one of them is the page shown.
                                get: { servicesExpanded || !query.isEmpty || pane.isService },
                                set: { servicesExpanded = $0 }
                            )) {
                                ForEach(found, id: \.self) { pane in
                                    PaneRow(pane: pane, isSetUp: isSetUp(pane))
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: Text("Поиск"))
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

    @ViewBuilder private var page: some View {
        switch pane {
        case .general: GeneralSettings()
        case .modes: ModesSettings()
        case .modules: ModuleCatalog { select(.module($0)) }
        case .panel: PanelBuilder()
        case .appearance: AppearanceSettings()
        case .menuBar: MenuBarSettings()
        case let .module(kind): ModulePage(kind: kind).id(kind)
        case let .service(service): ServicePage(service: service).id(service)
        }
    }

    /// «Раскладка» is offered only with beta builds (SPEC-layout).
    private func isListed(_ kind: ModuleKind) -> Bool { !kind.isBeta || settings.betaUpdates }

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
