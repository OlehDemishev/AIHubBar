import Foundation

/// «Итог дня»: what the agents did today — spend by project, background runs with their outcomes, limit hits and a
/// line per other service. The same lines go to the «История расхода» window and, once a day, to Telegram.
enum DaySummary {
    struct Input: Sendable {
        var sessionPercent: Double?
        var weekPercent: Double?
        /// Today's tokens by project (`UsageStore.Period.today`).
        var breakdown: TokenBreakdown?
        var hits: Int
        /// Background runs that started today, any state.
        var runs: [BackgroundRun]
        var others: [ServiceUsage] = []
    }

    struct Line: Equatable, Sendable {
        var text: String
        var isHeading = false
    }

    /// Runs of the day: those that started since midnight.
    static func today(_ runs: [BackgroundRun], now: Date = .now, calendar: Calendar = .current) -> [BackgroundRun] {
        let start = calendar.startOfDay(for: now)
        return runs.filter { $0.startedAt >= start && $0.reviewOf == nil }
    }

    static func lines(_ input: Input) -> [Line] {
        var lines: [Line] = []
        let limits = [
            input.sessionPercent.map { String(localized: "Сессия: \(UsageText.percent($0))") },
            input.weekPercent.map { String(localized: "Неделя: \(UsageText.percent($0))") },
        ].compactMap { $0 }
        if !limits.isEmpty { lines.append(Line(text: "Claude — " + limits.joined(separator: ", "))) }
        if input.hits > 0 { lines.append(Line(text: String(localized: "Упирался в лимит: \(input.hits)"))) }

        if let breakdown = input.breakdown, !breakdown.projects.isEmpty {
            lines.append(Line(text: String(localized: "По проектам"), isHeading: true))
            for row in breakdown.projects.prefix(5) {
                lines.append(Line(text: "• \(row.name) — \(Int((row.share * 100).rounded())) % (\(TokenBreakdown.tokensText(row.tokens)))"))
            }
            if breakdown.projects.count > 5 {
                lines.append(Line(text: String(localized: "и ещё \(breakdown.projects.count - 5)")))
            }
        }
        if !input.runs.isEmpty {
            lines.append(Line(text: String(localized: "Фоновые задачи"), isHeading: true))
            for run in input.runs.prefix(8) {
                let mark = switch run.state {
                case .succeeded: "✅"
                case .running: "⏳"
                case .failed, .stopped, .timedOut: "❌"
                }
                let agent = run.agent == nil ? "" : " · \(run.agentTitle)"
                lines.append(Line(text: "\(mark) \(run.project)\(agent): \(run.task)"))
            }
            if input.runs.count > 8 { lines.append(Line(text: String(localized: "и ещё \(input.runs.count - 8)"))) }
        }
        let others = input.others.compactMap(otherLine)
        if !others.isEmpty {
            lines.append(Line(text: String(localized: "Другие AI"), isHeading: true))
            lines += others.map { Line(text: "• " + $0) }
        }
        return lines
    }

    /// «Codex — 5 ч 12 %, Неделя 30 %»: the limits as they stand, nil for a service with none to show.
    static func otherLine(_ usage: ServiceUsage) -> String? {
        let limits = usage.rings.compactMap { window in window.percent.map { "\(window.title) \(UsageText.percent($0))" } }
        return limits.isEmpty ? nil : "\(usage.title) — " + limits.joined(separator: ", ")
    }

    /// Nothing happened today: no spend and no runs. Then there is nothing to send.
    static func isEmpty(_ input: Input) -> Bool {
        (input.breakdown?.projects.isEmpty ?? true) && input.runs.isEmpty
    }

    static func html(_ input: Input) -> String {
        (["🗓 <b>\(RunMessage.escape(String(localized: "Итог дня")))</b>"] + lines(input).map {
            $0.isHeading ? "\n<b>\(RunMessage.escape($0.text))</b>" : RunMessage.escape($0.text)
        }).joined(separator: "\n")
    }

    /// Today's send time, or yesterday's while today's hour has not come.
    static func due(hour: Int, now: Date = .now, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        return today > now ? calendar.date(byAdding: .day, value: -1, to: today) ?? today : today
    }
}
