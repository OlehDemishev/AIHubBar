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
        /// Installed skills the person put on the block list.
        var blocked: [SkillCatalog.Row] = []
        /// Copies the catalog installed whose source has a newer version.
        var updates: [SkillCatalog.Update] = []
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
    var hasAlert: Bool { !summary.dangerous.isEmpty || !summary.blocked.isEmpty }

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
    func refresh(force: Bool = false) async {
        guard force || !isRefreshing else { return }
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
                       blocked: installed.filter(\.isBlocked),
                       updates: try catalog.updates(),
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

    /// The entry that stands for a skill now: the same content, or else the same name.
    func locate(_ row: SkillCatalog.Row) async -> Int? {
        await worker.run { try? $0.locate(contentHash: row.contentHash, name: row.name, kind: row.kind) }
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

    // MARK: - Changing what is installed (SkillManage)

    /// Where what is taken out of an agent's folder is kept, so it can be put back.
    static var backupsFolder: URL { SessionFiles.supportDirectory.appending(path: "skills/backups") }

    private var place: SkillCatalog.Place { SkillCatalog.Place(roots: roots(settings.projectsDirectory), backups: Self.backupsFolder) }

    typealias Outcome<T: Sendable> = Result<T, SkillCatalog.Refusal>

    /// Runs one step on the catalog's queue; a step that changed something reads the block's summary again.
    private func act<T: Sendable>(changes: Bool, _ work: @escaping @Sendable (SkillCatalog, SkillCatalog.Place) throws -> T) async -> Outcome<T> {
        let place = self.place
        let result: Outcome<T> = await worker.run { catalog in
            do { return .success(try work(catalog, place)) } catch let refusal as SkillCatalog.Refusal {
                return .failure(refusal)
            } catch {
                AppLog.error("skills: \(error)")
                return .failure(SkillCatalog.Refusal(code: error.localizedDescription))
            }
        }
        if changes {
            if case .success = result { AppLog.info("skills: changed what is installed") }
            await refresh(force: true)
            marksVersion += 1
        }
        return result
    }

    func planInstall(_ id: Int, for agent: SkillAgent) async -> Outcome<SkillCatalog.Plan> {
        await act(changes: false) { try $0.planInstall(id, for: agent, $1) }
    }

    func install(_ id: Int, for agent: SkillAgent, contentHash: String, acknowledged: Bool) async -> Outcome<SkillCatalog.Done> {
        await act(changes: true) { try $0.install(id, for: agent, contentHash: contentHash, acknowledged: acknowledged, $1) }
    }

    func remove(_ installPath: String) async -> Outcome<SkillCatalog.Done> {
        await act(changes: true) { try $0.remove(installPath, $1) }
    }

    func setEnabled(_ installPath: String, _ on: Bool) async -> Outcome<SkillCatalog.Done> {
        await act(changes: true) { try $0.setEnabled(installPath, on, $1) }
    }

    func restore(_ journalID: Int) async -> Outcome<SkillCatalog.Done> {
        await act(changes: true) { try $0.restore(journalID, $1) }
    }

    func planUpdate(_ installPath: String) async -> Outcome<SkillCatalog.Plan> {
        await act(changes: false) { try $0.planUpdate(installPath, $1) }
    }

    func update(_ installPath: String, contentHash: String, acknowledged: Bool) async -> Outcome<SkillCatalog.Done> {
        await act(changes: true) { try $0.update(installPath, contentHash: contentHash, acknowledged: acknowledged, $1) }
    }

    func diff(_ installPath: String) async -> [SkillCatalog.FileDiff] {
        await worker.run { (try? $0.diff(installPath)) ?? [] }
    }

    func journal() async -> [SkillCatalog.LogRow] {
        await worker.run { (try? $0.journal()) ?? [] }
    }

    /// A folder the person chose: checked and listed, installed nowhere.
    func importFolder(_ folder: URL) async -> Outcome<Int> {
        await act(changes: true) { catalog, place in try catalog.importFolder(folder, now: place.now) }
    }

    // MARK: - Complaints and the block list (SkillReports)

    func report(_ id: Int, reason: SkillCatalog.ReportReason, details: String) async -> Outcome<Int> {
        let result: Outcome<Int> = await act(changes: false) { catalog, place in try catalog.report(id, reason: reason, details: details, now: place.now) }
        marksVersion += 1
        return result
    }

    func reports(of row: SkillCatalog.Row) async -> [SkillCatalog.Report] {
        await worker.run { (try? $0.reports(kind: row.kind, name: row.name)) ?? [] }
    }

    func markSent(_ reportID: Int, to place: String) async {
        _ = await act(changes: false) { catalog, _ in try catalog.markSent(reportID, to: place) }
        marksVersion += 1
    }

    func deleteReport(_ reportID: Int) async {
        _ = await act(changes: false) { catalog, _ in try catalog.deleteReport(reportID) }
        marksVersion += 1
    }

    func blockOf(_ id: Int) async -> SkillCatalog.Block? {
        await worker.run { try? $0.blockOf(id) }
    }

    func block(_ id: Int, everyVersion: Bool, reason: String) async {
        _ = await act(changes: true) { catalog, place in try catalog.block(id, everyVersion: everyVersion, reason: reason, now: place.now) }
    }

    func unblock(_ id: Int) async {
        _ = await act(changes: true) { catalog, _ in try catalog.unblock(id) }
    }

    func forget(_ id: Int) async {
        _ = await act(changes: true) { catalog, _ in try catalog.forget(id) }
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
