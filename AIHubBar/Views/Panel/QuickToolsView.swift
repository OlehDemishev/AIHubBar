import SwiftUI

/// «Быстрые команды» in the panel (SPEC-profiles §4.3): the library as buttons, two per row.
struct QuickCommandsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ProfileStore.self) private var modes
    @Environment(QuickToolsController.self) private var tools
    @Environment(CommandHotKeys.self) private var hotKeys

    /// The library, minus what the current profile left out.
    private var commands: [QuickCommand] {
        let chosen = modes.current?.module(.quickCommands)?.commands
        return settings.quickCommands.filter { ProfileModule.includes($0.id, in: chosen) }
    }
    @AppStorage(StorageKey.collapsedBlocks) private var collapsedRaw = ""
    @State private var confirming: String?

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BlockTitle(block: .quickCommands, title: "Быстрые команды")
            if !PanelBlock.collapsed(in: collapsedRaw).contains(.quickCommands) {
                if commands.isEmpty {
                    Text("Команд нет — добавьте в Настройках → «Что показывать».").scaledFont(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(commands) { command in
                        Button {
                            if command.confirm { confirming = command.id } else { tools.run(command) }
                        } label: {
                            HStack(spacing: 6) {
                                if tools.running.contains(command.id) {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: command.symbol).frame(width: 14)
                                }
                                Text(command.title).lineLimit(1)
                                Spacer(minLength: 0)
                                if let key = hotKeys.registered[command.id] {
                                    Text(key.title)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .layoutPriority(1)
                                }
                            }
                            .scaledFont(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(hotKeys.registered[command.id].map { command.value + "\n" + String(localized: "Сочетание клавиш: \($0.title)") } ?? command.value)
                        .accessibilityLabel(hotKeys.registered[command.id].map { "\(command.title), \($0.spoken)" } ?? command.title)
                    }
                }
                if let id = confirming, let command = settings.quickCommands.first(where: { $0.id == id }) {
                    HStack(spacing: 6) {
                        Text("Запустить «\(command.title)»?").scaledFont(.caption)
                        Spacer()
                        Button("Отмена") { confirming = nil }
                        Button("Запустить") {
                            confirming = nil
                            tools.run(command)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
                ForEach(settings.quickCommands) { command in
                    if let result = tools.results[command.id] {
                        Label("\(command.title): \(result.text)", systemImage: result.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                            .scaledFont(.caption)
                            .foregroundStyle(result.isError ? .orange : .secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// «Быстрые переключатели» in the panel (SPEC-profiles §4.4).
struct QuickTogglesView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ProfileStore.self) private var modes

    /// The profile's own choice, else the ones chosen in Settings → «Модули».
    private var toggles: [QuickToggle] {
        let chosen = modes.current?.module(.toggles)?.toggles
        return QuickToggle.available(installed: modes.activeModules)
            .filter { toggle in chosen.map { $0.contains(toggle.rawValue) } ?? settings.quickToggles.contains(toggle) }
    }
    @Environment(QuickToolsController.self) private var tools
    @AppStorage(StorageKey.collapsedBlocks) private var collapsedRaw = ""
    @State private var confirming: QuickToggle?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BlockTitle(block: .toggles, title: "Быстрые переключатели")
            if !PanelBlock.collapsed(in: collapsedRaw).contains(.toggles) {
                HStack(spacing: 6) {
                    ForEach(toggles, id: \.self) { toggle in
                        let on = tools.isOn(toggle) == true
                        Button {
                            if toggle.needsConfirmation { confirming = toggle } else { tools.perform(toggle) }
                        } label: {
                            QuickToggleTile(toggle: toggle, isOn: on, isRunning: tools.running.contains(toggle.rawValue))
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(on ? String(localized: "включено") : String(localized: "выключено"))
                        .help(hint(for: toggle))
                    }
                }
                // Stays while it's off: the person may open the panel long after, wondering where the desktop went.
                ForEach(toggles, id: \.self) { toggle in
                    if tools.isOn(toggle) == false, let note = toggle.offNote {
                        Label(note, systemImage: "info.circle")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let toggle = confirming {
                    HStack(spacing: 6) {
                        Text("\(toggle.title)? Это нельзя отменить.").scaledFont(.caption)
                        Spacer()
                        Button("Отмена") { confirming = nil }
                        Button("Да") {
                            confirming = nil
                            tools.perform(toggle)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                    .controlSize(.small)
                }
                ForEach(QuickToggle.allCases, id: \.self) { toggle in
                    if let result = tools.results[toggle.rawValue] {
                        Label(result.text, systemImage: result.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                            .scaledFont(.caption)
                            .foregroundStyle(result.isError ? .orange : .secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onAppear { tools.refreshStates() }
    }

    /// The tile's hover hint: its name, its state when known, and what turning it off takes away.
    private func hint(for toggle: QuickToggle) -> String {
        var hint = toggle.title
        if let isOn = tools.isOn(toggle) {
            hint += isOn ? String(localized: " — включено") : String(localized: " — выключено")
        }
        if let note = toggle.offNote {
            hint += "\n" + note
        }
        return hint
    }
}

/// One tile in «Быстрые переключатели»: the symbol (or a spinner while it runs) over the short name.
private struct QuickToggleTile: View {
    let toggle: QuickToggle
    let isOn: Bool
    let isRunning: Bool

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: toggle.symbol).scaledFont(size: 14)
                }
            }
            .frame(height: 18)
            Text(toggle.shortTitle)
                .scaledFont(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isOn ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07)))
        .foregroundStyle(isOn ? Color.accentColor : .primary)
        .contentShape(Rectangle())
    }
}
