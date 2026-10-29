import Foundation

// Models for `report.py --json` (version 1), see docs/SPEC.md §1.
// Decoding is tolerant: unknown fields are ignored, missing or malformed optional fields become nil/empty,
// unknown enum values map to `.unknown`.

struct ProjectsReport: Decodable, Sendable {
    var version: Int?
    var generated: Date?
    var diskFreeBytes: Int64?
    var projects: [Project]

    enum CodingKeys: String, CodingKey {
        case version, generated, projects
        case diskFreeBytes = "disk_free_bytes"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
        generated = c.isoDate(.generated)
        diskFreeBytes = try? c.decodeIfPresent(Int64.self, forKey: .diskFreeBytes)
        projects = c.lossyArray(.projects)
    }

    /// Worst health across projects; drives the dot on the menu bar icon.
    var hasRedProject: Bool {
        projects.contains { $0.health == .red }
    }
}

struct Project: Decodable, Identifiable, Sendable {
    var name: String
    var path: String
    var branch: String?
    var defaultBranch: String?
    var remote: String?
    var health: Health
    var lastActivity: Date?
    var dirty: Int
    var stashes: Int
    /// `nil` when `gh` is not available on the machine.
    var openPRs: [PullRequest]?
    var worktrees: [Worktree]
    var attention: [Attention]
    /// `nil` when the project has no docs/STATUS.md.
    var status: ProjectStatus?

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name, path, branch, remote, health, dirty, stashes, worktrees, attention, status
        case defaultBranch = "default_branch"
        case lastActivity = "last_activity"
        case openPRs = "open_prs"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? URL(fileURLWithPath: path).lastPathComponent
        branch = try? c.decodeIfPresent(String.self, forKey: .branch)
        defaultBranch = try? c.decodeIfPresent(String.self, forKey: .defaultBranch)
        remote = try? c.decodeIfPresent(String.self, forKey: .remote)
        health = (try? c.decodeIfPresent(Health.self, forKey: .health)) ?? .unknown
        lastActivity = c.isoDate(.lastActivity)
        dirty = (try? c.decodeIfPresent(Int.self, forKey: .dirty)) ?? 0
        stashes = (try? c.decodeIfPresent(Int.self, forKey: .stashes)) ?? 0
        openPRs = (try? c.decodeNil(forKey: .openPRs)) == false ? c.lossyArray(.openPRs) : nil
        worktrees = c.lossyArray(.worktrees)
        attention = c.lossyArray(.attention)
        status = try? c.decodeIfPresent(ProjectStatus.self, forKey: .status)
    }

    /// Attention items minus those that repeat a «Needs Oleh» entry (report.py adds them as «нужно от вас: …»),
    /// since the expanded row already lists Needs Oleh.
    var attentionNotInStatus: [Attention] {
        let needs = status?.summary?.needs ?? []
        return attention.filter { item in !needs.contains { !$0.isEmpty && item.text.hasSuffix($0) } }
    }

    /// Overall CI state of open PRs: the worst one wins.
    var pullRequestsCI: CIState {
        let states = (openPRs ?? []).map(\.ci)
        for state in [CIState.fail, .pending, .ok] where states.contains(state) {
            return state
        }
        return .none
    }
}

enum Health: String, Decodable, Sendable {
    case red, yellow, green, unknown

    init(from decoder: Decoder) throws {
        self = Health(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

enum CIState: String, Decodable, Sendable {
    case ok, fail, pending, none, unknown

    init(from decoder: Decoder) throws {
        self = CIState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

struct PullRequest: Decodable, Identifiable, Sendable {
    var number: Int
    var title: String
    var url: URL?
    var isDraft: Bool
    var ci: CIState

    var id: Int { number }

    enum CodingKeys: String, CodingKey {
        case number, title, url, isDraft, ci
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        url = (try? c.decodeIfPresent(String.self, forKey: .url)).flatMap { $0.flatMap(URL.init(string:)) }
        isDraft = (try? c.decodeIfPresent(Bool.self, forKey: .isDraft)) ?? false
        ci = (try? c.decodeIfPresent(CIState.self, forKey: .ci)) ?? .unknown
    }
}

struct Worktree: Decodable, Sendable {
    var path: String
    var branch: String?
    var dirty: Int?
}

struct Attention: Decodable, Sendable, Hashable {
    enum Level: String, Decodable, Sendable {
        case high, mid, low, unknown

        init(from decoder: Decoder) throws {
            self = Level(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    var level: Level
    var text: String

    enum CodingKeys: String, CodingKey { case level, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = (try? c.decodeIfPresent(Level.self, forKey: .level)) ?? .unknown
        text = try c.decode(String.self, forKey: .text)
    }
}

struct ProjectStatus: Decodable, Sendable {
    var path: String?
    /// `nil` when STATUS.md has no summary header.
    var summary: StatusSummary?
    var latestEntry: LatestEntry?

    enum CodingKeys: String, CodingKey {
        case path, summary
        case latestEntry = "latest_entry"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try? c.decodeIfPresent(String.self, forKey: .path)
        summary = try? c.decodeIfPresent(StatusSummary.self, forKey: .summary)
        latestEntry = try? c.decodeIfPresent(LatestEntry.self, forKey: .latestEntry)
    }
}

struct StatusSummary: Decodable, Sendable {
    var stage: String?
    var updated: String?
    var now: [String]
    var next: [String]
    var needs: [String]

    enum CodingKeys: String, CodingKey { case stage, updated, now, next, needs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stage = try? c.decodeIfPresent(String.self, forKey: .stage)
        updated = try? c.decodeIfPresent(String.self, forKey: .updated)
        now = c.lossyArray(.now)
        next = c.lossyArray(.next)
        needs = c.lossyArray(.needs)
    }
}

struct LatestEntry: Decodable, Sendable {
    var date: String?
    var title: String?
}

// MARK: - Tolerant decoding helpers

private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// Decodes an array, skipping elements that fail to decode; missing, `null` or malformed → `[]`.
    func lossyArray<Element: Decodable>(_ key: Key) -> [Element] {
        guard let items = try? decodeIfPresent([Lossy<Element>].self, forKey: key) else { return [] }
        return items.compactMap(\.value)
    }

    /// Decodes an ISO 8601 string (with or without fractional seconds); anything else → `nil`.
    func isoDate(_ key: Key) -> Date? {
        guard let string = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        return ISODate.parse(string)
    }
}

enum ISODate {
    static func parse(_ string: String) -> Date? {
        (try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(string, strategy: Date.ISO8601FormatStyle()))
    }
}
