import Foundation
import Testing
@testable import ClaudePult

/// MCP servers from Claude Code's files, instruction search and saved prompts.
struct ClaudeConfigTests {
    private func object(_ json: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:] }

    @Test func serversFromEveryFile() {
        let claude = object("""
        {"mcpServers":{"github":{"type":"stdio","command":"npx","args":["-y","@x/github"],"env":{"TOKEN":"secret"}}},
         "projects":{"/p/Ambo":{"mcpServers":{"db":{"command":"psql-mcp"}},"enabledMcpjsonServers":["docs"]}}}
        """)
        let settings = object(#"{"mcpServers":{"obsidian":{"type":"http","url":"https://127.0.0.1:27124/mcp?key=abc","headers":{"Authorization":"Bearer t"}}}}"#)
        let mcpFiles = ["/p/Ambo": object(#"{"mcpServers":{"docs":{"command":"docs-mcp"},"sentry":{"url":"https://mcp.sentry.dev/sse","type":"sse"},"old":{"command":"x"}}}"#)]
        let local = ["/p/Ambo": object(#"{"disabledMcpjsonServers":["old"]}"#)]
        let stashed = [MCPStash.Entry(name: "linear", scopeKey: "user", config: #"{"command":"linear-mcp"}"#)]
        let servers = MCPConfig.servers(claudeJSON: claude, settingsJSON: settings, mcpFiles: mcpFiles, localSettings: local, stashed: stashed)
        func server(_ name: String) -> MCPServer? { servers.first { $0.name == name } }

        #expect(server("github")?.scope == .user)
        #expect(server("github")?.target == "npx -y @x/github")
        #expect(server("obsidian")?.target == "https://127.0.0.1:27124/mcp")
        #expect(!servers.contains { $0.target.contains("secret") || $0.target.contains("key=") })
        #expect(server("db")?.scope == .local("/p/Ambo"))
        #expect(server("docs")?.status == .on)
        #expect(server("sentry")?.status == .pending)
        #expect(server("sentry")?.transport == "sse")
        #expect(server("old")?.status == .off)
        #expect(server("linear")?.status == .off)
    }

    @Test func switchingAProjectServer() {
        let off = MCPConfig.settingsLocal(["enabledMcpjsonServers": ["docs"], "model": "x"], disabling: "docs", true)
        #expect(off["disabledMcpjsonServers"] as? [String] == ["docs"])
        #expect(off["enabledMcpjsonServers"] == nil)
        #expect(off["model"] as? String == "x")
        let on = MCPConfig.settingsLocal(off, disabling: "docs", false)
        #expect(on["disabledMcpjsonServers"] == nil)
        #expect(on["enabledMcpjsonServers"] as? [String] == ["docs"])
    }

    @Test func instructionSearch() {
        let text = "# Правила\nКоммить на английском\nPR в main не вливать\n"
        #expect(InstructionFile.matches(text, query: "main").map(\.line) == [3])
        #expect(InstructionFile.matches(text, query: "коммить").first?.text == "Коммить на английском")
        #expect(InstructionFile.matches(text, query: "").isEmpty)
    }

    @Test func instructionFilesOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "md-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/home/.claude", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/Projects/Ambo", withIntermediateDirectories: true)
        try "g".write(toFile: root + "/home/.claude/CLAUDE.md", atomically: true, encoding: .utf8)
        try "a".write(toFile: root + "/Projects/Ambo/AGENTS.md", atomically: true, encoding: .utf8)
        let files = InstructionFile.all(home: root + "/home", projectsDirectory: root + "/Projects", projects: [("Ambo", root + "/Projects/Ambo")])
        #expect(files.map(\.title) == ["~/.claude/CLAUDE.md", "AGENTS.md"])
        #expect(files.last?.group == "Ambo")
    }

    @Test func savedPromptPlaceholders() {
        let prompt = SavedPrompt(title: "Ревью", text: "Проверь {ветка} в {проект}, файл {file}")
        #expect(prompt.needsFile)
        #expect(prompt.filled(project: "Ambo", branch: "feat/x", file: "/a.swift") == "Проверь feat/x в Ambo, файл /a.swift")
        #expect(SavedPrompt(title: "t", text: "{project}").filled(project: "Ambo", branch: nil, file: nil) == "Ambo")
        #expect(!SavedPrompt(title: "t", text: "{project}").needsFile)
    }

    @Test func promptsComeBeforeProjectsInSearch() {
        let results = PanelSearch.results("рев", sessions: [], projects: [.init(id: "/p/Revo", name: "Ревомат", detail: "")],
                                          quickCommands: [], commands: [], prompts: [.init(id: "1", name: "Ревью ветки", detail: "")])
        #expect(results.first == .prompt(id: "1", title: "Ревью ветки"))
        #expect(results.count == 2)
    }
}
