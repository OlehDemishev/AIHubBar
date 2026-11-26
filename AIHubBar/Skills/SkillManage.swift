import Foundation

/// Changing what is installed: putting a checked skill into an agent's folder, taking one out, switching it off,
/// bringing a newer version in — and undoing each of these. The only code in the catalog that writes into an agent's
/// folders. Port of `desktop/skill-catalog/src/manage.rs`.
///
/// The rules it keeps:
/// - A copy is made from the very bytes the scanner checked; if the folder changed since, it is checked again first,
///   and the person confirms what they were shown (the content hash they saw comes back with the request).
/// - A «review» or «dangerous» skill is installed only with an explicit acknowledgement.
/// - Nothing is run, nothing is downloaded, links are never copied.
/// - Nothing is deleted: what was there before is moved to the catalog's backups and can be put back.
/// - Every step is written to the journal.
extension SkillCatalog {
    /// Where the work happens: the agents' folders, the folder for backups, and the moment.
    struct Place: Sendable {
        var roots: SkillRoots
        var backups: URL
        var now: String = SkillCatalog.now()
    }

    /// Why a step was refused; `code` is the same word the desktop version uses.
    struct Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        var code: String
        var description: String { code }
        static let missing = Refusal(code: "missing"), agent = Refusal(code: "agent"), changed = Refusal(code: "changed")
        static let confirmation = Refusal(code: "confirmation"), exists = Refusal(code: "exists"), notYours = Refusal(code: "not-yours")
        static let state = Refusal(code: "state"), path = Refusal(code: "path")
    }

    static let manageMigration = """
        -- The copies the catalog made itself, so a newer version of their source can be offered.
        CREATE TABLE managed_installs (
            install_path   TEXT PRIMARY KEY,
            name           TEXT NOT NULL,
            origin_kind    TEXT NOT NULL,                  -- path: a folder on this Mac; later a repository at a commit
            origin         TEXT NOT NULL,
            source_hash    TEXT NOT NULL,                  -- the checked version the copy was made from
            installed_hash TEXT NOT NULL,                  -- what was written (the source without its links)
            installed_at   TEXT NOT NULL,
            notified_hash  TEXT                            -- the newer version the person was already told about
        );
        CREATE TABLE install_log (
            id            INTEGER PRIMARY KEY,
            at            TEXT NOT NULL,
            action        TEXT NOT NULL,                   -- install | update | remove | restore | on | off
            name          TEXT NOT NULL,
            agent         TEXT,
            install_path  TEXT NOT NULL,
            content_hash  TEXT,
            verdict       TEXT,
            risk_score    INTEGER,
            acknowledged  INTEGER NOT NULL DEFAULT 0,      -- installed after reading the findings of a «review» or «dangerous» skill
            origin        TEXT,
            backup_path   TEXT,                            -- where what was there before is kept
            link_target   TEXT,                            -- the removed thing was a link to this
            managed_json  TEXT,                            -- the managed_installs row that went with a removed or replaced copy
            restored_at   TEXT
        );
        """

    // MARK: - The source of a copy

    private struct Source {
        var id: Int
        var kind: String
        var source: String
        var path: String
        var contentHash: String
    }

    private func source(_ id: Int) throws -> Source {
        guard let row = try db.first("SELECT id, kind, source, path, content_hash FROM skills WHERE id = ?1", .int(Int64(id)), map: {
            Source(id: $0.int(0), kind: $0.text(1), source: $0.text(2), path: $0.text(3), contentHash: $0.text(4))
        }) else { throw Refusal.missing }
        return row
    }

    private func storedReport(_ id: Int) throws -> SkillReport? {
        guard let json = try db.first("SELECT report_json FROM scan_results WHERE skill_id = ?1 AND scanner_version = ?2",
                                      .int(Int64(id)), .int(Int64(SkillReport.scannerVersion)), map: { $0.text(0) }) else { return nil }
        return try JSONDecoder().decode(SkillReport.self, from: Data(json.utf8))
    }

    /// A folder the person pointed at («Добавить папку…»): checked and listed, installed nowhere. Returns its id; a
    /// folder already known with the same content keeps the id it has.
    @discardableResult
    func importFolder(_ folder: URL, now: String = SkillCatalog.now()) throws -> Int {
        let real = folder.resolvingSymlinksInPath().standardizedFileURL
        let files = try SkillFolder.read(real)
        let hash = files.contentHash
        let path = real.path
        if let id = try db.first("SELECT id FROM skills WHERE repo_url = '' AND path = ?1 AND content_hash = ?2", .text(path), .text(hash), map: { $0.int(0) }) {
            if try storedReport(id) == nil { try save(SkillScanner.scan(files), skill: id, now: now) }
            return id
        }
        let described = Self.describe(files, folder: path, listedName: nil)
        let isPlugin = files.file("SKILL.md") == nil && (files.file(".claude-plugin/plugin.json") != nil || files.file("gemini-extension.json") != nil)
        let report = SkillScanner.scan(files)
        return try db.transaction {
            // An older version of the same added folder gives way to the new one.
            try db.run("DELETE FROM skills WHERE source = 'folder' AND path = ?1", .text(path))
            try db.run("INSERT INTO skills (kind, name, description, source, path, content_hash, license, agents, updated_at, author, homepage) VALUES (?1, ?2, ?3, 'folder', ?4, ?5, ?6, '[]', ?7, ?8, ?9)",
                       .text(isPlugin ? "plugin" : "skill"), .text(described.name), .text(described.description), .text(path), .text(hash),
                       .optional(described.license), .text(now), .optional(described.author), .optional(described.homepage))
            let id = db.lastInsertID
            try save(report, skill: id, now: now)
            return id
        }
    }

    /// Takes an added folder out of the catalog. The folder itself is not touched.
    @discardableResult
    func forget(_ id: Int) throws -> Bool {
        try db.run("DELETE FROM skills WHERE id = ?1 AND source = 'folder'", .int(Int64(id))) > 0
    }

    /// The skill's files as they are on disk now, with a result about exactly them: a folder that changed since the
    /// last check is checked again. Returns the source as it is after that and whether it changed.
    private func current(_ id: Int, _ place: Place) throws -> (Source, SkillFiles, SkillReport, Bool) {
        let row = try source(id)
        guard row.source == "local" || row.source == "folder" else { throw Refusal.missing }
        let folder = URL(fileURLWithPath: row.path)
        guard let files = try? SkillFolder.read(folder) else { throw Refusal.missing }
        let hash = files.contentHash
        if hash == row.contentHash, let report = try storedReport(id) { return (row, files, report, false) }
        let newID: Int
        if row.source == "folder" {
            newID = try importFolder(folder, now: place.now)
        } else {
            try refreshInstalled(place.roots, now: place.now)
            guard let found = try db.first("SELECT id FROM skills WHERE source = 'local' AND path = ?1 AND content_hash = ?2", .text(row.path), .text(hash), map: { $0.int(0) }) else { throw Refusal.missing }
            newID = found
        }
        guard let report = try storedReport(newID) else { throw Refusal.missing }
        var now = row
        now.id = newID
        now.contentHash = hash
        return (now, files, report, hash != row.contentHash)
    }

    // MARK: - The plan: what the person is shown before anything is written

    struct Plan: Equatable, Sendable {
        /// The skill's id now (it changes when the folder was checked again).
        var skillID: Int
        var name: String
        var agent: SkillAgent?
        /// The folder the copy goes to.
        var target: String
        /// The other agents that read that folder: they get the skill too.
        var alsoSeenBy: [SkillAgent]
        var verdict: SkillVerdict
        var riskScore: Int
        /// What is confirmed: the request to install must come back with this hash.
        var contentHash: String
        /// The folder changed since it was last shown: this is a new check.
        var changed: Bool
        /// What the scanner found, the most serious first (notes left out).
        var findings: [SkillFinding]
        /// What is not copied: links and bundled dependency folders.
        var leftOut: [String]
        /// «Review» and «dangerous» need an explicit acknowledgement.
        var needsAck: Bool { verdict != .safe }
        /// An update of an installed copy: what is there now is kept in the backups.
        var replaces: Bool
        /// Why it can't be done: `blocked`, `plugin`, `no-skill-md`, `too-large`, `already`, `exists`, `name`.
        var blocked: String?
    }

    /// The folder agents install a skill into for the person, with every agent that reads it.
    static func installFolder(_ roots: SkillRoots, for agent: SkillAgent) -> (URL, [SkillAgent]) {
        let folders = roots.userSkillFolders
        // Codex: `~/.agents/skills`, the folder of its current documentation; `~/.codex/skills` is the older one.
        let index = switch agent {
        case .claude: 0
        case .codex: 2
        case .cursor: 3
        case .gemini: 4
        }
        return folders[index]
    }

    /// The folder's name in the agent's skills folder: the skill's own name when it follows the standard, else the
    /// name of the folder it comes from. Never anything that could leave the skills folder.
    private static func folderName(_ files: SkillFiles, source: URL) -> String? {
        if let text = files.file("SKILL.md")?.text, let own = SkillScanner.frontmatter(text).first(where: { $0.key == "name" })?.value, SkillScanner.isValidName(own) {
            return own
        }
        let name = source.lastPathComponent
        let plain = !name.isEmpty && name.count <= 64 && !name.hasPrefix(".") && name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || "-_.".contains($0) }
        return plain ? name : nil
    }

    private static func leftOut(_ files: SkillFiles) -> [String] {
        files.files.filter { $0.symlink != nil }.map(\.path) + files.skipped.map { "\($0)/" }
    }

    private func plan(_ source: Source, _ files: SkillFiles, _ report: SkillReport, changed: Bool, agent: SkillAgent?, target: URL,
                      readers: [SkillAgent], replaces: Bool, blocked: String?) throws -> Plan {
        // A stricter verdict the catalog keeps for this content (a model's, later) counts here too.
        let kept = try db.first("SELECT r.effective FROM scan_results r JOIN skills s ON s.id = r.skill_id WHERE s.content_hash = ?1 ORDER BY r.skill_id LIMIT 1",
                                .text(report.contentHash), map: { SkillVerdict(rawValue: $0.text(0)) }) ?? nil
        return Plan(skillID: source.id, name: target.lastPathComponent, agent: agent, target: target.path, alsoSeenBy: readers.filter { $0 != agent },
                    verdict: max(report.verdict, kept ?? report.verdict), riskScore: report.riskScore, contentHash: report.contentHash, changed: changed,
                    findings: report.findings.filter { $0.severity >= .low }, leftOut: Self.leftOut(files), replaces: replaces, blocked: blocked)
    }

    private static func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }

    /// What installing this skill for this agent would do. Nothing is written into an agent's folder.
    func planInstall(_ id: Int, for agent: SkillAgent, _ place: Place) throws -> Plan {
        let (source, files, report, changed) = try current(id, place)
        let (skillsFolder, readers) = Self.installFolder(place.roots, for: agent)
        let name = Self.folderName(files, source: URL(fileURLWithPath: source.path))
        let target = skillsFolder.appending(path: name ?? "skill").standardizedFileURL
        let hasIt = try db.first("SELECT EXISTS (SELECT 1 FROM installations i JOIN skills c ON c.id = i.skill_id WHERE c.content_hash = ?1 AND i.agent = ?2)",
                                 .text(source.contentHash), .text(agent.rawValue), map: { $0.bool(0) }) ?? false
        let isBlocked = try db.first("SELECT \(Self.isBlockedSQL) FROM skills s WHERE s.id = ?1", .int(Int64(source.id)), map: { $0.bool(0) }) ?? false
        let blocked: String? = if isBlocked {
            "blocked"
        } else if source.kind != "skill" {
            "plugin"
        } else if files.file("SKILL.md") == nil {
            "no-skill-md"
        } else if files.truncated {
            "too-large"
        } else if name == nil {
            "name"
        } else if hasIt {
            "already"
        } else if Self.exists(target) || Self.exists(SkillDiscovery.offFolder(skillsFolder).appending(path: name ?? "")) {
            "exists"
        } else {
            nil
        }
        var result = try plan(source, files, report, changed: changed, agent: agent, target: target, readers: readers, replaces: false, blocked: blocked)
        if result.blocked == nil { result.blocked = try policyRefusal(verdict: result.verdict, skillID: source.id) }
        return result
    }

    // MARK: - Writing a copy

    private static func isInside(_ relative: String) -> Bool {
        !relative.isEmpty && !relative.hasPrefix("/") && relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Writes the checked files into an empty folder: the bytes that were scanned, a large file copied and compared
    /// with its digest. Links are left out. Nothing of it is ever started.
    private static func writeCopy(_ files: SkillFiles, from source: URL, into folder: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files.files where file.symlink == nil {
            guard isInside(file.path) else { throw Refusal.path }
            let to = folder.appending(path: file.path)
            try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if file.unread {
                try manager.copyItem(at: source.appending(path: file.path), to: to)
                guard try SkillFolder.digest(of: to) == file.digest else { throw Refusal.changed }
            } else {
                try file.bytes.write(to: to)
            }
            try manager.setAttributes([.posixPermissions: file.isExecutable ? 0o755 : 0o644], ofItemAtPath: to.path)
        }
        // What was written is what was checked.
        guard try SkillFolder.read(folder).contentHash == files.contentHashWithoutLinks else { throw Refusal.changed }
    }

    private static func staging(_ skillsFolder: URL, _ name: String) -> URL {
        skillsFolder.deletingLastPathComponent().appending(path: skillsFolder.lastPathComponent + ".aihubbar-staging").appending(path: "\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    }

    private static func cleanStaging(_ stage: URL) {
        try? FileManager.default.removeItem(at: stage)
        try? FileManager.default.removeItem(at: stage.deletingLastPathComponent())   // only when empty: it fails otherwise
    }

    /// Moves a folder; across disks, where a rename can't, `moveItem` copies and removes.
    private static func move(_ from: URL, to: URL) throws {
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: from, to: to)
    }

    /// A new folder in the backups for what is taken out of an agent's folder.
    private static func backupPlace(_ place: Place, _ name: String) -> URL {
        let stamp = String(place.now.filter(\.isNumber).prefix(14))
        var candidate = place.backups.appending(path: "\(stamp)-\(name)")
        var number = 2
        while exists(candidate) {
            candidate = place.backups.appending(path: "\(stamp)-\(name)-\(number)")
            number += 1
        }
        return candidate
    }

    // MARK: - The journal and what the catalog installed

    struct Managed: Codable, Equatable, Sendable {
        var installPath: String
        var name: String
        var originKind: String
        var origin: String
        var sourceHash: String
        var installedHash: String
        var installedAt: String

        // The same JSON as the desktop version's.
        enum CodingKeys: String, CodingKey {
            case installPath = "install_path", name, originKind = "origin_kind", origin, sourceHash = "source_hash", installedHash = "installed_hash", installedAt = "installed_at"
        }
    }

    func managed(_ installPath: String) throws -> Managed? {
        try db.first("SELECT install_path, name, origin_kind, origin, source_hash, installed_hash, installed_at FROM managed_installs WHERE install_path = ?1", .text(installPath)) {
            Managed(installPath: $0.text(0), name: $0.text(1), originKind: $0.text(2), origin: $0.text(3), sourceHash: $0.text(4), installedHash: $0.text(5), installedAt: $0.text(6))
        }
    }

    private func saveManaged(_ row: Managed) throws {
        try db.run("INSERT OR REPLACE INTO managed_installs (install_path, name, origin_kind, origin, source_hash, installed_hash, installed_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                   .text(row.installPath), .text(row.name), .text(row.originKind), .text(row.origin), .text(row.sourceHash), .text(row.installedHash), .text(row.installedAt))
    }

    private struct Entry {
        var action: String
        var name: String
        var agent: String?
        var installPath: String
        var report: SkillReport?
        var acknowledged = false
        var origin: String?
        var backup: URL?
        var linkTarget: String?
        var managed: Managed?
    }

    @discardableResult
    private func log(_ place: Place, _ entry: Entry) throws -> Int {
        let managedJSON = try entry.managed.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try db.run("""
            INSERT INTO install_log (at, action, name, agent, install_path, content_hash, verdict, risk_score, acknowledged, origin, backup_path, link_target, managed_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
            """, .text(place.now), .text(entry.action), .text(entry.name), .optional(entry.agent), .text(entry.installPath), .optional(entry.report?.contentHash),
                   .optional(entry.report?.verdict.rawValue), .optional(entry.report?.riskScore), .bool(entry.acknowledged), .optional(entry.origin),
                   .optional(entry.backup?.path), .optional(entry.linkTarget), .optional(managedJSON))
        return db.lastInsertID
    }

    struct LogRow: Identifiable, Equatable, Sendable {
        var id: Int
        var at: String
        /// `install`, `update`, `remove`, `restore`, `on` or `off`.
        var action: String
        var name: String
        /// The agents, joined with commas.
        var agent: String?
        var installPath: String
        var verdict: SkillVerdict?
        var riskScore: Int?
        var acknowledged: Bool
        var origin: String?
        /// What this step took out is kept and can be put back.
        var canRestore: Bool
        var restored: Bool
    }

    /// Everything the catalog did in the agents' folders, the newest first.
    func journal(limit: Int = 200) throws -> [LogRow] {
        try db.query("""
            SELECT id, at, action, name, agent, install_path, verdict, risk_score, acknowledged, origin, backup_path, link_target, restored_at
            FROM install_log ORDER BY id DESC LIMIT ?1
            """, .int(Int64(limit))) { row in
            let backup = row.optionalText(10)
            let restored = !row.isNull(12)
            var isFolder: ObjCBool = false
            let kept = backup.map { FileManager.default.fileExists(atPath: $0, isDirectory: &isFolder) && isFolder.boolValue } ?? false
            return LogRow(id: row.int(0), at: row.text(1), action: row.text(2), name: row.text(3), agent: row.optionalText(4), installPath: row.text(5),
                          verdict: row.optionalText(6).flatMap(SkillVerdict.init), riskScore: row.optionalInt(7), acknowledged: row.bool(8), origin: row.optionalText(9),
                          canRestore: !restored && ["remove", "update", "restore"].contains(row.text(2)) && (!row.isNull(11) || kept), restored: restored)
        }
    }

    struct Done: Equatable, Sendable {
        var installPath: String
        var journalID: Int
    }

    // MARK: - Installing

    /// Copies the checked skill into the agent's skills folder. `contentHash` is what the person confirmed in the plan;
    /// `acknowledged` that they read the findings of a skill that is not «safe».
    @discardableResult
    func install(_ id: Int, for agent: SkillAgent, contentHash: String, acknowledged: Bool, _ place: Place) throws -> Done {
        let plan = try planInstall(id, for: agent, place)
        if let reason = plan.blocked { throw Refusal(code: reason) }
        guard plan.contentHash == contentHash else { throw Refusal.changed }
        guard !plan.needsAck || acknowledged else { throw Refusal.confirmation }
        let (source, files, report, _) = try current(plan.skillID, place)
        guard report.contentHash == contentHash else { throw Refusal.changed }
        let target = URL(fileURLWithPath: plan.target)
        let skillsFolder = target.deletingLastPathComponent()
        let stage = Self.staging(skillsFolder, plan.name)
        try? FileManager.default.removeItem(at: stage)
        defer { Self.cleanStaging(stage) }
        try Self.writeCopy(files, from: URL(fileURLWithPath: source.path), into: stage)
        try FileManager.default.createDirectory(at: skillsFolder, withIntermediateDirectories: true)
        // The last moment something could have appeared there.
        guard !Self.exists(target) else { throw Refusal.exists }
        try FileManager.default.moveItem(at: stage, to: target)

        try saveManaged(Managed(installPath: plan.target, name: plan.name, originKind: "path", origin: source.path, sourceHash: report.contentHash,
                                installedHash: files.contentHashWithoutLinks, installedAt: place.now))
        let journalID = try log(place, Entry(action: "install", name: plan.name, agent: agent.rawValue, installPath: plan.target, report: report,
                                             acknowledged: plan.needsAck && acknowledged, origin: source.path))
        try refreshInstalled(place.roots, now: place.now, byCatalog: true)
        return Done(installPath: plan.target, journalID: journalID)
    }

    // MARK: - Removing, switching off, putting back

    private struct Installed {
        var path: URL
        var name: String
        var agents: [String]
    }

    /// A skill of the person's own that the catalog lists: only such a folder is ever moved. The path must be one the
    /// catalog found itself, directly inside one of the agents' skills folders (or the folder for switched-off ones).
    private func installed(_ installPath: String, _ place: Place) throws -> Installed {
        let agents = try db.query("SELECT agent FROM installations WHERE install_path = ?1 AND scope = 'user' ORDER BY agent", .text(installPath)) { $0.text(0) }
        let path = URL(fileURLWithPath: installPath).standardizedFileURL
        let parent = path.deletingLastPathComponent().path
        let grand = path.deletingLastPathComponent().deletingLastPathComponent().path
        // A group folder (`skills/group/name`) is one level deeper.
        let known = place.roots.userSkillFolders.contains { folder, _ in
            let dirs = [folder.standardizedFileURL.path, SkillDiscovery.offFolder(folder).standardizedFileURL.path]
            return dirs.contains(parent) || dirs.contains(grand)
        }
        guard !agents.isEmpty, known, path.lastPathComponent != ".." else { throw Refusal.notYours }
        return Installed(path: path, name: path.lastPathComponent, agents: agents)
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Takes an installed skill out of the agent's folder. The folder goes to the backups, a link is only unlinked;
    /// either can be put back from the journal.
    @discardableResult
    func remove(_ installPath: String, _ place: Place) throws -> Done {
        let found = try installed(installPath, place)
        guard Self.exists(found.path) else { throw Refusal.missing }
        let was = try managed(installPath)
        let agents = found.agents.joined(separator: ", ")
        let journalID: Int
        if Self.isLink(found.path) {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: found.path.path)
            try FileManager.default.removeItem(at: found.path)
            journalID = try log(place, Entry(action: "remove", name: found.name, agent: agents, installPath: installPath, linkTarget: target, managed: was))
        } else {
            let backup = Self.backupPlace(place, found.name)
            try Self.move(found.path, to: backup)
            journalID = try log(place, Entry(action: "remove", name: found.name, agent: agents, installPath: installPath, backup: backup, managed: was))
        }
        try db.run("DELETE FROM managed_installs WHERE install_path = ?1", .text(installPath))
        try refreshInstalled(place.roots, now: place.now, byCatalog: true)
        return Done(installPath: installPath, journalID: journalID)
    }

    /// Switches a skill off or on: its folder moves, whole, to the folder beside the skills folder and back — the way
    /// the «инструкции и MCP» window does it.
    @discardableResult
    func setEnabled(_ installPath: String, _ on: Bool, _ place: Place) throws -> Done {
        let found = try installed(installPath, place)
        let parent = found.path.deletingLastPathComponent().path
        let folders = place.roots.userSkillFolders.map { $0.0.standardizedFileURL }
        let toFolder: URL? = on
            ? folders.first { SkillDiscovery.offFolder($0).standardizedFileURL.path == parent }
            : folders.first { $0.path == parent }.map { SkillDiscovery.offFolder($0) }
        guard let toFolder else { throw Refusal.state }
        let target = toFolder.appending(path: found.name).standardizedFileURL
        guard !Self.exists(target) else { throw Refusal.exists }
        try FileManager.default.createDirectory(at: toFolder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: found.path, to: target)
        try db.run("UPDATE managed_installs SET install_path = ?2 WHERE install_path = ?1", .text(installPath), .text(target.path))
        let journalID = try log(place, Entry(action: on ? "on" : "off", name: found.name, agent: found.agents.joined(separator: ", "), installPath: target.path))
        try refreshInstalled(place.roots, now: place.now, byCatalog: true)
        return Done(installPath: target.path, journalID: journalID)
    }

    /// Puts back what a step of the journal took out: a removed skill returns, an update gives way to the version
    /// before it (and is kept in turn, so this can be undone as well).
    @discardableResult
    func restore(_ journalID: Int, _ place: Place) throws -> Done {
        guard let step = try db.first("SELECT action, name, agent, install_path, backup_path, link_target, managed_json, restored_at FROM install_log WHERE id = ?1",
                                      .int(Int64(journalID)), map: { ($0.text(0), $0.text(1), $0.optionalText(2), $0.text(3), $0.optionalText(4), $0.optionalText(5), $0.optionalText(6), $0.isNull(7)) })
        else { throw Refusal.missing }
        let (action, name, agent, installPath, backup, link, managedJSON, notRestored) = step
        guard notRestored, ["remove", "update", "restore"].contains(action) else { throw Refusal.state }
        let target = URL(fileURLWithPath: installPath)
        let before = try managedJSON.map { try JSONDecoder().decode(Managed.self, from: Data($0.utf8)) }
        let there = Self.exists(target)
        var kept: URL?
        let nowManaged = try managed(installPath)
        if let link {
            guard !there else { throw Refusal.exists }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: link)
        } else {
            var isFolder: ObjCBool = false
            guard let backup, FileManager.default.fileExists(atPath: backup, isDirectory: &isFolder), isFolder.boolValue else { throw Refusal.missing }
            if there {
                // Only a step that replaced a copy may replace one back; a removed skill doesn't overwrite a new one.
                guard action != "remove" else { throw Refusal.exists }
                let aside = Self.backupPlace(place, name)
                try Self.move(target, to: aside)
                kept = aside
            }
            do {
                try Self.move(URL(fileURLWithPath: backup), to: target)
            } catch {
                if let kept { try? Self.move(kept, to: target) }
                throw error
            }
        }
        try db.run("DELETE FROM managed_installs WHERE install_path = ?1", .text(installPath))
        if let before { try saveManaged(before) }
        try db.run("UPDATE install_log SET restored_at = ?2 WHERE id = ?1", .int(Int64(journalID)), .text(place.now))
        let newID = try log(place, Entry(action: "restore", name: name, agent: agent, installPath: installPath, backup: kept, managed: nowManaged))
        try refreshInstalled(place.roots, now: place.now, byCatalog: true)
        return Done(installPath: installPath, journalID: newID)
    }

    // MARK: - Newer versions

    struct Update: Identifiable, Equatable, Sendable {
        var installPath: String
        var name: String
        /// Where the copy came from.
        var origin: String
        var fromHash: String
        var toHash: String
        /// The newer version's verdict: it is checked before it is offered.
        var verdict: SkillVerdict
        var riskScore: Int
        /// The installed copy was changed by hand since: an update would replace those changes.
        var edited: Bool
        /// The catalog's entry for the installed copy.
        var skillID: Int?
        var id: String { installPath }
    }

    private static func originFiles(_ row: Managed) -> SkillFiles? {
        row.originKind == "path" ? try? SkillFolder.read(URL(fileURLWithPath: row.origin)) : nil
    }

    /// The installed copies whose source has changed since they were made. A source that is gone is no update.
    func updates() throws -> [Update] {
        let rows = try db.query("SELECT install_path FROM managed_installs ORDER BY name, install_path") { $0.text(0) }.compactMap { try managed($0) }
        var found: [Update] = []
        for row in rows {
            guard let origin = Self.originFiles(row) else { continue }
            let toHash = origin.contentHash
            var isFolder: ObjCBool = false
            guard toHash != row.sourceHash, FileManager.default.fileExists(atPath: row.installPath, isDirectory: &isFolder), isFolder.boolValue else { continue }
            let report = SkillScanner.scan(origin)
            let edited = (try? SkillFolder.read(URL(fileURLWithPath: row.installPath)).contentHash).map { $0 != row.installedHash } ?? false
            let skillID = try db.first("SELECT skill_id FROM installations WHERE install_path = ?1 LIMIT 1", .text(row.installPath), map: { $0.int(0) })
            found.append(Update(installPath: row.installPath, name: row.name, origin: row.origin, fromHash: row.sourceHash, toHash: toHash,
                                verdict: report.verdict, riskScore: report.riskScore, edited: edited, skillID: skillID))
        }
        return found
    }

    struct DiffLine: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case added, removed, same, gap }
        var kind: Kind
        var text: String
    }

    struct FileDiff: Identifiable, Equatable, Sendable {
        enum Status: String, Sendable { case added, removed, changed }
        var path: String
        var status: Status
        /// The changed lines with three lines around them; empty for a file that is not text or too long to compare.
        var lines: [DiffLine]
        var notShown: Bool
        var id: String { path }
    }

    private static let diffCells = 4_000_000
    private static let context = 3

    /// A line by line comparison by the longest common subsequence; nil when the texts are too long for it.
    static func lineDiff(_ old: [String], _ new: [String]) -> [DiffLine]? {
        let (n, m) = (old.count, new.count)
        guard (n + 1) * (m + 1) <= diffCells else { return nil }
        let width = m + 1
        var table = [UInt32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * width + j] = old[i] == new[j] ? table[(i + 1) * width + j + 1] + 1 : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var all: [DiffLine] = []
        var (i, j) = (0, 0)
        while i < n || j < m {
            if i < n, j < m, old[i] == new[j] {
                all.append(DiffLine(kind: .same, text: SkillText.visible(old[i])))
                i += 1
                j += 1
            } else if i < n, j == m || table[(i + 1) * width + j] >= table[i * width + j + 1] {
                // A changed line reads as the old one, then the new one.
                all.append(DiffLine(kind: .removed, text: SkillText.visible(old[i])))
                i += 1
            } else {
                all.append(DiffLine(kind: .added, text: SkillText.visible(new[j])))
                j += 1
            }
        }
        // Only the changes and a few lines around each.
        let changed = all.indices.filter { all[$0].kind != .same }
        var shown: [DiffLine] = []
        var last: Int?
        for (index, line) in all.enumerated() where changed.contains(where: { abs($0 - index) <= context }) {
            if let previous = last, index > previous + 1 { shown.append(DiffLine(kind: .gap, text: "")) } else if last == nil, index > 0 { shown.append(DiffLine(kind: .gap, text: "")) }
            shown.append(line)
            last = index
        }
        return shown
    }

    private static func text(_ file: SkillFile) -> String? {
        file.symlink == nil && !file.unread && SkillFileKind.of(file).isText ? file.text : nil
    }

    /// What an update would change in an installed copy, file by file.
    func diff(_ installPath: String) throws -> [FileDiff] {
        guard let row = try managed(installPath), let origin = Self.originFiles(row), let installed = try? SkillFolder.read(URL(fileURLWithPath: installPath)) else { throw Refusal.missing }
        let paths = Set(installed.files.map(\.path) + origin.files.filter { $0.symlink == nil }.map(\.path)).sorted()
        var changes: [FileDiff] = []
        for path in paths {
            let old = installed.file(path)
            let new = origin.file(path).flatMap { $0.symlink == nil ? $0 : nil }
            let status: FileDiff.Status
            switch (old, new) {
            case let (a?, b?) where a.digest == b.digest: continue
            case (.some, .some): status = .changed
            case (nil, .some): status = .added
            case (.some, nil): status = .removed
            case (nil, nil): continue
            }
            // A side that is there but is not text can't be shown line by line.
            let oldText = old.map(Self.text), newText = new.map(Self.text)
            let lines: [DiffLine]? = if case .some(nil) = oldText { nil } else if case .some(nil) = newText { nil } else {
                Self.lineDiff(SkillScanner.lines((oldText ?? nil) ?? ""), SkillScanner.lines((newText ?? nil) ?? ""))
            }
            changes.append(FileDiff(path: path, status: status, lines: lines ?? [], notShown: lines == nil))
        }
        return changes
    }

    /// What bringing the newer version in would do: the newer version's own check, to be confirmed like an install.
    func planUpdate(_ installPath: String, _ place: Place) throws -> Plan {
        let found = try installed(installPath, place)
        guard let row = try managed(installPath), let origin = Self.originFiles(row) else { throw Refusal.missing }
        let report = SkillScanner.scan(origin)
        let newName = Self.describe(origin, folder: row.origin, listedName: nil).name
        let blocked: String? = if try isBlocked(kind: "skill", name: newName, contentHash: report.contentHash) || isBlocked(kind: "skill", name: row.name, contentHash: report.contentHash) { "blocked" } else if origin.file("SKILL.md") == nil { "no-skill-md" } else if origin.truncated { "too-large" } else if report.contentHash == row.sourceHash { "already" } else { nil }
        let id = try db.first("SELECT skill_id FROM installations WHERE install_path = ?1 LIMIT 1", .text(installPath), map: { $0.int(0) }) ?? 0
        let agents = found.agents.compactMap(SkillAgent.init)
        var result = try plan(Source(id: id, kind: "skill", source: "local", path: row.origin, contentHash: report.contentHash), origin, report, changed: true,
                              agent: agents.first, target: found.path, readers: agents, replaces: true, blocked: blocked)
        if result.blocked == nil { result.blocked = try policyRefusal(verdict: result.verdict, skillID: id) }
        return result
    }

    /// Replaces an installed copy with the newer version of its source. The copy that was there goes to the backups
    /// and can be put back from the journal.
    @discardableResult
    func update(_ installPath: String, contentHash: String, acknowledged: Bool, _ place: Place) throws -> Done {
        let plan = try planUpdate(installPath, place)
        if let reason = plan.blocked { throw Refusal(code: reason) }
        guard plan.contentHash == contentHash else { throw Refusal.changed }
        guard !plan.needsAck || acknowledged else { throw Refusal.confirmation }
        guard let was = try managed(installPath), let origin = Self.originFiles(was) else { throw Refusal.missing }
        let report = SkillScanner.scan(origin)
        guard report.contentHash == contentHash else { throw Refusal.changed }
        let target = URL(fileURLWithPath: installPath)
        let stage = Self.staging(target.deletingLastPathComponent(), plan.name)
        try? FileManager.default.removeItem(at: stage)
        defer { Self.cleanStaging(stage) }
        let backup = Self.backupPlace(place, plan.name)
        try Self.writeCopy(origin, from: URL(fileURLWithPath: was.origin), into: stage)
        try Self.move(target, to: backup)
        do {
            try FileManager.default.moveItem(at: stage, to: target)
        } catch {
            // The copy that was there comes back.
            try? Self.move(backup, to: target)
            throw error
        }
        var row = was
        row.sourceHash = report.contentHash
        row.installedHash = origin.contentHashWithoutLinks
        row.installedAt = place.now
        try saveManaged(row)
        let journalID = try log(place, Entry(action: "update", name: plan.name, agent: plan.agent?.rawValue, installPath: installPath, report: report,
                                             acknowledged: plan.needsAck && acknowledged, origin: was.origin, backup: backup, managed: was))
        try refreshInstalled(place.roots, now: place.now, byCatalog: true)
        return Done(installPath: installPath, journalID: journalID)
    }
}
