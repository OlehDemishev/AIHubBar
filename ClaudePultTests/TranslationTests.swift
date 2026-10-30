import Foundation
import Testing
@testable import ClaudePult

/// Machine translations checked against what ClaudePult actually does in each language (the built `.lproj` tables).
struct TranslationTests {
    private func table(_ language: ContentLanguage) -> [String: String] {
        guard language != .ru,
              let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language.rawValue),
              let table = NSDictionary(contentsOfFile: path) as? [String: String] else { return [:] }
        return table
    }

    private func text(_ key: String, _ language: ContentLanguage) -> String { table(language)[key] ?? key }

    /// The help and settings name the files ClaudePult writes in that language.
    @Test(arguments: ContentLanguage.allCases)
    func fileNamesMatchWhatIsWritten(_ language: ContentLanguage) {
        let strings = language.strings
        #expect(text("проект.md", language) == strings.cardFile)
        #expect(text("+ контент-план (контент-план.md)", language).contains(strings.planFile))
        #expect(text("Перевести на этап «%@» (пишется в проект.md)", language).contains(strings.cardFile))
        #expect(text("Дедлайны и публикации из проект.md", language).contains(strings.cardFile))
    }

    /// No Russian left inside other languages (a module name pasted as is, say); Ukrainian has no ы, э, ъ, ё.
    @Test(arguments: ContentLanguage.allCases.filter { $0 != .ru })
    func noRussianLeft(_ language: ContentLanguage) {
        let table = table(language)
        #expect(table.count > 500)
        let pattern = language == .uk ? "[ыэъёЫЭЪЁ]" : "[А-Яа-яЁё]"
        let leaks = table.filter { $0.value.range(of: pattern, options: .regularExpression) != nil }
        #expect(leaks.isEmpty, "\(leaks.values.prefix(3))")
    }
}
