import CryptoKit
import Foundation

/// One file as it was when a version was taken.
struct VersionFile: Codable, Equatable, Sendable {
    /// Relative to the project's folder.
    var path: String
    /// SHA-256 of the content; the content itself is `objects/<hash>`.
    var hash: String
    var size: Int
    var modified: Date
}

/// Why a version was taken.
enum VersionReason: Codable, Equatable, Sendable {
    /// The files changed since the last version (every 10 minutes while the Mac is on).
    case automatic
    /// Before an AI run; the command's title («Редактура»).
    case beforeRun(String)
    /// Before a version was put back, so the current state is never lost.
    case beforeRestore
}

/// The texts of a folder project at one moment (docs/specs/SPEC-content.md §4).
struct ProjectVersion: Codable, Equatable, Identifiable, Sendable {
    /// The file's name without `.json`: the time it was taken, sortable as text.
    var id: String
    var takenAt: Date
    var reason: VersionReason
    var files: [VersionFile]
    /// Text files left out for their size, by relative path.
    var skipped: [String] = []

    /// Paths whose content differs from `other` (added, changed or gone), sorted.
    func changed(from other: ProjectVersion?) -> [String] {
        let before = Dictionary(other?.files.map { ($0.path, $0.hash) } ?? [], uniquingKeysWith: { first, _ in first })
        let now = Dictionary(files.map { ($0.path, $0.hash) }, uniquingKeysWith: { first, _ in first })
        return Set(before.keys).union(now.keys).filter { before[$0] != now[$0] }.sorted()
    }

    /// The version's files that are different now (changed or gone), against the hashes of the files as they are.
    func differing(from current: [String: String]) -> [String] {
        files.filter { current[$0.path] != $0.hash }.map(\.path)
    }

    /// The files that appeared after the version; putting it back leaves them.
    func added(in current: [String: String]) -> [String] {
        let known = Set(files.map(\.path))
        return current.keys.filter { !known.contains($0) }.sorted()
    }
}

/// «Версии»: the draft versions of folder projects, kept outside the project's folder and without git
/// (SPEC-content §4, Oleh's decisions §9). `<root>/<project>/objects/<sha256>` holds each file content once,
/// `<root>/<project>/<time>.json` is one version: path → hash, size, date, and why it was taken. Pure file work, off
/// the main actor.
struct VersionStore: Sendable {
    var root: URL

    static var live: VersionStore { VersionStore(root: SessionFiles.supportDirectory.appending(path: "versions", directoryHint: .isDirectory)) }

    /// Files larger than this are skipped and named in the version (the default of «Модули → Версии»).
    static let defaultSizeLimit = 20 * 1024 * 1024
    /// Every version of the last day is kept, then one a day.
    static let keepAllFor: TimeInterval = 24 * 3600
    static let defaultKeepDays = 30

    // MARK: Where things are

    /// The project's folder in the store: its name for a person looking there, and a piece of the path's hash so
    /// two projects of the same name in different places don't mix.
    func folder(projectPath: String) -> URL {
        let path = (projectPath as NSString).standardizingPath
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let name = (path as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "-")
        return root.appending(path: "\(name)-\(digest)", directoryHint: .isDirectory)
    }

    private func objects(_ projectPath: String) -> URL { folder(projectPath: projectPath).appending(path: "objects", directoryHint: .isDirectory) }

    /// `20261120-153012-482`, UTC: sorts as text, and two versions a moment apart still differ.
    static func name(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    // MARK: Reading

    /// The project's versions, newest first.
    func versions(projectPath: String) -> [ProjectVersion] {
        let folder = folder(projectPath: projectPath)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(ProjectVersion.self, from: $0) } }
            .sorted { $0.id > $1.id }
    }

    /// A file's content as it was in a version.
    func content(projectPath: String, hash: String) -> Data? {
        guard Self.isHash(hash) else { return nil }
        return try? Data(contentsOf: objects(projectPath).appending(path: hash))
    }

    private static func isHash(_ text: String) -> Bool { text.count == 64 && text.allSatisfy(\.isHexDigit) }

    // MARK: Taking a version

    /// The project's text files and its card as they are now; nothing is written.
    static func scan(folder: URL, sizeLimit: Int = defaultSizeLimit) -> (files: [(file: VersionFile, data: Data)], skipped: [String]) {
        var files: [(VersionFile, Data)] = []
        var skipped: [String] = []
        for entry in FolderScanner.files(in: folder) where FolderScanner.textExtensions.contains(entry.url.pathExtension.lowercased()) {
            let path = FolderScanner.relativePath(entry.url, in: folder)
            let size = (try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= sizeLimit else { skipped.append(path); continue }
            guard let data = try? Data(contentsOf: entry.url) else { continue }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            files.append((VersionFile(path: path, hash: hash, size: data.count, modified: entry.modified), data))
        }
        return (files.sorted { $0.0.path < $1.0.path }, skipped.sorted())
    }

    /// Takes a version of the project's texts; nil when nothing differs from the last one, or there is no text at all.
    @discardableResult
    func take(projectPath: String, reason: VersionReason, now: Date = .now, sizeLimit: Int = defaultSizeLimit) throws -> ProjectVersion? {
        let scanned = Self.scan(folder: URL(fileURLWithPath: projectPath), sizeLimit: sizeLimit)
        let last = versions(projectPath: projectPath).first
        let version = ProjectVersion(id: Self.name(now), takenAt: now, reason: reason, files: scanned.files.map(\.file), skipped: scanned.skipped)
        guard !version.files.isEmpty || last?.files.isEmpty == false else { return nil }
        guard !version.changed(from: last).isEmpty || (last == nil && !version.files.isEmpty) else { return nil }

        let fm = FileManager.default
        let objects = objects(projectPath)
        try fm.createDirectory(at: objects, withIntermediateDirectories: true)
        for (file, data) in scanned.files {
            let url = objects.appending(path: file.hash)
            if !fm.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        }
        // Where the project is, so a person (and the clean-up of a deleted project) can tell whose versions these are.
        let origin = folder(projectPath: projectPath).appending(path: "project.txt")
        if !fm.fileExists(atPath: origin.path) { try? Data(projectPath.utf8).write(to: origin) }
        // The objects first: a version file never names content that is not there.
        try Self.encoder.encode(version).write(to: folder(projectPath: projectPath).appending(path: version.id + ".json"), options: .atomic)
        return version
    }

    // MARK: Putting a version back

    enum RestoreError: LocalizedError, Equatable {
        /// The version names a content the store no longer has.
        case missingContent(String)
        /// The file as it is now is over the size limit, so it can't be saved first.
        case currentTooLarge(String)

        var errorDescription: String? {
            switch self {
            case let .missingContent(path): String(localized: "Содержимое файла «\(path)» в этой версии не найдено.")
            case let .currentTooLarge(path): String(localized: "Файл «\(path)» сейчас больше лимита версий: сохранить его перед возвратом нельзя, поэтому он не тронут.")
            }
        }
    }

    /// A path from a version file stays inside the project's folder.
    static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    /// Puts the version's files (all, or only `paths`) back in place. The current state is saved as a version first,
    /// so nothing is lost; files added since the version stay. Returns the paths that were written.
    @discardableResult
    func restore(projectPath: String, version: ProjectVersion, paths: Set<String>? = nil, now: Date = .now,
                 sizeLimit: Int = defaultSizeLimit) throws -> [String] {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: projectPath)
        var writes: [(url: URL, path: String, data: Data)] = []
        // Everything is checked before anything is written.
        for file in version.files where paths?.contains(file.path) ?? true {
            guard Self.isSafe(file.path), let data = content(projectPath: projectPath, hash: file.hash) else {
                throw RestoreError.missingContent(file.path)
            }
            let url = base.appending(path: file.path)
            if let current = try? Data(contentsOf: url) {
                if current == data { continue }
                if current.count > sizeLimit { throw RestoreError.currentTooLarge(file.path) }
            }
            writes.append((url, file.path, data))
        }
        guard !writes.isEmpty else { return [] }
        try take(projectPath: projectPath, reason: .beforeRestore, now: now, sizeLimit: sizeLimit)
        for write in writes {
            try fm.createDirectory(at: write.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write.data.write(to: write.url, options: .atomic)
        }
        return writes.map(\.path)
    }

    /// The newest version taken no later than `date`: what the project was before a run that started then.
    func version(projectPath: String, before date: Date) -> ProjectVersion? {
        versions(projectPath: projectPath).first { $0.takenAt <= date.addingTimeInterval(1) }
    }

    // MARK: Keeping and removing

    /// Which versions stay: all of the last 24 hours, then the last one of each day for `keepDays` days.
    static func kept(_ versions: [ProjectVersion], now: Date = .now, keepDays: Int = defaultKeepDays, calendar: Calendar = .current) -> Set<String> {
        var kept = Set<String>()
        var days = Set<DateComponents>()
        for version in versions.sorted(by: { $0.id > $1.id }) {
            let age = now.timeIntervalSince(version.takenAt)
            if age <= keepAllFor {
                kept.insert(version.id)
            } else if age <= TimeInterval(keepDays) * 86_400 {
                // Newest first, so the first one seen of a day is that day's last.
                if days.insert(calendar.dateComponents([.year, .month, .day], from: version.takenAt)).inserted { kept.insert(version.id) }
            }
        }
        return kept
    }

    /// Removes the versions past their time and the contents no version names any more; returns how many versions went.
    @discardableResult
    func prune(projectPath: String, now: Date = .now, keepDays: Int = Self.defaultKeepDays, calendar: Calendar = .current) -> Int {
        let all = versions(projectPath: projectPath)
        let kept = Self.kept(all, now: now, keepDays: keepDays, calendar: calendar)
        let folder = folder(projectPath: projectPath)
        let fm = FileManager.default
        for version in all where !kept.contains(version.id) {
            try? fm.removeItem(at: folder.appending(path: version.id + ".json"))
        }
        let used = Set(all.filter { kept.contains($0.id) }.flatMap { $0.files.map(\.hash) })
        for object in (try? fm.contentsOfDirectory(at: objects(projectPath), includingPropertiesForKeys: nil)) ?? []
        where !used.contains(object.lastPathComponent) {
            try? fm.removeItem(at: object)
        }
        return all.count - kept.count
    }

    /// The stores of projects whose folder is gone, once their newest version is older than `after` days.
    @discardableResult
    func removeOrphans(now: Date = .now, after days: Int = Self.defaultKeepDays) -> [String] {
        let fm = FileManager.default
        var removed: [String] = []
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard let origin = try? String(contentsOf: folder.appending(path: "project.txt"), encoding: .utf8),
                  !fm.fileExists(atPath: origin) else { continue }
            let newest = versions(projectPath: origin).first?.takenAt ?? .distantPast
            guard now.timeIntervalSince(newest) > TimeInterval(days) * 86_400 else { continue }
            if (try? fm.removeItem(at: folder)) != nil { removed.append(origin) }
        }
        return removed
    }

    /// Bytes on disk, for «Модули → Версии».
    func size() -> Int {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in enumerator { total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }

    /// «Очистить»: every version of every project, or of one.
    func clear(projectPath: String? = nil) {
        try? FileManager.default.removeItem(at: projectPath.map(folder(projectPath:)) ?? root)
    }
}
