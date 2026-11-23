import Foundation

/// «Агент мог застрять»: a session that works but has done nothing for a long while, or keeps running the same
/// command. The session file holds only the last tool call, so the repeats are counted here, from one reading of the
/// files to the next — a hint, not a proof: the hook writes the same call again at most once a minute.
struct StuckWatch {
    enum Reason: Equatable, Sendable {
        case quiet(minutes: Int)
        case loop(times: Int, command: String)
    }

    struct Alert: Equatable, Sendable {
        var sessionID: String
        var reason: Reason
    }

    /// The row says «тихо» after 10 minutes; a notification waits twice as long.
    static let quietAfter: TimeInterval = 20 * 60
    /// The same command this many times among the last `loopWindow` tool calls.
    static let loopTimes = 5
    static let loopWindow = 12
    /// A session found already quiet for longer than this at the app's start is old news.
    static let replayWithin: TimeInterval = 2 * 60

    private struct Track {
        var prompt: Date?
        var lastToolAt: Date?
        var actions: [String] = []
        var quietFiredFor: Date?
        var loopFired: Set<String> = []
    }

    private var tracks: [String: Track] = [:]

    /// The latest sign of life: a tool call, a new request, any hook event.
    static func lastActivity(_ session: Session) -> Date {
        [session.lastToolAt, session.promptAt].compactMap { $0 }.reduce(session.updatedAt, max)
    }

    mutating func evaluate(_ sessions: [(session: Session, state: Session.State)], now: Date = .now) -> [Alert] {
        var alerts: [Alert] = []
        let present = Set(sessions.map(\.session.id))
        tracks = tracks.filter { present.contains($0.key) }
        for (session, state) in sessions {
            let isNew = tracks[session.id] == nil
            var track = tracks[session.id] ?? Track(prompt: session.promptAt)
            // A new request starts the count again.
            if track.prompt != session.promptAt { track = Track(prompt: session.promptAt) }
            defer { tracks[session.id] = track }

            if let at = session.lastToolAt, at != track.lastToolAt, let tool = session.lastTool {
                track.lastToolAt = at
                let command = session.lastTarget ?? ""
                let key = tool + "\u{1}" + command
                track.actions = Array((track.actions + [key]).suffix(Self.loopWindow))
                let times = track.actions.filter { $0 == key }.count
                if state == .running, tool == "Bash", !command.isEmpty, times >= Self.loopTimes, !track.loopFired.contains(key) {
                    track.loopFired.insert(key)
                    alerts.append(Alert(sessionID: session.id, reason: .loop(times: times, command: command)))
                }
            }

            guard state == .running else { continue }
            let last = Self.lastActivity(session)
            let quiet = now.timeIntervalSince(last)
            if quiet >= Self.quietAfter, track.quietFiredFor != last {
                track.quietFiredFor = last
                if !isNew || quiet < Self.quietAfter + Self.replayWithin {
                    alerts.append(Alert(sessionID: session.id, reason: .quiet(minutes: Int(quiet / 60))))
                }
            }
        }
        return alerts
    }

    static func title(_ session: Session) -> String {
        String(localized: "\(session.agentName) мог застрять — \(session.displayProject)")
    }

    static func body(_ reason: Reason) -> String {
        switch reason {
        case let .quiet(minutes):
            String(localized: "Сессия идёт, но уже \(minutes) мин ничего не делает. Посмотрите, не зависла ли она.")
        case let .loop(times, command):
            String(localized: "Раз за разом запускает одно и то же (уже \(times)): \(command)")
        }
    }
}
