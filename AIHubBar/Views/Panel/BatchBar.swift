import SwiftUI

/// «Выбрать» in the projects block of a folder profile (SPEC-content §5): the checked projects, a command of the
/// profile, and when to run it — now, at night or after the limit resets. Below it, the batches that wait or work.
struct BatchBar: View {
    let mode: Profile
    let projects: [FolderProject]
    @Binding var isSelecting: Bool
    @Binding var selection: Set<String>

    @Environment(BatchRunner.self) private var batches
    @Environment(AIServiceStore.self) private var services
    @Environment(AppSettings.self) private var settings
    @State private var serviceID: String?
    @State private var command: CommandTemplate?
    @State private var text = ""

    /// Only where a run needs nobody at the Mac.
    private var usable: [AIService] { services.available.filter { Batch.canRun($0, mode: mode) } }

    private var service: AIService? {
        let wanted = (serviceID ?? command?.service ?? mode.service).flatMap(AIService.init(id:)) ?? .claudeCode
        return usable.contains(wanted) ? wanted : usable.first
    }

    private var chosen: [FolderProject] { projects.filter { selection.contains($0.path) } }

    private var canStart: Bool {
        guard let command, service != nil, !chosen.isEmpty else { return false }
        return command.asks == nil || !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isSelecting {
                selecting
            } else if projects.count > 1 {
                Button {
                    isSelecting = true
                } label: {
                    Label("Выбрать", systemImage: "checklist").scaledFont(.caption)
                }
                .buttonStyle(.borderless)
                .help("Выполнить одну команду в нескольких проектах — по очереди, сейчас или ночью")
            }
            ForEach(batches.batches) { batch in
                BatchRow(batch: batch)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    @ViewBuilder private var selecting: some View {
        HStack(spacing: 6) {
            Text("Выбрано проектов: \(chosen.count)").scaledFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            Button(selection.count == projects.count ? String(localized: "Снять все") : String(localized: "Все")) {
                selection = selection.count == projects.count ? [] : Set(projects.map(\.path))
            }
            .buttonStyle(.link)
            .scaledFont(.caption)
            Spacer()
            if let service, usable.count > 1 {
                Menu {
                    ForEach(usable, id: \.id) { item in
                        Button(item.title) { serviceID = item.id }
                    }
                } label: {
                    Text(service.shortName(compatibleName: settings.aiServices.compatibleName)).scaledFont(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Каким сервисом выполнять")
            }
            Button("Отмена") { close() }.controlSize(.small)
        }
        if usable.isEmpty {
            Text("Пакет работает только в фоне: нужен Claude Code с запуском в фоне или модель по API.")
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
        } else if mode.commands.isEmpty {
            Text("У профиля нет команд: добавьте их в Настройки → «Профили».").scaledFont(.caption2).foregroundStyle(.secondary)
        } else {
            FlowLayout(spacing: 4) {
                ForEach(mode.commands) { item in
                    Toggle(item.title, isOn: Binding(get: { command?.id == item.id }, set: { command = $0 ? item : nil }))
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help(item.hint)
                }
            }
            if let command, let asks = command.asks {
                TextField(asks, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .help("Спрашивается один раз на весь пакет")
            }
            HStack(spacing: 6) {
                Button("Сейчас") { start(.now) }
                    .help("По одному проекту за раз, начиная сейчас")
                Button("На ночь") { start(.night) }
                    .help("Начнётся в час ночного запуска из настроек; утром одна сводка")
                if service == .claudeCode {
                    Button("После сброса лимита") { start(.afterReset) }
                        .help("Начнётся через две минуты после сброса лимита сессии")
                }
            }
            .controlSize(.small)
            .disabled(!canStart)
            Text("Проекты идут по очереди, не параллельно. У лимита пакет ждёт сброса; в конце придёт одна сводка.")
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func start(_ when: Batch.When) {
        guard let command, let service else { return }
        batches.add(command, projects: chosen, mode: mode, service: service, text: command.asks == nil ? nil : text, when: when)
        close()
    }

    private func close() {
        isSelecting = false
        selection = []
        command = nil
        text = ""
    }
}

/// A batch in the projects block: «Редактура · 3 из 10» and what can be done with it.
private struct BatchRow: View {
    let batch: Batch
    @Environment(BatchRunner.self) private var batches

    private var failed: [Batch.Item] { batch.items.filter { $0.state == .failed } }

    var body: some View {
        HStack(spacing: 5) {
            if batch.isFinished {
                Image(systemName: failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(failed.isEmpty ? .green : .orange)
            } else if batch.runningIndex != nil {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "clock").foregroundStyle(.secondary)
            }
            Text(verbatim: "\(batch.template.title) · \(batch.status())")
                .lineLimit(1)
                .help(failed.isEmpty ? batch.items.map(\.name).joined(separator: ", ")
                      : failed.map { "\($0.name): \($0.note ?? "")" }.joined(separator: "\n"))
            Spacer(minLength: 4)
            if batch.isFinished {
                Button("Убрать") { batches.dismiss(batch.id) }.buttonStyle(.link)
            } else {
                ConfirmedButton(title: "Отменить пакет?", message: String(localized: "Проекты, до которых очередь не дошла, не будут обработаны. Тот, что выполняется сейчас, закончит работу."), confirm: "Отменить пакет", role: nil) {
                    batches.cancel(batch.id)
                } label: { Text("Отменить") }
                .buttonStyle(.link)
            }
        }
        .scaledFont(.caption)
    }
}
