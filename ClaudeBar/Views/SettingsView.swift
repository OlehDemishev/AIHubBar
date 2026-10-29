import SwiftUI

struct SettingsView: View {
    @Environment(LoginItemController.self) private var loginItem

    var body: some View {
        Form {
            Section("Общие") {
                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { loginItem.state.isOn },
                    set: { loginItem.setEnabled($0) }
                ))

                if let message = loginItem.state.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if loginItem.state == .requiresApproval {
                    Button("Открыть «Объекты входа»") {
                        loginItem.openSystemSettings()
                    }
                }
                if let error = loginItem.lastError {
                    Text("Ошибка: \(error)")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Версия", value: Self.version)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
