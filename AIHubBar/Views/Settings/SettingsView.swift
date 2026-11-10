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
    /// The service «Сервисы AI» opens on: the last one looked at.
    @State private var lastService = ServiceTab.claude
    @State private var query = ""

    init() {
        SettingsRoute.migrate()
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { selected }, set: { if let new = $0 { select(new) } })) {
                if query.isEmpty {
                    ForEach(sidebar, id: \.self) { pane in
                        PaneRow(pane: pane, isOff: !isOn(pane), isQuiet: pane == .modes && modes.modes.count < 2, allServices: pane.isService)
                    }
                } else {
                    ForEach(SettingsPane.areas.filter { $0.matches(query) }, id: \.self) { pane in
                        PaneRow(pane: pane)
                    }
                    let modules = foundModules
                    if !modules.isEmpty {
                        Section("Модули") {
                            ForEach(modules, id: \.self) { pane in
                                PaneRow(pane: pane, isOff: !isOn(pane))
                            }
                        }
                    }
                    let services = SettingsPane.services.filter { $0.matches(query) }
                    if !services.isEmpty {
                        Section("Сервисы AI") {
                            ForEach(services, id: \.self) { pane in
                                PaneRow(pane: pane, isSetUp: isSetUp(pane))
                            }
                        }
                    }
                    if nothingFound {
                        Text("Ничего не найдено")
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: Text("Поиск"))
            .onAppear { remember(pane) }
            .onChange(of: pane) { remember(pane) }
            // The column width alone is not kept on macOS 27: the sidebar came up 144 pt wide and cut the names to
            // «Внешний…», «Строка ме…». The content's own minimum holds it.
            .frame(minWidth: 230)
            .navigationSplitViewColumnWidth(min: 230, ideal: 230, max: 320)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                PaneHeader(pane: pane, isOn: mainSwitch, back: pane.parent.map { parent in { select(parent) } })
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                if case let .service(service) = pane {
                    ServiceTabsBar(selection: service, isSetUp: { isSetUp(.service($0)) ?? false }) { select(.service($0)) }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 4)
                }
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

    /// The sidebar without a search: seven rows. The modules' pages and «Строка меню» open from «Что показывать».
    private var sidebar: [SettingsPane] {
        var rows: [SettingsPane] = [.general, .show, .appearance, servicesRow]
        if isAvailable(.notch) { rows.append(.module(.notch)) }
        return rows + [.modes, .shortcuts]
    }

    /// One row for every service: it stands for the service on screen, else for the last one looked at.
    private var servicesRow: SettingsPane { pane.isService ? pane : .service(lastService) }

    /// The row the page on screen belongs to.
    private var selected: SettingsPane { query.isEmpty ? pane.parent ?? pane : pane }

    private func remember(_ pane: SettingsPane) {
        if case let .service(service) = pane { lastService = service }
    }

    private var foundModules: [SettingsPane] {
        ModuleDefinition.all.map(\.kind).filter(isAvailable).map(SettingsPane.module).filter { $0.matches(query) }
    }

    private var nothingFound: Bool {
        !(SettingsPane.areas + foundModules + SettingsPane.services).contains { $0.matches(query) }
    }

    @ViewBuilder private var page: some View {
        switch pane {
        case .general: GeneralSettings()
        case .modes: ProfilesSettings()
        case .show: ShowSettings { select($0) }
        case .appearance: AppearanceSettings()
        case .menuBar: MenuBarSettings()
        case .shortcuts: ShortcutsSettings()
        case let .module(kind): ModulePage(kind: kind).id(kind)
        case let .service(service): ServicePage(service: service).id(service)
        }
    }

    /// A module in beta testing needs beta builds, and «Отчёты» only exist on a Mac with `_daily-report`.
    private func isAvailable(_ kind: ModuleKind) -> Bool {
        ModuleSwitch.isOffered(kind, settings: settings, modes: modes)
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
