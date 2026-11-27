import Foundation
import Testing
@testable import AIHubBar

/// Finding sources (`SkillSourceFinder`): what an awesome list, a plugin marketplace and GitHub's search are read as,
/// with the network replaced by a table. The samples follow the real formats seen on 2026-11-27.
struct SkillSourceFinderTests {
    static let list = SkillCatalog.GitHubRepo(owner: "someone", repo: "awesome-skills")

    @Test func anAwesomeListGivesItsRepositoriesWithTheirWords() {
        let markdown = """
            <a href="https://github.com/VoltAgent/voltagent"><img src="https://github.com/user-attachments/assets/x" /></a>
            [![Badge](https://img.shields.io/badge/x)](https://github.com/VoltAgent/official-mcp-servers)
            # Skills
            See [the spec](https://github.com/agentskills/agentskills) for the format.
            - [docx](https://github.com/anthropics/skills/tree/main/skills/docx) - Create, edit, analyze Word docs.
            - [pdf](https://github.com/anthropics/skills/tree/main/skills/pdf) - Extract text, tables.
            - **[obra/superpowers](https://github.com/obra/superpowers)** - A **core** skills library
            | [markstream-angular](https://github.com/Simon-He95/markstream-vue/tree/main/.agents/skills/markstream-angular) | Streaming Markdown in Angular |
            | Autohand Code | [github.com/autohandai/code-cli](https://github.com/autohandai/code-cli) |
            - [Sponsor](https://github.com/sponsors/someone) - thanks
            - [This list](https://github.com/someone/awesome-skills) - itself
            * [ignore me](https://example.com/github.com/evil/repo) - another host
            """
        let found = SkillSourceFinder.fromMarkdown(markdown, list: Self.list)
        #expect(found.map(\.repo.slug) == ["anthropics/skills", "obra/superpowers", "Simon-He95/markstream-vue", "autohandai/code-cli"])
        let anthropic = found[0]
        #expect(anthropic.title == "docx")
        #expect(anthropic.summary == "Create, edit, analyze Word docs.")
        #expect(anthropic.paths == ["skills/docx", "skills/pdf"])
        #expect(anthropic.lists == ["someone/awesome-skills"])
        #expect(anthropic.official)
        #expect(found[1].title == nil, "a title that is only the repository's name is not repeated")
        #expect(found[1].summary == "A core skills library")
        #expect(found[2].summary == "Streaming Markdown in Angular")
        #expect(found[2].paths == [".agents/skills/markstream-angular"])
    }

    @Test func whatAListSaysIsShownAsPlainShortText() {
        let long = String(repeating: "word ", count: 100)
        let markdown = """
            - [x](https://github.com/a/one) - \(long)
            - [y](https://github.com/a/two) - hidden\u{200B}\u{202E}text <script>alert(1)</script> [link](javascript:alert(1))
            """
        let found = SkillSourceFinder.fromMarkdown(markdown, list: Self.list)
        #expect(found[0].summary!.count <= SkillSourceFinder.maxSummary)
        #expect(found[1].summary == "hiddentext alert(1) link)")
    }

    @Test func aMarketplaceGivesThePluginsRepositories() throws {
        let marketplace = SkillCatalog.GitHubRepo(owner: "anthropics", repo: "claude-plugins-official")
        let json: [String: Any] = ["name": "m", "owner": ["name": "o"], "plugins": [
            ["name": "inside", "description": "Kept here", "source": "./plugins/inside"],
            ["name": "adlc", "description": "From a URL", "source": ["source": "url", "url": "https://github.com/SalesforceAIResearch/agentforce-adlc.git", "sha": "09bf"]],
            ["name": "sub", "source": ["source": "git-subdir", "url": "owner-x/tools", "path": "plugins/sub"]],
            ["name": "gh", "source": ["source": "github", "repo": "someone/plugin"]],
            ["name": "elsewhere", "source": ["source": "url", "url": "https://gitlab.com/a/b.git"]],
            ["name": "cmd", "source": ["source": "command", "command": "rm -rf /"]],
        ]]
        let found = SkillSourceFinder.fromMarketplace(try JSONSerialization.data(withJSONObject: json), list: marketplace)
        #expect(found.map(\.repo.slug) == ["anthropics/claude-plugins-official", "SalesforceAIResearch/agentforce-adlc", "owner-x/tools", "someone/plugin"])
        #expect(found[0].paths == ["plugins/inside"])
        #expect(found[1].summary == "From a URL")
        #expect(found[2].paths == ["plugins/sub"])
        #expect(SkillSourceFinder.fromMarketplace(Data("not json".utf8), list: marketplace).isEmpty)
    }

    @Test func theSearchSkipsForksArchivedAndPrivate() throws {
        let json: [String: Any] = ["items": [
            ["full_name": "a/kept", "description": "Skills", "stargazers_count": 1200],
            ["full_name": "a/fork", "fork": true], ["full_name": "a/old", "archived": true], ["full_name": "a/closed", "private": true],
            ["full_name": "../bad"],
        ]]
        let found = SkillSourceFinder.fromSearch(try JSONSerialization.data(withJSONObject: json))
        #expect(found.map(\.repo.slug) == ["a/kept"])
        #expect(found[0].stars == 1200)
    }

    @Test func listsTogetherPutTheMostNamedFirst() {
        func candidate(_ slug: String, _ list: String) -> SkillSourceFinder.Candidate {
            .init(repo: SkillCatalog.GitHubRepo.parse(slug)!, lists: [list])
        }
        let merged = SkillSourceFinder.merge([
            [candidate("x/one", "l1"), candidate("y/two", "l1"), candidate("anthropics/skills", "l1")],
            [candidate("Y/Two", "l2"), candidate("z/three", "l2")],
        ])
        #expect(merged.map(\.repo.slug) == ["y/two", "anthropics/skills", "x/one", "z/three"])
        #expect(merged[0].lists == ["l1", "l2"])
    }

    @Test func listsAreReadFromRawFilesAndSearchAsksGitHubOnce() async throws {
        final class Asked: @unchecked Sendable { var urls: [String] = [] }
        let asked = Asked()
        let fetch: SkillGitHub.Fetch = { url in
            asked.urls.append(url.absoluteString)
            if url.host == "raw.githubusercontent.com" { return (Data("- [s](https://github.com/o/r) - a skill".utf8), 200) }
            return (try JSONSerialization.data(withJSONObject: ["items": [["full_name": "o/r", "stargazers_count": 5]]]), 200)
        }
        let list = SkillSourceFinder.lists[0]
        let found = try await SkillGitHub.candidates(of: list, fetch: fetch)
        #expect(found.map(\.repo.slug) == ["o/r"])
        #expect(asked.urls == ["https://raw.githubusercontent.com/\(list.repo.slug)/HEAD/README.md"])
        let searched = try await SkillGitHub.search(topic: "agent-skills", words: "pdf &q=evil\n", fetch: fetch)
        #expect(searched.first?.stars == 5)
        let url = try #require(URLComponents(string: asked.urls[1]))
        #expect(url.host == "api.github.com" && url.path == "/search/repositories")
        #expect(url.queryItems?.first { $0.name == "q" }?.value == "pdf &q=evil topic:agent-skills fork:false archived:false")
        #expect(url.queryItems?.filter { $0.name == "q" }.count == 1)

        let limited: SkillGitHub.Fetch = { _ in (Data(), 403) }
        await #expect(throws: SkillGitHub.Failure(reason: "rate-limit")) { try await SkillGitHub.search(topic: "agent-skills", fetch: limited) }
        await #expect(throws: SkillGitHub.Failure(reason: "not-found")) { try await SkillGitHub.candidates(of: list, fetch: { _ in (Data(), 404) }) }
    }
}
