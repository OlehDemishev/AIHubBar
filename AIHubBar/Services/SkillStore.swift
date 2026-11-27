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
        /// Names an agent could load in two different versions.
        var conflicts = 0
        /// Changes outside the catalog the person hasn't looked at.
        var unseenChanges = 0
        /// Installed skills nobody used for 30 days.
        var unused = 0
        var total: Int { byVerdict.values.reduce(0, +) }
    }

    private(set) var summary = Summary()
    /// A skill a notification asked to show: the panel opens its card and clears this.
    var pendingSkill: Int?
    /// The block's «Замечено вне каталога» asks the section to open on the journal.
    var opensChanges = false
    /// The block asks the section to open on «Порядок» (conflicts, copies, unused, sets).
    var opensOrder = false
    /// A project whose skills the Skills section should pick when it opens: «Скиллы для проекта» (name, path).
    var pendingProject: ProjectRef?
    /// What the catalog may install and whom the person trusts (Settings → Скиллы).
    private(set) var policy = SkillCatalog.Policy()
    private(set) var trusted: [String] = []
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
                if self?.isActive() == true {
                    await self?.refresh()
                    self?.checkSourcesIfStale()
                    self?.refreshIndexIfStale()
                }
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    func refreshIfStale() {
        guard isActive() else { return }
        checkSourcesIfStale()
        if let lastUpdated, Date.now.timeIntervalSince(lastUpdated) < 5 * 60 { return }
        Task { await refresh() }
    }

    /// Looks through the agents' folders and logs, checks what is new or changed, and reads the block's summary.
    func refresh(force: Bool = false) async {
        guard force || !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let roots = roots(settings.projectsDirectory)
        let result = await worker.run { catalog -> Result<(Summary, [SkillCatalog.Event], [SkillCatalog.Update], SkillCatalog.Policy, [String]), Error> in
            Result {
                let refreshed = try catalog.refreshInstalled(roots)
                try catalog.readUsage(roots, since: .now.addingTimeInterval(-30 * 86400))
                AppLog.info("skills: \(refreshed.found) found, \(refreshed.scanned) checked, \(refreshed.removed) gone")
                return (try Self.summary(catalog), try catalog.eventsToAnnounce(), try catalog.updatesToAnnounce(), catalog.policy, try catalog.trustedAuthors())
            }
        }
        switch result {
        case .success(let (summary, events, updates, policy, trusted)):
            self.summary = summary
            self.policy = policy
            self.trusted = trusted
            Self.announce(events, updates)
            failure = nil
        case .failure(let error):
            failure = String(describing: error)
            AppLog.error("skills: \(error)")
        }
        lastUpdated = .now
    }

    /// Notifications about skills: what appeared or changed outside the catalog, and newer versions of its copies.
    private static func announce(_ events: [SkillCatalog.Event], _ updates: [SkillCatalog.Update]) {
        // A first look after a big change (a new Mac, a restored backup) could bring dozens: one line then.
        if events.count > 3 {
            Notifier.post(id: "skills-many-\(events.last?.id ?? 0)", title: String(localized: "Скиллы изменились вне каталога: \(events.count)"),
                          body: String(localized: "Посмотрите «Замечено вне каталога» в журнале раздела «Скиллы»."), target: .none)
        } else {
            for event in events {
                let title = event.verdict == .dangerous
                    ? String(localized: "Опасный скилл: \(event.name)")
                    : event.event == "appeared" ? String(localized: "Новый скилл: \(event.name)") : String(localized: "Скилл изменился: \(event.name)")
                let body = event.event == "appeared"
                    ? String(localized: "Появился не через каталог. Оценка: \(event.verdict?.title ?? "—").")
                    : String(localized: "Изменился не через каталог. Оценка: \(event.verdict?.title ?? "—").")
                Notifier.post(id: "skills-event-\(event.id)", title: title, body: body, target: event.skillID.map { .skill(id: $0) } ?? .none)
            }
        }
        for update in updates {
            Notifier.post(id: "skills-update-\(update.toHash.prefix(12))", title: String(localized: "Новая версия скилла: \(update.name)"),
                          body: String(localized: "Оценка новой версии: \(update.verdict.title). Посмотреть изменения и обновить можно в карточке."),
                          target: update.skillID.map { .skill(id: $0) } ?? .none)
        }
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
                       conflicts: try catalog.conflicts().count,
                       unseenChanges: try catalog.unseenEvents(),
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

    // MARK: - Watching, the policy, trusted authors (SkillWatch)

    func events() async -> [SkillCatalog.Event] {
        await worker.run { (try? $0.events()) ?? [] }
    }

    func markEventsSeen() async {
        await worker.run { try? $0.markEventsSeen() }
        summary.unseenChanges = 0
    }

    func setPolicy(_ policy: SkillCatalog.Policy) async {
        await worker.run { $0.policy = policy }
        self.policy = policy
        marksVersion += 1
    }

    func trust(_ author: String) async {
        let list: [String] = await worker.run { catalog in
            try? catalog.trust(author)
            return (try? catalog.trustedAuthors()) ?? []
        }
        trusted = list
        marksVersion += 1
    }

    func distrust(_ author: String) async {
        let list: [String] = await worker.run { catalog in
            try? catalog.distrust(author)
            return (try? catalog.trustedAuthors()) ?? []
        }
        trusted = list
        marksVersion += 1
    }

    // MARK: - The AI review (SkillReview)

    /// Tokens spent through the API go to the spend log (set by the app).
    var recordSpend: (SpendRecord) -> Void = { _ in }
    /// Skills being reviewed now: one request each at a time.
    private(set) var reviewing: Set<Int> = []

    /// The remembered review of a skill's content: in the interface language, else in any.
    func review(of row: SkillCatalog.Row) async -> SkillReview.Result? {
        let language = SkillReviewer.languageName
        return await worker.run { catalog in
            (try? catalog.cachedReview(contentHash: row.contentHash, language: language)) ?? (try? catalog.anyReview(contentHash: row.contentHash)) ?? nil
        }
    }

    /// Asks a model about a skill: its files go to Claude Code (no tools) or the Anthropic API. Nothing of the skill is run.
    func requestReview(_ id: Int) async -> Outcome<SkillReview.Result> {
        guard !reviewing.contains(id) else { return .failure(.state) }
        reviewing.insert(id)
        defer { reviewing.remove(id) }
        let language = SkillReviewer.languageName
        let prepared: Outcome<(String, SkillReview.Request)> = await act(changes: false) { catalog, _ in
            let (hash, request) = try catalog.reviewRequest(id, language: language)
            return (hash, request)
        }
        guard case .success(let (hash, request)) = prepared else {
            if case .failure(let refusal) = prepared { return .failure(refusal) }
            return .failure(.missing)
        }
        guard let who = await SkillReviewer.who() else { return .failure(.init(code: "no-reviewer")) }
        let model = SkillReviewer.defaultModel
        let answer: Swift.Result<SkillReviewer.Answer, SkillCatalog.Refusal> = switch who {
        case .claudeCode(let program):
            await SkillReviewer.viaClaude(request, program: program, scratch: SessionFiles.supportDirectory.appending(path: "skills/review"), model: model)
        case .api(let key):
            await SkillReviewer.viaAPI(request, key: key, model: model)
        }
        let reply: SkillReviewer.Answer
        switch answer {
        case .success(let value): reply = value
        case .failure(let refusal):
            AppLog.error("skills: the AI review failed: \(refusal.code)")
            return .failure(refusal)
        }
        if case .api = who {
            recordSpend(SpendRecord(date: .now, provider: .anthropic, model: reply.model, inputTokens: reply.inputTokens, outputTokens: reply.outputTokens))
        }
        let parsed = SkillReview.parse(reply.text, request: request)
        let result = SkillReview.Result(verdict: parsed.verdict, valid: parsed.valid, incomplete: request.incomplete, summary: parsed.summary, findings: parsed.findings,
                                        model: reply.model, via: who.via, language: language, inputTokens: reply.inputTokens, outputTokens: reply.outputTokens,
                                        reviewedAt: SkillCatalog.now())
        AppLog.info("skills: AI review via \(who.via), \(reply.model): \(result.verdict.rawValue)\(result.valid ? "" : " (unreadable answer)")")
        let saved: Outcome<Void> = await act(changes: true) { catalog, _ in try catalog.saveReview(result, contentHash: hash) }
        if case .failure(let refusal) = saved { return .failure(refusal) }
        return .success(result)
    }

    // MARK: - The person's model: search in plain words and translation (SkillAsk)

    /// A search in plain words is running.
    private(set) var asking = false
    /// Remembered translations into the interface language, keyed by the original text.
    private(set) var translated: [String: String] = [:]
    /// Texts being translated now.
    private(set) var translating: Set<String> = []
    /// Shows the originals instead of the translations everywhere.
    var showsOriginals = false

    private var askScratch: URL { SessionFiles.supportDirectory.appending(path: "skills/ask") }

    private func spend(_ answer: SkillReviewer.Answer, _ who: SkillReviewer.Who) {
        if case .api = who {
            recordSpend(SpendRecord(date: .now, provider: .anthropic, model: answer.model, inputTokens: answer.inputTokens, outputTokens: answer.outputTokens))
        }
    }

    /// Finds skills and repositories for what the person wrote: the model gives search words, the catalog and the index
    /// are searched here, the model picks the best of what was found. Two short requests; nothing is downloaded.
    func ask(_ question: String) async -> Outcome<[SkillAsk.Pick]> {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return .failure(.state) }
        // The person's own words count too: a skill named as they wrote it is found without the model.
        let typed = question.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }.prefix(6)
        return await pick(question: question, wordsPrompt: SkillAsk.wordsPrompt(question: question, nonce: SkillReview.nonce()), extraWords: Array(typed))
    }

    /// «Скиллы для проекта»: the project's stack is read here (names only) and the model picks from the catalog and the
    /// index what would help an agent work on it.
    func askForProject(_ path: String) async -> Outcome<(SkillProjectStack, [SkillAsk.Pick])> {
        let stack = await Task.detached(priority: .userInitiated) { SkillProjectStack.read(URL(fileURLWithPath: path)) }.value
        guard !stack.isEmpty else { return .failure(.init(code: "empty-project")) }
        let summary = stack.summary()
        let result = await pick(question: SkillAsk.projectQuestion(summary), wordsPrompt: SkillAsk.projectWordsPrompt(stack: summary, nonce: SkillReview.nonce()),
                                extraWords: stack.searchWords)
        return result.map { (stack, $0) }
    }

    /// The two requests of a search: words from the model, a local search, the model's picks by number.
    private func pick(question: String, wordsPrompt: SkillReviewer.Prompt, extraWords: [String]) async -> Outcome<[SkillAsk.Pick]> {
        guard !asking else { return .failure(.state) }
        asking = true
        defer { asking = false }
        guard let who = await SkillReviewer.who() else { return .failure(.init(code: "no-reviewer")) }
        let wordsAnswer = await SkillReviewer.ask(wordsPrompt, who: who, model: SkillAsk.model, scratch: askScratch)
        guard case .success(let first) = wordsAnswer else {
            if case .failure(let refusal) = wordsAnswer { AppLog.error("skills: plain-words search failed: \(refusal.code)"); return .failure(refusal) }
            return .failure(.missing)
        }
        spend(first, who)
        guard let words = SkillAsk.words(from: first.text) else { return .failure(.init(code: "unreadable")) }
        let all = words + extraWords.filter { word in !words.contains { $0.caseInsensitiveCompare(word) == .orderedSame } }
        let items: [SkillAsk.Item] = await worker.run { (try? $0.askCandidates(words: all)) ?? [] }
        AppLog.info("skills: plain-words search via \(who.via): \(words.count) words, \(items.count) candidates")
        guard !items.isEmpty else { return .success([]) }
        let rankAnswer = await SkillReviewer.ask(SkillAsk.rankPrompt(question: question, items: items, nonce: SkillReview.nonce(), language: SkillReviewer.languageName),
                                                 who: who, model: SkillAsk.model, scratch: askScratch)
        guard case .success(let second) = rankAnswer else {
            if case .failure(let refusal) = rankAnswer { AppLog.error("skills: plain-words search failed: \(refusal.code)"); return .failure(refusal) }
            return .failure(.missing)
        }
        spend(second, who)
        guard let picks = SkillAsk.picks(from: second.text, items: items) else { return .failure(.init(code: "unreadable")) }
        return .success(picks)
    }

    /// Reads the remembered translations of these texts into the interface language.
    func loadTranslations(_ texts: [String]) async {
        let language = SkillReviewer.languageName
        let wanted = texts.filter { !$0.isEmpty && translated[$0] == nil }
        guard !wanted.isEmpty else { return }
        let found: [String: String] = await worker.run { (try? $0.translations(of: wanted, language: language)) ?? [:] }
        if !found.isEmpty { translated.merge(found) { _, new in new } }
    }

    /// Texts among these that read as another language and have no translation yet.
    func untranslated(_ texts: [String]) -> [String] {
        let code = SkillReviewer.languageCode
        var seen: Set<String> = []
        return texts.filter { !$0.isEmpty && translated[$0] == nil && !translating.contains($0) && seen.insert($0).inserted && SkillAsk.needsTranslation($0, to: code) }
    }

    /// Asks the model to translate texts into the interface language, `SkillAsk.maxTexts` at a time, and remembers them.
    func translate(_ texts: [String]) async -> Outcome<Void> {
        let wanted = Array(untranslated(texts).prefix(SkillAsk.maxTexts))
        guard !wanted.isEmpty else { return .success(()) }
        guard let who = await SkillReviewer.who() else { return .failure(.init(code: "no-reviewer")) }
        translating.formUnion(wanted)
        defer { translating.subtract(wanted) }
        let language = SkillReviewer.languageName
        let answer = await SkillReviewer.ask(SkillAsk.translatePrompt(texts: wanted, nonce: SkillReview.nonce(), language: language),
                                             who: who, model: SkillAsk.model, scratch: askScratch)
        guard case .success(let reply) = answer else {
            if case .failure(let refusal) = answer { AppLog.error("skills: translation failed: \(refusal.code)"); return .failure(refusal) }
            return .failure(.missing)
        }
        spend(reply, who)
        guard let found = SkillAsk.translations(from: reply.text, texts: wanted) else { return .failure(.init(code: "unreadable")) }
        AppLog.info("skills: translated \(found.count) of \(wanted.count) descriptions via \(who.via)")
        let model = reply.model
        let saved: Outcome<Void> = await act(changes: false) { catalog, _ in try catalog.saveTranslations(found, language: language, model: model) }
        translated.merge(found) { _, new in new }
        return saved
    }

    /// The text to show: its translation when there is one and the person hasn't asked for originals.
    func shown(_ text: String) -> String {
        showsOriginals ? text : translated[text] ?? text
    }

    // MARK: - Order: conflicts, copies, unused skills, sets, export (SkillHousekeeping)

    struct Order: Equatable, Sendable {
        var conflicts: [SkillCatalog.Group] = []
        var duplicates: [SkillCatalog.Group] = []
        var unused: [SkillCatalog.Group] = []
        var sets: [String: Int] = [:]
    }

    func order() async -> Order {
        await worker.run { catalog in
            Order(conflicts: (try? catalog.conflicts()) ?? [], duplicates: (try? catalog.duplicates()) ?? [],
                  unused: (try? catalog.unusedSkills(since: .now.addingTimeInterval(-30 * 86400))) ?? [],
                  sets: Dictionary(((try? catalog.sets()) ?? []).map { ($0.name, $0.members) }, uniquingKeysWith: { first, _ in first }))
        }
    }

    func setsOf(_ row: SkillCatalog.Row) async -> [String] {
        await worker.run { (try? $0.setsOf(kind: row.kind, name: row.name)) ?? [] }
    }

    func addToSet(_ set: String, skill id: Int) async {
        _ = await act(changes: false) { catalog, place in try catalog.addToSet(set, skill: id, now: place.now) }
        marksVersion += 1
    }

    func removeFromSet(_ set: String, skill id: Int) async {
        _ = await act(changes: false) { catalog, _ in try catalog.removeFromSet(set, skill: id) }
        marksVersion += 1
    }

    func deleteSet(_ set: String) async {
        _ = await act(changes: false) { catalog, _ in try catalog.deleteSet(set) }
        marksVersion += 1
    }

    func setEnabled(set: String, _ on: Bool) async -> Outcome<Int> {
        await act(changes: true) { catalog, place in try catalog.setEnabled(set: set, on, place) }
    }

    func exportData() async -> Outcome<Data> {
        await act(changes: false) { catalog, place in try SkillCatalog.exportData(catalog.export(now: place.now)) }
    }

    func compare(with data: Data) async -> Outcome<SkillCatalog.Comparison> {
        await act(changes: false) { catalog, _ in try catalog.compare(with: SkillCatalog.readExport(data)) }
    }

    // MARK: - Sources: GitHub repositories (SkillRemote, SkillGitHub)

    /// Where downloaded skills are kept: one folder per repository and commit.
    static var remoteCache: URL { SessionFiles.supportDirectory.appending(path: "skills/remote") }

    private(set) var sources: [SkillCatalog.RemoteSource] = []
    /// Sources being checked now.
    private(set) var checking: Set<Int> = []
    @ObservationIgnored private var lastSourceCheck: Date?
    @ObservationIgnored private var checkingAll = false
    /// How sources are read; the tests give a table.
    @ObservationIgnored var fetch: SkillGitHub.Fetch = SkillGitHub.fetch

    func loadSources() async {
        sources = await worker.run { (try? $0.sources()) ?? [] }
    }

    /// Adds a repository by `owner/repo` or its address and checks it at once.
    func addSource(_ text: String) async -> Outcome<Void> {
        guard let repo = SkillCatalog.GitHubRepo.parse(text) else { return .failure(.init(code: "repo")) }
        let added: Outcome<Int> = await act(changes: false) { catalog, place in try catalog.addSource(repo, now: place.now) }
        guard case .success(let id) = added else { return .failure(.init(code: "repo")) }
        await loadSources()
        if let source = sources.first(where: { $0.id == id }) { await check(source) }
        return .success(())
    }

    func removeSource(_ id: Int) async {
        _ = await act(changes: true) { catalog, _ in try catalog.removeSource(id) }
        await pruneCache()
        await loadSources()
    }

    /// Checks every source: a new commit is downloaded and checked, an unchanged one only gets its stars.
    func checkSources() async {
        lastSourceCheck = .now
        await loadSources()
        for source in sources { await check(source) }
    }

    /// At most twice a day by itself: each check costs three of the 60 API requests GitHub allows an hour.
    func checkSourcesIfStale() {
        guard isActive(), !checkingAll else { return }
        if let last = lastSourceCheck, Date.now.timeIntervalSince(last) < 12 * 3600 { return }
        checkingAll = true
        Task {
            await checkSources()
            checkingAll = false
        }
    }

    func check(_ source: SkillCatalog.RemoteSource) async {
        guard !checking.contains(source.id) else { return }
        checking.insert(source.id)
        defer { checking.remove(source.id) }
        let repo = source.repo
        do {
            let found = try await SkillGitHub.repository(repo, fetch: fetch)
            let skills = SkillCatalog.remoteSkills(in: found.tree)
            var downloaded: [(folder: String, cache: URL, truncated: Bool)] = []
            for skill in skills {
                let folder = try await SkillGitHub.download(skill, of: repo, sha: found.sha, into: Self.remoteCache, fetch: fetch)
                downloaded.append((skill.folder, folder, skill.truncated || found.treeTruncated))
            }
            let ready = downloaded
            let imported: Outcome<Int> = await act(changes: true) { catalog, place in
                try catalog.importRemote(repo, sha: found.sha, branch: found.branch, stars: found.stars, license: found.license, skills: ready, now: place.now)
            }
            if case .success(let count) = imported { AppLog.info("skills: \(repo.slug) at \(found.sha.prefix(7)): \(count) skills") }
            await pruneCache()
        } catch {
            let reason = (error as? SkillGitHub.Failure)?.reason ?? "network"
            AppLog.error("skills: checking \(repo.slug) failed: \(reason)")
            _ = await act(changes: false) { catalog, place in try catalog.noteSourceFailed(source.id, error: reason, now: place.now) }
        }
        await loadSources()
    }

    // MARK: - Finding sources (SkillSourceFinder)

    /// Repositories the awesome lists and the official marketplace name, merged; read once and kept for 12 hours.
    private(set) var candidates: [SkillSourceFinder.Candidate] = []
    private(set) var findingSources = false
    /// Lists that could not be read last time, with the reason.
    private(set) var unreadLists: [String: String] = [:]
    @ObservationIgnored private var candidatesAt: Date?

    func findSources(force: Bool = false) async {
        guard !findingSources else { return }
        if !force, let at = candidatesAt, Date.now.timeIntervalSince(at) < 12 * 3600 { return }
        findingSources = true
        defer { findingSources = false }
        var groups: [[SkillSourceFinder.Candidate]] = []
        var failed: [String: String] = [:]
        for list in SkillSourceFinder.lists {
            do { groups.append(try await SkillGitHub.candidates(of: list, fetch: fetch)) } catch {
                failed[list.repo.slug] = (error as? SkillGitHub.Failure)?.reason ?? "network"
            }
        }
        candidates = SkillSourceFinder.merge(groups)
        unreadLists = failed
        if groups.count > 0 {
            candidatesAt = .now
            let found = candidates
            _ = await act(changes: false) { catalog, place in try catalog.replaceIndex(found, now: place.now) }
            indexVersion += 1
        }
        AppLog.info("skills: \(candidates.count) candidate sources from \(groups.count) lists, \(failed.count) unread")
    }

    /// Bumped when the index was filled again.
    private(set) var indexVersion = 0

    func index(query: String, limit: Int = 100) async -> SkillCatalog.IndexPage {
        await worker.run { (try? $0.index(query: query, limit: limit)) ?? SkillCatalog.IndexPage() }
    }

    /// The index is read from the lists twice a day by itself: six files from raw.githubusercontent.com, which GitHub's
    /// API limit doesn't count. Nothing of the repositories themselves is downloaded.
    func refreshIndexIfStale() {
        guard isActive(), !findingSources else { return }
        Task {
            let fetched: String? = await worker.run { (try? $0.indexFetchedAt()) ?? nil }
            if let fetched, let date = ISO8601DateFormatter.flexible(fetched), Date.now.timeIntervalSince(date) < 12 * 3600 { return }
            await findSources(force: true)
        }
    }

    /// GitHub's repository search, only on a click: 10 searches a minute without a token.
    func searchSources(topic: String, words: String) async -> Outcome<[SkillSourceFinder.Candidate]> {
        do { return .success(try await SkillGitHub.search(topic: topic, words: words, fetch: fetch)) } catch {
            return .failure(.init(code: (error as? SkillGitHub.Failure)?.reason ?? "network"))
        }
    }

    /// Deletes downloaded commits the catalog no longer points at.
    private func pruneCache() async {
        let kept: Set<String> = await worker.run { (try? $0.remoteCacheFolders()) ?? [] }
        let root = Self.remoteCache
        let manager = FileManager.default
        for owner in (try? manager.contentsOfDirectory(atPath: root.path)) ?? [] {
            for repo in (try? manager.contentsOfDirectory(atPath: root.appending(path: owner).path)) ?? [] {
                for sha in (try? manager.contentsOfDirectory(atPath: root.appending(path: owner).appending(path: repo).path)) ?? [] {
                    let folder = root.appending(path: owner).appending(path: repo).appending(path: sha).path
                    if !kept.contains(where: { $0.hasPrefix(folder + "/") }) { try? manager.removeItem(atPath: folder) }
                }
            }
        }
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

/// A project as «Скиллы для проекта» needs it.
struct ProjectRef: Equatable, Sendable {
    var name: String
    var path: String
}
