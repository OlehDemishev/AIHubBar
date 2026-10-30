import AppKit
import SwiftUI

/// Commands of a folder project (SPEC-modes §3): the mode's templates plus «Своя задача», the service to run them
/// with, «Сравнить» with 2–3 services, and what is running or done.
struct ProjectCommandsView: View {
    let project: FolderProject
    let mode: Mode

    @Environment(CommandEngine.self) private var engine
    @Environment(AIServiceStore.self) private var services
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @State private var serviceID: String?
    @State private var comparing = false
    @State private var compareIDs: Set<String> = []
    @State private var asking: CommandTemplate?
    @State private var text = ""

    private var commands: [CommandTemplate] { mode.commands + [.customTask] }

    private var service: AIService {
        (serviceID ?? mode.service).flatMap(AIService.init(id:)) ?? .claudeCode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Команды").scaledFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                Spacer()
                if !comparing {
                    Menu {
                        ForEach(services.available, id: \.id) { item in
                            Button(item.title) { serviceID = item.id }
                        }
                    } label: {
                        Text(service.shortName(compatibleName: settings.aiServices.compatibleName)).scaledFont(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Каким сервисом выполнять")
                }
                Toggle("Сравнить", isOn: $comparing.animation(.snappy(duration: 0.2)))
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .help("Выполнить одну команду 2–3 сервисами и положить результаты рядом")
            }

            if comparing {
                FlowRow(spacing: 4) {
                    ForEach(services.available, id: \.id) { item in
                        Toggle(item.shortName(compatibleName: settings.aiServices.compatibleName), isOn: Binding(
                            get: { compareIDs.contains(item.id) },
                            set: { on in
                                if on, compareIDs.count < 3 { compareIDs.insert(item.id) } else { compareIDs.remove(item.id) }
                            }
                        ))
                        .toggleStyle(.button)
                        .controlSize(.mini)
                    }
                }
                Text(compareIDs.count < 2 ? String(localized: "Выберите 2–3 сервиса, затем команду.") : String(localized: "Теперь выберите команду."))
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            FlowRow(spacing: 4) {
                ForEach(commands) { command in
                    Button(command.title) { start(command) }
                        .controlSize(.small)
                        .disabled(comparing && compareIDs.count < 2)
                        .help(command.task)
                }
            }

            if let asking {
                HStack(spacing: 6) {
                    TextField(asking.asks ?? String(localized: "Текст"), text: $text)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { perform(asking) }
                    Button("Выполнить") { perform(asking) }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Отмена") { self.asking = nil; text = "" }
                }
                .controlSize(.small)
            }

            if project.mainFile == nil, commands.contains(where: { $0.input == .mainFile && $0.id != CommandTemplate.customTask.id }) {
                Text("В папке нет текстового файла — команды получат только папку.").scaledFont(.caption2).foregroundStyle(.secondary)
            }

            let jobs = engine.jobs(for: project.path)
            if !jobs.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(jobs) { job in JobRow(job: job) }
                    Button("Убрать готовые") { engine.clearFinished(in: project.path) }
                        .buttonStyle(.link)
                        .scaledFont(.caption2)
                }
            }
        }
    }

    private func start(_ command: CommandTemplate) {
        if command.asks != nil {
            asking = command
            text = ""
        } else {
            perform(command)
        }
    }

    private func perform(_ command: CommandTemplate) {
        let input = command.asks == nil ? nil : text
        if comparing {
            let chosen = services.available.filter { compareIDs.contains($0.id) }
            engine.compare(command, project: project, mode: mode, services: chosen, text: input)
            comparing = false
            NSApp.activate()
            openWindow(id: "compare")
        } else {
            let target = command.service.flatMap(AIService.init(id:)) ?? service
            engine.run(command, project: project, mode: mode, service: target, text: input)
        }
        asking = nil
        text = ""
    }
}

private struct JobRow: View {
    let job: CommandEngine.Job

    var body: some View {
        HStack(spacing: 5) {
            switch job.state {
            case .running, .background:
                ProgressView().controlSize(.mini)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .openedInTerminal:
                Image(systemName: "terminal").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text("\(job.title) · \(job.service)").lineLimit(1)
            Spacer(minLength: 4)
            switch job.state {
            case .done:
                Button((job.resultFile as NSString).lastPathComponent) { NSWorkspace.shared.open(URL(fileURLWithPath: job.resultFile)) }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case let .failed(message), let .openedInTerminal(message):
                Text(message).foregroundStyle(.secondary).lineLimit(2).help(message)
            case .running, .background:
                Text("выполняется…").foregroundStyle(.secondary)
            }
        }
        .scaledFont(.caption)
    }
}

/// «Сравнить»: the results of one command next to each other (SPEC-modes §11.4). No verdicts from ClaudePult.
struct CompareView: View {
    @Environment(CommandEngine.self) private var engine

    var body: some View {
        if let comparison = engine.comparison {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(comparison.files, id: \.path) { file in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(file.label).font(.headline)
                                Spacer()
                                if FileManager.default.fileExists(atPath: file.path) {
                                    Button("Открыть") { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) }
                                        .controlSize(.small)
                                }
                            }
                            ScrollView {
                                Text((try? String(contentsOfFile: file.path, encoding: .utf8)) ?? String(localized: "Ещё выполняется…"))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        if file.path != comparison.files.last?.path { Divider() }
                    }
                }
            }
            .navigationTitle("Сравнение: \(comparison.title)")
        } else {
            Text("Сравнений пока не было: в развёрнутом проекте включите «Сравнить», выберите сервисы и команду.")
                .foregroundStyle(.secondary)
                .padding(40)
        }
    }
}
