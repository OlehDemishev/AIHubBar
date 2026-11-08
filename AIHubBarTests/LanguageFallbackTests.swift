import Testing
@testable import AIHubBar

struct LanguageFallbackTests {
    let available = ["en", "uk", "de", "pt-BR", "ja"]

    @Test func aTranslatedLanguageStays() {
        #expect(!LanguageFallback.needsEnglish(preferred: ["de-DE"], available: available))
        #expect(!LanguageFallback.needsEnglish(preferred: ["pt-PT"], available: available))
        #expect(!LanguageFallback.needsEnglish(preferred: ["ru-DE"], available: available), "the source language has no .lproj")
    }

    @Test func aLaterChoiceCounts() {
        #expect(!LanguageFallback.needsEnglish(preferred: ["nl-NL", "de-NL"], available: available))
    }

    @Test func anythingElseGetsEnglish() {
        #expect(LanguageFallback.needsEnglish(preferred: ["nl-NL"], available: available))
        #expect(LanguageFallback.needsEnglish(preferred: ["zh-Hans-CN", "tr"], available: available))
    }
}

struct InterfaceLanguageTests {
    let available = ["en", "uk", "de", "pt-BR", "ja"]

    @Test func aChosenLanguageWins() {
        #expect(InterfaceLanguage.afterRelaunch(choice: "en", system: ["ru-DE", "de-DE"], available: available) == "en")
        #expect(InterfaceLanguage.afterRelaunch(choice: "ru", system: ["de-DE"], available: available) == "ru")
    }

    @Test func asInTheSystemFollowsItsList() {
        #expect(InterfaceLanguage.afterRelaunch(choice: "", system: ["ru-DE", "en-DE"], available: available) == "ru", "the source language has no .lproj")
        #expect(InterfaceLanguage.afterRelaunch(choice: "", system: ["nl-NL", "de-NL"], available: available) == "de")
        #expect(InterfaceLanguage.afterRelaunch(choice: "", system: ["ru-DE"], available: available + ["ru"]) == "ru")
    }

    @Test func asInTheSystemWithNoTranslationIsEnglish() {
        #expect(InterfaceLanguage.afterRelaunch(choice: "", system: ["nl-NL"], available: available) == "en")
    }
}
