import Foundation

/// What a project is made of, read from its folder on this Mac for «Скиллы для проекта» (docs/specs/SPEC-skills.md §4b):
/// its languages by file count, the tools its files show (Xcode, Docker, GitHub Actions…) and the packages its manifests
/// name. Only names leave the Mac, and only to the person's own model; no file's content is sent, and nothing is run.
struct SkillProjectStack: Equatable, Sendable {
    var languages: [String] = []
    var tools: [String] = []
    var packages: [String] = []

    var isEmpty: Bool { languages.isEmpty && tools.isEmpty && packages.isEmpty }

    /// One short paragraph for the model, at most `limit` characters.
    func summary(limit: Int = 440) -> String {
        var parts: [String] = []
        if !languages.isEmpty { parts.append("Languages: " + languages.joined(separator: ", ") + ".") }
        if !tools.isEmpty { parts.append("Tools: " + tools.joined(separator: ", ") + ".") }
        if !packages.isEmpty { parts.append("Packages: " + packages.joined(separator: ", ") + ".") }
        let text = parts.joined(separator: " ")
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    /// The words the catalog is searched with besides the model's: languages and tools.
    var searchWords: [String] {
        Array((languages + tools).map { $0.components(separatedBy: " (").first ?? $0 }.prefix(8))
    }

    static let maxPackages = 30
    static let maxFileBytes = 512 * 1024
    static let maxEntries = 20_000
    static let skippedFolders: Set<String> = ["node_modules", "Pods", "build", "Build", "DerivedData", "dist", "target", "vendor", "venv",
                                              "__pycache__", "Carthage", "out", "coverage", "SourcePackages"]

    static let languageOf: [String: String] = [
        "swift": "Swift", "m": "Objective-C", "mm": "Objective-C", "kt": "Kotlin", "kts": "Kotlin", "java": "Java", "py": "Python",
        "ts": "TypeScript", "tsx": "TypeScript", "js": "JavaScript", "jsx": "JavaScript", "mjs": "JavaScript", "rs": "Rust", "go": "Go",
        "rb": "Ruby", "php": "PHP", "cs": "C#", "cpp": "C++", "cc": "C++", "c": "C", "h": "C", "dart": "Dart", "scala": "Scala",
        "ex": "Elixir", "exs": "Elixir", "lua": "Lua", "r": "R", "sql": "SQL", "sh": "Shell", "vue": "Vue", "svelte": "Svelte",
        "html": "HTML", "css": "CSS", "scss": "CSS", "md": "Markdown", "tex": "LaTeX", "ipynb": "Jupyter", "tf": "Terraform",
        "scad": "OpenSCAD", "FCStd": "FreeCAD",
    ]

    /// Reads a project folder: languages from up to `maxEntries` files four levels deep, manifests at the top and one
    /// level down (a monorepo's parts). Hidden folders, dependencies and build output are not walked.
    static func read(_ folder: URL) -> SkillProjectStack {
        let manager = FileManager.default
        var counts: [String: Int] = [:]
        var tools: [String] = []
        var packages: [String] = []
        func tool(_ name: String) { if !tools.contains(name) { tools.append(name) } }
        func add(_ names: [String]) {
            for name in names {
                let clean = String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "@/._-".unicodeScalars.contains($0) }).prefix(60)
                guard !clean.isEmpty, !packages.contains(where: { $0.caseInsensitiveCompare(String(clean)) == .orderedSame }) else { continue }
                packages.append(String(clean))
            }
        }

        let base = folder.standardizedFileURL.path
        if let walker = manager.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            var seen = 0
            for case let url as URL in walker {
                seen += 1
                if seen > maxEntries { break }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    walker.skipDescendants()
                    continue
                }
                let depth = url.standardizedFileURL.path.dropFirst(base.count).split(separator: "/").count
                if values?.isDirectory == true {
                    if url.pathExtension == "xcodeproj" { tool("Xcode") }
                    if skippedFolders.contains(url.lastPathComponent) || depth >= 4 { walker.skipDescendants() }
                    if url.lastPathComponent == "fastlane" { tool("fastlane") }
                    if url.lastPathComponent == "supabase" { tool("Supabase") }
                    continue
                }
                if let language = languageOf[url.pathExtension] ?? languageOf[url.pathExtension.lowercased()] { counts[language, default: 0] += 1 }
            }
        }
        // Markdown counts as a language only when the folder is mostly texts.
        let code = counts.filter { !["Markdown", "HTML", "CSS"].contains($0.key) }.values.reduce(0, +)
        if code > 0 && (counts["Markdown"] ?? 0) < code * 3 { counts["Markdown"] = nil }
        let languages = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5).map(\.key)

        var places = [folder]
        if let children = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            places += children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true && !skippedFolders.contains($0.lastPathComponent) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(30)
        }
        if manager.fileExists(atPath: folder.appending(path: ".github/workflows").path) { tool("GitHub Actions") }
        if manager.fileExists(atPath: folder.appending(path: ".gitlab-ci.yml").path) { tool("GitLab CI") }
        for place in places {
            func text(_ name: String) -> String? {
                let url = place.appending(path: name)
                guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileBytes,
                      (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return nil }
                return try? String(contentsOf: url, encoding: .utf8)
            }
            if let json = text("package.json"), let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] {
                tool("Node.js")
                for key in ["dependencies", "devDependencies"] { add(((root[key] as? [String: Any]) ?? [:]).keys.sorted()) }
            }
            if let swift = text("Package.swift") {
                tool("Swift Package Manager")
                add(matches(#"\.package\(\s*(?:name:\s*"[^"]*",\s*)?url:\s*"[^"]*/([^/"]+?)(?:\.git)?""#, swift))
            }
            if text("project.yml") != nil { tool("XcodeGen") }
            if let pods = text("Podfile") { tool("CocoaPods"); add(matches(#"pod\s+['"]([^'"]+)['"]"#, pods)) }
            if let requirements = text("requirements.txt") {
                add(requirements.split(whereSeparator: \.isNewline).compactMap { line in
                    let name = line.split(whereSeparator: { "<>=~;[ !#".contains($0) }).first.map(String.init) ?? ""
                    return line.hasPrefix("#") || line.hasPrefix("-") || name.isEmpty ? nil : name
                })
            }
            if let pyproject = text("pyproject.toml") {
                tool("Python project")
                add(matches(#"(?m)^\s*"([A-Za-z0-9_.\-]+)[^"]*",?\s*$"#, pyproject))
            }
            if let cargo = text("Cargo.toml") { tool("Cargo"); add(tomlKeys(cargo, sections: ["dependencies", "dev-dependencies"])) }
            if let go = text("go.mod") { tool("Go modules"); add(matches(#"(?m)^\s*(?:require\s+)?([a-z0-9.\-]+\.[a-z]+/[^\s]+)\s+v"#, go).map { $0.split(separator: "/").last.map(String.init) ?? $0 }) }
            if let gems = text("Gemfile") { tool("Bundler"); add(matches(#"gem\s+['"]([^'"]+)['"]"#, gems)) }
            if let composer = text("composer.json"), let root = (try? JSONSerialization.jsonObject(with: Data(composer.utf8))) as? [String: Any] {
                tool("Composer")
                add(((root["require"] as? [String: Any]) ?? [:]).keys.sorted().filter { $0 != "php" })
            }
            if let pubspec = text("pubspec.yaml") { tool("Flutter"); add(matches(#"(?m)^  ([a-z0-9_]+):"#, pubspec).filter { $0 != "flutter" && $0 != "sdk" }) }
            for gradle in ["build.gradle", "build.gradle.kts"] {
                if let file = text(gradle) { tool("Gradle"); if file.contains("com.android") { tool("Android") } }
            }
            if text("app.json")?.contains("\"expo\"") == true { tool("Expo") }
            if text("Dockerfile") != nil { tool("Docker") }
            if text("docker-compose.yml") != nil || text("compose.yaml") != nil { tool("Docker Compose") }
            if text("prisma/schema.prisma") != nil { tool("Prisma") }
            if text("vercel.json") != nil { tool("Vercel") }
            if text("firebase.json") != nil { tool("Firebase") }
            if text("Makefile") != nil { tool("Make") }
        }
        if manager.fileExists(atPath: folder.appending(path: "CLAUDE.md").path) || manager.fileExists(atPath: folder.appending(path: "AGENTS.md").path) {
            tool("agent instructions (CLAUDE.md/AGENTS.md)")
        }
        return SkillProjectStack(languages: languages, tools: tools, packages: Array(packages.prefix(maxPackages)))
    }

    private static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    private static func tomlKeys(_ text: String, sections: Set<String>) -> [String] {
        var inside = false
        var keys: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inside = sections.contains(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")))
                continue
            }
            if inside, let key = trimmed.split(separator: "=").first?.trimmingCharacters(in: .whitespaces), !key.isEmpty, !key.hasPrefix("#") {
                keys.append(key)
            }
        }
        return keys
    }
}
