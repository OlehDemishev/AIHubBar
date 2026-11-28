import Foundation

/// Keeping the installed skills in order (docs/specs/SPEC-skills.md, step 8): the same skill copied into several
/// folders, different skills under one name that an agent could mix up, skills nobody used, named sets, and an export
/// with hashes that a later look can be checked against.
extension SkillCatalog {
    static let housekeepingMigration = """
        CREATE TABLE skill_sets (
            name        TEXT PRIMARY KEY COLLATE NOCASE,
            created_at  TEXT NOT NULL
        );
        -- Members by kind and name, so a set follows its skills through updates.
        CREATE TABLE skill_set_members (
            set_name  TEXT NOT NULL REFERENCES skill_sets(name) ON DELETE CASCADE,
            kind      TEXT NOT NULL,
            name      TEXT NOT NULL,
            PRIMARY KEY (set_name, kind, name)
        );
        """

    // MARK: - Duplicates and conflicts

    /// One installed copy of a skill: where, for whom, which content.
    struct Copy: Equatable, Sendable, Identifiable {
        var skillID: Int
        var installPath: String
        var agents: [SkillAgent]
        var scope: String
        var project: String?
        var isEnabled: Bool
        var contentHash: String
        var verdict: SkillVerdict
        /// The real folder, links resolved: two places with one folder are one copy.
        var folder: String
        var id: String { installPath }
    }

    struct Group: Equatable, Sendable, Identifiable {
        var kind: String
        var name: String
        var copies: [Copy]
        var id: String { "\(kind)\n\(name)" }
        /// Different contents under this name.
        var versions: Int { Set(copies.map(\.contentHash)).count }
    }

    private func copies() throws -> [Copy] {
        let rows = try db.query("""
            SELECT s.id, s.kind, s.name, i.install_path, i.agent, i.scope, i.project, i.enabled, s.content_hash, r.effective, s.path
            FROM installations i JOIN skills s ON s.id = i.skill_id JOIN scan_results r ON r.skill_id = s.id
            ORDER BY s.kind, s.name COLLATE NOCASE, i.install_path, i.agent
            """) { ($0.int(0), $0.text(1), $0.text(2), $0.text(3), $0.text(4), $0.text(5), $0.optionalText(6), $0.bool(7), $0.text(8), $0.text(9), $0.text(10)) }
        var byPath: [String: (String, String, Copy)] = [:]
        var order: [String] = []
        for (id, kind, name, path, agent, scope, project, enabled, hash, verdict, folder) in rows {
            if byPath[path] == nil {
                byPath[path] = (kind, name, Copy(skillID: id, installPath: path, agents: [], scope: scope, project: project, isEnabled: enabled,
                                                 contentHash: hash, verdict: SkillVerdict(rawValue: verdict) ?? .review, folder: folder))
                order.append(path)
            }
            if let value = SkillAgent(rawValue: agent) { byPath[path]?.2.agents.append(value) }
        }
        return order.compactMap { byPath[$0]?.2 }
    }

    private func groups() throws -> [Group] {
        let rows = try db.query("SELECT DISTINCT i.install_path, s.kind, s.name FROM installations i JOIN skills s ON s.id = i.skill_id") { ($0.text(0), $0.text(1), $0.text(2)) }
        let names = Dictionary(rows.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { first, _ in first })
        var grouped: [String: Group] = [:]
        for copy in try copies() {
            guard let (kind, name) = names[copy.installPath] else { continue }
            grouped["\(kind)\n\(name)", default: Group(kind: kind, name: name, copies: [])].copies.append(copy)
        }
        return grouped.values.sorted { ($0.name.lowercased(), $0.kind) < ($1.name.lowercased(), $1.kind) }
    }

    /// Different skills under one name, switched on for the same agent: the agent may load either one.
    func conflicts() throws -> [Group] {
        try groups().filter { group in
            SkillAgent.allCases.contains { agent in
                Set(group.copies.filter { $0.isEnabled && $0.agents.contains(agent) }.map(\.contentHash)).count > 1
            }
        }
    }

    /// The same content copied into several folders: each copy has to be kept up to date on its own. A link to one
    /// shared folder is not a copy.
    func duplicates() throws -> [Group] {
        try groups().compactMap { group in
            let byContent = Dictionary(grouping: group.copies, by: \.contentHash).filter { Set($0.value.map(\.folder)).count > 1 }
            guard let copies = byContent.values.max(by: { $0.count < $1.count }) else { return nil }
            return Group(kind: group.kind, name: group.name, copies: copies)
        }
    }

    /// Installed, switched-on skills (not plugins) nobody used since a date, with the places they could be switched off.
    /// Copies synced from the Claude account are left out: the catalog can't switch them off, the next sync brings them back.
    func unusedSkills(since: Date) throws -> [Group] {
        let since = ISO8601DateFormatter().string(from: since)
        let used = Set(try db.query("SELECT DISTINCT name FROM skill_uses WHERE at >= ?1", .text(since)) { $0.text(0) })
        return try groups().filter { $0.kind == "skill" && !used.contains($0.name) }
            .map { Group(kind: $0.kind, name: $0.name, copies: $0.copies.filter { $0.isEnabled && $0.scope != "synced" }) }
            .filter { !$0.copies.isEmpty }
    }

    // MARK: - Sets

    func sets() throws -> [(name: String, members: Int)] {
        try db.query("SELECT s.name, (SELECT count(*) FROM skill_set_members m WHERE m.set_name = s.name) FROM skill_sets s ORDER BY s.name COLLATE NOCASE") { ($0.text(0), $0.int(1)) }
    }

    func setsOf(kind: String, name: String) throws -> [String] {
        try db.query("SELECT set_name FROM skill_set_members WHERE kind = ?1 AND name = ?2 ORDER BY set_name COLLATE NOCASE", .text(kind), .text(name)) { $0.text(0) }
    }

    /// Puts a skill into a set, making the set when it is new.
    func addToSet(_ set: String, skill id: Int, now: String = SkillCatalog.now()) throws {
        let title = String(set.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !title.isEmpty else { throw Refusal(code: "name") }
        guard let (kind, name) = try db.first("SELECT kind, name FROM skills WHERE id = ?1", .int(Int64(id)), map: { ($0.text(0), $0.text(1)) }) else { throw Refusal.missing }
        try db.transaction {
            try db.run("INSERT OR IGNORE INTO skill_sets (name, created_at) VALUES (?1, ?2)", .text(title), .text(now))
            let stored = try db.first("SELECT name FROM skill_sets WHERE name = ?1", .text(title), map: { $0.text(0) }) ?? title
            try db.run("INSERT OR IGNORE INTO skill_set_members (set_name, kind, name) VALUES (?1, ?2, ?3)", .text(stored), .text(kind), .text(name))
        }
    }

    func removeFromSet(_ set: String, skill id: Int) throws {
        guard let (kind, name) = try db.first("SELECT kind, name FROM skills WHERE id = ?1", .int(Int64(id)), map: { ($0.text(0), $0.text(1)) }) else { return }
        try db.run("DELETE FROM skill_set_members WHERE set_name = ?1 AND kind = ?2 AND name = ?3", .text(set), .text(kind), .text(name))
    }

    func deleteSet(_ set: String) throws {
        try db.transaction {
            try db.run("DELETE FROM skill_set_members WHERE set_name = ?1", .text(set))
            try db.run("DELETE FROM skill_sets WHERE name = ?1", .text(set))
        }
    }

    /// The person's own places of a set's skills: what «включить набор» and «выключить набор» move.
    func setPlaces(_ set: String) throws -> [Copy] {
        let members = Set(try db.query("SELECT kind, name FROM skill_set_members WHERE set_name = ?1", .text(set)) { "\($0.text(0))\n\($0.text(1))" })
        return try groups().filter { members.contains($0.id) }.flatMap(\.copies).filter { $0.scope == "user" }
    }

    /// Switches every skill of a set on or off in the person's own folders. Each move is a step of the journal; a
    /// place already in that state is left alone.
    @discardableResult
    func setEnabled(set: String, _ on: Bool, _ place: Place) throws -> Int {
        var moved = 0
        for copy in try setPlaces(set) where copy.isEnabled != on {
            try setEnabled(copy.installPath, on, place)
            moved += 1
        }
        return moved
    }

    // MARK: - Export with hashes

    struct Export: Codable, Equatable, Sendable {
        struct File: Codable, Equatable, Sendable {
            var path: String
            /// SHA-256 of the file's bytes; empty for a link.
            var sha256: String
            var size: UInt64
            var link: String?
        }

        struct Skill: Codable, Equatable, Sendable {
            var kind: String
            var name: String
            var installPath: String
            var agents: [String]
            var scope: String
            var enabled: Bool
            var contentHash: String
            var verdict: String
            var aiVerdict: String?
            var license: String?
            var author: String?
            var homepage: String?
            var files: [File]
        }

        var format = "aihubbar-skills"
        var version = 1
        var exportedAt: String
        var scannerVersion: Int
        var skills: [Skill]
    }

    /// Every installed skill with its files' hashes. Paths under the home folder are written as `~/…`, so the file can
    /// be shared without the account name.
    func export(now: String = SkillCatalog.now(), home: String = NSHomeDirectory()) throws -> Export {
        func shown(_ path: String) -> String { path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path }
        var skills: [Export.Skill] = []
        for group in try groups() {
            for copy in group.copies {
                let meta = try db.first("SELECT license, author, homepage FROM skills WHERE id = ?1", .int(Int64(copy.skillID))) { ($0.optionalText(0), $0.optionalText(1), $0.optionalText(2)) }
                let files = (try? SkillFolder.read(URL(fileURLWithPath: copy.installPath)))?.files ?? []
                skills.append(Export.Skill(kind: group.kind, name: group.name, installPath: shown(copy.installPath), agents: copy.agents.map(\.rawValue), scope: copy.scope,
                                           enabled: copy.isEnabled, contentHash: copy.contentHash, verdict: copy.verdict.rawValue,
                                           aiVerdict: try rememberedVerdict(contentHash: copy.contentHash)?.rawValue,
                                           license: meta?.0, author: meta?.1, homepage: meta?.2,
                                           files: files.map { Export.File(path: $0.path, sha256: $0.symlink == nil ? $0.digest.map { String(format: "%02x", $0) }.joined() : "",
                                                                          size: $0.size, link: $0.symlink) }))
            }
        }
        return Export(exportedAt: now, scannerVersion: SkillReport.scannerVersion, skills: skills)
    }

    static func exportData(_ export: Export) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(export)
    }

    struct Comparison: Equatable, Sendable {
        /// The same place, other content: the files that differ.
        var changed: [(name: String, installPath: String, files: [String])]
        /// In the export, gone now.
        var missing: [(name: String, installPath: String)]
        /// Installed now, not in the export.
        var added: [(name: String, installPath: String)]
        var unchanged: Int

        static func == (a: Comparison, b: Comparison) -> Bool {
            a.changed.map { "\($0.name)\($0.installPath)\($0.files)" } == b.changed.map { "\($0.name)\($0.installPath)\($0.files)" }
                && a.missing.map { $0.installPath } == b.missing.map { $0.installPath } && a.added.map { $0.installPath } == b.added.map { $0.installPath }
                && a.unchanged == b.unchanged
        }
    }

    /// Checks what is installed now against an earlier export: which skills changed (and which of their files), which
    /// are gone, which are new.
    func compare(with old: Export, home: String = NSHomeDirectory()) throws -> Comparison {
        let now = try export(home: home)
        let before = Dictionary(old.skills.map { ($0.installPath, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(now.skills.map { ($0.installPath, $0) }, uniquingKeysWith: { first, _ in first })
        var result = Comparison(changed: [], missing: [], added: [], unchanged: 0)
        for skill in now.skills {
            guard let previous = before[skill.installPath] else {
                result.added.append((skill.name, skill.installPath))
                continue
            }
            if previous.contentHash == skill.contentHash {
                result.unchanged += 1
                continue
            }
            let oldFiles = Dictionary(previous.files.map { ($0.path, $0.sha256) }, uniquingKeysWith: { first, _ in first })
            let newFiles = Dictionary(skill.files.map { ($0.path, $0.sha256) }, uniquingKeysWith: { first, _ in first })
            let differing = Set(oldFiles.keys).union(newFiles.keys).filter { oldFiles[$0] != newFiles[$0] }.sorted()
            result.changed.append((skill.name, skill.installPath, differing))
        }
        for skill in old.skills where after[skill.installPath] == nil { result.missing.append((skill.name, skill.installPath)) }
        return result
    }

    /// An export of even thousands of skills stays far below this; a bigger file is not one.
    static let exportLimit = 20 * 1024 * 1024

    static func readExport(_ data: Data) throws -> Export {
        guard data.count <= exportLimit else { throw Refusal(code: "format") }
        let export = try JSONDecoder().decode(Export.self, from: data)
        guard export.format == "aihubbar-skills" else { throw Refusal(code: "format") }
        return export
    }
}
