import Foundation
import Testing
@testable import AIHubBar

/// Small rules that came out of the 2026-11-09 review, each of which once went wrong without a word.
@MainActor
struct AuditTests {
    private func queued(_ id: String, path: String, at date: Date) -> LaunchController.QueuedLaunch {
        .init(id: id, command: .nextStep, target: .init(path: path, name: path, nextItems: [], baseRef: "main"), launchAt: date)
    }

    @Test func twoQueuedRunsForOneProjectStartOneAfterAnother() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let queue = [
            queued("a1", path: "/p/Ambo", at: now.addingTimeInterval(-60)),
            queued("a2", path: "/p/Ambo", at: now.addingTimeInterval(-30)),
            queued("b1", path: "/p/Site", at: now.addingTimeInterval(-10)),
            queued("c1", path: "/p/Later", at: now.addingTimeInterval(600)),
        ]
        // The second run for Ambo stays in the queue (it used to be removed and never started).
        #expect(LaunchController.dueNow(queue, busy: [], now: now).map(\.id) == ["a1", "b1"])
        // A project that is being started right now waits a tick too.
        #expect(LaunchController.dueNow(queue, busy: ["/p/Ambo"], now: now).map(\.id) == ["b1"])
        // Once the first is out of the queue, the second is due.
        #expect(LaunchController.dueNow(Array(queue.dropFirst()), busy: [], now: now).map(\.id) == ["a2", "b1"])
    }

    @Test func aShortcutNeedsOneCommandForPartOfAName() {
        let commands = [
            QuickCommand(id: "1", title: "Clean builds", kind: .script, value: "a"),
            QuickCommand(id: "2", title: "Clean caches", kind: .script, value: "b"),
            QuickCommand(id: "3", title: "Deploy", kind: .script, value: "c"),
        ]
        #expect(RunQuickCommandIntent.command(named: "clean builds", in: commands)?.id == "1", "the whole name, any case")
        #expect(RunQuickCommandIntent.command(named: "clean", in: commands) == nil, "two commands: neither is picked")
        #expect(RunQuickCommandIntent.command(named: "depl", in: commands)?.id == "3")
        #expect(RunQuickCommandIntent.command(named: "nothing", in: commands) == nil)
    }

    @Test func theImportNoteListsMissingFoldersWithCommas() {
        let a = "~/no-such-\(UUID().uuidString)", b = "~/no-such-\(UUID().uuidString)"
        let bundle = SettingsBundle(
            format: SettingsBundle.modeFormat, version: 3, exportedAt: .now, general: nil, appearance: nil, services: nil,
            modes: [Profile(name: "Видео", source: .gitReport(projects: a, dailyReport: b))], enabled: nil
        )
        let text = ImportConfirmation.summary(bundle)
        #expect(text.contains("\(a), \(b)"))
        #expect(!text.contains("String(localized"), "a piece of code used to be printed between the folders")
    }

    @Test func arabicIsLaidOutRightToLeft() {
        #expect(RightToLeftLayout.isNeeded(language: "ar"))
        #expect(!RightToLeftLayout.isNeeded(language: "ru") && !RightToLeftLayout.isNeeded(language: "ja"))
        let name = "claudepult-rtl-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let before = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(before, forName: UserDefaults.argumentDomain) }
        RightToLeftLayout.apply(defaults: defaults, language: "ar")
        #expect(defaults.bool(forKey: "NSForceRightToLeftWritingDirection") && defaults.bool(forKey: "AppleTextDirection"))
    }

    @Test func aGoodReportIsGoodInEveryLanguage() {
        // The scripts answer in Russian whatever the interface language is.
        #expect(!CommonCommand.reportNow.isFailure(exitCode: 0, summary: "Telegram: отправлено"))
        #expect(CommonCommand.reportNow.isFailure(exitCode: 0, summary: "Telegram: ошибка 401"))
        #expect(CommonCommand.cleanupRun.isFailure(exitCode: 0, summary: "Идёт сборка, пропускаю"))
    }

    /// The panel keeps the AI blocks in sight and folds the rest under «Ещё», unless there is nothing to gain.
    @Test func panelFoldsWhatIsNotAboutAI() {
        let all: [ModuleKind] = [.projects, .limits, .resources, .sessions, .keepAwake]
        #expect(PanelFold.split(all).main == [.projects, .limits, .sessions], "projects stay in sight, in the profile's order")
        #expect(PanelFold.split(all).more == [.resources, .keepAwake])
        #expect(PanelFold.split([.limits, .resources]).more.isEmpty, "one block is not worth a row")
        #expect(PanelFold.split([.notes, .resources]).main == [.notes, .resources], "nothing to keep in sight")
    }

    /// The header's account and plan come from Claude Code's own file; the e-mail is never taken.
    @Test func claudeIdentityFromConfig() throws {
        let json = #"{"oauthAccount":{"displayName":"Ann","emailAddress":"a@example.com","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_5x"}}"#
        let identity = try #require(ClaudeIdentity.parse(Data(json.utf8)))
        #expect(identity == ClaudeIdentity(name: "Ann", plan: "Max 5x"))
        #expect(ClaudeIdentity.plan(type: "claude_max", tier: "default_claude_max_20x") == "Max 20x")
        #expect(ClaudeIdentity.plan(type: "claude_pro", tier: "default_claude_ai") == "Pro")
        #expect(ClaudeIdentity.plan(type: "something_new", tier: nil) == nil)
        #expect(ClaudeIdentity.parse(Data("{}".utf8)) == nil)
    }
}
