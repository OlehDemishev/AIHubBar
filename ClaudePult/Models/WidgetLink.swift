import Foundation

/// `aihubbar://` links opened by clicks on the desktop widgets (ClaudePultWidget builds the same URLs):
/// `limits` — the limits window (the panel itself can't be opened from code, DECISIONS), `session/<id>` — that
/// session, as a click on its notification does, `search` — the search window.
enum WidgetLink {
    static let scheme = "aihubbar"

    static func resolve(_ url: URL) -> NotificationAction.Resolution? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        switch url.host?.lowercased() {
        case "limits": return .openWindow(id: "limits")
        case "search": return .openWindow(id: "search")
        case "session": return path.first.map { .showSession(id: $0) }
        default: return nil
        }
    }
}
