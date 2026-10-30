import Foundation

/// The built-in git scanner (SPEC-modes §3, source «git-репозитории»): what `report.py --json` gives Oleh, for people
/// without `_daily-report`. Every subfolder with a `.git` is a project; the result is the same JSON shape
/// `ProjectsReport` decodes, so the panel shows both the same way.
enum GitScanner {
    static let statusCandidates = ["docs/STATUS.md", "STATUS.md"]

    static func report(projectsDirectory: String, fetch: Bool) async -> ProjectsReport? {
        let root = URL(fileURLWithPath: projectsDirectory)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        let repos = children.filter { FileManager.default.fileExists(atPath: $0.appending(path: ".git").path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: FileManager.default.isExecutableFile(atPath:))

        // Repositories are scanned in parallel; each comes back as JSON, the only Sendable form of `[String: Any]`.
        let scanned = await withTaskGroup(of: (Int, Data?).self) { group in
            for (index, repo) in repos.enumerated() {
                group.addTask { (index, try? JSONSerialization.data(withJSONObject: await project(repo, fetch: fetch, gh: gh))) }
            }
            var result: [(Int, Data?)] = []
            for await item in group { result.append(item) }
            return result.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
        let projects = scanned.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        var json: [String: Any] = ["version": 1, "generated": ISO8601DateFormatter().string(from: .now), "projects": projects]
        if let free { json["disk_free_bytes"] = free }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(ProjectsReport.self, from: data)
    }

    static func git(_ repo: URL, _ arguments: [String], timeout: Duration = .seconds(30)) async -> String {
        guard let result = try? await ProcessRunner.run("/usr/bin/git", ["-C", repo.path] + arguments, timeout: timeout),
              result.exitCode == 0 else { return "" }
        // Only the end: `status --porcelain` lines start with a significant space.
        var text = result.stdoutText
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// One repository as a `report.py` project: branch, changes, stashes, worktrees, PRs with CI, STATUS.md, and
    /// «attention» items whose worst level is the health dot.
    static func project(_ repo: URL, fetch: Bool, gh: String?) async -> [String: Any] {
        var attention: [[String: String]] = []
        func attend(_ level: String, _ text: String) { attention.append(["level": level, "text": text]) }

        if fetch { _ = await git(repo, ["fetch", "--all", "--prune", "--quiet"], timeout: .seconds(60)) }
        var info: [String: Any] = ["name": repo.lastPathComponent, "path": repo.path]
        let branch = await git(repo, ["branch", "--show-current"])
        info["branch"] = branch.isEmpty ? "(detached HEAD)" : branch
        let base = await defaultBranch(repo)
        info["default_branch"] = base
        let remote = await git(repo, ["remote", "get-url", "origin"])
        if !remote.isEmpty { info["remote"] = remote }

        let last = await git(repo, ["log", "--exclude=refs/stash", "--all", "-1", "--format=%cI"])
        if let date = ISODate.parse(last) {
            info["last_activity"] = last
            let days = Int(Date.now.timeIntervalSince(date) / 86_400)
            if days >= 7 { attend("low", "нет коммитов \(days) дн.") }
        }

        let changes = lines(await git(repo, ["status", "--porcelain=v1"]))
        info["dirty"] = changes.count
        let work = changes.filter { line in
            let path = String(line.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return !statusCandidates.contains(path) && path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != "docs"
        }
        if !work.isEmpty {
            attend("high", "\(work.count) \(Plural.files(work.count)) не закоммичено (ветка \(info["branch"] ?? ""))")
        } else if !changes.isEmpty {
            attend("low", "изменения в STATUS.md не закоммичены")
        }

        let stashes = lines(await git(repo, ["stash", "list"])).count
        info["stashes"] = stashes
        if stashes > 0 { attend("high", "\(stashes) stash — отложенная работа, легко забыть") }

        for line in lines(await git(repo, ["for-each-ref", "refs/heads", "--format=%(refname:short)\t%(upstream:short)\t%(upstream:track)"])) {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 3, !parts[2].contains("gone") else { continue }
            if parts[1].isEmpty {
                // Pushed under the same name without tracking: only what is not pushed yet counts.
                let same = "origin/" + parts[0]
                if !(await git(repo, ["rev-parse", "--verify", "--quiet", same])).isEmpty {
                    let ahead = Int(await git(repo, ["rev-list", "--count", "\(same)..\(parts[0])"])) ?? 0
                    if ahead > 0 { attend("mid", "ветка \(parts[0]): \(ahead) не запушено") }
                    continue
                }
                let ahead = Int(await git(repo, ["rev-list", "--count", "\(base)..\(parts[0])"])) ?? 0
                if ahead > 0 { attend("high", "ветка \(parts[0]): \(ahead) коммит(ов) только на этом Маке") }
            } else if let range = parts[2].range(of: #"ahead (\d+)"#, options: .regularExpression),
                      let count = Int(parts[2][range].dropFirst("ahead ".count)) {
                attend("mid", "ветка \(parts[0]): \(count) не запушено")
            }
        }

        let (trees, treeNotes) = await worktrees(repo)
        info["worktrees"] = trees
        attention += treeNotes

        if let gh, !remote.isEmpty, let (prs, prNotes) = await pullRequests(repo, gh: gh) {
            info["open_prs"] = prs
            attention += prNotes
        }

        if let status = status(repo) {
            info["status"] = status.json
            for item in status.needs { attend("mid", "нужно от вас: " + item) }
            if !status.hasSummary { attend("low", "в STATUS.md нет шапки (Stage / Now / Next)") }
        }

        info["attention"] = attention
        let levels = Set(attention.compactMap { $0["level"] })
        info["health"] = levels.contains("high") ? "red" : levels.contains("mid") ? "yellow" : "green"
        return info
    }

    static func defaultBranch(_ repo: URL) async -> String {
        let head = await git(repo, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        if !head.isEmpty { return head }
        for candidate in ["origin/main", "origin/master", "main", "master"] {
            if !(await git(repo, ["rev-parse", "--verify", "--quiet", candidate])).isEmpty { return candidate }
        }
        return "HEAD"
    }

    static func worktrees(_ repo: URL) async -> ([[String: Any]], [[String: String]]) {
        var result: [[String: Any]] = []
        var notes: [[String: String]] = []
        var prunable = 0
        for block in (await git(repo, ["worktree", "list", "--porcelain"])).components(separatedBy: "\n\n") {
            var path: String?
            var branch: String?
            var stale = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("branch ") { branch = String(line.dropFirst("branch ".count)).replacingOccurrences(of: "refs/heads/", with: "") }
                if line.hasPrefix("prunable") { stale = true }
            }
            guard let path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path != repo.resolvingSymlinksInPath().path else { continue }
            guard !stale, FileManager.default.fileExists(atPath: path) else {
                prunable += 1
                continue
            }
            let dirty = lines(await git(URL(fileURLWithPath: path), ["status", "--porcelain=v1"])).count
            if dirty > 0 { notes.append(["level": "high", "text": "worktree \((path as NSString).lastPathComponent): \(dirty) незакоммиченных файлов"]) }
            result.append(["path": path, "branch": branch ?? "(detached)", "dirty": dirty])
        }
        if prunable > 0 { notes.append(["level": "low", "text": "\(prunable) устаревших worktree — `git worktree prune`"]) }
        return (result, notes)
    }

    static func pullRequests(_ repo: URL, gh: String) async -> ([[String: Any]], [[String: String]])? {
        guard let result = try? await ProcessRunner.run(
            gh, ["pr", "list", "--state", "open", "--limit", "20", "--json", "number,title,isDraft,url,statusCheckRollup"],
            currentDirectory: repo, timeout: .seconds(40)
        ), result.exitCode == 0,
            let prs = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [[String: Any]] else { return nil }
        var notes: [[String: String]] = []
        let list = prs.map { pr in
            var pr = pr
            let ci = ciState(pr["statusCheckRollup"] as? [[String: Any]] ?? [])
            pr["ci"] = ci
            pr["statusCheckRollup"] = nil
            let number = pr["number"] as? Int ?? 0
            if ci == "fail" {
                notes.append(["level": "high", "text": "PR #\(number): CI упал"])
            } else if pr["isDraft"] as? Bool != true {
                notes.append(["level": "mid", "text": "PR #\(number) ждёт merge: \(String((pr["title"] as? String ?? "").prefix(70)))"])
            }
            return pr
        }
        return (list, notes)
    }

    static func ciState(_ rollup: [[String: Any]]) -> String {
        guard !rollup.isEmpty else { return "none" }
        let states = rollup.map { (($0["conclusion"] as? String) ?? ($0["state"] as? String) ?? ($0["status"] as? String) ?? "").uppercased() }
        if states.contains(where: ["FAILURE", "CANCELLED", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED", "ERROR"].contains) { return "fail" }
        if states.contains(where: ["", "PENDING", "QUEUED", "IN_PROGRESS", "EXPECTED", "WAITING"].contains) { return "pending" }
        return "ok"
    }

    struct Status {
        var json: [String: Any]
        var needs: [String]
        var hasSummary: Bool
    }

    static func status(_ repo: URL) -> Status? {
        for candidate in statusCandidates {
            guard let text = try? String(contentsOf: repo.appending(path: candidate), encoding: .utf8) else { continue }
            var json: [String: Any] = ["path": candidate]
            let summary = StatusText.summary(text)
            if let summary { json["summary"] = summary }
            if let entry = StatusText.latestEntry(text) { json["latest_entry"] = entry }
            return Status(json: json, needs: summary?["needs"] as? [String] ?? [], hasSummary: summary != nil)
        }
        return nil
    }
}

/// The STATUS.md format of `~/Projects/CLAUDE.md`: a summary between `<!-- summary:start -->` and `<!-- summary:end -->`
/// with `**Stage:**`, `**Updated:**`, `**Now:**`, `**Next:**`, `**Needs …:**` and `- ` lists, and `## YYYY-MM-DD — title`
/// journal entries.
enum StatusText {
    static let labels: [String: String] = [
        "stage": "stage", "этап": "stage", "updated": "updated", "обновлено": "updated",
        "now": "now", "сейчас": "now", "в работе": "now", "next": "next", "дальше": "next", "план": "next",
        "blocked": "needs", "blockers": "needs", "блокеры": "needs",
    ]

    static func label(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces).lowercased()
        // «Needs Oleh», «Needs me», «Нужно от …»: whoever the person is.
        if name.hasPrefix("needs") || name.hasPrefix("нужно от") { return "needs" }
        return labels[name]
    }

    static func summary(_ text: String) -> [String: Any]? {
        guard let start = text.range(of: "<!-- summary:start -->"),
              let end = text.range(of: "<!-- summary:end -->", range: start.upperBound..<text.endIndex) else { return nil }
        var result: [String: Any] = ["stage": "", "updated": "", "now": [String](), "next": [String](), "needs": [String]()]
        var current: String?
        for raw in text[start.upperBound..<end.lowerBound].components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("**"), let close = line.range(of: ":**") {
                let key = label(String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound]))
                current = key
                let value = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
                if key == "stage" || key == "updated" {
                    if let key { result[key] = value }
                } else if let key, !value.isEmpty, value != "—", value != "-" {
                    result[key] = (result[key] as? [String] ?? []) + [value]
                }
                continue
            }
            if let current, ["now", "next", "needs"].contains(current), line.hasPrefix("- ") || line.hasPrefix("* ") {
                var item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                for box in ["[ ] ", "[x] ", "[X] "] where item.hasPrefix(box) { item = String(item.dropFirst(4)) }
                if !item.isEmpty, item != "—", item != "-" { result[current] = (result[current] as? [String] ?? []) + [item] }
            }
        }
        return result
    }

    /// The newest dated `## ` heading.
    static func latestEntry(_ text: String) -> [String: String]? {
        var best: (date: String, title: String)?
        for line in text.components(separatedBy: "\n") where line.hasPrefix("## ") {
            let heading = String(line.dropFirst(3))
            guard let range = heading.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { continue }
            let date = String(heading[range])
            let title = (String(heading[..<range.lowerBound]) + String(heading[range.upperBound...]))
                .trimmingCharacters(in: CharacterSet(charactersIn: " —-·|:\t"))
            if best == nil || date > best!.date { best = (date, title.isEmpty ? "(без названия)" : title) }
        }
        return best.map { ["date": $0.date, "title": $0.title] }
    }
}

enum Plural {
    /// «1 файл», «2 файла», «5 файлов».
    static func files(_ n: Int) -> String {
        let tens = n % 100, ones = n % 10
        if (11...14).contains(tens) { return "файлов" }
        switch ones {
        case 1: return "файл"
        case 2...4: return "файла"
        default: return "файлов"
        }
    }
}
