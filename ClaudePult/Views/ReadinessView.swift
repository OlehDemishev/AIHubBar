import AppKit
import SwiftUI

/// The readiness rows: a status icon, what it is, and one button when something is left to do.
struct ReadinessList: View {
    var items: [ReadinessItem]
    var perform: (ReadinessItem.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    icon(item.state).font(.title3).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).fontWeight(.medium)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if let action = item.action {
                        Button(action.title) { perform(action) }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
        }
    }

    private func icon(_ state: ReadinessItem.State) -> some View {
        let (name, color): (String, Color) = switch state {
        case .done: ("checkmark.circle.fill", .green)
        case .todo: ("exclamationmark.circle.fill", .orange)
        case .optional: ("circle.dashed", .secondary)
        }
        return Image(systemName: name).foregroundStyle(color)
    }
}

/// The readiness rows for this Mac, live: re-checked on appear, when ClaudePult comes back to the front
/// (after System Settings) and with «Проверить снова».
struct ReadinessSection: View {
    @Environment(AIServiceStore.self) private var services
    @Environment(HookController.self) private var hooks
    @Environment(NotificationPermission.self) private var notifications
    @Environment(LoginItemController.self) private var loginItem
    @Environment(\.openSettings) private var openSettings
    /// In «Помощь» a Mac with nothing left to do gets one line instead of four rows.
    var collapsesWhenReady = false
    @State private var expanded = false

    var body: some View {
        let items = Readiness.items(input)
        VStack(alignment: .leading, spacing: 8) {
            if collapsesWhenReady, Readiness.isReady(items), !expanded {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Всё готово")
                    Button("Подробнее") { expanded = true }
                        .buttonStyle(.link)
                }
            } else {
                ReadinessList(items: items, perform: perform)
                Button("Проверить снова", action: refresh)
                    .controlSize(.small)
                    .disabled(services.isScanning)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var input: Readiness.Input {
        let permission: Readiness.Notifications = switch notifications.state {
        case .allowed: .allowed
        case .denied: .denied
        case .notAsked, .unknown: .notAsked
        }
        return Readiness.Input(
            claudeVersion: services.agents[.claudeCode].map { $0.version ?? "" },
            otherServices: AgentKind.allCases.filter { $0 != .claudeCode && services.agents[$0] != nil }.map(\.title)
                + APIProvider.allCases.filter { services.hasKey.contains($0) }.map(\.title),
            servicesChecked: services.hasScanned,
            hooks: hooks.status,
            notifications: permission,
            loginItem: loginItem.state
        )
    }

    private func refresh() {
        hooks.refresh()
        notifications.refresh()
        loginItem.refresh()
        Task { await services.scan() }
    }

    private func perform(_ action: ReadinessItem.Action) {
        switch action {
        case .openServices:
            UserDefaults.standard.set("services", forKey: "settingsTab")
            NSApp.activate()
            openSettings()
        case .installHooks, .updateHooks: hooks.install()
        case .allowNotifications: notifications.request()
        case .openNotificationSettings: NotificationPermission.openSystemSettings()
        case .enableLoginItem: loginItem.setEnabled(true)
        case .openLoginItems: loginItem.openSystemSettings()
        }
    }
}
