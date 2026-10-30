import Foundation

/// The language of what ClaudePult writes and sends, not only shows: prompts for AI services, new `проект.md` /
/// `project.md` cards, content plans, template texts. It follows the interface language; Russian is the default.
enum ContentLanguage: String, CaseIterable, Sendable {
    case ru, en

    static var current: ContentLanguage {
        Bundle.main.preferredLocalizations.first.flatMap { code in allCases.first { code.hasPrefix($0.rawValue) } } ?? .ru
    }
}
