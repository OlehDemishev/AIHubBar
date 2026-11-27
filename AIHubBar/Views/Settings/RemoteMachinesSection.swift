import SwiftUI

/// «Сессии агентов» → «Сессии на других компьютерах»: the computers reached over SSH whose Claude Code sessions the
/// panel shows beside this Mac's (`RemoteMachines`).
struct RemoteMachinesSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RemoteMachines.self) private var remote

    var body: some View {
        @Bindable var settings = settings
        Section {
            ForEach($settings.remoteMachines) { $machine in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Название", text: $machine.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        TextField("Адрес для ssh", text: $machine.host, prompt: Text(verbatim: "user@host"))
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        Toggle("Показывать сессии", isOn: $machine.isOn)
                            .labelsHidden()
                            .help("Показывать сессии")
                        ConfirmedButton(title: "Убрать компьютер", message: removeMessage(machine), confirm: "Убрать", role: nil) {
                            // The value is read first: read inside the closure, it goes through the binding into the
                            // array being changed (see «Убрать аккаунт»).
                            let removed = machine
                            settings.remoteMachines.removeAll { $0.id == removed.id }
                            Task { await remote.uninstall(removed) }
                        } label: {
                            Label("Убрать компьютер", systemImage: "minus.circle").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Убрать компьютер")
                    }
                    status(machine)
                }
                .padding(.vertical, 2)
            }
            Button("Добавить компьютер") { settings.remoteMachines.append(RemoteMachine(name: "", host: "")) }
        } header: {
            HStack(spacing: 6) {
                Text("Сессии на других компьютерах")
                BetaBadge()
            }
        } footer: {
            Footnote(text: String(localized: "Другой Mac, сервер или виртуальная машина на Linux, куда этот Mac входит по SSH по ключу, без пароля: имя из ~/.ssh/config или user@host. «Установить» кладёт туда отслеживание AI Hub Bar (записи в ~/.claude/settings.json, с резервной копией рядом) и маленький скрипт; там нужен python3. Сессии Claude Code с того компьютера появятся в панели, с «Разрешить» и «Отклонить»."))
        }
    }

    @ViewBuilder
    private func status(_ machine: RemoteMachine) -> some View {
        let host = machine.host.trimmingCharacters(in: .whitespaces)
        if host.isEmpty {
            EmptyView()
        } else if !RemoteMachine.isValidHost(host) || host != machine.host {
            Text("В адресе могут быть буквы, цифры, точка и дефис, без пробелов: host или user@host.")
                .font(.callout)
                .foregroundStyle(.orange)
        } else {
            let link = remote.links[machine.id]
            HStack(spacing: 8) {
                if remote.settingUp.contains(machine.id) {
                    ProgressView().controlSize(.small)
                } else if let link {
                    Text(link.title)
                        .font(.callout)
                        .foregroundStyle(link == .connected ? .green : link == .connecting ? .secondary : .orange)
                }
                Spacer(minLength: 4)
                if link != .connected, machine.isOn {
                    Button("Подключиться снова") { remote.reconnect(machine) }
                }
                Button("Установить") { remote.install(machine) }
                    .disabled(remote.settingUp.contains(machine.id))
            }
            .controlSize(.small)
            if case let .offline(reason) = link {
                Text(verbatim: reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let result = remote.setup[machine.id] {
                Text(verbatim: result.text)
                    .font(.callout)
                    .foregroundStyle(result.isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func removeMessage(_ machine: RemoteMachine) -> String {
        String(localized: "\(machine.title): отслеживание AI Hub Bar с того компьютера тоже снимается, если он на связи.")
    }
}
