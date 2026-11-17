import XCTest
@testable import AIHubBar

/// The demo copy's sample data (`DemoData`): it must stay whole as the app's types change, and up to date with the
/// release it is recorded for.
@MainActor
final class DemoTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)

    /// A release with news raises `WhatsNew.version`. This fails until the demo shows that release's news too
    /// (docs/RELEASE.md → «Demo»).
    func testTheDemoIsUpToDateWithTheRelease() {
        XCTAssertEqual(DemoData.version, WhatsNew.version,
                       "Add what the new version shows to DemoData (docs/RELEASE.md → Demo), then raise DemoData.version")
    }

    func testTheHostAppIsNotADemo() {
        XCTAssertFalse(DemoMode.isActive)
        XCTAssertFalse(DemoMode.isMisconfigured)
    }

    func testTheStandardSceneFillsEveryBlock() throws {
        let data = DemoData.make(scene: .standard, now: now)
        XCTAssertEqual(data.snapshot?.session?.utilization, 62)
        XCTAssertEqual(data.snapshot?.week?.utilization, 48)
        XCTAssertEqual(UsageForecast.make(history: data.history, current: data.snapshot?.session, now: now), .lastsUntilReset)
        XCTAssertEqual(try XCTUnwrap(UsageForecast.pace(history: data.history, current: data.snapshot?.session, now: now)), 12, accuracy: 0.01)
        let week = try XCTUnwrap(data.week)
        XCTAssertEqual(week.days.reduce(0) { $0 + $1.percent }, 48, accuracy: 0.01)
        XCTAssertFalse(try XCTUnwrap(data.breakdowns[.week]).projects.isEmpty)
        XCTAssertGreaterThan(data.days.count, 20)
        XCTAssertEqual(data.hubLimits.map(\.source), [.codex, .copilot, .antigravity])
        XCTAssertEqual(data.sessions.map(\.state), [.waiting, .running, .running, .done])
        XCTAssertEqual(data.sessions.map(\.session.agent), [.claudeCode, .claudeCode, .codex, .claudeCode])
        XCTAssertEqual(data.approvals.keys.sorted(), ["demo-session-1"])
        XCTAssertEqual(data.runs.map(\.state), [.running, .succeeded])
        XCTAssertEqual(data.report?.projects.map(\.name), DemoData.projects)
        XCTAssertEqual(data.report?.projects.map(\.health), [.yellow, .green, .red, .green])
        XCTAssertEqual(ClaudeIdentity.parse(try XCTUnwrap(data.claudeIdentity)), ClaudeIdentity(name: "Alex", plan: "Max 5x"))
    }

    /// 0.11: without Claude the first other service with limits leads.
    func testWithoutClaudeCodexIsTheMainService() {
        let data = DemoData.make(scene: .codexMain, now: now)
        XCTAssertNil(data.snapshot)
        XCTAssertNil(data.claudeIdentity)
        let others = data.hubLimits.map { ServiceUsage.hub($0, history: LimitHistory(), now: now) }
        let main = MainService.pick(choice: MainService.auto, claude: nil, others: others)
        XCTAssertEqual(main?.hubSource, .codex)
        XCTAssertEqual(main?.firstLimit?.percent, 57)
        XCTAssertEqual(data.sessions.first?.session.agent, .codex)
    }

    func testTheDataIsTheSameOnEveryStart() {
        XCTAssertEqual(DemoData.records(now: now, calendar: .current), DemoData.records(now: now, calendar: .current))
    }

    func testAnAnswerInTheDemoLetsTheSessionGoOn() {
        let data = DemoData.make(scene: .standard, now: now)
        let directory = FileManager.default.temporaryDirectory.appending(path: "demo-tests-\(UUID().uuidString)")
        let store = SessionStore(directory: directory, approvalsDirectory: directory)
        store.showDemo(items: data.sessions, approvals: data.approvals)
        store.decide(requestID: "demo-approval-1", allow: true)
        XCTAssertTrue(store.approvals.isEmpty)
        XCTAssertEqual(store.items.first?.state, .running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
