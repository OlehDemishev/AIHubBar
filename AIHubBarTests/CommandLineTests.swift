import Foundation
import Testing
@testable import AIHubBar

@MainActor
struct CommandLineTests {
    @Test func everyUsageLineStartsWithItsFlag() {
        for command in CommandLineTool.commands {
            #expect(command.flags.contains { command.usage.hasPrefix($0) }, "\(command.usage)")
        }
    }

    @Test func flagsBelongToOneCommand() {
        let flags = CommandLineTool.commands.flatMap(\.flags)
        #expect(Set(flags).count == flags.count)
    }

    @Test func helpAndNoCommand() {
        #expect(CommandLineTool.run(["AIHubBar", "--help"]) == 0)
        // Nothing for the command line: the app starts.
        #expect(CommandLineTool.run(["AIHubBar"]) == nil)
        #expect(CommandLineTool.run(["AIHubBar", "-AppleLanguages", "(en)"]) == nil)
    }

    @Test func aFlagWithoutItsValueStartsTheApp() {
        #expect(CommandLineTool.run(["AIHubBar", "--app-command"]) == nil)
        #expect(CommandLineTool.run(["AIHubBar", "--show-session"]) == nil)
    }

    @Test func unknownValuesAreUsageErrors() {
        #expect(CommandLineTool.run(["AIHubBar", "--app-command", "no-such-command"]) == 2)
        #expect(CommandLineTool.run(["AIHubBar", "--command", "no-such-command"]) == 2)
    }

    @Test func appCommandNamesDontOverlap() {
        let windows = Set(AppRequests.windows.keys)
        let actions = Set(AppRequests.actions)
        let commands = Set(CommonCommand.allCases.map(\.cliName))
        #expect(windows.isDisjoint(with: actions))
        #expect(windows.isDisjoint(with: commands))
        #expect(actions.isDisjoint(with: commands))
    }
}

@MainActor
struct AppRequestsTests {
    @Test func aWindowRequestIsTakenOnce() {
        let requests = AppRequests()
        #expect(requests.takeWindow() == nil)
        requests.openWindow(.settings)
        #expect(requests.takeWindow() == .settings)
        #expect(requests.takeWindow() == nil)
        // The same window again is a new request.
        requests.openWindow(.settings)
        #expect(requests.takeWindow() == .settings)
    }

    @Test func theLatestRequestWins() {
        let requests = AppRequests()
        requests.openWindow(.help)
        requests.openWindow(.assistant)
        #expect(requests.takeWindow() == .assistant)
        #expect(requests.takeWindow() == nil)
    }
}

struct UpdatesTests {
    @Test func betaReadsTheBetaFeedAndChannel() {
        #expect(Updates.feedURL(beta: false) == nil)
        #expect(Updates.channels(beta: false).isEmpty)
        #expect(Updates.feedURL(beta: true) == Updates.betaFeedURL)
        #expect(Updates.channels(beta: true) == ["beta"])
    }
}
