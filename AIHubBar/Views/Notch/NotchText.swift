import Foundation

/// Words for the ears' hints and VoiceOver.
enum NotchText {
    static func earSummary(_ ear: NotchEar, usage: UsageSnapshot?, sessions: [SessionStore.Item], background: Int,
                           otherAI: [String: Double] = [:], liveActivity: Bool = false, now: Date = .now) -> String {
        switch ear {
        case .sessionLimit, .weekLimit:
            guard let window = ear == .sessionLimit ? usage?.session : usage?.week else { return ear.title }
            return "\(window.title): \(UsageText.percent(window.utilization))"
        case .otherAI:
            guard let fullest = fullestOther(otherAI) else { return ear.title }
            return "\(fullest.name): \(UsageText.percent(fullest.percent))"
        case .sessions:
            let waiting = sessions.filter { $0.state == .waiting }.count
            let running = sessions.filter { $0.state == .running }.count
            if liveActivity, waiting == 0, let featured = featured(sessions) {
                let others = running > 1 ? String(localized: "; ещё работают: \(running - 1)") : ""
                return activity(featured.session, now: now) + others
            }
            return String(localized: "Ждут ответа: \(waiting), работают: \(running)")
        case .background:
            return String(localized: "Фоновых задач: \(background)")
        case .none:
            return ""
        }
    }

    /// The other AI service closest to its limit (source raw value → percent, as `HubLimitsStore.percents`).
    static func fullestOther(_ percents: [String: Double]) -> (name: String, percent: Double)? {
        percents.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }
            .map { (HubLimit.Source(rawValue: $0.key)?.shortTitle ?? $0.key, $0.value) }
    }

    // MARK: Live activity (SPEC-notch §3.4)

    /// The working session the sessions ear follows: the one given a request last. A session recorded by an older
    /// hook has no request time yet and counts from its start, never from its last tool call.
    static func featured(_ items: [SessionStore.Item]) -> SessionStore.Item? {
        func asked(_ item: SessionStore.Item) -> Date { item.session.promptAt ?? item.session.startedAt ?? .distantPast }
        return items.filter { $0.state == .running }.max { asked($0) < asked($1) }
    }

    /// Whole minutes from `start` to `now`, never negative.
    static func minutes(from start: Date, to now: Date) -> Int { max(0, Int(now.timeIntervalSince(start) / 60)) }

    /// «AI Hub Bar: сделано 3 из 7, Пишет тесты, 4 мин» — the ear's hint and what VoiceOver reads.
    static func activity(_ session: Session, now: Date) -> String {
        var parts: [String] = []
        if let progress = session.progress { parts.append(String(localized: "сделано \(progress.done) из \(progress.total)")) }
        if let step = session.currentTodo { parts.append(step.text) } else if let action = session.actionText { parts.append(action) }
        if let start = session.promptAt { parts.append(DurationText.short(from: start, to: now)) }
        return parts.isEmpty ? session.displayProject : "\(session.displayProject): " + parts.joined(separator: ", ")
    }

    /// «7/7 · 12 мин · файлов: 5» under «Готово: …».
    static func finishedBody(progress: (done: Int, total: Int)?, duration: String?, files: Int?) -> String {
        [progress.map { "\($0.done)/\($0.total)" }, duration, files.flatMap { $0 > 0 ? String(localized: "файлов: \($0)") : nil }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The steps the card shows: all of them up to `limit`, else a window that keeps the step in progress in view
    /// with two done ones above it.
    static func visibleSteps(_ todos: [SessionTodo], limit: Int = 7) -> Range<Int> {
        guard todos.count > limit else { return 0..<todos.count }
        let current = todos.firstIndex { $0.status == .inProgress } ?? todos.firstIndex { $0.status == .pending } ?? todos.count - 1
        let start = min(max(current - 2, 0), todos.count - limit)
        return start..<(start + limit)
    }

    static func stepLabel(_ todo: SessionTodo) -> String {
        switch todo.status {
        case .completed: String(localized: "Сделано: \(todo.text)")
        case .inProgress: String(localized: "Сейчас: \(todo.text)")
        case .pending: String(localized: "Впереди: \(todo.text)")
        }
    }

    static func sessionHelp(_ item: SessionStore.Item) -> String {
        [item.session.displayProject, item.state.title, item.session.actionText].compactMap { $0 }.joined(separator: " · ")
    }
}
