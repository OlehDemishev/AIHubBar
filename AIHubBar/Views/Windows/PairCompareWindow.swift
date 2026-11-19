import AppKit
import SwiftUI

/// «Сравнение»: the two runs of a pair side by side — the outcome, the answer and the files each one changed.
struct PairCompareWindow: View {
    @Environment(RunStore.self) private var runs
    @Environment(\.openWindow) private var openWindow
    @State private var changes: [String: SessionChanges] = [:]
    @State private var copied = false
    @State private var shown: ShownDiff?

    /// The diff in the sheet: one side's file, or one variant against the other.
    private struct ShownDiff: Identifiable {
        var id = UUID()
        var title: String
        var lines: [PairCompare.DiffLine]
        var cut: Bool
    }

    private var sides: [BackgroundRun]? { runs.selectedPair.flatMap { PairCompare.sides($0, runs: runs.runs) } }

    var body: some View {
        Group {
            if let sides {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(sides[0].project): \(sides[0].task)")
                        .font(.headline)
                        .lineLimit(2)
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(sides) { run in
                            side(run, common: PairCompare.common(changes[sides[0].id], changes[sides[1].id]))
                        }
                    }
                    footer(sides)
                }
                .padding(16)
            } else {
                Text("Нет пары задач для сравнения")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 380)
        .sheet(item: $shown) { diff in diffSheet(diff) }
        .task(id: runs.selectedPair) {
            changes = [:]
            while !Task.isCancelled {
                guard let sides else { return }
                for run in sides {
                    if let read = await SessionChangesStore.read(folder: run.folder, since: run.startedAt) { changes[run.id] = read }
                }
                if sides.allSatisfy(\.state.isFinished) { return }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func side(_ run: BackgroundRun, common: Set<String>) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(run.state.title).foregroundStyle(run.state.color)
                    if let branch = run.worktreeBranch { Text(branch).monospaced().lineLimit(1).truncationMode(.middle) }
                    Spacer(minLength: 0)
                    if let changes = changes[run.id], !changes.isEmpty { Text(changes.summary).monospacedDigit() }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(RunMessage.outcomeText(run))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let changes = changes[run.id] {
                            if changes.isEmpty {
                                Text("Изменений в файлах нет").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(changes.files) { file in
                                Button {
                                    Task {
                                        let parsed = PairCompare.diffLines(await PairCompare.fileDiff(run, path: file.path))
                                        shown = ShownDiff(title: "\(run.agentTitle): \(file.path)", lines: parsed.lines, cut: parsed.cut)
                                    }
                                } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: common.contains(file.path) ? "arrow.left.arrow.right" : "doc")
                                        .foregroundStyle(common.contains(file.path) ? Color.accentColor : Color.secondary)
                                        .help(common.contains(file.path) ? Text("Этот файл изменили оба") : Text(verbatim: ""))
                                        .accessibilityLabel(common.contains(file.path) ? Text("Этот файл изменили оба") : Text(verbatim: ""))
                                    Text(file.path).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    if let added = file.added, added > 0 { Text(verbatim: "+\(added)").foregroundStyle(.green) }
                                    if let removed = file.removed, removed > 0 { Text(verbatim: "−\(removed)").foregroundStyle(.red) }
                                }
                                .font(.caption.monospaced())
                                .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Показать изменения в файле")
                            }
                        }
                    }
                }
                HStack {
                    Button("Журнал") {
                        runs.selectedLogRunID = run.id
                        openWindow(.runLog)
                    }
                    Button("Открыть папку") { NSWorkspace.shared.open(URL(fileURLWithPath: run.folder)) }
                }
                .controlSize(.small)
            }
            .padding(4)
        } label: {
            Text(run.agentTitle).font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func footer(_ sides: [BackgroundRun]) -> some View {
        let common = PairCompare.common(changes[sides[0].id], changes[sides[1].id])
        HStack {
            if !common.isEmpty {
                Label("Оба изменили файлов: \(common.count)", systemImage: "arrow.left.arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if PairCompare.diffCommand(sides) != nil, sides.allSatisfy(\.state.isFinished) {
                Button("Различия между вариантами") {
                    Task {
                        let parsed = PairCompare.diffLines(await PairCompare.betweenDiff(sides))
                        shown = ShownDiff(title: "\(sides[0].agentTitle) → \(sides[1].agentTitle)", lines: parsed.lines, cut: parsed.cut)
                    }
                }
                .help("Чем вариант второго сервиса отличается от варианта первого: то, что закоммичено в обеих ветках")
            }
            if let command = PairCompare.diffCommand(sides) {
                Button(copied ? "Скопировано" : "Скопировать команду сравнения") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                .help(Text(verbatim: command))
            }
        }
    }

    private func diffSheet(_ diff: ShownDiff) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: diff.title).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Закрыть") { shown = nil }.keyboardShortcut(.cancelAction)
            }
            if diff.lines.isEmpty {
                Text("Различий нет")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.lines) { line in
                            Text(verbatim: line.text.isEmpty ? " " : line.text)
                                .font(line.kind == .file ? .caption.monospaced().weight(.semibold) : .caption.monospaced())
                                .foregroundStyle(color(line.kind))
                                .padding(.top, line.kind == .file ? 6 : 0)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if diff.cut {
                    Text("Показано начало: строк \(PairCompare.diffLimit). Целиком — командой сравнения в терминале.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 620, idealWidth: 760, minHeight: 360, idealHeight: 520)
    }

    private func color(_ kind: PairCompare.DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green
        case .removed: .red
        case .hunk: .secondary
        case .file, .context: .primary
        }
    }
}
