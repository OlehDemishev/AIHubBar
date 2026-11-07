import SwiftUI

/// «Общие команды» block and the free disk space (docs/specs/SPEC.md §2.5).
struct CommandsView: View {
    @Environment(CommandStore.self) private var commands
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @State private var confirmCleanup = false
    @AppStorage(StorageKey.collapsedBlocks) private var collapsedRaw = ""

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                BlockTitle(block: .commands, title: "Отчёты")
                Spacer()
                disk
            }
            if !PanelBlock.collapsed(in: collapsedRaw).contains(.commands) { commandList }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .animation(.snappy(duration: 0.2), value: confirmCleanup)
    }

    @ViewBuilder
    private var commandList: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(CommonCommand.allCases) { command in
                button(command)
            }
        }

        if confirmCleanup {
            cleanupConfirmation
                .transition(.opacity.combined(with: .offset(y: -4)))
        }

        ForEach(CommonCommand.allCases) { command in
            if let result = commands.results[command] {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label {
                        Text("\(command.title): \(result.text)")
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: result.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                            .foregroundStyle(result.isError ? .red : .green)
                    }
                    Spacer(minLength: 4)
                    Button { commands.dismissResult(of: command) } label: {
                        Label("Скрыть", systemImage: "xmark").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Скрыть")
                }
                .scaledFont(.caption)
                if command == commands.cleanupOutput?.command {
                    Button("Вывод очистки…", action: showCleanupOutput)
                        .buttonStyle(.link)
                        .scaledFont(.caption)
                        .padding(.leading, 20)
                }
            }
        }
    }

    @ViewBuilder
    private var disk: some View {
        // The live figure, the one «Ресурсы Mac» shows; the report's is as old as the report.
        if let bytes = monitor.snapshot?.diskFree ?? DiskSpace.freeBytes() {
            let low = bytes < CommandStore.lowDiskBytes
            Label("Свободно \(CommandStore.diskText(bytes))", systemImage: low ? "exclamationmark.triangle.fill" : "internaldrive")
                .scaledFont(.caption, weight: low ? .semibold : .regular)
                .foregroundStyle(low ? .orange : .secondary)
                .help(low ? String(localized: "Меньше 20 ГБ — стоит запустить очистку") : String(localized: "Свободное место на диске"))
        }
    }

    private func button(_ command: CommonCommand) -> some View {
        let isRunning = commands.running.contains(command)
        return Button {
            if command == .cleanupRun {
                confirmCleanup = true
            } else {
                commands.run(command)
            }
        } label: {
            HStack(spacing: 6) {
                if isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: command.systemImage)
                        .frame(width: 14)
                }
                Text(command.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .scaledFont(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(command == .cleanupRun ? .red : nil)
        .disabled(isRunning)
        .help(command.help)
    }

    private var cleanupConfirmation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Удалить сборки, кэши и сбросить симуляторы? Сначала можно посмотреть список: «Очистка: проверить».")
                .scaledFont(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Отмена") { confirmCleanup = false }
                Button("Очистить") {
                    confirmCleanup = false
                    commands.run(.cleanupRun)
                }
                .tint(.red)
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
    }

    private func showCleanupOutput() {
        NSApp.activate()
        openWindow(.cleanupOutput)
    }
}

/// Output of `cleanup.py` (dry run or real run) in its own window.
struct CleanupOutputView: View {
    @Environment(CommandStore.self) private var commands

    var body: some View {
        Group {
            if let output = commands.cleanupOutput {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(output.command.title).scaledFont(.headline)
                        Spacer()
                        Text(output.date.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    Divider()
                    ScrollView {
                        Text(output.text)
                            .scaledFont(.callout, design: .monospaced)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Text("Очистка ещё не запускалась")
                        .foregroundStyle(.secondary)
                    Button(CommonCommand.cleanupCheck.title) { commands.run(.cleanupCheck) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }
}
