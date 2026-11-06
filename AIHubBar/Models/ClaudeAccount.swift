import CryptoKit
import Foundation

/// A second Claude account: Claude Code keeps each one in its own config folder (`CLAUDE_CONFIG_DIR`), with its sign-in
/// in its own Keychain entry. The main account needs no entry here.
struct ClaudeAccount: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name: String
    /// As typed or chosen; `~` allowed.
    var configDir: String

    var expandedDir: String { PathText.expand(configDir) }
    var keychainService: String { Self.keychainService(configDir: expandedDir) }

    /// Claude Code's own naming: the first 8 hex digits of the SHA-256 of the folder (read from its code, 2.1.316).
    static func keychainService(configDir: String) -> String {
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return UsageService.keychainService + "-" + hex.prefix(8)
    }

    /// `claude auth login` for this account, for Terminal.
    func signInCommandLine(claude: String) -> String {
        "CLAUDE_CONFIG_DIR=\(ShellQuote.quote(expandedDir)) \(ShellQuote.quote(claude)) auth login"
    }
}
