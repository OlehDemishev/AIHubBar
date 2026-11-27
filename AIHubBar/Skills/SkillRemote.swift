import Foundation

/// Skills from GitHub repositories (docs/specs/SPEC-skills.md, «Удалённые источники»). A source is a public repository;
/// the catalog finds every folder with a SKILL.md in its tree at one commit, the app downloads those folders' files into
/// its own cache (`SkillGitHub`), and they are checked by the same scanner as installed skills. A remote skill's row has
/// `source = 'github'`, `repo_url`, the folder inside the repository (`repo_path`), the commit and its cache folder as
/// `path`, so a card, a preview, an AI review and an install read it like any folder. Nothing is run.
extension SkillCatalog {
    static let remoteMigration = """
        CREATE TABLE skill_sources (
            id          INTEGER PRIMARY KEY,
            kind        TEXT NOT NULL DEFAULT 'github',
            owner       TEXT NOT NULL,
            repo        TEXT NOT NULL,
            branch      TEXT,                              -- the default branch, as GitHub said last time
            commit_sha  TEXT,                              -- the commit the catalog holds
            stars       INTEGER,
            license     TEXT,
            official    INTEGER NOT NULL DEFAULT 0,
            added_at    TEXT NOT NULL,
            checked_at  TEXT,
            error       TEXT,                              -- why the last check failed
            UNIQUE (kind, owner, repo)
        );
        ALTER TABLE skills ADD COLUMN repo_path TEXT;
        """

    /// Owners whose repositories are marked official: the makers of the agents.
    static let officialOwners: Set<String> = ["anthropics", "openai", "google-gemini", "cursor"]

    /// Suggested when the catalog has no source yet: Anthropic's own skills.
    static let suggestedSources = ["anthropics/skills"]

    struct GitHubRepo: Equatable, Hashable, Sendable {
        var owner: String
        var repo: String
        var slug: String { "\(owner)/\(repo)" }
        var url: String { "https://github.com/\(owner)/\(repo)" }

        /// `owner/repo`, `github.com/owner/repo`, `https://github.com/owner/repo(.git)(/tree/…)`. Only GitHub's own
        /// characters are let through, so nothing in a typed name can reach the API or the cache path as something else.
        static func parse(_ text: String) -> GitHubRepo? {
            var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["https://", "http://", "www."] where value.lowercased().hasPrefix(prefix) { value.removeFirst(prefix.count) }
            if value.lowercased().hasPrefix("github.com/") { value.removeFirst("github.com/".count) } else if value.contains("://") || value.contains("github.") { return nil }
            let parts = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { return nil }
            let owner = parts[0]
            var repo = parts[1]
            if repo.hasSuffix(".git") { repo.removeLast(4) }
            func valid(_ name: String, extra: String) -> Bool {
                !name.isEmpty && name.count <= 100 && !name.hasPrefix(".") && name != ".." && name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || extra.contains($0) }
            }
            guard valid(owner, extra: "-"), valid(repo, extra: "-_.") else { return nil }
            return GitHubRepo(owner: owner, repo: repo)
        }
    }

    struct RemoteSource: Identifiable, Equatable, Sendable {
        var id: Int
        var repo: GitHubRepo
        var branch: String?
        var commitSHA: String?
        var stars: Int?
        var license: String?
        var official: Bool
        var checkedAt: String?
        var error: String?
        /// Skills the catalog holds from it now.
        var skills: Int
    }

    // MARK: - Sources

    func sources() throws -> [RemoteSource] {
        try db.query("""
            SELECT o.id, o.owner, o.repo, o.branch, o.commit_sha, o.stars, o.license, o.official, o.checked_at, o.error,
                   (SELECT count(*) FROM skills s WHERE s.source = 'github' AND s.repo_url = 'https://github.com/' || o.owner || '/' || o.repo)
            FROM skill_sources o ORDER BY o.official DESC, o.owner COLLATE NOCASE, o.repo COLLATE NOCASE
            """) { row in
            RemoteSource(id: row.int(0), repo: GitHubRepo(owner: row.text(1), repo: row.text(2)), branch: row.optionalText(3), commitSHA: row.optionalText(4),
                   stars: row.optionalInt(5), license: row.optionalText(6), official: row.bool(7), checkedAt: row.optionalText(8), error: row.optionalText(9),
                   skills: row.int(10))
        }
    }

    @discardableResult
    func addSource(_ repo: GitHubRepo, now: String = SkillCatalog.now()) throws -> Int {
        try db.run("INSERT OR IGNORE INTO skill_sources (kind, owner, repo, official, added_at) VALUES ('github', ?1, ?2, ?3, ?4)",
                   .text(repo.owner), .text(repo.repo), .bool(Self.officialOwners.contains(repo.owner.lowercased())), .text(now))
        return try db.first("SELECT id FROM skill_sources WHERE kind = 'github' AND owner = ?1 AND repo = ?2", .text(repo.owner), .text(repo.repo), map: { $0.int(0) }) ?? 0
    }

    /// Takes a source out with its skills. Installed copies stay where they are; their updates stop.
    func removeSource(_ id: Int) throws {
        guard let repo = try db.first("SELECT owner, repo FROM skill_sources WHERE id = ?1", .int(Int64(id)), map: { GitHubRepo(owner: $0.text(0), repo: $0.text(1)) }) else { return }
        try db.transaction {
            try db.run("DELETE FROM skills WHERE source = 'github' AND repo_url = ?1", .text(repo.url))
            try db.run("DELETE FROM skill_sources WHERE id = ?1", .int(Int64(id)))
        }
    }

    func noteSourceFailed(_ id: Int, error: String, now: String = SkillCatalog.now()) throws {
        try db.run("UPDATE skill_sources SET error = ?2, checked_at = ?3 WHERE id = ?1", .int(Int64(id)), .text(String(error.prefix(300))), .text(now))
    }

    // MARK: - A repository's tree

    struct TreeEntry: Equatable, Sendable {
        var path: String
        /// `blob`, `tree` or `commit` (a submodule).
        var type: String
        /// `100644`, `100755` (executable), `120000` (a link).
        var mode: String
        var size: Int
    }

    struct RemoteSkill: Equatable, Sendable {
        /// The folder inside the repository; empty for a skill at the root.
        var folder: String
        /// The files to download: plain files only, relative to `folder`.
        var files: [TreeEntry]
        /// Links and anything else left out, relative to `folder`.
        var leftOut: [String]
        /// Too many files or bytes: only part is downloaded, and the check says so.
        var truncated: Bool
    }

    /// At most this many skills are taken from one repository.
    static let maxRemoteSkills = 300

    /// The skills in a tree: every folder with a SKILL.md, with the files under it. Folders the scanner doesn't walk
    /// (`node_modules`, `.git`) are left out, links are never downloaded, and each skill keeps to the scanner's limits.
    static func remoteSkills(in tree: [TreeEntry], limits: SkillLimits = SkillLimits()) -> [RemoteSkill] {
        let blobs = tree.filter { $0.type == "blob" }
        let folders = blobs.filter { $0.path == "SKILL.md" || $0.path.hasSuffix("/SKILL.md") }
            .map { $0.path == "SKILL.md" ? "" : String($0.path.dropLast("/SKILL.md".count)) }
            .filter { folder in !folder.split(separator: "/").contains { ["node_modules", ".git", "__pycache__", ".venv", "venv"].contains(String($0)) } }
            .sorted()
            .prefix(maxRemoteSkills)
        return folders.map { folder in
            let prefix = folder.isEmpty ? "" : folder + "/"
            var files: [TreeEntry] = []
            var leftOut: [String] = []
            var truncated = false
            var total = 0
            for entry in tree where entry.path.hasPrefix(prefix) && entry.path != folder {
                let relative = String(entry.path.dropFirst(prefix.count))
                let parts = relative.split(separator: "/").map(String.init)
                if parts.contains(where: { ["node_modules", ".git", "__pycache__", ".venv", "venv", ".tox", "site-packages"].contains($0) }) {
                    if let skipped = parts.firstIndex(where: { ["node_modules", ".venv", "venv", "site-packages"].contains($0) }) {
                        let name = parts[...skipped].joined(separator: "/") + "/"
                        if !leftOut.contains(name) { leftOut.append(name) }
                    }
                    continue
                }
                guard entry.type == "blob" else { continue }
                if entry.mode == "120000" {
                    leftOut.append(relative)
                    continue
                }
                if files.count >= limits.maxFiles || entry.size > Int(limits.maxFileBytes) || total + entry.size > Int(limits.maxTotalBytes) {
                    truncated = true
                    continue
                }
                total += entry.size
                files.append(TreeEntry(path: relative, type: entry.type, mode: entry.mode, size: entry.size))
            }
            return RemoteSkill(folder: folder, files: files, leftOut: leftOut, truncated: truncated)
        }
    }

    // MARK: - Importing what was downloaded

    /// Puts the skills of one commit, already in their cache folders, into the catalog and checks them. The source's
    /// rows of older commits leave; a skill whose content didn't change keeps its check.
    @discardableResult
    func importRemote(_ repo: GitHubRepo, sha: String, branch: String, stars: Int?, license: String?, skills: [(folder: String, cache: URL, truncated: Bool)],
                      now: String = SkillCatalog.now()) throws -> Int {
        var loaded: [(String, URL, SkillFiles)] = []
        for skill in skills {
            guard var files = try? SkillFolder.read(skill.cache) else { continue }
            if skill.truncated { files.truncated = true }
            loaded.append((skill.folder, skill.cache, files))
        }
        let official = Self.officialOwners.contains(repo.owner.lowercased())
        return try db.transaction {
            try db.run("DELETE FROM skills WHERE source = 'github' AND repo_url = ?1 AND coalesce(commit_sha, '') <> ?2", .text(repo.url), .text(sha))
            for (folder, cache, files) in loaded {
                let hash = files.contentHash
                let described = Self.describe(files, folder: folder.isEmpty ? repo.repo : folder, listedName: nil)
                let id: Int
                if let known = try db.first("SELECT id FROM skills WHERE repo_url = ?1 AND path = ?2 AND content_hash = ?3", .text(repo.url), .text(cache.path), .text(hash), map: { $0.int(0) }) {
                    id = known
                } else {
                    try db.run("""
                        INSERT INTO skills (kind, name, description, source, repo_url, path, commit_sha, content_hash, license, agents, official, stars, updated_at, author, homepage, repo_path)
                        VALUES ('skill', ?1, ?2, 'github', ?3, ?4, ?5, ?6, ?7, '[]', ?8, ?9, ?10, ?11, ?12, ?13)
                        """, .text(described.name), .text(described.description), .text(repo.url), .text(cache.path), .text(sha), .text(hash),
                               .optional(described.license ?? license), .bool(official), .optional(stars), .text(now), .optional(described.author ?? repo.owner),
                               .text(described.homepage ?? repo.url), .text(folder))
                    id = db.lastInsertID
                }
                try db.run("UPDATE skills SET stars = ?2, official = ?3 WHERE id = ?1", .int(Int64(id)), .optional(stars), .bool(official))
                if try db.first("SELECT 1 FROM scan_results WHERE skill_id = ?1 AND scanner_version = ?2", .int(Int64(id)), .int(Int64(SkillReport.scannerVersion)), map: { _ in true }) == nil {
                    try save(SkillScanner.scan(files), skill: id, now: now)
                }
            }
            try db.run("""
                UPDATE skill_sources SET branch = ?3, commit_sha = ?4, stars = ?5, license = ?6, checked_at = ?7, error = NULL, official = ?8
                WHERE kind = 'github' AND owner = ?1 AND repo = ?2
                """, .text(repo.owner), .text(repo.repo), .text(branch), .text(sha), .optional(stars), .optional(license), .text(now), .bool(official))
            return loaded.count
        }
    }

    /// The cache folders the catalog still points at: everything else in the cache can go.
    func remoteCacheFolders() throws -> Set<String> {
        Set(try db.query("SELECT path FROM skills WHERE source = 'github'") { $0.text(0) })
    }

    /// Where a remote skill's files are now, for a copy the catalog installed from it: its row of the newest commit.
    func remoteFolder(repoURL: String, repoPath: String) throws -> URL? {
        try db.first("SELECT path FROM skills WHERE source = 'github' AND repo_url = ?1 AND coalesce(repo_path, '') = ?2 ORDER BY id DESC LIMIT 1",
                     .text(repoURL), .text(repoPath), map: { URL(fileURLWithPath: $0.text(0)) })
    }

    /// Sources a skill row can be read from on this Mac: installed folders, added folders, downloaded copies.
    static func isReadable(_ source: String) -> Bool { ["local", "folder", "github"].contains(source) }
}
