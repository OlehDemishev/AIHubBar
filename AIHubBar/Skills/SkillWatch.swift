import Foundation

/// Watching for changes made outside the catalog, the person's install policy and trusted authors
/// (docs/specs/SPEC-skills.md, step 6). Each refresh compares the skills on disk with the last one by kind and name:
/// a new name «appeared», a known name with content not seen before «changed», a name that left «gone». A skill
/// switched off or moved keeps its name and content, so it is no event. Changes the catalog made itself are recorded
/// as such and never announced.
extension SkillCatalog {
    static let watchMigration = """
        CREATE TABLE skill_events (
            id            INTEGER PRIMARY KEY,
            at            TEXT NOT NULL,
            event         TEXT NOT NULL,                   -- appeared | changed | gone
            kind          TEXT NOT NULL,
            name          TEXT NOT NULL,
            content_hash  TEXT,
            verdict       TEXT,
            by_catalog    INTEGER NOT NULL DEFAULT 0,
            seen          INTEGER NOT NULL DEFAULT 0,
            announced     INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE skill_policy (
            key    TEXT PRIMARY KEY,
            value  TEXT NOT NULL
        );
        CREATE TABLE trusted_authors (
            name      TEXT PRIMARY KEY COLLATE NOCASE,
            added_at  TEXT NOT NULL
        );
        """

    // MARK: - What is on disk, by kind and name

    /// The installed contents of each skill: kind and name → content hashes.
    func installedContents() throws -> [String: Set<String>] {
        var contents: [String: Set<String>] = [:]
        for (kind, name, hash) in try db.query("SELECT kind, name, content_hash FROM skills WHERE source = 'local'", map: { ($0.text(0), $0.text(1), $0.text(2)) }) {
            contents["\(kind)\n\(name)", default: []].insert(hash)
        }
        return contents
    }

    /// Writes what changed between two looks at the disk. The first look of a new catalog is the starting point:
    /// nothing in it is «new».
    func recordChanges(before: [String: Set<String>], wasEmpty: Bool, byCatalog: Bool, now: String) throws {
        guard !wasEmpty else { return }
        let after = try installedContents()
        func add(_ event: String, _ key: String, hash: String?) throws {
            let parts = key.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            let verdict = try hash.flatMap { hash in
                try db.first("SELECT r.effective FROM scan_results r JOIN skills s ON s.id = r.skill_id WHERE s.content_hash = ?1 LIMIT 1", .text(hash), map: { $0.text(0) })
            }
            try db.run("INSERT INTO skill_events (at, event, kind, name, content_hash, verdict, by_catalog, seen, announced) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, ?7)",
                       .text(now), .text(event), .text(parts[0]), .text(parts[1]), .optional(hash), .optional(verdict), .bool(byCatalog))
        }
        try db.transaction {
            for (key, hashes) in after.sorted(by: { $0.key < $1.key }) {
                if let old = before[key] {
                    for hash in hashes.subtracting(old).sorted() { try add("changed", key, hash: hash) }
                } else {
                    for hash in hashes.sorted() { try add("appeared", key, hash: hash) }
                }
            }
            for key in before.keys.sorted() where after[key] == nil { try add("gone", key, hash: nil) }
        }
    }

    struct Event: Identifiable, Equatable, Sendable {
        var id: Int
        var at: String
        /// `appeared`, `changed` or `gone`.
        var event: String
        var kind: String
        var name: String
        var contentHash: String?
        var verdict: SkillVerdict?
        var byCatalog: Bool
        var seen: Bool
        /// The catalog's entry now, when the skill is still there.
        var skillID: Int?
        var isTrusted: Bool
    }

    private static let eventColumns = """
        e.id, e.at, e.event, e.kind, e.name, e.content_hash, e.verdict, e.by_catalog, e.seen,
        (SELECT min(s.id) FROM skills s WHERE s.kind = e.kind AND s.name = e.name AND (e.content_hash IS NULL OR s.content_hash = e.content_hash)),
        EXISTS (SELECT 1 FROM skills s WHERE s.kind = e.kind AND s.name = e.name AND \(trustedSQL))
        """

    private func event(_ row: SQLiteDB.Row) -> Event {
        Event(id: row.int(0), at: row.text(1), event: row.text(2), kind: row.text(3), name: row.text(4), contentHash: row.optionalText(5),
              verdict: row.optionalText(6).flatMap(SkillVerdict.init), byCatalog: row.bool(7), seen: row.bool(8), skillID: row.optionalInt(9), isTrusted: row.bool(10))
    }

    /// What changed outside the catalog, the newest first.
    func events(limit: Int = 100) throws -> [Event] {
        try db.query("SELECT \(Self.eventColumns) FROM skill_events e WHERE e.by_catalog = 0 ORDER BY e.id DESC LIMIT ?1", .int(Int64(limit)), map: event)
    }

    func unseenEvents() throws -> Int {
        try db.first("SELECT count(*) FROM skill_events WHERE by_catalog = 0 AND seen = 0", map: { $0.int(0) }) ?? 0
    }

    func markEventsSeen() throws {
        try db.run("UPDATE skill_events SET seen = 1 WHERE seen = 0")
    }

    /// The changes to tell the person about, each once: outside the catalog, not «gone», and from a trusted author
    /// only when the new content is dangerous.
    func eventsToAnnounce() throws -> [Event] {
        guard policy.notifyOutside else {
            try db.run("UPDATE skill_events SET announced = 1 WHERE announced = 0")
            return []
        }
        let fresh = try db.query("SELECT \(Self.eventColumns) FROM skill_events e WHERE e.announced = 0 AND e.by_catalog = 0 ORDER BY e.id", map: event)
        try db.run("UPDATE skill_events SET announced = 1 WHERE announced = 0")
        return fresh.filter { $0.event != "gone" && (!$0.isTrusted || $0.verdict == .dangerous) }
    }

    /// The newer versions the person was not told about yet; each is remembered, so a notification comes once per version.
    func updatesToAnnounce() throws -> [Update] {
        var fresh: [Update] = []
        for update in try updates() {
            let told = try db.first("SELECT notified_hash FROM managed_installs WHERE install_path = ?1", .text(update.installPath), map: { $0.optionalText(0) }) ?? nil
            if told != update.toHash {
                try db.run("UPDATE managed_installs SET notified_hash = ?2 WHERE install_path = ?1", .text(update.installPath), .text(update.toHash))
                fresh.append(update)
            }
        }
        return fresh
    }

    // MARK: - The install policy

    struct Policy: Equatable, Sendable {
        enum Install: String, CaseIterable, Sendable {
            /// Any verdict; «review» and «dangerous» after the person ticks the box.
            case all
            /// Never «dangerous», even with the box ticked.
            case noDangerous
            /// Only «safe».
            case safeOnly
        }

        var install = Install.all
        /// Only skills from a trusted author can be installed.
        var trustedOnly = false
        /// Notifications about skills that appear or change outside the catalog.
        var notifyOutside = true
    }

    var policy: Policy {
        get {
            let values = Dictionary((try? db.query("SELECT key, value FROM skill_policy", map: { ($0.text(0), $0.text(1)) })) ?? [], uniquingKeysWith: { $1 })
            return Policy(install: values["install"].flatMap(Policy.Install.init) ?? .all, trustedOnly: values["trustedOnly"] == "1",
                          notifyOutside: values["notifyOutside"] != "0")
        }
        set {
            for (key, value) in [("install", newValue.install.rawValue), ("trustedOnly", newValue.trustedOnly ? "1" : "0"), ("notifyOutside", newValue.notifyOutside ? "1" : "0")] {
                _ = try? db.run("INSERT OR REPLACE INTO skill_policy (key, value) VALUES (?1, ?2)", .text(key), .text(value))
            }
        }
    }

    /// Why the policy refuses a plan: `policy-dangerous`, `policy-review`, `policy-trusted`, or nil.
    func policyRefusal(verdict: SkillVerdict, skillID: Int) throws -> String? {
        let policy = policy
        if policy.install == .noDangerous, verdict == .dangerous { return "policy-dangerous" }
        if policy.install == .safeOnly, verdict != .safe { return "policy-review" }
        if policy.trustedOnly {
            let trusted = try db.first("SELECT \(Self.trustedSQL) FROM skills s WHERE s.id = ?1", .int(Int64(skillID)), map: { $0.bool(0) }) ?? false
            if !trusted { return "policy-trusted" }
        }
        return nil
    }

    // MARK: - Trusted authors

    /// A skill row `s` whose author, or the owner of the GitHub repository it names, is trusted. Both are what the
    /// skill says about itself: trust only quiets notifications and narrows what may be installed, it never lowers a
    /// verdict or skips a confirmation.
    static let trustedSQL = """
        EXISTS (SELECT 1 FROM trusted_authors t WHERE t.name = s.author COLLATE NOCASE
                OR instr(lower(coalesce(s.homepage, '')), 'https://github.com/' || lower(t.name) || '/') = 1)
        """

    func trustedAuthors() throws -> [String] {
        try db.query("SELECT name FROM trusted_authors ORDER BY name COLLATE NOCASE", map: { $0.text(0) })
    }

    func trust(_ author: String, now: String = SkillCatalog.now()) throws {
        let name = String(author.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !name.isEmpty else { throw Refusal(code: "name") }
        try db.run("INSERT OR IGNORE INTO trusted_authors (name, added_at) VALUES (?1, ?2)", .text(name), .text(now))
    }

    func distrust(_ author: String) throws {
        try db.run("DELETE FROM trusted_authors WHERE name = ?1", .text(author))
    }

    /// The name to trust for a skill: its author, else the owner of the GitHub repository it names.
    static func authorToTrust(_ row: Row) -> String? {
        if let author = row.author, !author.isEmpty { return author }
        return githubRepository(row.homepage)?.pathComponents.dropFirst().first
    }
}
