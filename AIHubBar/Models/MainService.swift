import Foundation

/// Which AI service is the main one: its limits lead the panel's block and are the two numbers of the menu bar item,
/// the island and the folded block. It was always Claude; a person with only Codex or Antigravity saw «Установить
/// Claude Code» instead of their own limits (2026-11-11).
enum MainService {
    /// The setting's values: `auto`, `claude` or a `HubLimit.Source` raw value.
    static let auto = ""
    static let claude = "claude"

    /// Claude while it has limits to show, else the first other service that has them. A chosen service is main while
    /// it has limits; without them the choice falls back to the automatic one, so the numbers never go blank because
    /// of a setting.
    static func pick(choice: String, claude: ServiceUsage?, others: [ServiceUsage]) -> ServiceUsage? {
        let withLimits = others.filter { !$0.rings.isEmpty }
        if choice == Self.claude, let claude { return claude }
        if let chosen = withLimits.first(where: { $0.service == HubLimit.Source(rawValue: choice).map(ServiceUsage.Service.hub) }) {
            return chosen
        }
        return claude ?? withLimits.first
    }

    /// What the setting offers: the services that have limits now, and the saved one even when it has none.
    static func choices(saved: String, others: [ServiceUsage]) -> [HubLimit.Source] {
        var sources = others.filter { !$0.rings.isEmpty }.compactMap(\.hubSource)
        if let kept = HubLimit.Source(rawValue: saved), !sources.contains(kept) { sources.append(kept) }
        return sources
    }

    @MainActor
    static func current(usage: UsageStore, hub: HubLimitsStore, settings: AppSettings) -> ServiceUsage? {
        let claude = usage.snapshot.map {
            ServiceUsage.claude($0, forecast: usage.forecast, pace: usage.pace, week: usage.weekUsage, error: usage.lastError)
        }
        return pick(choice: settings.mainService, claude: claude, others: hub.usages)
    }
}

extension ServiceUsage {
    var hubSource: HubLimit.Source? {
        if case let .hub(source) = service { return source }
        return nil
    }

    /// The limit shown first (Claude's session, Codex's 5 hours) and the one beside it (the week).
    var firstLimit: LimitWindow? { rings.first }
    var secondLimit: LimitWindow? { rings.dropFirst().first }
}
