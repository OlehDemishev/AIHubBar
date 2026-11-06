import Foundation
import Observation

/// The limits of the extra Claude accounts (`ClaudeAccount`), read every five minutes. No history or forecast: those
/// come from the journals, which belong to the main account.
@MainActor
@Observable
final class ClaudeAccountsStore {
    struct Reading: Equatable, Sendable {
        var snapshot: UsageSnapshot?
        var error: String?
    }

    private(set) var readings: [String: Reading] = [:]
    private let settings: AppSettings
    private var loop: Task<Void, Never>?
    /// After HTTP 429 an account is left alone for a while.
    private var pausedUntil: [String: Date] = [:]
    var isActive: () -> Bool = { true }

    init(settings: AppSettings) {
        self.settings = settings
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

    func refresh() async {
        guard isActive() else { return }
        for account in settings.claudeAccounts {
            if let until = pausedUntil[account.id], until > .now { continue }
            do {
                let snapshot = try await UsageService.fetch(keychainService: account.keychainService)
                readings[account.id] = Reading(snapshot: snapshot)
            } catch {
                if case UsageError.rateLimited = error { pausedUntil[account.id] = .now.addingTimeInterval(30 * 60) }
                readings[account.id] = Reading(snapshot: readings[account.id]?.snapshot, error: error.localizedDescription)
            }
        }
        let ids = Set(settings.claudeAccounts.map(\.id))
        readings = readings.filter { ids.contains($0.key) }
    }

    var usages: [ServiceUsage] {
        settings.claudeAccounts.compactMap { account in
            guard let reading = readings[account.id] else { return nil }
            if let snapshot = reading.snapshot {
                var usage = ServiceUsage.claude(snapshot, forecast: .unknown, week: nil, error: reading.error)
                usage.service = .claudeAccount(account.id)
                usage.title = account.name
                return usage
            }
            return ServiceUsage(service: .claudeAccount(account.id), title: account.name, rings: [], bars: [], forecast: .unknown, error: reading.error)
        }
    }
}
