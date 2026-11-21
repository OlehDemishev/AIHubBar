import Foundation
import Observation

/// Runs batches (SPEC-content §5): one background run per project, one after another and never in parallel, so a
/// batch does not burn the limit at once; near a limit it waits, as single runs do; one summary at the end. The
/// queue is kept in `batches.json`, so a batch left for the night survives a restart.
@MainActor
@Observable
final class BatchRunner {
    private(set) var batches: [Batch] = []

    private let engine: CommandEngine
    private let url: URL
    private var loop: Task<Void, Never>?

    // What the runner asks the rest of the app; the tests answer here.
    @ObservationIgnored var profile: @MainActor (String) -> Profile? = { _ in nil }
    /// Claude's limit holds background work right now.
    @ObservationIgnored var isHeld: @MainActor () -> Bool = { false }
    @ObservationIgnored var nightStart: @MainActor (Date) -> Date = { $0 }
    /// When the session limit resets, if known.
    @ObservationIgnored var resetsAt: @MainActor () -> Date? = { nil }
    @ObservationIgnored var announce: @MainActor (_ batch: Batch) -> Void = { _ in }

    init(engine: CommandEngine, url: URL = SessionFiles.supportDirectory.appending(path: "batches.json")) {
        self.engine = engine
        self.url = url
        batches = Self.load(url)
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// When a batch asked for `when` starts.
    func startDate(_ when: Batch.When, now: Date = .now) -> Date {
        switch when {
        case .now: now
        case .night: nightStart(now)
        // Two minutes after the reset, as single runs; in an hour when the reset is not known.
        case .afterReset: (resetsAt() ?? now.addingTimeInterval(3600)).addingTimeInterval(120)
        }
    }

    @discardableResult
    func add(_ template: CommandTemplate, projects: [FolderProject], mode: Profile, service: AIService, text: String?,
             when: Batch.When, now: Date = .now) -> Batch? {
        guard !projects.isEmpty, Batch.canRun(service, mode: mode) else { return nil }
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let batch = Batch(
            id: UUID().uuidString, template: template, profileID: mode.id, serviceID: service.id,
            text: text?.isEmpty == false ? text : nil, when: when, startAt: startDate(when, now: now),
            items: projects.map { Batch.Item(projectPath: $0.path, name: $0.name) }
        )
        batches.append(batch)
        save()
        AppLog.info("Batch «\(template.title)»: \(projects.count) projects, \(when.rawValue), starts \(batch.startAt.ISO8601Format())")
        tick(now: now)
        return batch
    }

    /// «Отменить»: what has not started is dropped; the project being worked on finishes.
    func cancel(_ id: String) {
        guard let index = batches.firstIndex(where: { $0.id == id }) else { return }
        batches[index].items.removeAll { $0.state == .waiting }
        if batches[index].items.isEmpty { batches.remove(at: index) }
        save()
    }

    /// «Убрать»: a finished batch leaves the list.
    func dismiss(_ id: String) {
        batches.removeAll { $0.id == id && $0.isFinished }
        save()
    }

    /// One step: looks at what is running, then starts the next project — one at a time over all batches.
    func tick(now: Date = .now) {
        let before = batches
        for index in batches.indices { settle(&batches[index]) }
        let busy = batches.contains { $0.runningIndex != nil }
        if !busy, let index = batches.firstIndex(where: { !$0.isFinished && $0.startAt <= now }) {
            if !(batches[index].waitsForLimit && isHeld()) { startNext(&batches[index]) }
        }
        for index in batches.indices where batches[index].isFinished && !batches[index].announced {
            batches[index].announced = true
            announce(batches[index])
            AppLog.info("Batch «\(batches[index].template.title)» finished: \(batches[index].doneCount) of \(batches[index].items.count)")
        }
        if batches != before { save() }
    }

    /// The running project's command finished, or was lost with a restart.
    private func settle(_ batch: inout Batch) {
        guard let index = batch.runningIndex else { return }
        let item = batch.items[index]
        guard let file = item.resultFile else {
            batch.items[index].state = .failed
            return
        }
        switch engine.state(ofResult: file, projectPath: item.projectPath) {
        case .done:
            batch.items[index].state = .done
        case let .failed(message):
            batch.items[index].state = .failed
            batch.items[index].note = message
        case .running, .background:
            break
        case .openedInTerminal, nil:
            // Nothing knows about it any more: a model by API was working when the app was closed.
            let exists = FileManager.default.fileExists(atPath: file)
            batch.items[index].state = exists ? .done : .failed
            if !exists { batch.items[index].note = String(localized: "прервано: приложение было закрыто") }
        }
    }

    private func startNext(_ batch: inout Batch) {
        guard let index = batch.nextIndex else { return }
        let item = batch.items[index]
        guard let mode = profile(batch.profileID), let service = AIService(id: batch.serviceID), Batch.canRun(service, mode: mode) else {
            fail(&batch, index, String(localized: "профиля или сервиса больше нет"))
            return
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.projectPath, isDirectory: &isFolder), isFolder.boolValue else {
            fail(&batch, index, String(localized: "папки больше нет"))
            return
        }
        // Read now, not when the batch was made: at night the main file may be another one.
        let project = FolderScanner.project(URL(fileURLWithPath: item.projectPath), resultPatterns: mode.resultPatterns)
        // Quiet: a batch of ten is one summary at the end, not ten banners and one more.
        batch.items[index].resultFile = engine.run(batch.template, project: project, mode: mode, service: service, text: batch.text, quiet: true)
        batch.items[index].state = .running
        AppLog.info("Batch «\(batch.template.title)»: \(index + 1) of \(batch.items.count) started — \(item.name)")
    }

    private func fail(_ batch: inout Batch, _ index: Int, _ note: String) {
        batch.items[index].state = .failed
        batch.items[index].note = note
    }

    // MARK: Files

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Finished batches older than a day are not read back.
    static func load(_ url: URL, now: Date = .now) -> [Batch] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let batches = try? decoder.decode([Batch].self, from: data) else { return [] }
        return batches.filter { !($0.isFinished && now.timeIntervalSince($0.startAt) > 86_400) }
    }

    private func save() {
        AppLog.attempt("Batches not saved") {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(batches).write(to: url, options: .atomic)
        }
    }
}
