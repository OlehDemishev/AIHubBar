import Foundation

enum RelativeTime {
    /// Short Russian "time ago": «только что», «5 мин назад», «3 ч назад», «2 дн назад».
    static func ago(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "только что"
        case ..<3600: return "\(Int(seconds / 60)) мин назад"
        case ..<86_400: return "\(Int(seconds / 3600)) ч назад"
        default: return "\(Int(seconds / 86_400)) дн назад"
        }
    }
}

enum GitRemote {
    /// Web URL for a git remote: `git@host:owner/repo.git`, `ssh://git@host/owner/repo.git`
    /// and `https://user:token@host/owner/repo.git` all become `https://host/owner/repo`.
    /// Credentials are always dropped. Returns `nil` for local paths and unknown formats.
    static func webURL(_ remote: String?) -> URL? {
        guard var remote = remote?.trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty else { return nil }

        // scp-like syntax: [user@]host:path
        if !remote.contains("://"), let colon = remote.firstIndex(of: ":") {
            var host = String(remote[..<colon])
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            remote = "https://\(host)/\(remote[remote.index(after: colon)...])"
        }

        guard var components = URLComponents(string: remote),
              let scheme = components.scheme?.lowercased(),
              ["https", "http", "ssh", "git"].contains(scheme),
              let host = components.host, !host.isEmpty
        else { return nil }

        components.scheme = "https"
        components.user = nil
        components.password = nil
        components.port = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard path.count > 1 else { return nil }
        components.path = path
        return components.url
    }
}
