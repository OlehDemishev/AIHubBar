import Foundation

/// Complaints about a skill and the person's block list (docs/specs/SPEC-skills.md). A complaint is kept on this Mac
/// first; it reaches the skill's author or AI Hub Bar only through a GitHub page the person opens and submits
/// themselves. A blocked skill can't be installed or updated from the catalog, and an installed one is an alert.
extension SkillCatalog {
    static let reportsMigration = """
        -- Where a skill says it lives (a plugin's `repository` or `homepage`, a SKILL.md's `metadata`): for complaints.
        ALTER TABLE skills ADD COLUMN homepage TEXT;
        CREATE TABLE skill_reports (
            id            INTEGER PRIMARY KEY,
            kind          TEXT NOT NULL,
            name          TEXT NOT NULL,
            content_hash  TEXT NOT NULL,
            reason        TEXT NOT NULL,                   -- malicious | misleading | broken | license | falseAlarm | other
            details       TEXT NOT NULL DEFAULT '',
            created_at    TEXT NOT NULL,
            sent_to       TEXT NOT NULL DEFAULT ''         -- ',author,aihubbar,': the GitHub pages the person opened for it
        );
        CREATE INDEX skill_reports_skill ON skill_reports(kind, name);
        -- By kind and name; an empty content hash blocks every version.
        CREATE TABLE skill_blocks (
            kind          TEXT NOT NULL,
            name          TEXT NOT NULL,
            content_hash  TEXT NOT NULL DEFAULT '',
            reason        TEXT NOT NULL DEFAULT '',
            created_at    TEXT NOT NULL,
            PRIMARY KEY (kind, name, content_hash)
        );
        """

    /// The SQL that says a skill row `s` is blocked.
    static let isBlockedSQL = "EXISTS (SELECT 1 FROM skill_blocks b WHERE b.kind = s.kind AND b.name = s.name AND (b.content_hash = '' OR b.content_hash = s.content_hash))"

    enum ReportReason: String, CaseIterable, Codable, Sendable {
        case malicious, misleading, broken, license, falseAlarm, other

        /// The option of the repository's skill_report.yml form.
        var formOption: String {
            switch self {
            case .malicious: "Looks malicious"
            case .misleading: "Does something else than it says"
            case .broken: "Doesn't work"
            case .license: "License or authorship"
            case .falseAlarm: "The check was wrong (false alarm)"
            case .other: "Something else"
            }
        }
    }

    struct Report: Identifiable, Equatable, Sendable {
        var id: Int
        var kind: String
        var name: String
        var contentHash: String
        var reason: ReportReason
        var details: String
        var createdAt: String
        /// `author`, `aihubbar`: the pages opened for it.
        var sentTo: Set<String>
    }

    /// Keeps a complaint about the skill as it is now. Nothing leaves this Mac.
    @discardableResult
    func report(_ id: Int, reason: ReportReason, details: String, now: String = SkillCatalog.now()) throws -> Int {
        guard let (kind, name, hash) = try db.first("SELECT kind, name, content_hash FROM skills WHERE id = ?1", .int(Int64(id)), map: { ($0.text(0), $0.text(1), $0.text(2)) }) else { throw Refusal.missing }
        let text = String(details.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        try db.run("INSERT INTO skill_reports (kind, name, content_hash, reason, details, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                   .text(kind), .text(name), .text(hash), .text(reason.rawValue), .text(text), .text(now))
        return db.lastInsertID
    }

    /// The complaints about a skill, any version of it, the newest first.
    func reports(kind: String, name: String) throws -> [Report] {
        try db.query("SELECT id, kind, name, content_hash, reason, details, created_at, sent_to FROM skill_reports WHERE kind = ?1 AND name = ?2 ORDER BY id DESC", .text(kind), .text(name)) {
            Report(id: $0.int(0), kind: $0.text(1), name: $0.text(2), contentHash: $0.text(3), reason: ReportReason(rawValue: $0.text(4)) ?? .other,
                   details: $0.text(5), createdAt: $0.text(6), sentTo: Set($0.text(7).split(separator: ",").map(String.init)))
        }
    }

    /// Remembers that the person opened a GitHub page for the complaint (`author` or `aihubbar`).
    func markSent(_ reportID: Int, to place: String) throws {
        let now = try db.first("SELECT sent_to FROM skill_reports WHERE id = ?1", .int(Int64(reportID)), map: { $0.text(0) }) ?? ""
        let places = Set(now.split(separator: ",").map(String.init)).union([place]).sorted()
        try db.run("UPDATE skill_reports SET sent_to = ?2 WHERE id = ?1", .int(Int64(reportID)), .text("," + places.joined(separator: ",") + ","))
    }

    func deleteReport(_ reportID: Int) throws {
        try db.run("DELETE FROM skill_reports WHERE id = ?1", .int(Int64(reportID)))
    }

    // MARK: - The block list

    struct Block: Equatable, Sendable {
        /// Only this version; every version when false.
        var isThisVersion: Bool
        var reason: String
        var createdAt: String
    }

    /// Blocks a skill: this version only, or every version of that name.
    func block(_ id: Int, everyVersion: Bool, reason: String = "", now: String = SkillCatalog.now()) throws {
        guard let (kind, name, hash) = try db.first("SELECT kind, name, content_hash FROM skills WHERE id = ?1", .int(Int64(id)), map: { ($0.text(0), $0.text(1), $0.text(2)) }) else { throw Refusal.missing }
        try db.run("INSERT OR REPLACE INTO skill_blocks (kind, name, content_hash, reason, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
                   .text(kind), .text(name), .text(everyVersion ? "" : hash), .text(String(reason.prefix(500))), .text(now))
    }

    /// Takes every block off this skill: its version's and the one for every version.
    func unblock(_ id: Int) throws {
        guard let (kind, name, hash) = try db.first("SELECT kind, name, content_hash FROM skills WHERE id = ?1", .int(Int64(id)), map: { ($0.text(0), $0.text(1), $0.text(2)) }) else { return }
        try db.run("DELETE FROM skill_blocks WHERE kind = ?1 AND name = ?2 AND (content_hash = '' OR content_hash = ?3)", .text(kind), .text(name), .text(hash))
    }

    /// The block that covers this skill, every version's first.
    func blockOf(_ id: Int) throws -> Block? {
        try db.first("""
            SELECT b.content_hash, b.reason, b.created_at FROM skill_blocks b JOIN skills s ON b.kind = s.kind AND b.name = s.name
            WHERE s.id = ?1 AND (b.content_hash = '' OR b.content_hash = s.content_hash) ORDER BY b.content_hash = '' DESC LIMIT 1
            """, .int(Int64(id))) { Block(isThisVersion: !$0.text(0).isEmpty, reason: $0.text(1), createdAt: $0.text(2)) }
    }

    /// Whether a version of a skill is blocked, by its kind, name and content.
    func isBlocked(kind: String, name: String, contentHash: String) throws -> Bool {
        try db.first("SELECT 1 FROM skill_blocks WHERE kind = ?1 AND name = ?2 AND (content_hash = '' OR content_hash = ?3) LIMIT 1",
                     .text(kind), .text(name), .text(contentHash), map: { _ in true }) ?? false
    }

    // MARK: - Where a complaint can go

    /// The skill's GitHub repository when it names one: only such a link gets «Автору на GitHub».
    static func githubRepository(_ homepage: String?) -> URL? {
        guard let homepage, var components = URLComponents(string: homepage.trimmingCharacters(in: .whitespaces)),
              components.scheme == "https", components.host == "github.com" else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts.prefix(2).allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } && !$0.hasPrefix(".") }) else { return nil }
        components.path = "/" + parts[0] + "/" + (parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1])
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The facts a complaint carries, with nothing from this Mac's paths: the name, the hash, the verdict and its rules.
    static func reportFacts(_ card: Card) -> (skill: String, hash: String, verdict: String) {
        let rules = card.assessment.reasons.map(\.finding.rule)
        let verdict = "\(card.assessment.verdict.rawValue), risk \(card.assessment.riskScore) of 100" + (rules.isEmpty ? "" : ": " + rules.joined(separator: ", "))
        return ("\(card.row.name) (\(card.row.kind))", card.row.contentHash, verdict)
    }

    /// The text of a complaint for the author's issue tracker, in English: the catalog's facts and the person's words.
    static func reportText(_ report: Report, card: Card) -> String {
        let facts = reportFacts(card)
        var lines = ["Skill: \(facts.skill)", "Content hash: \(facts.hash)", "AI Hub Bar's check: \(facts.verdict)", "Reason: \(report.reason.formOption)"]
        if !report.details.isEmpty { lines += ["", report.details] }
        return lines.joined(separator: "\n")
    }
}
