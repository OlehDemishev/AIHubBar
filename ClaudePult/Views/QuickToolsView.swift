import SwiftUI

/// «Быстрые команды» in the panel (SPEC-profiles §4.3): the library as buttons, two per row.
struct QuickCommandsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(QuickToolsController.self) private var tools
    @AppStorage("collapsedBlocks") private var collapsedRaw = ""
    @State private var confirming: String?

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BlockTitle(block: .quickCommands, title: "Быстрые команды")
            if !PanelBlock.collapsed(in: collapsedRaw).contains(.quickCommands) {
                if settings.quickCommands.isEmpty {
                    Text("Команд нет — добавьте в Настройках → «Модули».").scaledFont(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(settings.quickCommands) { command in
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
                            }
                            .scaledFont(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(command.value)
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
    @Environment(QuickToolsController.self) private var tools
    @AppStorage("collapsedBlocks") private var collapsedRaw = ""
    @State private var confirming: QuickToggle?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BlockTitle(block: .toggles, title: "Быстрые переключатели")
            if !PanelBlock.collapsed(in: collapsedRaw).contains(.toggles) {
                HStack(spacing: 6) {
                    ForEach(QuickToggle.allCases.filter(settings.quickToggles.contains), id: \.self) { toggle in
                        let on = tools.isOn(toggle) == true
                        Button {
                            if toggle.needsConfirmation { confirming = toggle } else { tools.perform(toggle) }
                        } label: {
                            VStack(spacing: 3) {
                                Group {
                                    if tools.running.contains(toggle.rawValue) {
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
                                .fill(on ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07)))
                            .foregroundStyle(on ? Color.accentColor : .primary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(toggle.title + (tools.isOn(toggle).map { $0 ? String(localized: " — включено") : String(localized: " — выключено") } ?? ""))
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
}
