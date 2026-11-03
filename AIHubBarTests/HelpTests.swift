import Foundation
import Testing
@testable import AIHubBar

/// docs/specs/SPEC-help.md: every topic is in the sidebar once, has something to say, and the search finds by its words.
@MainActor
struct HelpTests {
    @Test func everyTopicIsListedOnce() {
        let listed = HelpTopic.groups.flatMap(\.topics)
        #expect(listed.count == HelpTopic.allCases.count)
        #expect(Set(listed) == Set(HelpTopic.allCases))
    }

    @Test func everyTopicHasContent() {
        for topic in HelpTopic.allCases {
            #expect(!topic.title.isEmpty && !topic.summary.isEmpty, "\(topic)")
            #expect(!topic.sections.flatMap(\.facts).isEmpty, "\(topic) has facts")
            #expect(Set(topic.sections.flatMap(\.facts).map(\.id)).count == topic.sections.flatMap(\.facts).count, "\(topic): fact ids are unique")
        }
    }

    @Test func searchFindsByFactWords() {
        #expect(HelpTopic.menuBar.matches("капсул"))
        #expect(HelpTopic.commandLine.matches("--sessions"))
        #expect(!HelpTopic.layout.matches("zzz-nothing"))
        #expect(HelpTopic.allCases.allSatisfy { $0.matches(" ") })
    }

    @Test func exportCarriesEveryTopic() throws {
        let export = HelpExport.make()
        #expect(export.topics.map(\.id) == HelpTopic.groups.flatMap(\.topics).map(\.rawValue))
        #expect(export.labels.keys.sorted() == ["beta", "help", "replay", "scripts", "search", "start"])
        let json = try JSONEncoder().encode(export)
        #expect(json.count > 5000)
    }
}
