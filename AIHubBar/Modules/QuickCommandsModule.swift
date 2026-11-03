import AppKit
import SwiftUI

// «Быстрые команды» (docs/specs/SPEC-refactor.md §3): what the module is, its Settings sections and its «Панель сейчас» line.

extension ModuleDefinition {
    static let quickCommands = ModuleDefinition(
        kind: .quickCommands,
        group: .work,
        symbol: "bolt.square",
        title: String(localized: "Быстрые команды"),
        summary: String(localized: "Свои кнопки: скрипт в фоне или в Терминале, ярлык из «Команд» macOS, ссылка, файл, папка или приложение. У каждой может быть своё сочетание клавиш."),
        tagline: String(localized: "Скрипты, ярлыки, ссылки, файлы"),
        notifications: [.commands],
        keywords: [String(localized: "Команды")]
    )
}

extension ModuleUI {
    static let quickCommands = ModuleUI(
        settings: { AnyView(QuickCommandsSection()) },
        sketch: { AnyView(QuickCommandsSketch()) }
    )
}

/// «Панель сейчас»: how many commands.
private struct QuickCommandsSketch: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        SketchLine(String(localized: "Команд: \(settings.quickCommands.count)"))
    }
}

/// The «Быстрые команды» library: what each button runs (SPEC-profiles §4.3).
struct QuickCommandsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(CommandHotKeys.self) private var hotKeys

    private static let symbols = ["bolt", "terminal", "folder", "link", "doc", "arrow.down.circle", "network", "hammer", "play", "wand.and.stars", "camera", "music.note"]

    var body: some View {
        @Bindable var settings = settings
        Section {
            ForEach($settings.quickCommands) { $command in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("", selection: $command.symbol) {
                            ForEach(Self.symbols, id: \.self) { Image(systemName: $0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 60)
                        .help("Значок кнопки")
                        TextField("Название", text: $command.title)
                        Button { move(command.id, by: -1) } label: { Label("Выше", systemImage: "chevron.up").labelStyle(.iconOnly) }
                            .disabled(settings.quickCommands.first?.id == command.id)
                            .help("Выше")
                        Button { move(command.id, by: 1) } label: { Label("Ниже", systemImage: "chevron.down").labelStyle(.iconOnly) }
                            .disabled(settings.quickCommands.last?.id == command.id)
                            .help("Ниже")
                        Button(role: .destructive) { settings.quickCommands.removeAll { $0.id == command.id } } label: { Label("Удалить команду", systemImage: "trash").labelStyle(.iconOnly) }
                            .help("Удалить команду")
                    }
                    .buttonStyle(.borderless)
                    Picker("Что делает", systemImage: "bolt", selection: $command.kind) {
                        ForEach(QuickCommand.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField(placeholder(command.kind), text: $command.value)
                        .font(.callout.monospaced())
                    Toggle("Спрашивать перед запуском", systemImage: "questionmark.circle", isOn: $command.confirm)
                    IconRow("Сочетание клавиш", systemImage: "keyboard") {
                        HotKeyRecorder(combo: $command.hotKey)
                    }
                    if let problem = hotKeys.problem(for: command) {
                        Label(problem.text, systemImage: problem.blocks ? "exclamationmark.triangle.fill" : "info.circle")
                            .font(.caption)
                            .foregroundStyle(problem.blocks ? .orange : .secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Button("Добавить команду") {
                settings.quickCommands.append(QuickCommand(title: String(localized: "Новая команда"), kind: .script, value: ""))
            }
        } header: {
            Text("Команды")
        } footer: {
            Footnote(text: String(localized: "Скрипт в фоне запускается через zsh в домашней папке, итог приходит уведомлением; «в Терминале» — открывает новое окно. Ярлык — имя из приложения «Команды». Открыть — ссылка (https://…) или путь (~/…). Сочетание клавиш запускает команду из любого приложения, как кнопка в панели, — и тоже спрашивает, если включено «Спрашивать перед запуском»."))
        }
    }

    private func placeholder(_ kind: QuickCommand.Kind) -> String {
        switch kind {
        case .script, .terminal: String(localized: "команда, например: brew upgrade")
        case .shortcut: String(localized: "имя ярлыка")
        case .open: String(localized: "https://… или ~/папка")
        }
    }

    private func move(_ id: String, by offset: Int) {
        guard let index = settings.quickCommands.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), settings.quickCommands.count - 1)
        settings.quickCommands.swapAt(index, target)
    }
}
