import Foundation
import Observation

/// Folder projects of the current mode (SPEC-modes §3): scanned on panel open if older than 60 s and every 5 min.
/// Writes only `проект.md` (stage changes, a new card) and new project folders — never other files.
@MainActor
@Observable
final class FolderProjectStore {
    private(set) var projects: [FolderProject] = []
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    private let settings: AppSettings
    private var loop: Task<Void, Never>?
    private var scannedSource: ProjectSource?

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isActive: Bool { settings.activeSource.isFolders }

    /// The projects folder of a `.folders` source; new projects go there.
    var rootFolder: String? {
        if case let .folders(path) = settings.activeSource { return PathText.expand(path) }
        return nil
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }
    }

    func refreshIfStale() {
        guard !isRefreshing else { return }
        if scannedSource == settings.activeSource, let lastUpdated, Date.now.timeIntervalSince(lastUpdated) < 60 { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        let source = settings.activeSource
        guard source.isFolders else {
            projects = []
            scannedSource = source
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let started = ContinuousClock.now
        let scanned = await Task.detached(priority: .utility) { FolderScanner.scan(source: source) }.value
        projects = scanned
        scannedSource = source
        lastUpdated = .now
        let folder = source.folder ?? ""
        lastError = folderMissing(source) ? String(localized: "Папки нет: \(folder)") : nil
        AppLog.info("Folder projects: \(scanned.count) in \((ContinuousClock.now - started).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))")
    }

    private func folderMissing(_ source: ProjectSource) -> Bool {
        source.folder.map { !FileManager.default.fileExists(atPath: PathText.expand($0)) } ?? false
    }

    /// Sets «Этап:» in the project's card, creating the card if there is none.
    func setStage(_ stage: String, of project: FolderProject) {
        update(project) { ProjectCardFile.setting(.stage, to: stage, in: $0) }
    }

    func createCard(for project: FolderProject, firstStage: String?) {
        let url = URL(fileURLWithPath: ProjectCardFile.path(in: project.path))
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        write(ProjectCardFile.template(name: project.name, stage: firstStage), to: url)
        Task { await refresh() }
    }

    enum CreateError: LocalizedError {
        case noRoot, badName, exists

        var errorDescription: String? {
            switch self {
            case .noRoot: String(localized: "У этого режима нет папки проектов")
            case .badName: String(localized: "Название не подходит для папки")
            case .exists: String(localized: "Такая папка уже есть")
            }
        }
    }

    /// A new folder with a card in the mode's projects folder.
    @discardableResult
    func createProject(named rawName: String, firstStage: String?) throws -> String {
        guard let root = rootFolder else { throw CreateError.noRoot }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else { throw CreateError.badName }
        let folder = URL(fileURLWithPath: root).appending(path: name)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw CreateError.exists }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        write(ProjectCardFile.template(name: name, stage: firstStage), to: folder.appending(path: ProjectCardFile.fileName))
        AppLog.info("Folder project created: \(folder.path)")
        Task { await refresh() }
        return folder.path
    }

    private func update(_ project: FolderProject, _ change: (String) -> String) {
        let url = URL(fileURLWithPath: ProjectCardFile.path(in: project.path))
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ProjectCardFile.template(name: project.name, stage: nil)
        write(change(current), to: url)
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].card = ProjectCardFile.parse(change(current))
            projects[index].hasCardFile = true
        }
    }

    private func write(_ text: String, to url: URL) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            lastError = String(localized: "Не удалось записать \(url.lastPathComponent): \(error.localizedDescription)")
            AppLog.error("Writing \(url.path) failed: \(error.localizedDescription)")
        }
    }
}
