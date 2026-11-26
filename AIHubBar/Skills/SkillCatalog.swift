import Foundation

/// The local catalog of Agent Skills: one SQLite file with every skill and plugin found on this Mac, the scanner's
/// result for each, where each is installed, and which skills the agents actually used. Port of
/// `desktop/skill-catalog` (stages 1–2), with usage added.
///
/// Reading a skill never runs it (`SkillScanner`), and nothing here writes into an agent's folders. Not thread-safe:
/// `SkillStore` makes every call from one queue.
final class SkillCatalog {
    let db: SQLiteDB

    /// The file's layout; raised with every change, each step in `migrations`.
    private static let migrations: [String] = [
        """
        CREATE TABLE skills (
            id            INTEGER PRIMARY KEY,
            kind          TEXT NOT NULL DEFAULT 'skill',   -- skill | plugin
            name          TEXT NOT NULL,
            description   TEXT NOT NULL DEFAULT '',
            source        TEXT NOT NULL,                   -- local; later folder, github and the catalog sites
            repo_url      TEXT NOT NULL DEFAULT '',
            path          TEXT NOT NULL,
            commit_sha    TEXT,
            content_hash  TEXT NOT NULL,
            license       TEXT,
            agents        TEXT NOT NULL DEFAULT '[]',
            official      INTEGER NOT NULL DEFAULT 0,
            stars         INTEGER,
            updated_at    TEXT NOT NULL,
            UNIQUE (repo_url, path, content_hash)
        );
        CREATE TABLE scan_results (
            skill_id        INTEGER PRIMARY KEY REFERENCES skills(id) ON DELETE CASCADE,
            scanner_version INTEGER NOT NULL,
            risk_score      INTEGER NOT NULL,
            verdict         TEXT NOT NULL,                 -- the static check's: safe | review | dangerous
            effective       TEXT NOT NULL,                 -- what the list shows: the static one, or a model's when stricter
            has_scripts     INTEGER NOT NULL,
            categories      TEXT NOT NULL,                 -- ',network,secrets,': findings worth reading
            counts          TEXT NOT NULL,                 -- critical, high, medium, low
            report_json     TEXT NOT NULL,
            scanned_at      TEXT NOT NULL
        );
        CREATE TABLE installations (
            id            INTEGER PRIMARY KEY,
            skill_id      INTEGER NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
            agent         TEXT NOT NULL,
            install_path  TEXT NOT NULL,
            scope         TEXT NOT NULL,
            project       TEXT,
            enabled       INTEGER NOT NULL DEFAULT 1,
            installed_at  TEXT NOT NULL,
            UNIQUE (agent, install_path)
        );
        CREATE INDEX installations_skill ON installations(skill_id);
        CREATE VIRTUAL TABLE skills_fts USING fts5(name, description, content='skills', content_rowid='id', tokenize='unicode61');
        CREATE TRIGGER skills_ai AFTER INSERT ON skills BEGIN
            INSERT INTO skills_fts(rowid, name, description) VALUES (new.id, new.name, new.description);
        END;
        CREATE TRIGGER skills_ad AFTER DELETE ON skills BEGIN
            INSERT INTO skills_fts(skills_fts, rowid, name, description) VALUES ('delete', old.id, old.name, old.description);
        END;
        CREATE TRIGGER skills_au AFTER UPDATE ON skills BEGIN
            INSERT INTO skills_fts(skills_fts, rowid, name, description) VALUES ('delete', old.id, old.name, old.description);
            INSERT INTO skills_fts(rowid, name, description) VALUES (new.id, new.name, new.description);
        END;
        -- Which skills the agents used, read from their session logs; each log is read from where it was left.
        CREATE TABLE skill_uses (
            name     TEXT NOT NULL,                        -- the skill's name as the agent called it, without a plugin prefix
            agent    TEXT NOT NULL,
            at       TEXT NOT NULL,
            log      TEXT NOT NULL,
            UNIQUE (log, at, name)
        );
        CREATE INDEX skill_uses_name ON skill_uses(name, at);
        CREATE TABLE log_offsets (
            path   TEXT PRIMARY KEY,
            size   INTEGER NOT NULL,
            offset INTEGER NOT NULL
        );
        """,
        """
        ALTER TABLE skills ADD COLUMN author TEXT;
        -- ',network,runsCode,': what the skill can do (`SkillAssessment`); NULL until worked out from the report.
        ALTER TABLE scan_results ADD COLUMN capabilities TEXT;
        -- A person's own marks, by kind and name: they stay when the skill is updated and its content changes.
        CREATE TABLE skill_marks (
            kind        TEXT NOT NULL,
            name        TEXT NOT NULL,
            favorite    INTEGER NOT NULL DEFAULT 0,
            note        TEXT NOT NULL DEFAULT '',
            updated_at  TEXT NOT NULL,
            PRIMARY KEY (kind, name)
        );
        CREATE TABLE saved_filters (
            id          INTEGER PRIMARY KEY,
            name        TEXT NOT NULL,
            filters     TEXT NOT NULL,                     -- `Filters` as JSON
            created_at  TEXT NOT NULL
        );
        """,
        // Step 4: what the catalog installed itself, and the journal of every change in the agents' folders.
        manageMigration,
        // Step 5: complaints and the block list.
        reportsMigration,
        // Step 6: changes made outside the catalog, the install policy, trusted authors.
        watchMigration,
        // Step 7: the AI review.
        reviewMigration,
        // Step 8: named sets.
        housekeepingMigration,
    ]

    init(path: String) throws {
        db = try SQLiteDB(path: path)
        let version = db.userVersion
        guard version <= Self.migrations.count else { throw SQLiteDB.Failure(message: "the catalog was written by a newer version (layout \(version))") }
        for (step, sql) in Self.migrations.enumerated().dropFirst(version) {
            try db.transaction {
                try db.execute(sql)
                db.userVersion = step + 1
            }
        }
        try fillCapabilities()
    }

    /// Works out what each checked skill can do where it isn't known yet: after the layout's step 2.
    private func fillCapabilities() throws {
        let missing = try db.query("SELECT skill_id, report_json FROM scan_results WHERE capabilities IS NULL") { ($0.int(0), $0.text(1)) }
        guard !missing.isEmpty else { return }
        try db.transaction {
            for (id, json) in missing {
                guard let report = try? JSONDecoder().decode(SkillReport.self, from: Data(json.utf8)) else { continue }
                try db.run("UPDATE scan_results SET capabilities = ?2 WHERE skill_id = ?1", .int(Int64(id)), .text(Self.capabilities(report)))
            }
        }
    }

    static func capabilities(_ report: SkillReport) -> String {
        let assessment = SkillAssessment(report, llmVerdict: nil)
        let present = SkillAssessment.Capability.allCases.filter { assessment.level($0) != .none }.map(\.rawValue)
        return present.isEmpty ? "" : "," + present.joined(separator: ",") + ","
    }

    static func now() -> String { ISO8601DateFormatter().string(from: .now) }

    // MARK: - What a folder is

    struct Described: Equatable {
        var name: String
        var description: String
        var license: String?
        var author: String?
        /// Where the skill says it lives: a repository or a home page.
        var homepage: String?
    }

    /// The name, description and license a skill or plugin gives itself; the folder's name when it gives none.
    static func describe(_ files: SkillFiles, folder: String, listedName: String?) -> Described {
        let fallback = listedName ?? (folder as NSString).lastPathComponent
        if let text = files.file("SKILL.md")?.text {
            let meta = SkillScanner.frontmatter(text)
            func value(_ key: String) -> String? { meta.first { $0.key == key }.map(\.value).flatMap { $0.isEmpty ? nil : $0 } }
            // `description: >` puts the text on the following lines.
            var description = value("description") ?? ""
            if [">", "|", ">-", "|-"].contains(description) || description.isEmpty { description = foldedDescription(text) }
            return Described(name: value("name") ?? fallback, description: description, license: value("license"), author: value("author") ?? metadata("author", text),
                             homepage: value("homepage") ?? value("repository") ?? metadata("repository", text) ?? metadata("homepage", text))
        }
        for manifest in [".claude-plugin/plugin.json", "gemini-extension.json"] {
            guard let data = files.file(manifest)?.bytes, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            func value(_ key: String) -> String? { (root[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            let author = value("author") ?? ((root["author"] as? [String: Any])?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let repository = value("repository") ?? ((root["repository"] as? [String: Any])?["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Described(name: listedName ?? value("name") ?? fallback, description: value("description") ?? "", license: value("license"), author: author,
                             homepage: repository ?? value("homepage"))
        }
        return Described(name: fallback, description: "", license: nil, author: nil, homepage: nil)
    }

    /// A field indented under `metadata:`, where the Agent Skills standard puts extra fields (`author`, `repository`).
    private static func metadata(_ key: String, _ text: String) -> String? {
        var inside = false
        for line in SkillScanner.lines(text).dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if line.hasPrefix("metadata:") { inside = true; continue }
            guard inside else { continue }
            guard line.hasPrefix(" ") || line.hasPrefix("\t") else { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { continue }
            var value = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) { value = String(value.dropFirst().dropLast()) }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func foldedDescription(_ text: String) -> String {
        var words: [String] = []
        var inside = false
        for line in SkillScanner.lines(text).dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if line.hasPrefix("description:") { inside = true; continue }
            guard inside else { continue }
            guard line.hasPrefix(" ") || line.hasPrefix("\t") else { break }
            words.append(line.trimmingCharacters(in: .whitespaces))
        }
        return words.joined(separator: " ")
    }

    // MARK: - Refreshing what is installed

    struct Refreshed: Equatable, Sendable {
        var found = 0
        /// Checked now: new, changed, or checked before by older rules.
        var scanned = 0
        /// No longer on disk.
        var removed = 0
        /// Folders that could not be read.
        var failed: [String] = []
    }

    /// Finds every installed skill and plugin, checks the new and changed ones, forgets the ones that are gone. A
    /// folder whose content didn't change keeps its result, unless the scanner's rules are newer.
    @discardableResult
    func refreshInstalled(_ roots: SkillRoots, now: String = SkillCatalog.now(), byCatalog: Bool = false) throws -> Refreshed {
        let before = try installedContents()
        let wasEmpty = try db.first("SELECT count(*) FROM skills WHERE source = 'local'", map: { $0.int(0) }) == 0
            && db.first("SELECT count(*) FROM skill_events", map: { $0.int(0) }) == 0
        let found = SkillDiscovery.discover(roots)
        var stats = Refreshed(found: found.count)
        // Reading and checking happen before the transaction: the file stays free for readers meanwhile.
        var loaded: [(FoundSkill, SkillFiles)] = []
        for entry in found {
            do { loaded.append((entry, try SkillFolder.read(URL(fileURLWithPath: entry.folder)))) } catch { stats.failed.append("\(entry.folder): \(error.localizedDescription)") }
        }
        try db.transaction {
            var keptSkills: [Int] = []
            var keptPlaces: [Int] = []
            for (entry, files) in loaded {
                let hash = files.contentHash
                let described = Self.describe(files, folder: entry.folder, listedName: entry.listedName)
                let agents = Array(Set(entry.places.map(\.agent.rawValue))).sorted()
                let agentsJSON = String(decoding: (try? JSONEncoder().encode(agents)) ?? Data("[]".utf8), as: UTF8.self)
                let id: Int
                if let known = try db.first("SELECT id FROM skills WHERE repo_url = '' AND path = ?1 AND content_hash = ?2", .text(entry.folder), .text(hash), map: { $0.int(0) }) {
                    id = known
                    try db.run("UPDATE skills SET kind = ?2, name = ?3, description = ?4, license = ?5, agents = ?6, author = ?7, homepage = ?8 WHERE id = ?1",
                               .int(Int64(id)), .text(entry.kind), .text(described.name), .text(described.description), .optional(described.license), .text(agentsJSON),
                               .optional(described.author), .optional(described.homepage))
                } else {
                    try db.run("INSERT INTO skills (kind, name, description, source, path, content_hash, license, agents, updated_at, author, homepage) VALUES (?1, ?2, ?3, 'local', ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                               .text(entry.kind), .text(described.name), .text(described.description), .text(entry.folder), .text(hash), .optional(described.license), .text(agentsJSON), .text(now),
                               .optional(described.author), .optional(described.homepage))
                    id = db.lastInsertID
                }
                keptSkills.append(id)
                let checked = try db.first("SELECT 1 FROM scan_results WHERE skill_id = ?1 AND scanner_version = ?2", .int(Int64(id)), .int(Int64(SkillReport.scannerVersion)), map: { _ in true }) ?? false
                if !checked {
                    try save(SkillScanner.scan(files), skill: id, now: now)
                    stats.scanned += 1
                }
                for place in entry.places {
                    try db.run("""
                        INSERT INTO installations (skill_id, agent, install_path, scope, project, enabled, installed_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                        ON CONFLICT (agent, install_path) DO UPDATE SET skill_id = excluded.skill_id, scope = excluded.scope, project = excluded.project, enabled = excluded.enabled
                        """, .int(Int64(id)), .text(place.agent.rawValue), .text(place.installPath), .text(place.scope), .optional(place.project), .bool(place.isEnabled), .text(now))
                    if let placeID = try db.first("SELECT id FROM installations WHERE agent = ?1 AND install_path = ?2", .text(place.agent.rawValue), .text(place.installPath), map: { $0.int(0) }) {
                        keptPlaces.append(placeID)
                    }
                }
            }
            // What is no longer on disk. A folder that failed to read keeps what was known about it.
            if stats.failed.isEmpty {
                let places = keptPlaces.map(String.init).joined(separator: ",")
                let skills = keptSkills.map(String.init).joined(separator: ",")
                try db.run("DELETE FROM installations WHERE id NOT IN (\(places)) AND skill_id IN (SELECT id FROM skills WHERE source = 'local')")
                stats.removed = try db.run("DELETE FROM skills WHERE source = 'local' AND id NOT IN (\(skills))")
            }
        }
        // Added folders follow their folder: a changed one is checked again, a gone one leaves the catalog.
        for (id, path, hash) in try db.query("SELECT id, path, content_hash FROM skills WHERE source = 'folder'", map: { ($0.int(0), $0.text(1), $0.text(2)) }) {
            guard let files = try? SkillFolder.read(URL(fileURLWithPath: path)) else {
                try db.run("DELETE FROM skills WHERE id = ?1", .int(Int64(id)))
                continue
            }
            if files.contentHash != hash { try importFolder(URL(fileURLWithPath: path), now: now) }
        }
        // A folder that could not be read is not «gone»: changes are compared only after a clean look.
        if stats.failed.isEmpty { try recordChanges(before: before, wasEmpty: wasEmpty, byCatalog: byCatalog, now: now) }
        return stats
    }

    func save(_ report: SkillReport, skill: Int, now: String) throws {
        let categories = Set(report.findings.filter { $0.severity >= .low }.map(\.category.rawValue)).sorted()
        let counts = Self.counts(report.findings)
        try db.run("""
            INSERT OR REPLACE INTO scan_results (skill_id, scanner_version, risk_score, verdict, effective, has_scripts, categories, counts, report_json, scanned_at, capabilities)
            VALUES (?1, ?2, ?3, ?4, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            """, .int(Int64(skill)), .int(Int64(report.scannerVersion)), .int(Int64(report.riskScore)), .text(report.verdict.rawValue), .bool(report.hasScripts),
                   .text(categories.isEmpty ? "" : "," + categories.joined(separator: ",") + ","), .text(counts.map(String.init).joined(separator: ",")),
                   .text(String(decoding: try JSONEncoder().encode(report), as: UTF8.self)), .text(now), .text(Self.capabilities(report)))
        // A model's stricter verdict about this content stays when the content is checked again or found in a new place.
        if try rememberedVerdict(contentHash: report.contentHash) != nil { try applyReview(contentHash: report.contentHash) }
    }

    /// How many findings of each severity, most serious first: critical, high, medium, low.
    static func counts(_ findings: [SkillFinding]) -> [Int] {
        [SkillSeverity.critical, .high, .medium, .low].map { severity in findings.filter { $0.severity == severity }.count }
    }

    // MARK: - The list

    /// Everything the list can be narrowed and ordered by. Saved as JSON (`saved_filters`): a field added later reads
    /// as its default from an older saved filter.
    struct Filters: Hashable, Codable, Sendable {
        enum Sort: String, Codable, CaseIterable, Sendable {
            /// The most dangerous first.
            case risk
            case name
            /// The most used in 30 days first.
            case mostUsed
            /// Added or changed most recently first.
            case newest
        }

        enum State: String, Codable, CaseIterable, Sendable {
            case any
            /// Switched on for at least one agent.
            case on
            /// Installed, but switched off everywhere.
            case off
        }

        enum Usage: String, Codable, CaseIterable, Sendable {
            case any
            /// Used in the last 30 days.
            case used
            case unused
        }

        /// Words of the name and description, or of the person's note.
        var query = ""
        var verdict: SkillVerdict?
        var minRisk = 0
        var maxRisk = 100
        /// Installed for any of these agents.
        var agents: Set<SkillAgent> = []
        /// Installed in any of these places: `user`, `project`, `plugin`, `extension`.
        var scopes: Set<String> = []
        /// `skill` or `plugin`.
        var kind: String?
        /// Has a finding of any of these kinds.
        var findings: Set<SkillCategory> = []
        /// Can do every one of these.
        var can: Set<SkillAssessment.Capability> = []
        /// Can do none of these.
        var cannot: Set<SkillAssessment.Capability> = []
        var noScripts = false
        var state = State.any
        var usage = Usage.any
        var favoritesOnly = false
        var withNote = false
        /// Only the skills on the block list.
        var blockedOnly = false
        /// Only the skills the person complained about.
        var withReport = false
        /// Only the skills of trusted authors.
        var trustedOnly = false
        /// Only the skills a language model reviewed.
        var aiReviewed = false
        /// Only the skills of this set.
        var set: String?
        /// A license by name; an empty one means skills without a license.
        var license: String?
        var author: String?
        /// Added or changed in the last days.
        var newWithinDays: Int?
        var sort = Sort.risk

        init(query: String = "", verdict: SkillVerdict? = nil, agents: Set<SkillAgent> = [], findings: Set<SkillCategory> = [], noScripts: Bool = false) {
            self.query = query
            self.verdict = verdict
            self.agents = agents
            self.findings = findings
            self.noScripts = noScripts
        }

        /// How many of the filters beyond the search, the verdict, «Избранное» and the order are set: for the filter
        /// button. Those four have their own controls above the list.
        var activeCount: Int {
            var plain = self
            plain.query = ""
            plain.verdict = nil
            plain.sort = .risk
            let all: [Bool] = [
                plain.minRisk > 0 || plain.maxRisk < 100, !agents.isEmpty, !scopes.isEmpty, kind != nil, !findings.isEmpty, !can.isEmpty, !cannot.isEmpty,
                noScripts, state != .any, usage != .any, withNote, blockedOnly, withReport, trustedOnly, aiReviewed, set != nil, license != nil, author != nil, newWithinDays != nil,
            ]
            return all.filter { $0 }.count
        }

        private enum CodingKeys: String, CodingKey {
            case query, verdict, minRisk, maxRisk, agents, scopes, kind, findings, can, cannot, noScripts, state, usage, favoritesOnly, withNote, blockedOnly, withReport, trustedOnly, aiReviewed, set, license, author, newWithinDays, sort
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Values this version doesn't know (a newer verdict, agent or capability) are left out, not a failure.
            func strings(_ key: CodingKeys) -> [String] { ((try? c.decodeIfPresent([String].self, forKey: key)) ?? nil) ?? [] }
            func string(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
            func int(_ key: CodingKeys) -> Int? { (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil }
            query = string(.query) ?? ""
            verdict = string(.verdict).flatMap(SkillVerdict.init)
            minRisk = int(.minRisk) ?? 0
            maxRisk = int(.maxRisk) ?? 100
            agents = Set(strings(.agents).compactMap(SkillAgent.init))
            scopes = Set(strings(.scopes))
            kind = string(.kind)
            findings = Set(strings(.findings).compactMap(SkillCategory.init))
            can = Set(strings(.can).compactMap(SkillAssessment.Capability.init))
            cannot = Set(strings(.cannot).compactMap(SkillAssessment.Capability.init))
            noScripts = ((try? c.decodeIfPresent(Bool.self, forKey: .noScripts)) ?? nil) ?? false
            state = string(.state).flatMap(State.init) ?? .any
            usage = string(.usage).flatMap(Usage.init) ?? .any
            favoritesOnly = ((try? c.decodeIfPresent(Bool.self, forKey: .favoritesOnly)) ?? nil) ?? false
            withNote = ((try? c.decodeIfPresent(Bool.self, forKey: .withNote)) ?? nil) ?? false
            blockedOnly = ((try? c.decodeIfPresent(Bool.self, forKey: .blockedOnly)) ?? nil) ?? false
            withReport = ((try? c.decodeIfPresent(Bool.self, forKey: .withReport)) ?? nil) ?? false
            trustedOnly = ((try? c.decodeIfPresent(Bool.self, forKey: .trustedOnly)) ?? nil) ?? false
            aiReviewed = ((try? c.decodeIfPresent(Bool.self, forKey: .aiReviewed)) ?? nil) ?? false
            set = string(.set)
            license = string(.license)
            author = string(.author)
            newWithinDays = int(.newWithinDays)
            sort = string(.sort).flatMap(Sort.init) ?? .risk
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(query, forKey: .query)
            try c.encodeIfPresent(verdict?.rawValue, forKey: .verdict)
            try c.encode(minRisk, forKey: .minRisk)
            try c.encode(maxRisk, forKey: .maxRisk)
            try c.encode(agents.map(\.rawValue).sorted(), forKey: .agents)
            try c.encode(scopes.sorted(), forKey: .scopes)
            try c.encodeIfPresent(kind, forKey: .kind)
            try c.encode(findings.map(\.rawValue).sorted(), forKey: .findings)
            try c.encode(can.map(\.rawValue).sorted(), forKey: .can)
            try c.encode(cannot.map(\.rawValue).sorted(), forKey: .cannot)
            try c.encode(noScripts, forKey: .noScripts)
            try c.encode(state.rawValue, forKey: .state)
            try c.encode(usage.rawValue, forKey: .usage)
            try c.encode(favoritesOnly, forKey: .favoritesOnly)
            try c.encode(withNote, forKey: .withNote)
            try c.encode(blockedOnly, forKey: .blockedOnly)
            try c.encode(withReport, forKey: .withReport)
            try c.encode(trustedOnly, forKey: .trustedOnly)
            try c.encode(aiReviewed, forKey: .aiReviewed)
            try c.encodeIfPresent(set, forKey: .set)
            try c.encodeIfPresent(license, forKey: .license)
            try c.encodeIfPresent(author, forKey: .author)
            try c.encodeIfPresent(newWithinDays, forKey: .newWithinDays)
            try c.encode(sort.rawValue, forKey: .sort)
        }
    }

    struct Row: Identifiable, Equatable, Sendable {
        var id: Int
        var kind: String
        var name: String
        var description: String
        var source: String
        var path: String
        var contentHash: String
        var license: String?
        var author: String?
        var agents: [SkillAgent]
        var isInstalled: Bool
        /// Installed, but switched off everywhere.
        var isOff: Bool
        var verdict: SkillVerdict
        var staticVerdict: SkillVerdict
        var riskScore: Int
        var hasScripts: Bool
        /// Findings by severity: critical, high, medium, low.
        var counts: [Int]
        var isFavorite: Bool
        /// The person's own note; empty when there is none.
        var note: String
        /// Uses in the last 30 days.
        var uses: Int
        /// When this content was first seen.
        var addedAt: String
        /// On the person's block list (this version or every version).
        var isBlocked: Bool
        /// Complaints the person kept about it, any version.
        var reports: Int
        /// Where it says it lives.
        var homepage: String?
        /// Its author (or its GitHub owner) is on the person's trusted list.
        var isTrusted: Bool
    }

    struct Result: Equatable, Sendable {
        var rows: [Row] = []
        /// How many match with any verdict, and with each.
        var total = 0
        var byVerdict: [SkillVerdict: Int] = [:]
    }

    /// What a person typed, as an FTS5 query: every word must be there, the last one may be unfinished. Quoting each
    /// word keeps FTS5's own operators from being read as a query language.
    static func ftsQuery(_ typed: String) -> String {
        let words = typed.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.map { "\"\($0)\"" }
        guard let last = words.last else { return "" }
        return (words.dropLast() + [last + "*"]).joined(separator: " ")
    }

    /// The same content in several folders (copied into each agent's own) is one skill: the lowest id stands for all.
    private static let onePerContent = "s.id IN (SELECT min(id) FROM skills GROUP BY kind, content_hash)"

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func conditions(_ filters: Filters, withVerdict: Bool, now: Date) -> (String, [SQLiteDB.Value]) {
        var sql = [Self.onePerContent]
        var values: [SQLiteDB.Value] = []
        func bind(_ value: String) -> String {
            values.append(.text(value))
            return "?\(values.count)"
        }
        func list(_ items: some Sequence<String>) -> String { items.sorted().map(bind).joined(separator: ", ") }
        let installed = "EXISTS (SELECT 1 FROM installations i JOIN skills c ON c.id = i.skill_id WHERE c.content_hash = s.content_hash"
        let query = Self.ftsQuery(filters.query)
        if !query.isEmpty {
            let note = filters.query.trimmingCharacters(in: .whitespaces)
            sql.append("""
                (s.content_hash IN (SELECT c.content_hash FROM skills c WHERE c.id IN (SELECT rowid FROM skills_fts WHERE skills_fts MATCH \(bind(query))))
                OR instr(lower(coalesce(m.note, '')), lower(\(bind(note)))) > 0)
                """)
        }
        if withVerdict, let verdict = filters.verdict { sql.append("r.effective = \(bind(verdict.rawValue))") }
        if filters.minRisk > 0 { sql.append("r.risk_score >= \(max(0, min(100, filters.minRisk)))") }
        if filters.maxRisk < 100 { sql.append("r.risk_score <= \(max(0, min(100, filters.maxRisk)))") }
        if !filters.agents.isEmpty { sql.append("\(installed) AND i.agent IN (\(list(filters.agents.map(\.rawValue)))))") }
        if !filters.scopes.isEmpty { sql.append("\(installed) AND i.scope IN (\(list(filters.scopes))))") }
        if let kind = filters.kind { sql.append("s.kind = \(bind(kind))") }
        if !filters.findings.isEmpty {
            sql.append("(" + filters.findings.map(\.rawValue).sorted().map { "r.categories LIKE \(bind("%,\($0),%"))" }.joined(separator: " OR ") + ")")
        }
        for capability in filters.can.map(\.rawValue).sorted() { sql.append("coalesce(r.capabilities, '') LIKE \(bind("%,\(capability),%"))") }
        for capability in filters.cannot.map(\.rawValue).sorted() { sql.append("coalesce(r.capabilities, '') NOT LIKE \(bind("%,\(capability),%"))") }
        if filters.noScripts { sql.append("r.has_scripts = 0") }
        switch filters.state {
        case .any: break
        case .on: sql.append("\(installed) AND i.enabled = 1)")
        case .off: sql.append("\(installed)) AND NOT \(installed) AND i.enabled = 1)")
        }
        let since = Self.iso(now.addingTimeInterval(-30 * 86400))
        switch filters.usage {
        case .any: break
        case .used: sql.append("EXISTS (SELECT 1 FROM skill_uses u WHERE u.name = s.name AND u.at >= \(bind(since)))")
        case .unused: sql.append("NOT EXISTS (SELECT 1 FROM skill_uses u WHERE u.name = s.name AND u.at >= \(bind(since)))")
        }
        if filters.favoritesOnly { sql.append("coalesce(m.favorite, 0) = 1") }
        if filters.withNote { sql.append("coalesce(m.note, '') <> ''") }
        if filters.blockedOnly { sql.append(Self.isBlockedSQL) }
        if filters.trustedOnly { sql.append(Self.trustedSQL) }
        if let set = filters.set {
            sql.append("EXISTS (SELECT 1 FROM skill_set_members g WHERE g.set_name = \(bind(set)) COLLATE NOCASE AND g.kind = s.kind AND g.name = s.name)")
        }
        if filters.aiReviewed { sql.append("EXISTS (SELECT 1 FROM llm_reviews l WHERE l.content_hash = s.content_hash)") }
        if filters.withReport { sql.append("EXISTS (SELECT 1 FROM skill_reports p WHERE p.kind = s.kind AND p.name = s.name)") }
        if let license = filters.license {
            sql.append(license.isEmpty ? "coalesce(s.license, '') = ''" : "s.license = \(bind(license))")
        }
        if let author = filters.author { sql.append(author.isEmpty ? "coalesce(s.author, '') = ''" : "s.author = \(bind(author))") }
        if let days = filters.newWithinDays { sql.append("s.updated_at >= \(bind(Self.iso(now.addingTimeInterval(-Double(max(days, 0)) * 86400))))") }
        return (sql.joined(separator: " AND "), values)
    }

    /// The columns of a `Row`; `since` is where the uses are counted from. The date is this file's own, never typed.
    private static func columns(since: Date) -> String {
        """
        s.id, s.kind, s.name, s.description, s.source, s.path, s.content_hash, s.license, r.effective, r.verdict, r.risk_score, r.has_scripts, r.counts,
        s.author, coalesce(m.favorite, 0), coalesce(m.note, ''), s.updated_at,
        (SELECT count(*) FROM skill_uses u WHERE u.name = s.name AND u.at >= '\(iso(since))') AS uses,
        \(isBlockedSQL), (SELECT count(*) FROM skill_reports p WHERE p.kind = s.kind AND p.name = s.name), s.homepage,
        \(trustedSQL)
        """
    }

    /// How many columns `columns` has: what a query adds comes after.
    private static let columnCount: Int32 = 22

    private static let from = "FROM skills s JOIN scan_results r ON r.skill_id = s.id LEFT JOIN skill_marks m ON m.kind = s.kind AND m.name = s.name"

    private func row(_ row: SQLiteDB.Row) throws -> Row {
        let hash = row.text(6)
        let places = try db.query("SELECT i.agent, i.enabled FROM installations i JOIN skills c ON c.id = i.skill_id WHERE c.content_hash = ?1 ORDER BY i.agent", .text(hash)) { ($0.text(0), $0.bool(1)) }
        var agents: [SkillAgent] = []
        for (agent, _) in places { if let value = SkillAgent(rawValue: agent), !agents.contains(value) { agents.append(value) } }
        return Row(id: row.int(0), kind: row.text(1), name: row.text(2), description: row.text(3), source: row.text(4), path: row.text(5), contentHash: hash,
                   license: row.optionalText(7), author: row.optionalText(13), agents: agents, isInstalled: !places.isEmpty, isOff: !places.isEmpty && places.allSatisfy { !$0.1 },
                   verdict: SkillVerdict(rawValue: row.text(8)) ?? .review, staticVerdict: SkillVerdict(rawValue: row.text(9)) ?? .review,
                   riskScore: row.int(10), hasScripts: row.bool(11), counts: row.text(12).split(separator: ",").compactMap { Int($0) },
                   isFavorite: row.bool(14), note: row.text(15), uses: row.int(17), addedAt: row.text(16),
                   isBlocked: row.bool(18), reports: row.int(19), homepage: row.optionalText(20), isTrusted: row.bool(21))
    }

    private static func order(_ sort: Filters.Sort) -> String {
        let risk = "CASE r.effective WHEN 'dangerous' THEN 0 WHEN 'review' THEN 1 ELSE 2 END, r.risk_score DESC"
        let name = "s.name COLLATE NOCASE, s.path"
        return switch sort {
        case .risk: "\(risk), \(name)"
        case .name: name
        case .mostUsed: "uses DESC, \(name)"
        case .newest: "s.updated_at DESC, \(name)"
        }
    }

    /// The skills that match in the chosen order, with the numbers for the verdict buttons.
    func search(_ filters: Filters, now: Date = .now) throws -> Result {
        let (wanted, values) = conditions(filters, withVerdict: true, now: now)
        let rows = try db.query("""
            SELECT \(Self.columns(since: now.addingTimeInterval(-30 * 86400))) \(Self.from) WHERE \(wanted)
            ORDER BY \(Self.order(filters.sort)) LIMIT 500
            """, values, map: row)
        let (anyVerdict, countValues) = conditions(filters, withVerdict: false, now: now)
        var byVerdict: [SkillVerdict: Int] = [:]
        for (verdict, count) in try db.query("SELECT r.effective, count(*) \(Self.from) WHERE \(anyVerdict) GROUP BY r.effective", countValues, map: { ($0.text(0), $0.int(1)) }) {
            byVerdict[SkillVerdict(rawValue: verdict) ?? .review, default: 0] += count
        }
        return Result(rows: rows, total: byVerdict.values.reduce(0, +), byVerdict: byVerdict)
    }

    /// The entry that stands for a skill whose id is gone (a change on disk, an install, an update): the one with the
    /// same content, or else the installed one of the same kind and name.
    func locate(contentHash: String, name: String, kind: String) throws -> Int? {
        if let id = try db.first("SELECT min(id) FROM skills WHERE content_hash = ?1 AND kind = ?2", .text(contentHash), .text(kind), map: { $0.optionalInt(0) }) ?? nil {
            return id
        }
        return try db.first("""
            SELECT s.id FROM skills s WHERE s.kind = ?1 AND s.name = ?2
            ORDER BY EXISTS (SELECT 1 FROM installations i WHERE i.skill_id = s.id) DESC, s.id LIMIT 1
            """, .text(kind), .text(name), map: { $0.int(0) })
    }

    /// What the filter's lists offer: the licenses, authors and places the catalog has.
    struct Facets: Equatable, Sendable {
        var licenses: [String] = []
        var authors: [String] = []
        var scopes: [String] = []
        var hasUnlicensed = false
    }

    func facets() throws -> Facets {
        let wanted = "FROM skills s WHERE \(Self.onePerContent)"
        return Facets(licenses: try db.query("SELECT DISTINCT s.license \(wanted) AND coalesce(s.license, '') <> '' ORDER BY s.license COLLATE NOCASE") { $0.text(0) },
                      authors: try db.query("SELECT DISTINCT s.author \(wanted) AND coalesce(s.author, '') <> '' ORDER BY s.author COLLATE NOCASE") { $0.text(0) },
                      scopes: try db.query("SELECT DISTINCT scope FROM installations ORDER BY scope") { $0.text(0) },
                      hasUnlicensed: try db.first("SELECT 1 \(wanted) AND coalesce(s.license, '') = '' LIMIT 1") { _ in true } ?? false)
    }

    // MARK: - The person's marks

    /// Marks a skill as a favourite or not. Marks follow the skill's kind and name, so an update keeps them.
    func setFavorite(_ id: Int, _ favorite: Bool, now: String = SkillCatalog.now()) throws {
        try mark(id, now: now, set: "favorite = excluded.favorite", favorite: favorite, note: nil)
    }

    /// Keeps the person's note on a skill; an empty one removes it.
    func setNote(_ id: Int, _ note: String, now: String = SkillCatalog.now()) throws {
        let text = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        try mark(id, now: now, set: "note = excluded.note", favorite: nil, note: text)
    }

    private func mark(_ id: Int, now: String, set: String, favorite: Bool?, note: String?) throws {
        guard let (kind, name) = try db.first("SELECT kind, name FROM skills WHERE id = ?1", .int(Int64(id)), map: { ($0.text(0), $0.text(1)) }) else { return }
        try db.transaction {
            try db.run("""
                INSERT INTO skill_marks (kind, name, favorite, note, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)
                ON CONFLICT (kind, name) DO UPDATE SET \(set), updated_at = excluded.updated_at
                """, .text(kind), .text(name), .bool(favorite ?? false), .text(note ?? ""), .text(now))
            try db.run("DELETE FROM skill_marks WHERE kind = ?1 AND name = ?2 AND favorite = 0 AND note = ''", .text(kind), .text(name))
        }
    }

    struct SavedFilter: Identifiable, Equatable, Sendable {
        var id: Int
        var name: String
        var filters: Filters
    }

    func savedFilters() throws -> [SavedFilter] {
        try db.query("SELECT id, name, filters FROM saved_filters ORDER BY name COLLATE NOCASE, id") { row in
            SavedFilter(id: row.int(0), name: row.text(1), filters: (try? JSONDecoder().decode(Filters.self, from: Data(row.text(2).utf8))) ?? Filters())
        }
    }

    /// Saves the filters under a name; a filter of the same name is replaced.
    @discardableResult
    func saveFilter(_ name: String, _ filters: Filters, now: String = SkillCatalog.now()) throws -> Int {
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !title.isEmpty else { throw SQLiteDB.Failure(message: "a saved filter needs a name") }
        let json = String(decoding: try JSONEncoder().encode(filters), as: UTF8.self)
        return try db.transaction {
            try db.run("DELETE FROM saved_filters WHERE name = ?1", .text(title))
            try db.run("INSERT INTO saved_filters (name, filters, created_at) VALUES (?1, ?2, ?3)", .text(title), .text(json), .text(now))
            return db.lastInsertID
        }
    }

    func deleteFilter(_ id: Int) throws {
        try db.run("DELETE FROM saved_filters WHERE id = ?1", .int(Int64(id)))
    }

    // MARK: - A skill's card

    struct FileRow: Equatable, Sendable, Identifiable {
        var path: String
        var size: UInt64
        /// `doc`, `script`, `config`, `program`, `archive`, `media`, `binary`, `text` or `link`.
        var kind: String
        var findings: Int
        var isReadable: Bool
        var id: String { path }
    }

    struct Card: Equatable, Sendable {
        var row: Row
        var places: [SkillPlace]
        var report: SkillReport
        var assessment: SkillAssessment
        var scannedAt: String
        /// The files as they are on disk now; empty when the folder can't be read.
        var files: [FileRow]
        /// The folder changed since it was checked: the verdict is about an older version.
        var isChanged: Bool
        /// The folder is gone or unreadable.
        var isMissing: Bool
        var uses: Uses
    }

    private func filesOf(_ row: Row) -> SkillFiles? {
        guard row.source == "local" || row.source == "folder" else { return nil }
        return try? SkillFolder.read(URL(fileURLWithPath: row.path))
    }

    private static func kind(_ file: SkillFile) -> (String, Bool) {
        if file.symlink != nil { return ("link", false) }
        let kind = SkillFileKind.of(file)
        return (kind.name, kind.isText && !file.unread)
    }

    func card(_ id: Int, now: Date = .now) throws -> Card? {
        guard let (row, reportJSON, scannedAt) = try db.first("""
            SELECT \(Self.columns(since: now.addingTimeInterval(-30 * 86400))), r.report_json, r.scanned_at \(Self.from) WHERE s.id = ?1
            """, .int(Int64(id)), map: { (try self.row($0), $0.text(Self.columnCount), $0.text(Self.columnCount + 1)) }) else { return nil }
        let report = try JSONDecoder().decode(SkillReport.self, from: Data(reportJSON.utf8))
        let places = try db.query("""
            SELECT i.agent, i.install_path, i.scope, i.project, i.enabled FROM installations i JOIN skills c ON c.id = i.skill_id
            WHERE c.content_hash = ?1 ORDER BY i.agent, i.install_path
            """, .text(row.contentHash)) { r in
            SkillPlace(agent: SkillAgent(rawValue: r.text(0)) ?? .claude, installPath: r.text(1), scope: r.text(2), project: r.optionalText(3), isEnabled: r.bool(4))
        }
        let onDisk = filesOf(row)
        let files: [FileRow] = (onDisk?.files ?? []).map { file -> FileRow in
            let (kind, readable) = Self.kind(file)
            return FileRow(path: file.path, size: file.size, kind: kind, findings: report.findings.filter { $0.file == file.path }.count, isReadable: readable)
        }
        let llm = row.verdict > row.staticVerdict ? row.verdict : nil
        return Card(row: row, places: places, report: report, assessment: SkillAssessment(report, llmVerdict: llm), scannedAt: scannedAt, files: files,
                    isChanged: onDisk.map { $0.contentHash != row.contentHash } ?? false, isMissing: (row.source == "local" || row.source == "folder") && onDisk == nil,
                    uses: try uses(of: row.name, since: now.addingTimeInterval(-30 * 86400)))
    }

    struct Preview: Equatable, Sendable {
        var path: String
        /// The text line by line, invisible characters spelled out as `<U+200B>`.
        var lines: [String]
        /// The file is longer than what is shown.
        var isCut: Bool
        /// The lines the scanner pointed at, the most serious finding of each.
        var marks: [Int: SkillFinding]
    }

    /// The text of one of a skill's files. `file` must be a path the skill's own folder lists: nothing else on the
    /// disk can be asked for, and a link is never opened.
    func preview(_ id: Int, file: String) throws -> Preview? {
        guard let card = try card(id), let files = filesOf(card.row), let entry = files.files.first(where: { $0.path == file }), Self.kind(entry).1 else { return nil }
        var lines: [String] = []
        var cut = false
        for line in SkillScanner.lines(entry.text) {
            if lines.count == 2000 { cut = true; break }
            let shown = SkillText.visible(line)
            lines.append(shown.count > 2000 ? String(shown.prefix(2000)) + "…" : shown)
        }
        var marks: [Int: SkillFinding] = [:]
        // Findings come most serious first, so the first one of a line is the one to show.
        for finding in card.report.findings where finding.file == file && finding.line > 0 && marks[finding.line] == nil { marks[finding.line] = finding }
        return Preview(path: file, lines: lines, isCut: cut, marks: marks)
    }

    // MARK: - Usage

    struct Uses: Equatable, Sendable {
        var count = 0
        var last: Date?
        var agents: [SkillAgent] = []
    }

    /// How often a skill was used since a date, by the name agents call it.
    func uses(of name: String, since: Date) throws -> Uses {
        let rows = try db.query("SELECT agent, at FROM skill_uses WHERE name = ?1 AND at >= ?2 ORDER BY at", .text(name), .text(ISO8601DateFormatter().string(from: since))) { ($0.text(0), $0.text(1)) }
        var agents: [SkillAgent] = []
        for (agent, _) in rows { if let value = SkillAgent(rawValue: agent), !agents.contains(value) { agents.append(value) } }
        return Uses(count: rows.count, last: rows.last.flatMap { ISO8601DateFormatter.flexible($0.1) }, agents: agents)
    }

    struct Used: Equatable, Sendable, Identifiable {
        var name: String
        var count: Int
        var agents: [SkillAgent]
        /// The installed skill of that name, when there is one.
        var skillID: Int?
        var verdict: SkillVerdict?
        var id: String { name }
    }

    /// The skills used most since a date, with their verdicts when they are in the catalog.
    func mostUsed(since: Date, limit: Int) throws -> [Used] {
        let rows = try db.query("""
            SELECT u.name, count(*) AS n, group_concat(DISTINCT u.agent) FROM skill_uses u WHERE u.at >= ?1
            GROUP BY u.name ORDER BY n DESC, u.name LIMIT ?2
            """, .text(ISO8601DateFormatter().string(from: since)), .int(Int64(limit))) { ($0.text(0), $0.int(1), $0.text(2)) }
        return try rows.map { name, count, agents in
            let skill = try db.first("""
                SELECT s.id, r.effective FROM skills s JOIN scan_results r ON r.skill_id = s.id
                WHERE s.name = ?1 AND EXISTS (SELECT 1 FROM installations i WHERE i.skill_id = s.id) ORDER BY s.id LIMIT 1
                """, .text(name)) { ($0.int(0), SkillVerdict(rawValue: $0.text(1))) }
            return Used(name: name, count: count, agents: agents.split(separator: ",").compactMap { SkillAgent(rawValue: String($0)) }, skillID: skill?.0, verdict: skill?.1 ?? nil)
        }
    }

    /// Installed skills (not plugins) nobody used since a date.
    func unused(since: Date) throws -> Int {
        try db.first("""
            SELECT count(*) FROM skills s WHERE s.kind = 'skill' AND \(Self.onePerContent)
            AND EXISTS (SELECT 1 FROM installations i JOIN skills c ON c.id = i.skill_id WHERE c.content_hash = s.content_hash AND i.enabled = 1)
            AND NOT EXISTS (SELECT 1 FROM skill_uses u WHERE u.name = s.name AND u.at >= ?1)
            """, .text(ISO8601DateFormatter().string(from: since))) { $0.int(0) } ?? 0
    }

    /// Reads what was added to the agents' session logs since the last time: Claude Code's `Skill` tool calls, and
    /// Codex reading a `skills/<name>/SKILL.md`. Each file is read from where it was left; a file that got shorter is
    /// read again from the start. Logs older than `since` are not opened.
    @discardableResult
    func readUsage(_ roots: SkillRoots, since: Date) throws -> Int {
        var added = 0
        let sources: [(URL, SkillAgent, (String) -> String?)] = [
            (roots.claudeDir.appending(path: "projects"), .claude, SkillUsage.claudeSkill),
            (roots.codexDir.appending(path: "sessions"), .codex, SkillUsage.codexSkill),
        ]
        for (folder, agent, extract) in sources {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let modified = values?.contentModificationDate, modified >= since, let size = values?.fileSize else { continue }
                let known = try db.first("SELECT size, offset FROM log_offsets WHERE path = ?1", .text(url.path)) { ($0.int(0), $0.int(1)) }
                var start = known?.1 ?? 0
                if let known, known.0 == size { continue }
                if start > size { start = 0 }
                let (uses, end) = SkillUsage.read(url, from: start, extract: extract)
                try db.transaction {
                    for (name, at) in uses {
                        added += try db.run("INSERT OR IGNORE INTO skill_uses (name, agent, at, log) VALUES (?1, ?2, ?3, ?4)", .text(name), .text(agent.rawValue), .text(at), .text(url.path))
                    }
                    try db.run("INSERT OR REPLACE INTO log_offsets (path, size, offset) VALUES (?1, ?2, ?3)", .text(url.path), .int(Int64(size)), .int(Int64(end)))
                }
            }
        }
        return added
    }
}

/// Finding skill calls in the agents' logs without parsing every line: only lines that contain the marker are read.
enum SkillUsage {
    private static let claudeMarker = Data(#""name":"Skill","input":{"skill":""#.utf8)
    private static let codexMarker = Data("SKILL.md".utf8)

    /// The skill's name in a Claude Code log line, without a plugin prefix (`plugin:name` → `name`).
    static func claudeSkill(_ line: String) -> String? {
        guard let range = line.range(of: #""name":"Skill","input":{"skill":""#) else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let name = String(rest[..<end])
        return name.split(separator: ":").last.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
    }

    // swiftlint:disable:next force_try
    private static let codexPath = try! NSRegularExpression(pattern: #"skills/([A-Za-z0-9._-]+)/SKILL\.md"#)

    /// The skill whose SKILL.md a Codex command or tool call read. Only a call counts, not the list of skills Codex
    /// is given at the start of a session.
    static func codexSkill(_ line: String) -> String? {
        guard line.contains("\"function_call\"") || line.contains("\"local_shell_call\"") || line.contains("\"custom_tool_call\"") || line.contains("\"exec_command") else { return nil }
        guard let match = codexPath.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private static func timestamp(_ line: String) -> String? {
        guard let range = line.range(of: #""timestamp":""#) else { return nil }
        let rest = line[range.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }

    /// The uses in a log from a byte offset on, and the offset after the last whole line.
    static func read(_ url: URL, from start: Int, extract: (String) -> String?) -> ([(String, String)], Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], start) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(start))
        var uses: [(String, String)] = []
        var offset = start
        var pending = Data()
        while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            guard let lastBreak = pending.lastIndex(of: 0x0A) else { continue }
            let whole = pending[pending.startIndex...lastBreak]
            if whole.range(of: claudeMarker) != nil || whole.range(of: codexMarker) != nil {
                for line in whole.split(separator: 0x0A) where line.range(of: claudeMarker) != nil || line.range(of: codexMarker) != nil {
                    let text = String(decoding: line, as: UTF8.self)
                    if let name = extract(text), let at = timestamp(text) { uses.append((name, at)) }
                }
            }
            offset += whole.count
            pending = Data(pending[pending.index(after: lastBreak)...])
        }
        return (uses, offset)
    }
}

extension ISO8601DateFormatter {
    /// A timestamp with or without fractions of a second, as the agents write them.
    static func flexible(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
