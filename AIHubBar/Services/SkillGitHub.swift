import Foundation
import os

/// Reading a GitHub repository for the Skills Catalog: its default branch, stars and license, the commit at the tip,
/// the tree at that commit, and the files of each skill folder — downloaded into the app's own cache, never run.
/// Public repositories only. Without a token the REST API allows 60 requests an hour, and a check costs three
/// (`/repos`, `/commits`, `/git/trees`); the files come from raw.githubusercontent.com, which is not counted. With the
/// person's own token (Settings → Скиллы → «Вход в GitHub», kept in the Keychain) it allows 5,000; the token goes to
/// api.github.com only, never to another host or along a redirect.
/// Documented at docs.github.com/rest (repos, commits, git trees).
enum SkillGitHub {
    /// Gets a URL's bytes; the app uses URLSession, the tests a table.
    typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    static let api = "https://api.github.com"
    static let raw = "https://raw.githubusercontent.com"

    struct Failure: Error, Equatable, CustomStringConvertible {
        var reason: String
        var description: String { reason }
    }

    /// Hosts the app reads from. A redirect anywhere else is not followed.
    static let hosts: Set<String> = ["api.github.com", "raw.githubusercontent.com", "github.com", "codeload.github.com", "objects.githubusercontent.com"]

    final class StayOnGitHub: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            SkillGitHub.redirect(request)
        }
    }

    /// Where a redirect may go: an https GitHub host, and the token only to the API.
    static func redirect(_ request: URLRequest) -> URLRequest? {
        guard request.url?.scheme == "https", let host = request.url?.host?.lowercased(), hosts.contains(host) else { return nil }
        var request = request
        if host != "api.github.com" { request.setValue(nil, forHTTPHeaderField: "Authorization") }
        return request
    }

    /// The person's GitHub token, when they signed in; set by `SkillStore`.
    static let token = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The request for a URL: the token rides along only to api.github.com over https.
    static func request(_ url: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        if let token, url.scheme == "https", url.host?.lowercased() == "api.github.com" {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "AIHubBar",
        ]
        return URLSession(configuration: configuration, delegate: StayOnGitHub(), delegateQueue: nil)
    }()

    static let fetch: Fetch = { url in
        let (data, response) = try await session.data(for: request(url, token: token.withLock { $0 }))
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// What GitHub allows a token an hour (`/rate_limit`, not counted itself): the limit, or a failure — `bad-token`
    /// when GitHub doesn't know it.
    static func limit(token: String) async throws -> Int {
        let (data, response) = try await session.data(for: request(URL(string: "\(api)/rate_limit")!, token: token))
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401: throw Failure(reason: "bad-token")
        case 403, 429: throw Failure(reason: "rate-limit")
        case let status: throw Failure(reason: "HTTP \(status)")
        }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let core = ((root?["resources"] as? [String: Any])?["core"] as? [String: Any])?["limit"] as? NSNumber
        return core?.intValue ?? 0
    }

    struct Repository: Equatable, Sendable {
        var branch: String
        var stars: Int?
        var license: String?
        var sha: String
        var tree: [SkillCatalog.TreeEntry]
        var treeTruncated: Bool
    }

    private static func json(_ url: URL, _ fetch: Fetch) async throws -> [String: Any] {
        let (data, status) = try await fetch(url)
        switch status {
        case 200: break
        case 404: throw Failure(reason: "not-found")
        case 403, 429: throw Failure(reason: "rate-limit")
        default: throw Failure(reason: "HTTP \(status)")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure(reason: "unreadable") }
        return object
    }

    /// The repository at the tip of its default branch.
    static func repository(_ repo: SkillCatalog.GitHubRepo, fetch: Fetch = SkillGitHub.fetch) async throws -> Repository {
        guard let info = URL(string: "\(api)/repos/\(repo.owner)/\(repo.repo)") else { throw Failure(reason: "not-found") }
        let meta = try await json(info, fetch)
        if meta["private"] as? Bool == true { throw Failure(reason: "not-found") }
        let branch = (meta["default_branch"] as? String) ?? "main"
        let license = ((meta["license"] as? [String: Any])?["spdx_id"] as? String).flatMap { $0 == "NOASSERTION" ? nil : $0 }
        let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? branch
        guard let commitURL = URL(string: "\(api)/repos/\(repo.owner)/\(repo.repo)/commits/\(encodedBranch)") else { throw Failure(reason: "not-found") }
        let commit = try await json(commitURL, fetch)
        guard let sha = commit["sha"] as? String, sha.count == 40, sha.allSatisfy(\.isHexDigit) else { throw Failure(reason: "unreadable") }
        guard let treeURL = URL(string: "\(api)/repos/\(repo.owner)/\(repo.repo)/git/trees/\(sha)?recursive=1") else { throw Failure(reason: "not-found") }
        let tree = try await json(treeURL, fetch)
        let entries = ((tree["tree"] as? [[String: Any]]) ?? []).compactMap { item -> SkillCatalog.TreeEntry? in
            guard let path = item["path"] as? String, let type = item["type"] as? String else { return nil }
            return SkillCatalog.TreeEntry(path: path, type: type, mode: (item["mode"] as? String) ?? "", size: (item["size"] as? NSNumber)?.intValue ?? 0)
        }
        return Repository(branch: branch, stars: (meta["stargazers_count"] as? NSNumber)?.intValue, license: license, sha: sha, tree: entries,
                          treeTruncated: tree["truncated"] as? Bool ?? false)
    }

    /// A path inside the cache folder, or nil for anything that would leave it.
    static func inside(_ base: URL, _ relative: String) -> URL? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return parts.reduce(base) { $0.appending(path: String($1)) }
    }

    /// Downloads one skill's files at a commit into `cache/<owner>/<repo>/<sha>/files/<folder>`. A folder already there
    /// from an earlier check of the same commit is used as it is: a marker in `<sha>/done/` (outside the skill, so it is
    /// neither checked nor copied) says it was downloaded whole.
    static func download(_ skill: SkillCatalog.RemoteSkill, of repo: SkillCatalog.GitHubRepo, sha: String, into cache: URL,
                         fetch: Fetch = SkillGitHub.fetch) async throws -> URL {
        let commitFolder = cache.appending(path: repo.owner).appending(path: repo.repo).appending(path: sha)
        let files = commitFolder.appending(path: "files")
        let folder: URL
        if skill.folder.isEmpty {
            // Beside `files`, not in it: no folder of the repository can share its place.
            folder = commitFolder.appending(path: "root")
        } else {
            guard let inner = inside(files, skill.folder) else { throw Failure(reason: "path") }
            folder = inner
        }
        // Every character but letters and digits is percent-encoded, so `-` names the root skill and nothing else.
        let marker = skill.folder.isEmpty ? "-" : skill.folder.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "skill"
        let done = commitFolder.appending(path: "done").appending(path: marker)
        if FileManager.default.fileExists(atPath: done.path) { return folder }
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in skill.files {
            guard let target = inside(folder, file.path) else { throw Failure(reason: "path") }
            let repoPath = skill.folder.isEmpty ? file.path : skill.folder + "/" + file.path
            let encoded = repoPath.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0) }.joined(separator: "/")
            guard let url = URL(string: "\(raw)/\(repo.owner)/\(repo.repo)/\(sha)/\(encoded)") else { throw Failure(reason: "path") }
            let (data, status) = try await fetch(url)
            guard status == 200 else { throw Failure(reason: status == 404 ? "not-found" : "HTTP \(status)") }
            guard data.count <= Int(SkillLimits().maxFileBytes) else { throw Failure(reason: "too-large") }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: file.mode == "100755" ? 0o755 : 0o644], ofItemAtPath: target.path)
        }
        try FileManager.default.createDirectory(at: done.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: done)
        return folder
    }
}
