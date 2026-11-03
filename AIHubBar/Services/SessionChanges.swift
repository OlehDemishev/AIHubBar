import AppKit
import Observation

/// What a session changed in its folder (git): files and lines since it started, committed or not, plus new files.
struct SessionChanges: Equatable, Sendable {
    struct File: Equatable, Identifiable, Sendable {
        var path: String
        /// nil for binary files.
        var added: Int?
        var removed: Int?
        var isNew = false
        var id: String { path }
    }

    var files: [File]

    var added: Int { files.compactMap(\.added).reduce(0, +) }
    var removed: Int { files.compactMap(\.removed).reduce(0, +) }
    var isEmpty: Bool { files.isEmpty }

    /// `git diff --numstat <base>` («12\t3\tpath», «-\t-\tbinary») and `git ls-files --others --exclude-standard`.
    static func parse(numstat: String, untracked: String) -> SessionChanges {
        var files = numstat.split(separator: "\n").compactMap { line -> File? in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            return File(path: parts[2], added: Int(parts[0]), removed: Int(parts[1]))
        }
        let known = Set(files.map(\.path))
        files += untracked.split(separator: "\n").map(String.init).filter { !known.contains($0) }
            .map { File(path: $0, added: nil, removed: nil, isNew: true) }
        return SessionChanges(files: files)
    }

    /// «3 файла +120 −8».
    var summary: String {
        var text = String(localized: "файлов: \(files.count)")
        if added > 0 { text += " +\(added)" }
        if removed > 0 { text += " −\(removed)" }
        return text
    }

    /// Git's empty tree: the base when the repository has no commit from before the session.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
}

/// Reads the changes of the sessions shown in the panel, at most every 30 seconds per folder.
@MainActor
@Observable
final class SessionChangesStore {
    private(set) var changes: [String: SessionChanges] = [:]
    private var checked: [String: Date] = [:]

    func refresh(folder: String, since start: Date?) async {
        let key = Self.key(folder, start)
        if let last = checked[key], Date.now.timeIntervalSince(last) < 30 { return }
        checked[key] = .now
        changes[key] = await Self.read(folder: folder, since: start)
    }

    func changes(folder: String, since start: Date?) -> SessionChanges? { changes[Self.key(folder, start)] }

    private static func key(_ folder: String, _ start: Date?) -> String { "\(folder)|\(start?.timeIntervalSince1970 ?? 0)" }

    nonisolated static func read(folder: String, since start: Date?) async -> SessionChanges? {
        guard (try? await GitService.run(["rev-parse", "--is-inside-work-tree"], in: folder, timeout: .seconds(10))) != nil else { return nil }
        var base = "HEAD"
        if let start {
            let before = try? await GitService.run(["rev-list", "-1", "--before=\(start.ISO8601Format())", "HEAD"], in: folder, timeout: .seconds(10))
            base = before?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? SessionChanges.emptyTree
        }
        guard let numstat = try? await GitService.run(["diff", "--numstat", base], in: folder, timeout: .seconds(20)) else { return nil }
        let untracked = (try? await GitService.run(["ls-files", "--others", "--exclude-standard"], in: folder, timeout: .seconds(20))) ?? ""
        return SessionChanges.parse(numstat: numstat, untracked: untracked)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
