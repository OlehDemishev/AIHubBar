import Foundation
import Testing
@testable import ClaudePult

struct FormattingTests {
    @Test(arguments: [
        (0.0, "только что"),
        (59, "только что"),
        (60, "1 мин назад"),
        (59 * 60, "59 мин назад"),
        (3600, "1 ч назад"),
        (23 * 3600 + 3599, "23 ч назад"),
        (86_400, "1 дн назад"),
        (10 * 86_400, "10 дн назад"),
        (-30, "только что"),
    ] as [(TimeInterval, String)])
    func relativeTime(secondsAgo: TimeInterval, expected: String) {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(RelativeTime.ago(now.addingTimeInterval(-secondsAgo), now: now) == expected)
    }

    @Test(arguments: [
        ("https://github.com/owner/repo.git", "https://github.com/owner/repo"),
        ("https://github.com/owner/repo", "https://github.com/owner/repo"),
        ("https://github.com/owner/repo/", "https://github.com/owner/repo"),
        ("git@github.com:owner/repo.git", "https://github.com/owner/repo"),
        ("ssh://git@github.com/owner/repo.git", "https://github.com/owner/repo"),
        ("ssh://git@github.com:22/owner/repo.git", "https://github.com/owner/repo"),
        ("https://user:secret@github.com/owner/repo.git", "https://github.com/owner/repo"),
        ("  https://gitlab.example.com/group/sub/repo.git\n", "https://gitlab.example.com/group/sub/repo"),
    ] as [(String, String)])
    func remoteToWebURL(remote: String, expected: String) {
        #expect(GitRemote.webURL(remote)?.absoluteString == expected)
    }

    @Test(arguments: [nil, "", "/Users/me/repos/local.git", "file:///tmp/repo.git", "https://github.com"] as [String?])
    func remoteWithoutWebURL(remote: String?) {
        #expect(GitRemote.webURL(remote) == nil)
    }

    @Test func pathPrependsHomebrewOnce() throws {
        let env = ProcessRunner.environment(base: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"])
        let path = try #require(env["PATH"]).split(separator: ":").map(String.init)
        #expect(path.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        #expect(path.contains("/usr/local/bin"))
        #expect(path.last == "/bin")
        #expect(env["PYTHONIOENCODING"] == "utf-8")
    }
}
