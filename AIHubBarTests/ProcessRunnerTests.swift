import Foundation
import Testing
@testable import AIHubBar

/// Every external command goes through `ProcessRunner`: a call must end when its timeout says so.
struct ProcessRunnerTests {
    @Test func aChildLeftBehindDoesNotHoldTheCall() async throws {
        // `sleep` inherits the pipes and keeps them open for a minute; the shell itself exits at once.
        let started = ContinuousClock.now
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "echo done; sleep 60 &"], timeout: .seconds(30))
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "done\n")
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func aProcessThatIgnoresTheTimeoutIsKilled() async {
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 1; done"], timeout: .seconds(1))
        }
        #expect(ContinuousClock.now - started < .seconds(15))
    }

    @Test func outputOnBothPipesComesBackWhole() async throws {
        // More than a pipe holds (64 KB) on each: both must be drained while the process runs.
        let script = "head -c 300000 /dev/zero | tr '\\0' a; head -c 300000 /dev/zero | tr '\\0' b >&2"
        let result = try await ProcessRunner.run("/bin/sh", ["-c", script], timeout: .seconds(20))
        #expect(result.stdout.count == 300_000 && result.stderr.count == 300_000)
    }
}

/// Things that could end or damage what they touch: a broken pipe, a config that is a link.
struct SafeWritesTests {
    @Test func aWriteToAClosedPipeIsAnErrorNotTheEndOfTheApp() {
        // The test host is the app, so its start-up has run. Without SIGPIPE ignored this write ends the process.
        let pipe = Pipe()
        try? pipe.fileHandleForReading.close()
        #expect(throws: (any Error).self) {
            try pipe.fileHandleForWriting.write(contentsOf: Data("x".utf8))
        }
    }

    @Test func aConfigThatIsALinkStaysALink() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "claudepult-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appending(path: "dotfiles-settings.json"), link = dir.appending(path: "settings.json")
        try Data("{}".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try HookJSONFile(url: link, shownAs: "settings.json").write(["theme": "dark"])
        let values = try link.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
        #expect(try String(contentsOf: real, encoding: .utf8).contains("dark"), "the file behind the link got the change")
    }
}
