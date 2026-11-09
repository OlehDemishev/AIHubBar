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
