import Foundation

/// Who is signed in to Claude Code and on which plan, for the panel's header. Claude Code keeps it in `~/.claude.json`
/// → `oauthAccount`; the file is only read, and nothing of it is stored or sent anywhere.
struct ClaudeIdentity: Equatable, Sendable {
    /// The name the person gave Claude, never the e-mail: the panel ends up in screenshots.
    var name: String?
    /// «Max 5x», «Pro»…; nil for a plan this version doesn't know.
    var plan: String?

    static func read(home: String = NSHomeDirectory()) -> ClaudeIdentity? {
        guard let data = FileManager.default.contents(atPath: home + "/.claude.json") else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> ClaudeIdentity? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any] else { return nil }
        let name = [account["displayName"], account["fullName"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        let plan = plan(type: account["organizationType"] as? String, tier: account["organizationRateLimitTier"] as? String)
        return name == nil && plan == nil ? nil : ClaudeIdentity(name: name, plan: plan)
    }

    /// `claude_max` + `default_claude_max_5x` → «Max 5x». The names are Anthropic's own, not translated.
    static func plan(type: String?, tier: String?) -> String? {
        let base: String? = switch type {
        case "claude_max": "Max"
        case "claude_pro": "Pro"
        case "claude_team": "Team"
        case "claude_enterprise": "Enterprise"
        default: nil
        }
        guard let base else { return nil }
        guard base == "Max", let tier, let match = tier.range(of: #"_(\d+)x$"#, options: .regularExpression) else { return base }
        return base + " " + tier[match].dropFirst()
    }
}
