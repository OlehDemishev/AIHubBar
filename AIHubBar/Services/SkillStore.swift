import Foundation
import Observation

/// The Skills Catalog for the panel (docs/specs/SPEC-skills.md): finds the skills of Claude Code, Codex, Cursor and
/// Gemini CLI on this Mac, checks each with `SkillScanner`, counts which ones the agents used, and keeps what the
/// «Скиллы» block and section show. The catalog's file is used from one queue only; nothing from a skill is run.
@MainActor
@Observable
final class SkillStore {
    /// What the «Скиллы» block shows.
    struct Alert: Identifiable, Equatable, Sendable {
        var row: SkillCatalog.Row
        /// The first finding that made it dangerous.
        var rule: String?
        var id: Int { row.id }
    }

    struct Summary: Equatable, Sendable {
        var byVerdict: [SkillVerdict: Int] = [:]
        /// Dangerous skills, the most dangerous first, each with the rule that decided it.
        var dangerous: [Alert] = []
        var mostUsed: [SkillCatalog.Used] = []
        /// Installed skills nobody used for 30 days.
        var unused = 0
        var total: Int { byVerdict.values.reduce(0, +) }
    }

    private(set) var summary = Summary()
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    private(set) var failure: String?

    var isActive: () -> Bool = { true }

    /// Something in the block needs attention: a dangerous skill is installed.
    var hasAlert: Bool { !summary.dangerous.isEmpty }

    private let settings: AppSettings
    private let roots: @Sendable (String) -> SkillRoots
    private let worker: Worker
    private var loop: Task<Void, Never>?

    static var databasePath: String { SessionFiles.supportDirectory.appending(path: "skills/catalog.db").path }

    init(settings: AppSettings, path: String = SkillStore.databasePath, roots: @escaping @Sendable (String) -> SkillRoots = SkillStore.realRoots) {
        self.settings = settings
        self.roots = roots
        worker = Worker(path: path)
    }

    /// The folders the agents load skills from on this Mac, with the projects folder of the settings.
    nonisolated static func realRoots(projectsDirectory: String) -> SkillRoots {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let claude = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appending(path: ".claude")
        let codex = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appending(path: ".codex")
        return SkillRoots(home: home, claudeDir: claude, codexDir: codex, projectsDir: URL(fileURLWithPath: (projectsDirectory as NSString).expandingTildeInPath))
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if self?.isActive() == true { await self?.refresh() }
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    func refreshIfStale() {
        guard isActive() else { return }
        if let lastUpdated, Date.now.timeIntervalSince(lastUpdated) < 5 * 60 { return }
        Task { await refresh() }
    }

    /// Looks through the agents' folders and logs, checks what is new or changed, and reads the block's summary.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let roots = roots(settings.projectsDirectory)
        let result = await worker.run { catalog -> Result<Summary, Error> in
            Result {
                let refreshed = try catalog.refreshInstalled(roots)
                try catalog.readUsage(roots, since: .now.addingTimeInterval(-30 * 86400))
                AppLog.info("skills: \(refreshed.found) found, \(refreshed.scanned) checked, \(refreshed.removed) gone")
                return try Self.summary(catalog)
            }
        }
        switch result {
        case .success(let summary):
            self.summary = summary
            failure = nil
        case .failure(let error):
            failure = String(describing: error)
            AppLog.error("skills: \(error)")
        }
        lastUpdated = .now
    }

    nonisolated private static func summary(_ catalog: SkillCatalog) throws -> Summary {
        let all = try catalog.search(SkillCatalog.Filters())
        let installed = all.rows.filter(\.isInstalled)
        var byVerdict: [SkillVerdict: Int] = [:]
        for row in installed { byVerdict[row.verdict, default: 0] += 1 }
        let dangerous = try installed.filter { $0.verdict == .dangerous }.map { row in
            Alert(row: row, rule: try catalog.card(row.id)?.assessment.reasons.first?.finding.rule)
        }
        return Summary(byVerdict: byVerdict, dangerous: dangerous,
                       mostUsed: try catalog.mostUsed(since: .now.addingTimeInterval(-7 * 86400), limit: 3),
                       unused: try catalog.unused(since: .now.addingTimeInterval(-30 * 86400)))
    }

    // MARK: - For the section

    func search(_ filters: SkillCatalog.Filters) async -> SkillCatalog.Result {
        await worker.run { (try? $0.search(filters)) ?? SkillCatalog.Result() }
    }

    func card(_ id: Int) async -> SkillCatalog.Card? {
        await worker.run { try? $0.card(id) }
    }

    func preview(_ id: Int, file: String) async -> SkillCatalog.Preview? {
        await worker.run { try? $0.preview(id, file: file) }
    }

    func facets() async -> SkillCatalog.Facets {
        await worker.run { (try? $0.facets()) ?? SkillCatalog.Facets() }
    }

    /// Bumped when a mark or a saved filter changes: the section reads its list again.
    private(set) var marksVersion = 0

    func setFavorite(_ id: Int, _ favorite: Bool) async {
        await worker.run { catalog in
            do { try catalog.setFavorite(id, favorite) } catch { AppLog.error("skills: favourite: \(error)") }
        }
        marksVersion += 1
    }

    func setNote(_ id: Int, _ note: String) async {
        await worker.run { catalog in
            do { try catalog.setNote(id, note) } catch { AppLog.error("skills: note: \(error)") }
        }
        marksVersion += 1
    }

    func savedFilters() async -> [SkillCatalog.SavedFilter] {
        await worker.run { (try? $0.savedFilters()) ?? [] }
    }

    func saveFilter(_ name: String, _ filters: SkillCatalog.Filters) async {
        await worker.run { catalog in
            do { try catalog.saveFilter(name, filters) } catch { AppLog.error("skills: saving a filter: \(error)") }
        }
        marksVersion += 1
    }

    func deleteFilter(_ id: Int) async {
        await worker.run { catalog in
            do { try catalog.deleteFilter(id) } catch { AppLog.error("skills: deleting a filter: \(error)") }
        }
        marksVersion += 1
    }

    /// The catalog's file, opened on first use and used from one queue.
    final class Worker: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.demishev.claudepult.skills", qos: .utility)
        private let path: String
        private var catalog: SkillCatalog?

        init(path: String) { self.path = path }

        func run<T: Sendable>(_ work: @escaping @Sendable (SkillCatalog) -> T) async -> T where T: Sendable {
            await withCheckedContinuation { continuation in
                queue.async {
                    do {
                        if self.catalog == nil { self.catalog = try SkillCatalog(path: self.path) }
                        // swiftlint:disable:next force_unwrapping
                        continuation.resume(returning: work(self.catalog!))
                    } catch {
                        AppLog.error("skills: the catalog can't be opened: \(error)")
                        // A catalog in memory keeps the panel working; nothing is kept between runs then.
                        let fallback = (try? SkillCatalog(path: ":memory:"))
                        self.catalog = fallback
                        if let fallback { continuation.resume(returning: work(fallback)) } else { fatalError("SQLite is not available") }
                    }
                }
            }
        }
    }
}
