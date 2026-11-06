import Foundation
import Testing
@testable import AIHubBar

struct ClaudeAccountTests {
    @Test func keychainNameFollowsClaudeCode() {
        #expect(ClaudeAccount.keychainService(configDir: "/Users/x/.claude-work") == "Claude Code-credentials-74ed04d5")
    }

    @Test func signInUsesTheAccountsFolder() {
        let account = ClaudeAccount(name: "Work", configDir: "/Users/x/.claude-work")
        #expect(account.signInCommandLine(claude: "/bin/claude")
            == "CLAUDE_CONFIG_DIR=\(ShellQuote.quote("/Users/x/.claude-work")) \(ShellQuote.quote("/bin/claude")) auth login")
    }

    @Test func aTildeIsExpandedBeforeHashing() {
        let tilde = ClaudeAccount(name: "A", configDir: "~/.claude-work")
        #expect(tilde.keychainService == ClaudeAccount.keychainService(configDir: NSHomeDirectory() + "/.claude-work"))
    }
}
