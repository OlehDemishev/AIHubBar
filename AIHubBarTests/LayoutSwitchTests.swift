import AppKit
import Testing
@testable import AIHubBar

/// «Раскладка» (SPEC-layout): which word is retyped and how, with small layouts and word lists instead of the
/// system's.
struct LayoutSwitchTests {
    private static let codes: [UInt16] = [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39, 6, 7, 8, 9, 11, 45, 46, 43, 47, 44, 18]

    private static func layout(_ id: String, _ language: String, _ characters: String) -> KeyLayout {
        var keys: [KeyStroke: String] = [:]
        for (code, character) in zip(codes, characters) {
            keys[KeyStroke(keyCode: code)] = String(character)
            keys[KeyStroke(keyCode: code, shift: true)] = String(character).uppercased()
        }
        return KeyLayout(id: id, language: language, name: id, keys: keys)
    }

    private let en = layout("abc", "en", "qwertyuiop[asdfghjkl;'zxcvbnm,./1")
    private let ru = layout("ru", "ru", "йцукенгшщзхфывапролджэячсмитьбю.1")
    /// German swaps Y and Z.
    private let de = layout("de", "de", "qwertzuiop[asdfghjkl;'yxcvbnm,./1")

    private let words: [String: Set<String>] = [
        "en": ["hello", "yes", "don't", "the"],
        "ru": ["привет", "лоб", "технология", "мир", "да"],
        "de": ["mir", "hallo"],
    ]

    private func isWord(_ word: String, _ language: String) -> Bool { words[language]?.contains(word.lowercased()) ?? false }

    private func strokes(_ text: String, in layout: KeyLayout) -> [KeyStroke] { text.compactMap(layout.stroke(for:)) }

    private func fix(_ text: String, in layout: KeyLayout, others: [KeyLayout]? = nil, learned: Set<String> = []) -> String? {
        LayoutWords.correction(for: strokes(text, in: layout), in: layout, others: others ?? [en, ru], learned: learned, isWord: isWord)?.text
    }

    @Test func wrongLayoutWordIsRetyped() {
        let correction = LayoutWords.correction(for: strokes("ghbdtn", in: en), in: en, others: [en, ru], learned: [], isWord: isWord)
        #expect(correction == LayoutCorrection(layoutID: "ru", typed: "ghbdtn", text: "привет"))
        #expect(fix("руддщ", in: ru) == "hello")
        #expect(fix("Ghbdtn", in: en) == "Привет")
    }

    @Test func realWordsStay() {
        #expect(fix("hello", in: en) == nil)
        #expect(fix("привет", in: ru) == nil)
        #expect(fix("hello,", in: en) == nil)
    }

    /// The comma after a word stays a comma; the comma key inside or at the end of a Russian word is «б».
    @Test func endsAreReadBothWays() {
        #expect(fix("ghbdtn,", in: en) == "привет,")
        #expect(fix("kj,", in: en) == "лоб")
        #expect(fix("руддщб", in: ru) == "hello,")
        #expect(fix("nt[yjkjubz", in: en) == "технология")
        #expect(fix("вщтэе", in: ru) == "don't")
    }

    @Test func shortCodedAndLearnedWordsStay() {
        #expect(fix("z", in: en) == nil)
        #expect(fix("ghbdtn1", in: en) == nil)
        #expect(fix("qwzx", in: en) == nil)
        #expect(fix("ghbdtn", in: en, learned: ["ghbdtn"]) == nil)
        #expect(fix("lf", in: en) == "да")
    }

    @Test func latinLayoutsDifferOnlyWhereKeysDo() {
        #expect(fix("zes", in: de, others: [en, de]) == "yes")
        // The same letters in both layouts: nothing to retype.
        #expect(fix("mir", in: en, others: [en, de]) == nil)
    }

    @Test func doubleShiftGoesWhereTheWordReads() {
        let layouts = [en, ru, de]
        #expect(LayoutWords.manualTarget(for: strokes("ghbdtn", in: en), in: en, among: layouts, isWord: isWord)?.id == "ru")
        #expect(LayoutWords.manualTarget(for: strokes("zes", in: de), in: de, among: layouts, isWord: isWord)?.id == "abc")
        // Not a word anywhere: the next layout in the list.
        #expect(LayoutWords.manualTarget(for: strokes("qwzx", in: en), in: ru, among: layouts, isWord: isWord)?.id == "de")
    }

    @Test func selectionIsConverted() {
        let result = LayoutWords.convert("ghbdtn vbh!", among: [en, ru], current: "abc", isWord: isWord)
        #expect(result?.text == "привет мир!")
        #expect(result?.layoutID == "ru")
        #expect(LayoutWords.convert("руддщ", among: [en, ru], current: "abc", isWord: isWord)?.text == "hello")
        #expect(LayoutWords.convert("123", among: [en, ru], current: "abc", isWord: isWord) == nil)
    }

    @Test func learnedWordsAreKeptOnce() {
        let list = LayoutWords.learning("Ghbdtn", into: ["vbh", "ghbdtn"])
        #expect(list == ["ghbdtn", "vbh"])
        #expect(LayoutWords.learning("a", into: ["b", "c"], limit: 2) == ["a", "b"])
    }

    @Test func doubleShift() {
        var gestures = ModifierGestures()
        #expect(gestures.flags(shift: true, option: false, other: false, at: 0) == nil)
        #expect(gestures.flags(shift: false, option: false, other: false, at: 0.1) == nil)
        #expect(gestures.flags(shift: true, option: false, other: false, at: 0.3) == nil)
        #expect(gestures.flags(shift: false, option: false, other: false, at: 0.4) == .doubleShift)
        // A third tap starts over.
        #expect(gestures.flags(shift: true, option: false, other: false, at: 0.5) == nil)
        #expect(gestures.flags(shift: false, option: false, other: false, at: 0.6) == nil)
    }

    @Test func shiftForCapitalsIsNotAGesture() {
        var gestures = ModifierGestures()
        _ = gestures.flags(shift: true, option: false, other: false, at: 0)
        _ = gestures.flags(shift: false, option: false, other: false, at: 0.1)
        _ = gestures.flags(shift: true, option: false, other: false, at: 0.2)
        gestures.reset() // a letter typed with Shift
        #expect(gestures.flags(shift: false, option: false, other: false, at: 0.3) == nil)

        var slow = ModifierGestures()
        _ = slow.flags(shift: true, option: false, other: false, at: 0)
        _ = slow.flags(shift: false, option: false, other: false, at: 0.1)
        _ = slow.flags(shift: true, option: false, other: false, at: 1)
        #expect(slow.flags(shift: false, option: false, other: false, at: 1.1) == nil)

        var held = ModifierGestures()
        _ = held.flags(shift: true, option: false, other: false, at: 0)
        _ = held.flags(shift: false, option: false, other: false, at: 0.1)
        _ = held.flags(shift: true, option: false, other: false, at: 0.2)
        #expect(held.flags(shift: false, option: false, other: false, at: 1) == nil)
    }

    @Test func optionShift() {
        var gestures = ModifierGestures()
        _ = gestures.flags(shift: false, option: true, other: false, at: 0)
        _ = gestures.flags(shift: true, option: true, other: false, at: 0.1)
        _ = gestures.flags(shift: false, option: true, other: false, at: 0.2)
        #expect(gestures.flags(shift: false, option: false, other: false, at: 0.25) == .optionShift)

        // ⌥⇧ with a key in between types a character instead.
        _ = gestures.flags(shift: false, option: true, other: false, at: 1)
        _ = gestures.flags(shift: true, option: true, other: false, at: 1.1)
        gestures.reset()
        _ = gestures.flags(shift: false, option: true, other: false, at: 1.2)
        #expect(gestures.flags(shift: false, option: false, other: false, at: 1.3) == nil)
    }

    @Test func settingsDecodeTolerantly() throws {
        let empty = try JSONDecoder().decode(LayoutSettings.self, from: Data("{}".utf8))
        #expect(empty == LayoutSettings())
        let partial = try JSONDecoder().decode(LayoutSettings.self, from: Data(#"{"auto":false,"learned":["ghbdtn"],"future":1}"#.utf8))
        #expect(partial.auto == false)
        #expect(partial.learned == ["ghbdtn"])
        #expect(partial.doubleShift)
    }

    @Test func everyLanguagePairIsOffered() {
        let abc2 = KeyLayout(id: "abc2", language: "en", name: "abc2", keys: en.keys)
        let directions = LayoutWords.directions(among: [en, ru, abc2, de])
        #expect(directions.map(\.title) == ["EN → RU", "EN → DE", "RU → EN", "RU → DE", "DE → EN", "DE → RU"])
        #expect(LayoutWords.directions(among: [en, abc2]).isEmpty)
    }

    /// EN → RU off: «ghbdtn» stays, while RU → EN still fixes. Only that way round, and it comes back when turned on.
    @Test func aDirectionTurnedOffFixesNothing() {
        var settings = LayoutSettings()
        let direction = FixDirection(from: "en", to: "ru")
        #expect(settings.fixes(direction))
        settings.setFixes(direction, false)
        settings.setFixes(direction, false)
        #expect(settings.offDirections == [direction])
        #expect(fix("ghbdtn", in: en, others: settings.autoTargets(from: en, among: [en, ru])) == nil)
        #expect(fix("руддщ", in: ru, others: settings.autoTargets(from: ru, among: [en, ru])) == "hello")
        settings.setFixes(direction, true)
        #expect(settings.offDirections.isEmpty)
        #expect(fix("ghbdtn", in: en, others: settings.autoTargets(from: en, among: [en, ru])) == "привет")
    }

    /// The same presses read as «zes» in English and «yes» in German: turning one way off leaves the other.
    private func typedInRussian(others: [KeyLayout], learned: Set<String> = []) -> String? {
        LayoutWords.correction(for: strokes("яуы", in: ru), in: ru, others: others, learned: learned) { word, language in
            (language == "en" && word == "zes") || (language == "de" && word == "yes")
        }?.text
    }

    @Test func aDirectionOffLeavesTheOthersOpen() {
        var settings = LayoutSettings()
        #expect(typedInRussian(others: settings.autoTargets(from: ru, among: [ru, en, de])) == "zes")
        settings.setFixes(FixDirection(from: "ru", to: "en"), false)
        #expect(typedInRussian(others: settings.autoTargets(from: ru, among: [ru, en, de])) == "yes")
    }

    @Test func offDirectionsSurviveSaving() throws {
        var settings = LayoutSettings()
        settings.setFixes(FixDirection(from: "ru", to: "en"), false)
        let decoded = try JSONDecoder().decode(LayoutSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        // Garbage in the field costs that field only.
        let odd = try JSONDecoder().decode(LayoutSettings.self, from: Data(#"{"auto":false,"offDirections":"x"}"#.utf8))
        #expect(odd.offDirections.isEmpty)
        #expect(odd.auto == false)
    }

    /// Either side of a fix may be in the dictionary, in any case, with punctuation after it.
    @Test func exceptionsStopAFixFromEitherSide() {
        #expect(fix("ghbdtn,", in: en, learned: ["ghbdtn"]) == nil)
        #expect(fix("Ghbdtn", in: en, learned: ["ghbdtn"]) == nil)
        #expect(fix("ghbdtn", in: en, learned: ["привет"]) == nil)
        #expect(fix("ghbdtn,", in: en, learned: ["привет"]) == nil)
        #expect(fix("ghbdtn", in: en, learned: ["другое"]) == "привет")
    }

    /// An exception in one language doesn't stop the fix into another.
    @Test func anExceptionLeavesTheNextLayoutInPlay() {
        #expect(typedInRussian(others: [ru, en, de], learned: ["zes"]) == "yes")
        #expect(typedInRussian(others: [ru, en, de], learned: ["zes", "yes"]) == nil)
    }

    @Test func wordsAreAddedByHand() {
        #expect(LayoutWords.addingExceptions(" VS, «github»;\nкто-то  don't ", to: ["old", "vs"]) == ["vs", "github", "кто-то", "don't", "old"])
        #expect(LayoutWords.addingExceptions(" ,; «» ", to: ["old"]) == ["old"])
    }

    /// ⌥⇧ converts around an exception and keeps the spaces and line breaks.
    @Test func selectionKeepsExceptions() {
        let result = LayoutWords.convert("ghbdtn hello\nvbh", among: [en, ru], current: "abc", exceptions: ["hello"], isWord: isWord)
        #expect(result?.text == "привет hello\nмир")
        #expect(result?.layoutID == "ru")
        #expect(LayoutWords.convert("ghbdtn vbh", among: [en, ru], current: "abc", exceptions: ["мир"], isWord: isWord)?.text == "привет vbh")
        #expect(LayoutWords.convert("hello", among: [en, ru], current: "abc", exceptions: ["hello"], isWord: isWord) == nil)
    }

    @Test func layoutIsAModuleOutsideThePanel() {
        #expect(!ModuleKind.layout.isBuiltIn)
        #expect(!ModuleKind.layout.isPanelBlock)
    }

    /// The Mac's own layouts and dictionaries, where it has an English and a Russian layout.
    @MainActor
    @Test func systemLayoutsAndDictionaries() {
        let layouts = KeyboardLayouts.enabled().map(\.layout)
        guard let english = layouts.first(where: { $0.language == "en" }), let russian = layouts.first(where: { $0.language == "ru" }) else { return }
        func isWord(_ word: String, _ language: String) -> Bool {
            NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        let typed = "ghbdtn".compactMap(english.stroke(for:))
        #expect(typed.count == 6)
        #expect(LayoutWords.correction(for: typed, in: english, others: [english, russian], learned: [], isWord: isWord)?.text == "привет")
        let hello = "руддщ".compactMap(russian.stroke(for:))
        #expect(LayoutWords.correction(for: hello, in: russian, others: [english, russian], learned: [], isWord: isWord)?.text == "hello")
        #expect(LayoutWords.correction(for: "hello".compactMap(english.stroke(for:)), in: english, others: [english, russian], learned: [], isWord: isWord) == nil)
    }
}

@MainActor
struct LayoutAccessTests {
    @Test func theSystemPromptComesUpOnce() {
        #expect(LayoutSwitcher.shouldAskForAccess(isOn: true, granted: false, alreadyAsked: false))
        #expect(!LayoutSwitcher.shouldAskForAccess(isOn: true, granted: false, alreadyAsked: true), "not at every launch")
        #expect(!LayoutSwitcher.shouldAskForAccess(isOn: true, granted: true, alreadyAsked: false))
        #expect(!LayoutSwitcher.shouldAskForAccess(isOn: false, granted: false, alreadyAsked: false), "a module that is off asks nothing")
    }

    @Test func havingAskedOutlivesALaunch() throws {
        let name = "claudepult-layout-access-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.layoutAccessAsked)
        settings.layoutAccessAsked = true
        #expect(AppSettings(defaults: defaults).layoutAccessAsked)
    }
}
