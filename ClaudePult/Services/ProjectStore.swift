import Foundation
import Observation

/// Holds the latest project report and keeps it fresh:
/// on panel open if older than 60 s, every 5 min without fetch, every 30 min with `git fetch`.
@MainActor
@Observable
final class ProjectStore {
    private(set) var report: ProjectsReport?
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
