import Foundation

/// Finding repositories to add as sources (docs/specs/SPEC-skills.md, «Где искать источники»). Three documented, public
/// ways, none needing a token (checked 2026-11-27):
///
/// - **Awesome lists**: the READMEs of a few well-known lists of skills on GitHub, read as plain Markdown from
///   raw.githubusercontent.com (not counted against the API's 60 an hour). Every `github.com/<owner>/<repo>` link in a
///   list item or table row is a candidate; the text after it is its description.
/// - **The official plugin marketplace** `anthropics/claude-plugins-official`: its `.claude-plugin/marketplace.json`
///   (format: code.claude.com/docs/en/plugins/marketplace-reference) names each plugin's repository in `source`.
/// - **GitHub's repository search** by topic (`topic:agent-skills`, docs.github.com/en/rest/search): 10 searches a minute
///   without a token, so only on the person's click.
///
/// Catalog sites were looked at and left out: skills.sh's API needs a Vercel token, skillsmp.com refuses automated
/// reading of its own docs. A candidate is only a suggestion — nothing is added, downloaded or trusted until the person
/// adds it, and then it is checked like any source. Everything a list says is untrusted text, shown verbatim and cut.
enum SkillSourceFinder {
    struct List: Equatable, Sendable {
        var repo: SkillCatalog.GitHubRepo
        /// The file to read, at the default branch (`HEAD`).
        var file: String
        var kind: Kind
    }

    enum Kind: String, Sendable { case awesome, marketplace }

    static let lists: [List] = [
        "ComposioHQ/awesome-claude-skills", "VoltAgent/awesome-agent-skills", "travisvn/awesome-claude-skills",
        "BehiSecc/awesome-claude-skills", "heilcheng/awesome-agent-skills",
    ].compactMap { SkillCatalog.GitHubRepo.parse($0).map { List(repo: $0, file: "README.md", kind: .awesome) } }
        + [List(repo: SkillCatalog.GitHubRepo(owner: "anthropics", repo: "claude-plugins-official"), file: ".claude-plugin/marketplace.json", kind: .marketplace)]

    /// The topics GitHub's search is asked about.
    static let topics = ["agent-skills", "claude-skills"]

    struct Candidate: Identifiable, Equatable, Sendable {
        var repo: SkillCatalog.GitHubRepo
        var id: String { repo.slug.lowercased() }
        /// What the first list called it (a skill's or plugin's name), when it differs from the repository.
        var title: String?
        var summary: String?
        /// The lists that name it, by `owner/repo`.
        var lists: [String] = []
        /// Folders inside it the lists point at (`skills/docx`).
        var paths: [String] = []
        var stars: Int?
        var official: Bool { SkillCatalog.officialOwners.contains(repo.owner.lowercased()) }
    }

    /// Owners that are GitHub's own pages, not repositories.
    static let notOwners: Set<String> = ["user-attachments", "sponsors", "orgs", "topics", "features", "marketplace", "apps", "settings",
                                         "login", "about", "pricing", "collections", "trending", "search", "explore", "notifications", "site"]

    static let maxSummary = 200
    static let maxCandidates = 1000

    static func clean(_ text: String, limit: Int = maxSummary) -> String? {
        var value = text
        // Markdown links keep their words, images and HTML go.
        value = value.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[*_`|]+"#, with: " ", options: .regularExpression)
        value = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !($0.properties.isDefaultIgnorableCodePoint) })
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        while let first = value.first, "-–—:·".contains(first) { value.removeFirst(); value = value.trimmingCharacters(in: .whitespaces) }
        guard !value.isEmpty else { return nil }
        return value.count > limit ? String(value.prefix(limit - 1)) + "…" : value
    }

    private static let link = try! NSRegularExpression(
        pattern: #"\[([^\]\n]{1,200})\]\(\s*https?://(?:www\.)?github\.com/([A-Za-z0-9-]{1,100})/([A-Za-z0-9._-]{1,100})(?:/tree/[^/\s)]+/([^\s)#?]+))?/?(?:[#?][^)\s]*)?\s*\)"#)

    /// The repositories an awesome list's Markdown links to, in the order they first appear.
    static func fromMarkdown(_ text: String, list: SkillCatalog.GitHubRepo) -> [Candidate] {
        var found: [String: Candidate] = [:]
        var order: [String] = []
        for line in text.split(whereSeparator: \.isNewline).prefix(20_000) {
            let line = String(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Only list items and table rows: headers, badges and banners are not entries.
            guard trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("|") || trimmed.first?.isNumber == true else { continue }
            let ns = line as NSString
            let matches = link.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let first = matches.first else { continue }
            let after = ns.substring(from: first.range.location + first.range.length)
            let summary = clean(after.components(separatedBy: "|").first { clean($0) != nil } ?? after)
            for match in matches {
                let owner = ns.substring(with: match.range(at: 2)), name = ns.substring(with: match.range(at: 3))
                guard !notOwners.contains(owner.lowercased()), let repo = SkillCatalog.GitHubRepo.parse("\(owner)/\(name)"),
                      repo.slug.lowercased() != list.slug.lowercased() else { continue }
                let title = clean(ns.substring(with: match.range(at: 1)), limit: 80)
                let path = match.range(at: 4).location == NSNotFound ? nil : ns.substring(with: match.range(at: 4)).removingPercentEncoding
                add(&found, &order, repo, title: title, summary: match == first ? summary : nil, list: list.slug, path: path)
            }
        }
        return order.compactMap { found[$0] }
    }

    /// The repositories the plugins of a Claude Code marketplace come from. A plugin kept inside the marketplace's own
    /// repository (a `./path` source) points at that repository.
    static func fromMarketplace(_ data: Data, list: SkillCatalog.GitHubRepo) -> [Candidate] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plugins = object["plugins"] as? [[String: Any]] else { return [] }
        var found: [String: Candidate] = [:]
        var order: [String] = []
        for plugin in plugins.prefix(maxCandidates) {
            var repo: SkillCatalog.GitHubRepo?
            var path: String?
            if let relative = plugin["source"] as? String {
                repo = list
                path = relative.hasPrefix("./") ? String(relative.dropFirst(2)) : relative
            } else if let source = plugin["source"] as? [String: Any] {
                switch source["source"] as? String {
                case "github": repo = (source["repo"] as? String).flatMap(SkillCatalog.GitHubRepo.parse)
                case "url": repo = (source["url"] as? String).flatMap(githubURL)
                case "git-subdir":
                    repo = (source["url"] as? String).flatMap { githubURL($0) ?? SkillCatalog.GitHubRepo.parse($0) }
                    path = source["path"] as? String
                default: break
                }
            }
            guard let repo, !notOwners.contains(repo.owner.lowercased()) else { continue }
            add(&found, &order, repo, title: (plugin["name"] as? String).flatMap { clean($0, limit: 80) },
                summary: (plugin["description"] as? String).flatMap { clean($0) }, list: list.slug, path: path)
        }
        return order.compactMap { found[$0] }
    }

    /// `https://github.com/o/r(.git)`, and nothing on another host.
    static func githubURL(_ text: String) -> SkillCatalog.GitHubRepo? {
        let lower = text.lowercased()
        guard lower.hasPrefix("https://github.com/") || lower.hasPrefix("https://www.github.com/") else { return nil }
        return SkillCatalog.GitHubRepo.parse(text)
    }

    /// GitHub's answer to a repository search: public, not archived, not forks.
    static func fromSearch(_ data: Data) -> [Candidate] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard item["private"] as? Bool != true, item["archived"] as? Bool != true, item["fork"] as? Bool != true,
                  let repo = (item["full_name"] as? String).flatMap(SkillCatalog.GitHubRepo.parse) else { return nil }
            return Candidate(repo: repo, summary: (item["description"] as? String).flatMap { clean($0) },
                             stars: (item["stargazers_count"] as? NSNumber)?.intValue)
        }
    }

    private static func add(_ found: inout [String: Candidate], _ order: inout [String], _ repo: SkillCatalog.GitHubRepo,
                            title: String?, summary: String?, list: String, path: String?) {
        let key = repo.slug.lowercased()
        if found[key] == nil {
            guard order.count < maxCandidates else { return }
            found[key] = Candidate(repo: repo)
            order.append(key)
        }
        var candidate = found[key]!
        if candidate.title == nil, let title, title.lowercased() != repo.repo.lowercased(), title.lowercased() != key { candidate.title = title }
        if candidate.summary == nil { candidate.summary = summary }
        if !candidate.lists.contains(list) { candidate.lists.append(list) }
        if let path = path.flatMap({ clean($0, limit: 120) }), !candidate.paths.contains(path), candidate.paths.count < 20 { candidate.paths.append(path) }
        found[key] = candidate
    }

    /// Several lists together: one candidate per repository, named by every list that has it, most-named first, then
    /// the official ones, then in the order the lists gave them.
    static func merge(_ groups: [[Candidate]]) -> [Candidate] {
        var found: [String: Candidate] = [:]
        var order: [String] = []
        for group in groups {
            for candidate in group {
                if var known = found[candidate.id] {
                    known.lists += candidate.lists.filter { !known.lists.contains($0) }
                    known.paths += candidate.paths.filter { !known.paths.contains($0) }.prefix(max(0, 20 - known.paths.count))
                    if known.title == nil { known.title = candidate.title }
                    if known.summary == nil { known.summary = candidate.summary }
                    if known.stars == nil { known.stars = candidate.stars }
                    found[candidate.id] = known
                } else {
                    found[candidate.id] = candidate
                    order.append(candidate.id)
                }
            }
        }
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return order.compactMap { found[$0] }.sorted {
            if $0.lists.count != $1.lists.count { return $0.lists.count > $1.lists.count }
            if $0.official != $1.official { return $0.official }
            return position[$0.id]! < position[$1.id]!
        }
    }
}

extension SkillGitHub {
    /// One list's candidates, read from raw.githubusercontent.com at its default branch.
    static func candidates(of list: SkillSourceFinder.List, fetch: Fetch = SkillGitHub.fetch) async throws -> [SkillSourceFinder.Candidate] {
        guard let url = URL(string: "\(raw)/\(list.repo.owner)/\(list.repo.repo)/HEAD/\(list.file)") else { throw Failure(reason: "not-found") }
        let (data, status) = try await fetch(url)
        switch status {
        case 200: break
        case 404: throw Failure(reason: "not-found")
        case 403, 429: throw Failure(reason: "rate-limit")
        default: throw Failure(reason: "HTTP \(status)")
        }
        guard data.count <= 5_000_000 else { throw Failure(reason: "too-large") }
        switch list.kind {
        case .awesome:
            guard let text = String(data: data, encoding: .utf8) else { throw Failure(reason: "unreadable") }
            return SkillSourceFinder.fromMarkdown(text, list: list.repo)
        case .marketplace:
            return SkillSourceFinder.fromMarketplace(data, list: list.repo)
        }
    }

    /// GitHub's repository search for a topic, most stars first; `words` narrows it. Costs one of 10 searches a minute.
    static func search(topic: String, words: String = "", fetch: Fetch = SkillGitHub.fetch) async throws -> [SkillSourceFinder.Candidate] {
        let typed = String(words.filter { !$0.isNewline }.prefix(100)).trimmingCharacters(in: .whitespaces)
        let query = (typed.isEmpty ? "" : typed + " ") + "topic:\(topic) fork:false archived:false"
        var components = URLComponents(string: "\(api)/search/repositories")!
        components.queryItems = [.init(name: "q", value: query), .init(name: "sort", value: "stars"), .init(name: "order", value: "desc"),
                                 .init(name: "per_page", value: "50")]
        guard let url = components.url else { throw Failure(reason: "not-found") }
        let (data, status) = try await fetch(url)
        switch status {
        case 200: return SkillSourceFinder.fromSearch(data)
        case 403, 429: throw Failure(reason: "rate-limit")
        case 422: return []
        default: throw Failure(reason: "HTTP \(status)")
        }
    }
}

/// The index: every repository the open lists name, kept in the catalog file so it can be searched without the network
/// and without downloading anything. A repository's files are fetched only when the person asks for it to be checked —
/// then it becomes an ordinary source.
extension SkillCatalog {
    static let indexMigration = """
        CREATE TABLE skill_index (
            slug        TEXT PRIMARY KEY COLLATE NOCASE,   -- owner/repo
            owner       TEXT NOT NULL,
            repo        TEXT NOT NULL,
            title       TEXT,
            summary     TEXT,
            lists       TEXT NOT NULL,                     -- the lists that name it, one per line
            paths       TEXT NOT NULL,                     -- folders inside it the lists point at, one per line
            position    INTEGER NOT NULL,                  -- most-named first
            fetched_at  TEXT NOT NULL
        );
        """

    struct IndexEntry: Identifiable, Equatable, Sendable {
        var candidate: SkillSourceFinder.Candidate
        var id: String { candidate.id }
        /// Already a source: its skills are in the catalog.
        var sourceID: Int?
        /// Skills the catalog holds from it.
        var skills: Int
    }

    struct IndexPage: Equatable, Sendable {
        var entries: [IndexEntry] = []
        /// All matches, of which `entries` are the first.
        var matches = 0
        /// Everything in the index.
        var total = 0
        var fetchedAt: String?
    }

    /// Replaces the index with what the lists say now. An empty answer (no list could be read) keeps the old one.
    func replaceIndex(_ candidates: [SkillSourceFinder.Candidate], now: String = SkillCatalog.now()) throws {
        guard !candidates.isEmpty else { return }
        try db.transaction {
            try db.run("DELETE FROM skill_index")
            for (position, candidate) in candidates.prefix(SkillSourceFinder.maxCandidates * 2).enumerated() {
                try db.run("""
                    INSERT OR IGNORE INTO skill_index (slug, owner, repo, title, summary, lists, paths, position, fetched_at)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                    """, .text(candidate.repo.slug), .text(candidate.repo.owner), .text(candidate.repo.repo), .optional(candidate.title),
                           .optional(candidate.summary), .text(candidate.lists.joined(separator: "\n")), .text(candidate.paths.joined(separator: "\n")),
                           .int(Int64(position)), .text(now))
            }
        }
    }

    /// When the index was last filled, or nil if never.
    func indexFetchedAt() throws -> String? {
        try db.first("SELECT max(fetched_at) FROM skill_index", map: { $0.optionalText(0) }) ?? nil
    }

    /// The index matching every word of `query` in its name, title, description or folders; most-named first.
    func index(query: String = "", limit: Int = 100) throws -> IndexPage {
        var conditions: [String] = []
        var values: [SQLiteDB.Value] = []
        for word in query.lowercased().split(whereSeparator: \.isWhitespace).prefix(8) {
            let escaped = String(word).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            values.append(.text("%\(escaped)%"))
            let n = values.count
            conditions.append("(i.slug LIKE ?\(n) ESCAPE '\\' OR coalesce(i.title, '') LIKE ?\(n) ESCAPE '\\' OR coalesce(i.summary, '') LIKE ?\(n) ESCAPE '\\' OR i.paths LIKE ?\(n) ESCAPE '\\')")
        }
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        var page = IndexPage()
        page.total = try db.first("SELECT count(*) FROM skill_index", map: { $0.int(0) }) ?? 0
        page.matches = try db.query("SELECT count(*) FROM skill_index i \(filter)", values, map: { $0.int(0) }).first ?? 0
        page.fetchedAt = try indexFetchedAt()
        page.entries = try db.query("""
            SELECT i.owner, i.repo, i.title, i.summary, i.lists, i.paths,
                   (SELECT o.id FROM skill_sources o WHERE o.kind = 'github' AND lower(o.owner || '/' || o.repo) = lower(i.slug)),
                   (SELECT count(*) FROM skills s WHERE s.source = 'github' AND lower(s.repo_url) = lower('https://github.com/' || i.slug))
            FROM skill_index i \(filter) ORDER BY i.position LIMIT \(max(1, min(limit, 1000)))
            """, values) { row in
            let lines = { (text: String) in text.split(separator: "\n").map(String.init) }
            return IndexEntry(candidate: SkillSourceFinder.Candidate(repo: GitHubRepo(owner: row.text(0), repo: row.text(1)), title: row.optionalText(2),
                                                                     summary: row.optionalText(3), lists: lines(row.text(4)), paths: lines(row.text(5))),
                              sourceID: row.optionalInt(6), skills: row.int(7))
        }
        return page
    }
}
