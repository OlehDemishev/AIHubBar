import AppKit
import SwiftUI

/// «Журнал» window: a readable view of a background run's stream-json log, refreshed while it runs.
struct RunLogView: View {
    @Environment(RunStore.self) private var runs
    @Environment(VersionKeeper.self) private var versions
    @Environment(\.openWindow) private var openWindow
    /// There is a version of the project taken before this run: «Что изменилось» has something to show.
    @State private var hasVersion = false
    @State private var entries: [StreamJSON.Entry] = []
    @State private var followsEnd = true
    @Environment(AppSettings.self) private var settings
    /// Read from the log for a run finished before the app kept its usage.
    @State private var logUsage: RunUsage?

    private var run: BackgroundRun? { runs.selectedLogRunID.flatMap(runs.run(id:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let run {
                header(run)
                Divider()
                log
            } else {
                Text("Нет выбранной фоновой задачи")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .task(id: runs.selectedLogRunID) {
            hasVersion = false
            logUsage = nil
            if let run, versions.isActive() { hasVersion = await versions.hasVersion(projectPath: run.projectPath, before: run.startedAt) }
        }
        .task(id: runs.selectedLogRunID) {
            while !Task.isCancelled {
                if let run {
                    let url = run.logURL
                    let (parsed, usage) = await Task.detached(priority: .utility) {
                        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                        return (StreamJSON.entries(fromLog: text), StreamJSON.usage(fromLog: text))
                    }.value
                    if parsed != entries { entries = parsed }
                    if usage != logUsage { logUsage = usage }
                    if run.state.isFinished, !entries.isEmpty { break }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func header(_ run: BackgroundRun) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(run.project): \(run.task)")
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(run.state.title).foregroundStyle(run.state.color)
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if let branch = run.worktreeBranch { Text(branch).monospaced() }
                    if let usage = run.usage ?? logUsage {
                        // Codex names no cost: the person's own OpenAI price, when there is one.
                        let provider = run.agent == CodexExec.agent ? APIProvider.openai : .anthropic
                        Text(verbatim: usage.line(price: settings.aiServices.prices[provider.rawValue]))
                            .monospacedDigit()
                            .help("Сколько токенов ушло на задачу и что тот же объём стоит через API. По подписке за задачу ничего не списывается.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if run.isPaused {
                Button("Продолжить сейчас") { runs.resume(run.id) }
                    .help("На паузе до сброса лимита")
            }
            if run.state == .running {
                ConfirmedButton(title: "Остановить", message: run.task, confirm: "Остановить", role: nil) {
                    runs.stop(run.id)
                } label: { Text("Остановить") }
            }
            if hasVersion {
                Button("Что изменилось") {
                    versions.shown = .init(projectPath: run.projectPath, before: run.startedAt)
                    openWindow(.versions)
                }
                .help("Тексты проекта до этой задачи и сейчас")
            }
            Button("Файл журнала") {
                NSWorkspace.shared.activateFileViewerSelecting([run.logURL])
            }
        }
        .padding(12)
    }

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        row(entry).id(entry.id)
                    }
                    // On screen only while the log is scrolled to its end.
                    Color.clear.frame(height: 1)
                        .onAppear { followsEnd = true }
                        .onDisappear { followsEnd = false }
                }
                .padding(12)
                .textSelection(.enabled)
            }
            .onChange(of: entries.count) {
                // New lines pull the view down only for someone reading the end: scrolled up, earlier output stays put.
                if followsEnd, let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: StreamJSON.Entry) -> some View {
        switch entry.kind {
        case .text:
            Text(entry.text)
        case .tool:
            Label(entry.text, systemImage: "wrench.and.screwdriver")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
        case .result:
            Label(entry.text, systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .error:
            Label(entry.text, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}

extension BackgroundRun.State {
    var title: String {
        switch self {
        case .running: String(localized: "выполняется")
        case .succeeded: String(localized: "готово")
        case .failed: String(localized: "ошибка")
        case .stopped: String(localized: "остановлено")
        case .timedOut: String(localized: "лимит времени")
        }
    }

    var color: Color {
        switch self {
        case .running: .blue
        case .succeeded: .green
        case .failed, .timedOut: .red
        case .stopped: .secondary
        }
    }

    /// The session state shown in the «Сессии» block.
    var sessionState: Session.State {
        switch self {
        case .running: .running
        case .succeeded: .done
        case .failed, .timedOut: .error
        case .stopped: .ended
        }
    }
}
