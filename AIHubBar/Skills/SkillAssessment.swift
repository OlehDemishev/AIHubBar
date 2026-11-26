import Foundation

/// The answer to «why this verdict»: the findings that decided it, what the skill can do, and what would make it
/// safer. Built from a `SkillReport` alone; the words for each part live in the string catalog.
struct SkillAssessment: Equatable, Sendable {
    /// What a skill can do, in the terms a person thinks in.
    enum Capability: String, CaseIterable, Codable, Sendable {
        /// Reaches the internet.
        case network
        /// Sends data out (uploads, webhooks, paste sites).
        case sendsData
        /// Runs scripts or commands.
        case runsCode
        /// Reads keys, passwords or tokens.
        case readsSecrets
        /// Deletes, needs administrator rights, starts with the system.
        case changesSystem
        /// Changes the agent's own permissions or settings.
        case changesAgent
        /// Installs packages that were not checked.
        case installsPackages
        /// Brings hooks: commands that run by themselves.
        case hooks
        /// Brings MCP servers.
        case mcp
        /// Has text or code that is hidden or can't be read.
        case hidden
        /// Has instructions aimed against the person.
        case againstUser
    }

    /// How much of a capability was found.
    enum Level: Int, Comparable, Sendable {
        case none, present, risky
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// One finding that explains the verdict.
    struct Reason: Equatable, Sendable {
        var finding: SkillFinding
        /// More findings of the same rule.
        var alsoFound: Int
    }

    /// What would make the skill safer, for whoever writes it or decides to trust it.
    enum Advice: String, CaseIterable, Sendable {
        /// Signs of an attack: no fix makes this one safe to install as it is.
        case doNotInstall
        case reviewScriptsFirst
        case downloadThenReview
        case pinVersion
        case pinPackages
        case checkPackageName
        case narrowTools
        case noPermissionChanges
        case useHTTPS
        case shipReadableSource
        case scopeKeys
        case noLinks
        case readHooks
        case addLicense
        case fixFrontmatter
    }

    var verdict: SkillVerdict
    var riskScore: Int
    /// The findings that decided the verdict, the most serious first: at most three rules.
    var reasons: [Reason]
    /// Findings worth reading that are not among the reasons.
    var otherFindings: Int
    var capabilities: [Capability: Level]
    var advice: [Advice]

    func level(_ capability: Capability) -> Level { capabilities[capability] ?? .none }

    // MARK: - From a report

    /// Which capability each rule shows.
    static let capabilityOf: [String: [Capability]] = [
        "net-call": [.network], "hardcoded-ip": [.network], "net-upload": [.network, .sendsData], "exfil-endpoint": [.network, .sendsData],
        "exfil-combo": [.sendsData, .readsSecrets], "hook-network": [.network, .hooks], "mcp-insecure-url": [.network, .mcp],
        "pipe-to-shell": [.network, .runsCode], "decode-exec": [.runsCode, .hidden], "dynamic-exec": [.runsCode],
        "scripts-present": [.runsCode], "executable-binary": [.runsCode, .hidden], "command-inline-exec": [.runsCode],
        "secret-read": [.readsSecrets], "sensitive-path": [.readsSecrets], "env-dump": [.readsSecrets], "env-secret": [.readsSecrets], "dotenv-read": [.readsSecrets],
        "rm-rf-home": [.changesSystem], "rm-rf": [.changesSystem], "sudo": [.changesSystem], "chmod-open": [.changesSystem],
        "persistence": [.changesSystem], "shell-rc": [.changesSystem],
        "agent-config": [.changesAgent], "broad-permissions": [.changesAgent], "allowed-tools-shell": [.changesAgent, .runsCode],
        "pkg-install": [.installsPackages], "pkg-remote": [.installsPackages], "typosquat": [.installsPackages], "not-walked": [.installsPackages],
        "hook-command": [.hooks, .runsCode], "mcp-server": [.mcp], "mcp-remote-code": [.mcp, .installsPackages],
        "long-base64": [.hidden], "long-hex": [.hidden], "char-codes": [.hidden], "packed-code": [.hidden], "minified": [.hidden],
        "archive": [.hidden], "unknown-binary": [.hidden], "invisible-chars": [.hidden], "invisible-bidi": [.hidden, .againstUser],
        "invisible-tags": [.hidden, .againstUser], "pi-hidden-text": [.hidden, .againstUser], "pi-hidden-comment": [.hidden, .againstUser],
        "pi-override": [.againstUser], "pi-conceal": [.againstUser], "pi-disable-safety": [.againstUser, .changesAgent],
        "pi-exfil": [.againstUser, .sendsData, .readsSecrets], "pi-role": [.againstUser],
    ]

    /// The advice a rule calls for.
    static let adviceFor: [String: Advice] = [
        "scripts-present": .reviewScriptsFirst, "dynamic-exec": .reviewScriptsFirst, "command-inline-exec": .reviewScriptsFirst,
        "pipe-to-shell": .downloadThenReview, "mcp-remote-code": .pinVersion, "pkg-install": .pinPackages, "pkg-remote": .pinPackages,
        "not-walked": .pinPackages, "typosquat": .checkPackageName, "allowed-tools-shell": .narrowTools,
        "broad-permissions": .noPermissionChanges, "agent-config": .noPermissionChanges, "hardcoded-ip": .useHTTPS, "mcp-insecure-url": .useHTTPS,
        "long-base64": .shipReadableSource, "long-hex": .shipReadableSource, "char-codes": .shipReadableSource, "packed-code": .shipReadableSource,
        "minified": .shipReadableSource, "executable-binary": .shipReadableSource, "archive": .shipReadableSource,
        "env-secret": .scopeKeys, "symlink": .noLinks, "hook-command": .readHooks, "no-license": .addLicense,
        "frontmatter": .fixFrontmatter, "no-skill-md": .fixFrontmatter,
    ]

    /// Rules that mean an attack rather than a risky habit: when one decides a «dangerous» verdict, no fix is offered.
    static let attackRules: Set<String> = [
        "exfil-combo", "pi-exfil", "pi-override", "pi-conceal", "pi-disable-safety", "pi-hidden-text", "pi-hidden-comment", "invisible-tags",
        "decode-exec", "persistence", "shell-rc", "rm-rf-home", "secret-read", "exfil-endpoint",
    ]

    init(_ report: SkillReport, llmVerdict: SkillVerdict? = nil) {
        verdict = max(report.verdict, llmVerdict ?? .safe)
        riskScore = report.riskScore
        let worth = report.findings.filter { $0.severity >= .low }

        // The reasons: one finding per rule, the most serious rules first. For «dangerous» only what reaches the
        // level that made it so; for «review» whatever is worth reading.
        let floor: SkillSeverity = report.verdict == .dangerous ? (worth.contains { $0.severity == .critical } ? .critical : .high) : .low
        var seen: [String: Int] = [:]
        var picked: [Reason] = []
        for finding in worth where finding.severity >= floor {
            if let index = seen[finding.rule] {
                picked[index].alsoFound += 1
            } else if picked.count < 3 {
                seen[finding.rule] = picked.count
                picked.append(Reason(finding: finding, alsoFound: 0))
            }
        }
        reasons = picked
        let shown = picked.reduce(0) { $0 + 1 + $1.alsoFound }
        otherFindings = max(0, worth.count - shown)

        var levels: [Capability: Level] = [:]
        for finding in worth {
            for capability in Self.capabilityOf[finding.rule] ?? [] {
                let level: Level = finding.severity >= .high ? .risky : .present
                levels[capability] = max(levels[capability] ?? .none, level)
            }
        }
        capabilities = levels

        let attack = report.verdict == .dangerous && report.findings.contains { $0.severity >= .high && Self.attackRules.contains($0.rule) }
        if attack {
            advice = [.doNotInstall]
        } else {
            var list: [Advice] = []
            for finding in report.findings {
                if let item = Self.adviceFor[finding.rule], !list.contains(item) { list.append(item) }
            }
            // Ordered as the enum lists them: the weightiest first.
            advice = Advice.allCases.filter { list.contains($0) }
        }
    }
}
