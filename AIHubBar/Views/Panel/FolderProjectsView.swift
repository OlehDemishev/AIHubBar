import AppKit
import SwiftUI

/// The projects block of a folder mode (SPEC-modes §3): one row per folder with its stage and metrics, expanding
/// into stage switching and file actions; «Новый проект» at the bottom.
struct FolderProjectsView: View {
    @Environment(FolderProjectStore.self) private var store
    @Environment(ProfileStore.self) private var modes
    /// Held by the panel, so a project found in the search can open here.
    @Binding var expanded: Set<String>
    @State private var newName = ""
    @State private var isCreating = false
    @State private var createError: String?

    private var mode: Profile? { modes.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .scaledFont(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }
            if store.projects.isEmpty, store.lastUpdated != nil {
                let root = PathText.tilde(store.rootFolder ?? "")
                Text(store.rootFolder == nil ? String(localized: "Папка пуста.") : String(localized: "Проектов пока нет: каждая папка внутри «\(root)» — проект."))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else if store.projects.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            ForEach(store.projects) { project in
                FolderProjectRow(
                    project: project,
                    mode: mode,
                    stages: mode?.stageList ?? [],
                    metrics: (mode?.metrics ?? []).compactMap(FolderMetric.init(rawValue:)),
                    wordsPerMinute: mode?.wordsPerMinute ?? 150,
                    isExpanded: Binding(
                        get: { expanded.contains(project.id) },
                        set: { if $0 { expanded.insert(project.id) } else { expanded.remove(project.id) } }
                    )
                )
            }
            if store.rootFolder != nil {
                newProject
            }
        }
        .padding(6)
    }

    @ViewBuilder private var newProject: some View {
        if isCreating {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("Название проекта", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(create)
                    Button("Создать", action: create)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Отмена") { isCreating = false; newName = ""; createError = nil }
                }
                if let createError {
                    Text(createError).scaledFont(.caption).foregroundStyle(.red)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.top, 4)
        } else {
            Button {
                isCreating = true
            } label: {
                Label("Новый проект", systemImage: "plus")
                    .scaledFont(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
    }

    private func create() {
        do {
            let path = try store.createProject(named: newName, firstStage: mode?.stageList.first)
            expanded.insert(path)
            isCreating = false
            newName = ""
            createError = nil
        } catch {
            createError = error.localizedDescription
        }
    }
}

private struct FolderProjectRow: View {
    @Environment(\.panelCalm) private var panelCalm
    let project: FolderProject
    let mode: Profile?
    let stages: [String]
    let metrics: [FolderMetric]
    let wordsPerMinute: Int
    @Binding var isExpanded: Bool

    @Environment(FolderProjectStore.self) private var store
    @Environment(CalendarStore.self) private var calendar
    @State private var isHovered = false

    /// «просрочено 2 дн», unless the work is finished. The deadline itself may not be among the row's metrics.
    private var overdue: String? {
        guard let deadline = project.card.deadline, deadline < Calendar.current.startOfDay(for: .now) else { return nil }
        if let done = mode?.doneStage, project.card.stage == done { return nil }
        return CalendarText.relative(deadline, hasTime: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(panelCalm ? nil : .snappy(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                summary
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded {
                details
                    .padding(.leading, 30)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(isExpanded ? 0.05 : isHovered ? 0.08 : 0))
        )
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "chevron.right")
                .scaledFont(.caption2, weight: .semibold)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .flipsForRightToLeftLayoutDirection(true)
                .frame(width: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let stage = project.card.stage {
                        StageChip(stage: stage, index: stages.firstIndex(of: stage), count: stages.count)
                    }
                }
                let line = metrics.compactMap { $0.text(for: project, wordsPerMinute: wordsPerMinute) }
                if !line.isEmpty || overdue != nil {
                    HStack(spacing: 6) {
                        if !line.isEmpty {
                            Text(line.joined(separator: " · ")).foregroundStyle(.secondary)
                        }
                        if let overdue {
                            Text(overdue).foregroundStyle(.red).layoutPriority(1)
                        }
                    }
                    .scaledFont(.caption)
                    .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !stages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Этап").scaledFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                    FlowLayout(spacing: 4) {
                        ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                            Button {
                                store.setStage(stage, of: project)
                                Task { await calendar.refresh() }
                            } label: {
                                StageChip(stage: stage, index: index, count: stages.count, isSelected: project.card.stage == stage)
                            }
                            .buttonStyle(.plain)
                            .help(project.card.stage == stage ? String(localized: "Текущий этап") : String(localized: "Перевести на этап «\(stage)» (пишется в проект.md)"))
                        }
                    }
                }
            }
            if let format = project.card.values[.format] ?? project.card.values[.platform] {
                Text(format).scaledFont(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Папка") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) }
                if let main = project.mainFile {
                    Button(main) { NSWorkspace.shared.open(URL(fileURLWithPath: project.path).appending(path: main)) }
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Главный файл — по нему считаются слова и хронометраж")
                }
                if project.hasCardFile {
                    let card = ProjectCardFile.path(in: project.path)
                    Button((card as NSString).lastPathComponent) { NSWorkspace.shared.open(URL(fileURLWithPath: card)) }
                } else {
                    Button("Создать \(ProjectCardFile.fileName)") { store.createCard(for: project, firstStage: stages.first) }
                        .help("Карточка проекта: этап, дедлайн, дата публикации, формат, главный файл")
                }
            }
            .buttonStyle(.link)
            .scaledFont(.caption)
            if let mode {
                ProjectCommandsView(project: project, mode: mode)
            }
        }
    }
}

/// A stage name on a colour that moves from blue (start) to green (done).
struct StageChip: View {
    let stage: String
    let index: Int?
    let count: Int
    var isSelected = true

    private var color: Color {
        guard let index, count > 1 else { return .gray }
        let progress = Double(index) / Double(count - 1)
        return Color(hue: 0.6 - 0.27 * progress, saturation: 0.65, brightness: 0.62)
    }

    var body: some View {
        Text(stage)
            .scaledFont(.caption2, weight: .medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(isSelected ? 0.85 : 0.18)))
            .foregroundStyle(isSelected ? .white : .primary)
            .lineLimit(1)
    }
}
