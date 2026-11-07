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
