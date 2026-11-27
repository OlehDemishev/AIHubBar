import Foundation

/// Static safety checks for Agent Skills and Claude Code plugins. Port of `desktop/skill-scanner` (rules v2).
///
/// The one rule that is never broken: nothing from a skill is ever run. Its files are bytes to read — no process is
/// started, no script is loaded, no link is followed, and nothing written in them is taken as an instruction.
struct SkillFinding: Equatable, Codable, Sendable {
    var rule: String
    var category: SkillCategory
    var severity: SkillSeverity
    var file: String
    /// 1-based; 0 when the finding is about the whole file.
    var line: Int
    /// The line itself (or what was found), shortened.
    var excerpt: String
}

enum SkillVerdict: String, Codable, Sendable, CaseIterable, Comparable {
    /// Instructions only: no scripts, no network, nothing to look at.
    case safe
    /// Scripts, network or settings: read the findings first.
    case review
    /// Looks like an attack: data sent out, hidden code or instructions, staying in the system.
    case dangerous

    private var rank: Int { [.safe: 0, .review: 1, .dangerous: 2][self] ?? 1 }
    static func < (a: SkillVerdict, b: SkillVerdict) -> Bool { a.rank < b.rank }
}

struct SkillReport: Equatable, Codable, Sendable {
    /// Raised whenever the rules or the scoring change: stored results of an older version are checked again.
    /// 3: local sockets, a copy of the environment, `curl | sh` named in prose, comments in code (2026-11-27, after
    /// false alarms on anthropics/skills). The Rust scanner in desktop/ stays at 2 until Windows work resumes.
    static let scannerVersion = 4

    var scannerVersion = SkillReport.scannerVersion
    var contentHash: String
    var riskScore: Int
    var verdict: SkillVerdict
    var findings: [SkillFinding]
    var hasScripts: Bool
    var languages: [String]
    var fileCount: Int
    var totalBytes: UInt64

    func has(_ rule: String) -> Bool { findings.contains { $0.rule == rule } }
}

enum SkillScanner {
    /// At most this many findings of one rule in one file are kept: the first ones tell the story.
    private static let perRuleAndFile = 8

    /// When the first rule matched a line, the second says nothing new about it.
    private static let covers: [(String, String)] = [
        ("secret-read", "sensitive-path"), ("rm-rf-home", "rm-rf"), ("pkg-remote", "pkg-install"), ("net-upload", "net-call"),
        ("pipe-to-shell", "net-call"), ("pipe-to-shell", "dynamic-exec"), ("decode-exec", "dynamic-exec"), ("decode-exec", "long-base64"),
        ("shell-rc", "sensitive-path"),
    ]

    private static let pip = ["requests", "numpy", "pandas", "urllib3", "boto3", "setuptools", "pyyaml", "cryptography", "pillow", "django", "flask", "scipy", "matplotlib", "beautifulsoup4", "selenium", "pytest", "openai", "anthropic", "tensorflow", "torch", "httpx", "aiohttp", "pydantic", "fastapi", "colorama", "jinja2", "click", "sqlalchemy", "paramiko", "playwright", "python-dotenv", "tqdm", "pypdf", "openpyxl"]
    private static let npm = ["react", "lodash", "express", "axios", "chalk", "commander", "typescript", "webpack", "eslint", "prettier", "moment", "request", "puppeteer", "playwright", "dotenv", "electron", "jquery", "yargs", "openai", "cross-env", "node-fetch", "sharp", "nodemon", "mongoose", "vite", "react-dom"]

    // Fixed expressions, compiled once.
    // swiftlint:disable force_try
    private static let install = try! NSRegularExpression(pattern: ##"(?i)\b(pip\d?|pipx|uv\s+pip|uv\s+add|uvx|npm|npx|pnpm|yarn|bunx?)\s+(?:install|i|add|dlx|x)?\s*([^\n;&|#`]*)"##)
    private static let comment = try! NSRegularExpression(pattern: ##"(?s)<!--(.*?)-->"##)
    private static let commentOrder = try! NSRegularExpression(pattern: SkillRules.commentOrder)
    private static let inlineCommand = try! NSRegularExpression(pattern: ##"(?:^|\s)!`([^`\n]+)`"##)
    // swiftlint:enable force_try

    /// The findings collected while a skill is read, deduplicated and capped.
    final class Collector {
        private(set) var list: [SkillFinding] = []

        func push(_ rule: String, _ severity: SkillSeverity, _ file: String, _ line: Int, _ excerpt: String) {
            if list.contains(where: { $0.rule == rule && $0.file == file && $0.line == line }) { return }
            if list.filter({ $0.rule == rule && $0.file == file }).count >= perRuleAndFile { return }
            list.append(SkillFinding(rule: rule, category: SkillRules.category(rule), severity: severity, file: file, line: line, excerpt: SkillText.excerpt(excerpt)))
        }
    }

    // MARK: - Lines

    /// Lines as Rust's `str::lines` gives them: split at `\n`, a trailing `\r` dropped, no empty line after a final
    /// line break — so line numbers and counts are the same in both scanners.
    static func lines(_ text: String) -> [String] {
        var all = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        if text.hasSuffix("\n") || text.isEmpty { all.removeLast() }
        return all
    }

    private static func ns(_ text: String) -> NSRange { NSRange(text.startIndex..., in: text) }

    /// A match that is known to be harmless: a public key, an example file, a picture written as text.
    private static func harmless(_ rule: String, path: String, line: String, match: Range<String.Index>) -> Bool {
        let rest = line[match.upperBound...].lowercased()
        switch rule {
        case "secret-read", "sensitive-path":
            let word = rest.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" }).first.map(String.init) ?? ""
            return rest.hasPrefix(".pub") || ((rest.hasPrefix("/id_") || rest.hasPrefix("\\id_")) && word.hasSuffix(".pub"))
                || rest.hasPrefix("/known_hosts") || rest.hasPrefix("\\known_hosts") || rest.hasPrefix("/authorized_keys") || rest.hasPrefix("/config")
        case "dotenv-read":
            return [".example", ".sample", ".template", ".dist", ".defaults"].contains { rest.hasPrefix($0) }
        case "long-base64":
            let text = line[match]
            let lower = line.lowercased()
            let slashes = text.filter { $0 == "/" }.count
            return lower.contains("data:image/") || lower.contains("data:font/") || lower.contains("data:application/font") || lower.contains("sha512-") || lower.contains("sha256-") || lower.contains("integrity")
                || path.hasSuffix(".lock") || path.hasSuffix("-lock.json") || path.hasSuffix(".svg")
                // A long path or a row of one letter is not an encoded block.
                || slashes * 12 > text.utf8.count || !text.contains(where: \.isNumber) || !text.contains(where: \.isLowercase) || !text.contains(where: \.isUppercase)
        case "long-hex":
            return path.hasSuffix(".lock") || path.hasSuffix("-lock.json")
        case "exfil-endpoint":
            // «hooks.slack.com/services/T.../B.../xxx» in a guide is a placeholder: nothing can be sent to it. Only for
            // the webhooks whose secret is the path after the match (an attacker can't choose it), and only up to `?`/`#`.
            let said = line[match].lowercased()
            guard ["hooks.slack.com/services", "/api/webhooks", "api.telegram.org/bot"].contains(where: { said.hasSuffix($0) }) else { return false }
            let token = rest.prefix { !$0.isWhitespace && !"\"'`)>?#,;".contains($0) }
            return ["...", "…", "xxx", "your", "<", "placeholder", "redacted", "***"].contains { token.contains($0) }
        case "net-call":
            // A Unix domain socket talks to a process on this Mac (LibreOffice, a local server), not to the network.
            return line[match].lowercased().hasPrefix("socket.") && line.contains("AF_UNIX")
        case "pipe-to-shell":
            // «`curl | sh` lines» names the practice; a command has something between the tool and the pipe.
            let text = line[match]
            guard let bar = text.firstIndex(of: "|") else { return false }
            let tool = text.prefix { !$0.isWhitespace && $0 != "|" }
            return text[text.index(text.startIndex, offsetBy: tool.count)..<bar].trimmingCharacters(in: .whitespaces).isEmpty
        case "pi-conceal":
            let said = line[match].lowercased()
            // «Do not tell the user they need to …» advises on wording; «never … without asking the user» means ask.
            if rest.hasPrefix(" they ") || rest.hasPrefix(" to ") || rest.hasPrefix(" that they ") { return true }
            if said.hasPrefix("without") {
                let before = line[..<match.lowerBound].lowercased().suffix(60)
                return ["never ", "don't ", "do not ", "not "].contains { before.contains($0) }
            }
            return false
        case "pi-override":
            // «if a new system prompt regresses» is about managing prompts, not a new one being set.
            let said = line[match].lowercased()
            if said.hasPrefix("new system prompt") || said.hasPrefix("new  system") {
                let before = line[..<match.lowerBound].lowercased().suffix(12)
                let announces = rest.hasPrefix(":") || rest.hasPrefix(" is") || rest.hasPrefix(" follows") || rest.hasPrefix(" below")
                return !announces && (before.hasSuffix("a ") || before.hasSuffix("the ") || before.hasSuffix("each ") || before.hasSuffix("every "))
            }
            return false
        default:
            return false
        }
    }

    /// A line that is only a comment in a script: `#` (not a shebang), `//`, `/*`, `*`, `--`, `;`, `REM`.
    static func isComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#!") { return false }
        return ["#", "//", "/*", "*", "--", ";", "REM ", "rem "].contains { trimmed.hasPrefix($0) }
    }

    /// Whether the text at `start` opens right after a quotation mark.
    private static func quoted(_ line: String, _ start: String.Index) -> Bool {
        let before = line[..<start].trimmingCharacters(in: .whitespaces)
        guard let last = before.last else { return false }
        return ["\"", "'", "`", "“", "«", "‘", "„"].contains(last)
    }

    /// Package names in an install command that are one typo away from a well-known package.
    private static func typosquats(_ line: String) -> [(String, String)] {
        var found: [(String, String)] = []
        for match in install.matches(in: line, range: ns(line)) {
            guard let toolRange = Range(match.range(at: 1), in: line), let wordsRange = Range(match.range(at: 2), in: line) else { continue }
            let tool = line[toolRange].lowercased()
            let known = tool.hasPrefix("pip") || tool.hasPrefix("uv") ? pip : npm
            for word in line[wordsRange].split(whereSeparator: \.isWhitespace) {
                if word.hasPrefix("-") || word.contains("://") || (word.contains("/") && !word.hasPrefix("@")) { continue }
                let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"',()")).lowercased()
                var name = trimmed.split(whereSeparator: { "=<>~[!".contains($0) }).first.map(String.init) ?? ""
                if let at = name.lastIndex(of: "@"), at != name.startIndex { name = String(name[..<at]) }
                if name.utf8.count < 5 || known.contains(name) { continue }
                if let popular = known.first(where: { SkillText.oneTypoApart(name, $0) }) { found.append((name, popular)) }
            }
        }
        return found
    }

    /// Checks a text line by line. `fixedLine` is for text that came out of another file (a hook's command): every
    /// finding points at that line. Returns the rules that matched.
    @discardableResult
    static func scanText(_ path: String, _ text: String, isDoc: Bool, fixedLine: Int? = nil, into out: Collector) -> Set<String> {
        var matched: Set<String> = []
        var linesOf: [String: [Int]] = [:]
        let all = lines(text)
        for (index, raw) in all.enumerated() {
            let number = fixedLine ?? index + 1
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let hidden = SkillText.hasHidden(raw)
            let line = hidden ? SkillText.withoutHidden(raw) : raw
            var here: [(LineRule, SkillSeverity)] = []
            for (rule, regex) in SkillRules.compiled {
                if isDoc && rule.inDocs == .skip { continue }
                let found = regex.matches(in: line, range: ns(line)).lazy
                    .compactMap { Range($0.range, in: line) }
                    .first { !harmless(rule.id, path: path, line: line, match: $0) }
                guard let found else { continue }
                var severity = isDoc && rule.inDocs == .lower ? rule.severity.lowered : rule.severity
                // In a script a comment doesn't run: a path or a command written there to explain an attack weighs two
                // steps less. Words aimed at the agent (`pi-…`) are read in comments too, so they keep their weight.
                if !isDoc && !rule.id.hasPrefix("pi-") && isComment(line) { severity = severity.lowered.lowered }
                // A phrase in quotes is talked about, not said: a skill that warns about «"ignore previous
                // instructions"» is not an attack. It still counts, a step lower, so quotes are no way around the rule.
                if rule.id.hasPrefix("pi-") && quoted(line, found.lowerBound) { severity = severity.lowered }
                here.append((rule, severity))
                // Words that only come together once the invisible characters are taken out were split on purpose.
                if hidden && rule.id.hasPrefix("pi-") && regex.firstMatch(in: raw, range: ns(raw)) == nil {
                    out.push("pi-hidden-text", .critical, path, number, raw)
                    matched.insert("pi-hidden-text")
                }
            }
            let ids = here.map(\.0.id)
            for (rule, severity) in here {
                if covers.contains(where: { $0.1 == rule.id && ids.contains($0.0) }) { continue }
                out.push(rule.id, severity, path, number, raw)
                matched.insert(rule.id)
                linesOf[rule.id, default: []].append(index)
            }
            if ids.contains("pkg-install") || ids.contains("pkg-remote") {
                for (name, popular) in typosquats(line) {
                    out.push("typosquat", isDoc ? .medium : .high, path, number, "\(name) (did you mean \(popular)?)")
                    matched.insert("typosquat")
                }
            }
        }

        // Reaching for secrets and sending data out, together.
        func of(_ ids: [String]) -> [Int] { ids.flatMap { linesOf[$0] ?? [] } }
        let sends = of(["net-upload", "exfil-endpoint"])
        let calls = of(["net-call"])
        let reads = of(["secret-read", "env-dump"])
        let mentions = of(["sensitive-path"])
        var combo: (Int, SkillSeverity)?
        if isDoc {
            // In a document only when they stand next to each other: an AWS skill may mention both a page apart.
            if let send = sends.first(where: { send in (reads + mentions).contains { abs(send - $0) <= 3 } }) { combo = (send, .high) }
        } else if !reads.isEmpty && (!sends.isEmpty || !calls.isEmpty) {
            if let line = sends.first ?? calls.first { combo = (line, .critical) }
        } else if !mentions.isEmpty, let line = sends.first {
            combo = (line, .critical)
        }
        if let (index, severity) = combo {
            out.push("exfil-combo", severity, path, fixedLine ?? index + 1, all.indices.contains(index) ? all[index] : "")
            matched.insert("exfil-combo")
        }
        return matched
    }

    // MARK: - Whole files

    private static func hiddenCharacters(_ path: String, _ text: String, into out: Collector) {
        // A zero-width space before a code fence is how Markdown shows a fence inside a fence.
        let report = SkillText.report(text.replacingOccurrences(of: "\u{200B}```", with: "```"))
        if report.tags.count > 0 {
            out.push("invisible-tags", .critical, path, report.tags.firstLine, "\(report.tags.count) hidden characters: «\(report.tagText)»")
        }
        if report.bidi.count > 0 {
            out.push("invisible-bidi", .high, path, report.bidi.firstLine, "\(report.bidi.count) text direction controls")
        }
        if report.zeroWidth.count > 0 {
            // A few are usually a copy-paste accident; many are there on purpose.
            out.push("invisible-chars", report.zeroWidth.count >= 10 ? .high : .medium, path, report.zeroWidth.firstLine, "\(report.zeroWidth.count) zero-width characters")
        }
    }

    private static func lineAt(_ text: String, _ index: String.Index) -> Int {
        text[..<index].filter { $0 == "\n" }.count + 1
    }

    private static func hiddenComments(_ path: String, _ text: String, into out: Collector) {
        for match in comment.matches(in: text, range: ns(text)) {
            guard let whole = Range(match.range, in: text), let body = Range(match.range(at: 1), in: text) else { continue }
            let cleaned = SkillText.withoutHidden(String(text[body]))
            if commentOrder.firstMatch(in: cleaned, range: ns(cleaned)) != nil {
                out.push("pi-hidden-comment", .high, path, lineAt(text, whole.lowerBound), text[body].split(whereSeparator: \.isWhitespace).joined(separator: " "))
            }
        }
    }

    /// The `key: value` lines between the first two `---` lines, each with its 1-based line number. Nested keys and
    /// list items are left out: only what the standard puts at the top level.
    static func frontmatter(_ text: String) -> [(key: String, value: String, line: Int)] {
        var values: [(String, String, Int)] = []
        let all = lines(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        guard all.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [] }
        for (index, line) in all.enumerated().dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if let first = line.first, [" ", "\t", "#", "-"].contains(first) { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            values.append((line[..<colon].trimmingCharacters(in: .whitespaces), value, index + 1))
        }
        return values
    }

    private static func frontmatterEnd(_ text: String) -> Int {
        var seen = 0
        for (index, line) in lines(text).enumerated() where line.trimmingCharacters(in: .whitespaces) == "---" {
            seen += 1
            if seen == 2 { return index + 1 }
        }
        return 0
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
            && !name.hasPrefix("-") && !name.hasSuffix("-") && !name.contains("--")
    }

    /// Tools a skill or a slash command approves in advance; the shell with no limits is the one that matters.
    private static func allowedTools(_ path: String, _ meta: [(key: String, value: String, line: Int)], into out: Collector) {
        for entry in meta where entry.key == "allowed-tools" || entry.key == "allowed_tools" {
            let tools = entry.value.split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]\"'")) }
            if tools.contains(where: { ["Bash", "Bash(*)", "Bash(*:*)", "*", "PowerShell", "PowerShell(*)", "Shell"].contains($0) }) {
                out.push("allowed-tools-shell", .medium, path, entry.line, entry.value)
            }
        }
    }

    /// Checks SKILL.md's own rules; returns whether it names a license.
    private static func skillMD(_ path: String, _ text: String, into out: Collector) -> Bool {
        let meta = frontmatter(text)
        func value(_ key: String) -> String? { meta.first { $0.key == key }?.value }
        let name = value("name") ?? ""
        let description = value("description") ?? ""
        // A long description is written on the following lines (`description: >`): then the key is there with no value.
        let hasDescription = meta.contains { $0.key == "description" }
        if name.isEmpty || !hasDescription {
            out.push("frontmatter", .low, path, 1, name.isEmpty ? "name is missing" : "description is missing")
        } else if !isValidName(name) {
            out.push("frontmatter", .info, path, 1, "name «\(name)»: lowercase letters, digits and hyphens, up to 64")
        } else if description.count > 1024 {
            out.push("frontmatter", .info, path, 1, "description is longer than 1024 characters")
        }
        allowedTools(path, meta, into: out)
        // Claude Code lets a skill bring its own hooks in the frontmatter.
        let end = frontmatterEnd(text)
        var inHooks = false
        for (index, line) in lines(text).enumerated().prefix(end) {
            if line.hasPrefix("hooks:") {
                inHooks = true
                continue
            }
            if inHooks, let first = line.first, first != " ", first != "\t" { inHooks = false }
            if inHooks, let range = line.range(of: "command:") {
                let command = line[range.upperBound...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                SkillStructured.hook(path, line: index + 1, event: "frontmatter", command: command, into: out)
            }
        }
        return !(value("license") ?? "").isEmpty
    }

    private static func slashCommand(_ path: String, _ text: String, into out: Collector) {
        allowedTools(path, frontmatter(text), into: out)
        for (index, line) in lines(text).enumerated() {
            for match in inlineCommand.matches(in: line, range: ns(line)) {
                guard let range = Range(match.range(at: 1), in: line) else { continue }
                out.push("command-inline-exec", .medium, path, index + 1, String(line[range]))
                scanText(path, String(line[range]), isDoc: false, fixedLine: index + 1, into: out)
            }
        }
    }

    private static func isMinified(_ text: String) -> Bool {
        let all = lines(text)
        let longest = all.map(\.utf8.count).max() ?? 0
        let size = text.utf8.count
        return longest > 3000 || (size > 4000 && !all.isEmpty && size / all.count > 500)
    }

    // MARK: - A whole skill

    /// Checks a loaded skill or plugin. Nothing is run and nothing outside `files` is read.
    static func scan(_ skill: SkillFiles) -> SkillReport {
        let out = Collector()
        var languages: Set<String> = []
        var hasScripts = false
        var hasSkillMD = false
        var hasLicense = false
        let isPlugin = skill.files.contains { $0.path.hasSuffix(".claude-plugin/plugin.json") || $0.path.hasSuffix("gemini-extension.json") }

        for file in skill.files {
            let path = file.path
            let name = path.split(separator: "/").last.map(String.init) ?? path
            if let target = file.symlink {
                let outside = target.hasPrefix("/") || target.hasPrefix("~") || target.hasPrefix("\\") || target.contains("..") || target.contains(":")
                out.push("symlink", outside ? .high : .medium, path, 0, "→ \(target)")
                continue
            }
            let kind = SkillFileKind.of(file)
            switch kind {
            case .media:
                continue
            case .executable:
                hasScripts = true
                out.push("executable-binary", .high, path, 0, name)
                continue
            case .archive:
                out.push("archive", .medium, path, 0, name)
                continue
            case .unknownBinary:
                out.push("unknown-binary", .low, path, 0, name)
                continue
            case .script(let language):
                hasScripts = true
                languages.insert(language)
                out.push("scripts-present", .low, path, 0, language)
            case .doc, .config, .otherText:
                break
            }
            if file.unread {
                out.push("large-file", .low, path, 0, "\(file.size / 1024) KB")
                continue
            }
            let text = file.text
            let isDoc = kind == .doc
            if case .script = kind, isMinified(text) { out.push("minified", .medium, path, 0, name) }
            hiddenCharacters(path, text, into: out)
            scanText(path, text, isDoc: isDoc, into: out)
            if isDoc { hiddenComments(path, text, into: out) }
            let upper = name.uppercased()
            if upper.hasPrefix("LICENSE") || upper.hasPrefix("LICENCE") || upper == "COPYING" || upper == "NOTICE" { hasLicense = true }
            if name == "SKILL.md" {
                hasSkillMD = true
                if skillMD(path, text, into: out) { hasLicense = true }
            } else if isDoc && (path.hasPrefix("commands/") || path.contains("/commands/")) {
                slashCommand(path, text, into: out)
            }
            if name.hasSuffix(".json") && SkillStructured.scanJSON(path, text, into: out) { hasLicense = true }
        }

        for folder in skill.skipped { out.push("not-walked", .medium, folder, 0, folder) }
        if skill.truncated { out.push("truncated", .medium, "", 0, "the size limits were reached") }
        if !hasSkillMD && !isPlugin { out.push("no-skill-md", .low, "SKILL.md", 0, "SKILL.md is missing") }
        if !hasLicense { out.push("no-license", .info, "", 0, "no LICENSE file and no license in SKILL.md") }

        let findings = out.list.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.file != $1.file { return $0.file < $1.file }
            return $0.line < $1.line
        }
        let (risk, verdict) = score(findings)
        return SkillReport(contentHash: skill.contentHash, riskScore: risk, verdict: verdict, findings: findings, hasScripts: hasScripts,
                           languages: languages.sorted(), fileCount: skill.files.count, totalBytes: skill.totalBytes)
    }

    /// A rule counts once at its worst severity; up to three more findings of the same rule add a fifth each. One
    /// critical finding, or two serious ones, is enough for «dangerous»; anything worth reading makes it «review».
    static func score(_ findings: [SkillFinding]) -> (Int, SkillVerdict) {
        // Each rule counts once at its worst finding; up to three more of its findings add a fifth of their own weight.
        // Rules 3: everything is split by severity — what can't be an attack on its own (medium, low) adds 34 at most,
        // so a long skill full of examples reads «review»; «dangerous» takes a critical finding or two serious ones.
        var serious = 0
        var minor = 0
        func add(_ severity: SkillSeverity, _ weight: Int) {
            if severity >= .high { serious += weight } else { minor += weight }
        }
        for (_, group) in Dictionary(grouping: findings, by: \.rule) {
            let sorted = group.sorted { $0.severity > $1.severity }
            add(sorted[0].severity, sorted[0].severity.weight)
            for extra in sorted.dropFirst().prefix(3) { add(extra.severity, extra.severity.weight / 5) }
        }
        let risk = min(serious + min(minor, 34), 100)
        let critical = findings.contains { $0.severity == .critical }
        let verdict: SkillVerdict = critical || risk >= 70 ? .dangerous : risk >= 5 ? .review : .safe
        return (risk, verdict)
    }

    /// Loads and checks a folder.
    static func scan(folder: URL) throws -> (SkillFiles, SkillReport) {
        let files = try SkillFolder.read(folder)
        return (files, scan(files))
    }
}

// MARK: - Hooks, MCP servers and permissions in JSON (`structured.rs`)

enum SkillStructured {
    private static let network: Set<String> = ["net-call", "net-upload", "exfil-endpoint", "pipe-to-shell", "hardcoded-ip", "exfil-combo"]

    /// The 1-based line where `needle` first stands, or 0.
    private static func lineOf(_ text: String, _ needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return (SkillScanner.lines(text).firstIndex { $0.contains(needle) }).map { $0 + 1 } ?? 0
    }

    /// The first words of a command as they stand in the JSON text.
    private static func needle(_ command: String) -> String {
        String(command.prefix { $0 != "\"" && $0 != "\\" && $0 != "\n" }.prefix(40))
    }

    /// A command that runs by itself on an agent event.
    static func hook(_ path: String, line: Int, event: String, command: String, into out: SkillScanner.Collector) {
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        out.push("hook-command", .medium, path, line, "\(event): \(command)")
        let matched = SkillScanner.scanText(path, command, isDoc: false, fixedLine: line, into: out)
        if !matched.isDisjoint(with: network) { out.push("hook-network", .high, path, line, "\(event): \(command)") }
    }

    private static func command(of entry: [String: Any]) -> String? {
        guard let command = entry["command"] as? String else { return nil }
        let args = (entry["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        return args.isEmpty ? command : command + " " + args.joined(separator: " ")
    }

    private static func hooks(_ path: String, _ text: String, _ hooks: [String: Any], into out: SkillScanner.Collector) {
        for (event, entries) in hooks.sorted(by: { $0.key < $1.key }) {
            for entry in (entries as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
                // Claude Code: `{matcher, hooks: [{type, command}]}`; Codex and Copilot put the command on the entry.
                let inner = (entry["hooks"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [entry]
                for item in inner {
                    for key in ["command", "commandWindows", "bash", "powershell", "prompt", "url"] {
                        let command = key == "command" ? command(of: item) : item[key] as? String
                        if let command { hook(path, line: lineOf(text, needle(command)), event: event, command: command, into: out) }
                    }
                }
            }
        }
    }

    private static func isLocal(_ url: String) -> Bool {
        let host = url.components(separatedBy: "://").dropFirst().first ?? ""
        return host.hasPrefix("localhost") || host.hasPrefix("127.") || host.hasPrefix("[::1]")
    }

    private static func isBareIP(_ url: String) -> Bool {
        let host = (url.components(separatedBy: "://").dropFirst().first ?? "").split(whereSeparator: { $0 == "/" || $0 == ":" }).first.map(String.init) ?? ""
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    private static func mcpServers(_ path: String, _ text: String, _ servers: [String: Any], into out: SkillScanner.Collector) {
        for (name, value) in servers.sorted(by: { $0.key < $1.key }) {
            guard let server = value as? [String: Any] else { continue }
            let line = lineOf(text, "\"\(name)\"")
            if let command = command(of: server) {
                out.push("mcp-server", .medium, path, line, "\(name): \(command)")
                SkillScanner.scanText(path, command, isDoc: false, fixedLine: line, into: out)
                let first = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                var program = first.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
                for suffix in [".exe", ".cmd"] where program.hasSuffix(suffix) { program = String(program.dropLast(suffix.count)) }
                let fetched = ["npx", "bunx", "uvx", "pipx", "pnpx"].contains(program) || command.contains(" dlx ") || command.contains("npm exec") || command.contains("uv tool run")
                // `package@1.2.3` or `package==1.2.3` names one version; `@latest` and a bare name don't.
                let pinned = command.split(whereSeparator: \.isWhitespace).dropFirst().contains { word in
                    let version: Substring?
                    if let range = word.range(of: "==", options: .backwards) {
                        version = word[range.upperBound...]
                    } else if let at = word.lastIndex(of: "@"), at != word.startIndex {
                        version = word[word.index(after: at)...]
                    } else {
                        version = nil
                    }
                    return version?.first?.isNumber == true
                }
                if fetched && !pinned { out.push("mcp-remote-code", .high, path, line, "\(name): \(command)") }
            }
            if let url = (server["url"] ?? server["httpUrl"]) as? String {
                out.push("mcp-server", .medium, path, line, "\(name): \(url)")
                if !isLocal(url) && (url.hasPrefix("http://") || url.hasPrefix("ws://") || isBareIP(url)) {
                    out.push("mcp-insecure-url", .high, path, line, "\(name): \(url)")
                }
                SkillScanner.scanText(path, url, isDoc: false, fixedLine: line, into: out)
            }
        }
    }

    private static func permissions(_ path: String, _ text: String, _ root: [String: Any], into out: SkillScanner.Collector) {
        func wide(_ rule: String) -> Bool {
            ["*", "Bash", "Bash(*)", "Bash(*:*)", "PowerShell", "PowerShell(*)"].contains(rule) || (rule.hasPrefix("Bash(*") && rule.count <= 8)
        }
        let permissions = root["permissions"] as? [String: Any]
        for rule in (permissions?["allow"] as? [Any])?.compactMap({ $0 as? String }) ?? [] where wide(rule) {
            out.push("broad-permissions", .high, path, lineOf(text, "\"allow\""), "allow: \(rule)")
        }
        if permissions?["defaultMode"] as? String == "bypassPermissions" {
            out.push("broad-permissions", .high, path, lineOf(text, "defaultMode"), "defaultMode: bypassPermissions")
        }
        if root["enableAllProjectMcpServers"] as? Bool == true {
            out.push("broad-permissions", .high, path, lineOf(text, "enableAllProjectMcpServers"), "enableAllProjectMcpServers: true")
        }
    }

    /// Returns whether the file names a license (a plugin's manifest does).
    static func scanJSON(_ path: String, _ text: String, into out: SkillScanner.Collector) -> Bool {
        let cleaned = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        guard let root = (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any] else { return false }
        if let found = root["hooks"] as? [String: Any] { hooks(path, text, found, into: out) }
        if let found = root["mcpServers"] as? [String: Any] {
            mcpServers(path, text, found, into: out)
        } else if path == ".mcp.json" || path.hasSuffix("/.mcp.json") {
            // A plugin's `.mcp.json` may list the servers at the top level.
            mcpServers(path, text, root, into: out)
        }
        permissions(path, text, root, into: out)
        let manifest = path.hasSuffix("plugin.json") || path.hasSuffix("gemini-extension.json") || path.hasSuffix("package.json")
        return manifest && !((root["license"] as? String) ?? "").isEmpty
    }
}
