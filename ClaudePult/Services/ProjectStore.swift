import Foundation
import Observation

/// Holds the latest project report and keeps it fresh:
/// on panel open if older than 60 s, every 5 min without fetch, every 30 min with `git fetch`.
@MainActor
@Observable
final class ProjectStore {
    private(set) var report: ProjectsReport? {
        didSet { announcePullRequests(from: oldValue?.projects, to: report?.projects) }
    }
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    static let staleAfter: TimeInterval = 60
    static let backgroundInterval: Duration = .seconds(5 * 60)
    static let fetchInterval: TimeInterval = 30 * 60

    private let settings: AppSettings
    private var lastFetch = Date.now
    private var loop: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
    }

    var projects: [Project] { report?.projects ?? [] }

    /// CI went red or green, a PR closed: a notification (and Telegram if chosen) whose click opens the PR.
    private func announcePullRequests(from old: [Project]?, to new: [Project]?) {
        guard settings.pullRequestAlerts, let old, let new else { return }
        let changes = PullRequestAlerts.changes(from: old, to: new)
        for change in changes {
            let url = PullRequestAlerts.url(change)
            Notifier.post(id: "pr-\(PullRequestAlerts.title(change))", title: PullRequestAlerts.title(change),
                          body: PullRequestAlerts.body(change), target: url.map { .link($0) } ?? .none)
        }
        guard !changes.isEmpty else { return }
        AppLog.info("Pull request changes: \(changes.count)")
        if settings.pullRequestAlertsToTelegram, let credentials = Telegram.credentials(dailyReportDirectory: settings.dailyReportDirectory) {
            let html = changes.map { change in
                let title = RunMessage.escape(PullRequestAlerts.title(change)) + " — " + RunMessage.escape(PullRequestAlerts.body(change))
                return PullRequestAlerts.url(change).map { "\(title)\n<a href=\"\(RunMessage.escape($0.absoluteString))\">PR</a>" } ?? title
            }.joined(separator: "\n\n")
            Task { _ = await Telegram.send(html: html, with: credentials) }
        }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.backgroundInterval)
                guard let self else { return }
                let fetch = Date.now.timeIntervalSince(lastFetch) >= Self.fetchInterval - 10
                await refresh(fetch: fetch)
            }
        }
    }

    func refreshIfStale() {
        guard !isRefreshing else { return }
        if let lastUpdated, Date.now.timeIntervalSince(lastUpdated) < Self.staleAfter { return }
        Task { await refresh() }
    }

    func refresh(fetch: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if fetch { lastFetch = .now }
        // Folder projects live in `FolderProjectStore`.
        if case .gitBuiltin = settings.activeSource {
            let started = ContinuousClock.now
            if let scanned = await GitScanner.report(projectsDirectory: settings.projectsDirectory, fetch: fetch) {
                report = scanned
                lastUpdated = .now
                lastError = FileManager.default.fileExists(atPath: settings.projectsDirectory) ? nil : String(localized: "Папки нет: \(settings.projectsDirectory)")
                AppLog.info("Git scan\(fetch ? " (fetch)" : ""): \(scanned.projects.count) projects in \((ContinuousClock.now - started).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))")
            } else {
                lastError = String(localized: "Не удалось прочитать репозитории")
            }
            return
        }
        guard settings.activeSource.isReport else {
            report = nil
            lastError = nil
            return
        }

        do {
            report = try await ReportService.load(
                script: settings.reportScript,
                projectsDirectory: settings.projectsDirectory,
                fetch: fetch
            )
            lastUpdated = .now
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            AppLog.error("Refresh failed: \(error.localizedDescription)")
        }
    }
}
