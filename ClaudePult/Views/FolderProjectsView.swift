import AppKit
import SwiftUI

/// The projects block of a folder mode (SPEC-modes §3): one row per folder with its stage and metrics, expanding
/// into stage switching and file actions; «Новый проект» at the bottom.
struct FolderProjectsView: View {
    @Environment(FolderProjectStore.self) private var store
    @Environment(ModeStore.self) private var modes
    @State private var expanded: Set<String> = []
    @State private var newName = ""
    @State private var isCreating = false
    @State private var createError: String?

    private var mode: Mode? { modes.current }

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
                Text(store.rootFolder == nil ? "Папка пуста." : "Проектов пока нет: каждая папка внутри «\(PathText.tilde(store.rootFolder ?? ""))» — проект.")
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
    let project: FolderProject
    let stages: [String]
    let metrics: [FolderMetric]
    let wordsPerMinute: Int
    @Binding var isExpanded: Bool

    @Environment(FolderProjectStore.self) private var store
    @State private var isHovered = false

    private var overdue: Bool {
        guard let deadline = project.card.deadline else { return false }
        return deadline < Calendar.current.startOfDay(for: .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
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
                if !line.isEmpty {
                    Text(line.joined(separator: " · "))
                        .scaledFont(.caption)
                        .foregroundStyle(overdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
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
                    FlowRow(spacing: 4) {
                        ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                            Button {
                                store.setStage(stage, of: project)
                            } label: {
                                StageChip(stage: stage, index: index, count: stages.count, isSelected: project.card.stage == stage)
                            }
                            .buttonStyle(.plain)
                            .help(project.card.stage == stage ? "Текущий этап" : "Перевести на этап «\(stage)» (пишется в проект.md)")
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
                    Button(ProjectCardFile.fileName) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: project.path).appending(path: ProjectCardFile.fileName))
                    }
                } else {
                    Button("Создать \(ProjectCardFile.fileName)") { store.createCard(for: project, firstStage: stages.first) }
                        .help("Карточка проекта: этап, дедлайн, дата публикации, формат, главный файл")
                }
            }
            .buttonStyle(.link)
            .scaledFont(.caption)
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
        return Color(hue: 0.6 - 0.27 * progress, saturation: 0.65, brightness: 0.85)
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

/// Lays children out left to right, wrapping to the next line.
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
