import Foundation

/// One key press as the keyboard sent it. The same press types a different letter in each layout, so a word is kept
/// as presses and can be read in any layout (docs/specs/SPEC-layout.md §2).
struct KeyStroke: Hashable, Sendable {
    var keyCode: UInt16
    var shift = false
    var caps = false
}

/// A keyboard layout reduced to what «Раскладка» needs: its language and what each press types there.
struct KeyLayout: Equatable, Sendable {
    var id: String
    /// Two letters: «ru», «en», «uk», «de», «fr», «pt», «es».
    var language: String
    var name: String
    var keys: [KeyStroke: String]
    /// Presses that wait for the next one (´ then e = é): a word with one can't be counted letter by letter.
    var deadKeys: Set<KeyStroke> = []

    func text(_ strokes: [KeyStroke]) -> String { strokes.map { keys[$0] ?? "" }.joined() }

    /// The press that types `character` here; the plainest one when several do.
    func stroke(for character: Character) -> KeyStroke? {
        let text = String(character)
        return keys.filter { $0.value == text }.keys.min { ($0.caps ? 1 : 0, $0.shift ? 1 : 0, $0.keyCode) < ($1.caps ? 1 : 0, $1.shift ? 1 : 0, $1.keyCode) }
    }

    /// What the menu bar shows for it.
    var badge: String { LayoutWords.badge(language) }
}

/// What a finished word is replaced with.
struct LayoutCorrection: Equatable, Sendable {
    /// The layout the word was meant for; the keyboard switches to it.
    var layoutID: String
    var typed: String
    var text: String
}

/// One way an automatic fix can go, by language: «EN → RU». A person thinks in languages, and a second Russian layout
/// shouldn't bring new switches.
struct FixDirection: Codable, Hashable, Sendable {
    var from: String
    var to: String

    var title: String { "\(LayoutWords.badge(from)) → \(LayoutWords.badge(to))" }
}

/// Words, layouts and the choice between them. Pure: «is this a word» comes from outside (the system spell checker
/// in the app, a word list in tests).
enum LayoutWords {
    /// The languages «Раскладка» knows (SPEC-layout §1); layouts of other languages are left alone.
    static let languages = ["ru", "en", "uk", "de", "fr", "pt", "es"]

    /// Shorter words are left alone: a lone «z» may be «я» or a variable.
    static let minimumLetters = 2
    /// Longer runs are not words someone typed (a pasted token, a held key).
    static let maximumStrokes = 40

    static func badge(_ language: String) -> String { language == "uk" ? "UA" : language.uppercased() }

    /// Every direction between the languages of `layouts`, in their order. Layouts of one language aren't offered.
    static func directions(among layouts: [KeyLayout]) -> [FixDirection] {
        let languages = layouts.map(\.language).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return languages.flatMap { from in languages.filter { $0 != from }.map { FixDirection(from: from, to: $0) } }
    }

    /// A press that belongs inside a word: a letter, or an apostrophe or hyphen between letters («don't», «кто-то»).
    private static func isLetter(_ text: String) -> Bool { text.count == 1 && text.first?.isLetter == true }
    private static func isJoiner(_ text: String) -> Bool { ["'", "’", "-"].contains(text) }

    /// How many presses at each end are not letters, or nil when the middle is not a word (digits, a «.» inside,
    /// fewer than two letters).
    static func wordRange(_ parts: [String]) -> Range<Int>? {
        guard let first = parts.firstIndex(where: isLetter), let last = parts.lastIndex(where: isLetter) else { return nil }
        let middle = parts[first...last]
        guard middle.allSatisfy({ isLetter($0) || isJoiner($0) }), middle.filter(isLetter).count >= minimumLetters else { return nil }
        return first..<(last + 1)
    }

    /// The word typed with `strokes` in `current`, if it was meant for another layout: nil when it is a word here,
    /// is an exception or would become one (`learned`), has digits, or reads as a word in no other layout.
    ///
    /// The ends are read both ways: «ghbdtn,» is «привет,» (the comma as typed), «kj,» is «лоб» (the comma key is «б»).
    static func correction(for strokes: [KeyStroke], in current: KeyLayout, others: [KeyLayout], learned: Set<String>,
                           isWord: (String, String) -> Bool) -> LayoutCorrection? {
        guard !strokes.isEmpty, strokes.count <= maximumStrokes, !strokes.contains(where: current.deadKeys.contains) else { return nil }
        let typedParts = strokes.map { current.keys[$0] ?? "" }
        guard !typedParts.contains(where: { $0.isEmpty || $0.contains(where: \.isNumber) }) else { return nil }
        let typed = typedParts.joined()
        guard !isException(typed, in: learned) else { return nil }
        let typedRange = wordRange(typedParts)
        if let typedRange, isWord(typedParts[typedRange].joined(), current.language) { return nil }

        for layout in others where layout.id != current.id {
            let parts = strokes.map { layout.keys[$0] ?? "" }
            guard !parts.contains(where: \.isEmpty) else { continue }
            var text: String?
            if let range = wordRange(parts), isWord(parts[range].joined(), layout.language) {
                text = parts.joined()
            } else if let typedRange, typedRange.count < parts.count {
                let core = Array(parts[typedRange])
                if core.allSatisfy({ isLetter($0) || isJoiner($0) }), wordRange(core) == 0..<core.count, isWord(core.joined(), layout.language) {
                    text = typedParts[..<typedRange.lowerBound].joined() + core.joined() + typedParts[typedRange.upperBound...].joined()
                }
            }
            if let text, text != typed, !isException(text, in: learned) { return LayoutCorrection(layoutID: layout.id, typed: typed, text: text) }
        }
        return nil
    }

    /// Double Shift on a word: where it goes — the layout it reads as a word in, otherwise the next one in the list.
    static func manualTarget(for strokes: [KeyStroke], in current: KeyLayout, among layouts: [KeyLayout],
                             isWord: (String, String) -> Bool) -> KeyLayout? {
        let index = layouts.firstIndex { $0.id == current.id } ?? -1
        let others = (layouts[(index + 1)...] + layouts[..<max(index, 0)]).filter { $0.id != current.id }
        let readable = others.first { layout in
            let parts = strokes.map { layout.keys[$0] ?? "" }
            return wordRange(parts).map { isWord(parts[$0].joined(), layout.language) } ?? false
        }
        return readable ?? others.first
    }

    /// ⌥⇧ on selected text: which layout it was typed in (the one that can type most of its letters; `current` wins
    /// a tie), and the text as the same presses type it in the layout where most of it reads as words. Exceptions stay
    /// as they are, so «ghbdtn GitHub» can become «привет GitHub».
    static func convert(_ text: String, among layouts: [KeyLayout], current: String?, exceptions: Set<String> = [],
                        isWord: (String, String) -> Bool) -> (text: String, layoutID: String)? {
        let letters = text.filter(\.isLetter)
        guard !letters.isEmpty, layouts.count > 1 else { return nil }
        func typeable(_ layout: KeyLayout) -> Int { letters.filter { layout.stroke(for: $0) != nil }.count }
        let ranked = layouts.enumerated().sorted { a, b in
            let (ca, cb) = (typeable(a.element), typeable(b.element))
            if ca != cb { return ca > cb }
            if (a.element.id == current) != (b.element.id == current) { return a.element.id == current }
            return a.offset < b.offset
        }
        let source = ranked[0].element
        let start = layouts.firstIndex(of: source) ?? 0
        let targets = (layouts[(start + 1)...] + layouts[..<start]).filter { $0.id != source.id }
        var best: (text: String, layoutID: String, score: Int)?
        for target in targets {
            let converted = mappingWords(of: text) { word in
                let mapped = String(word.flatMap { character -> String in
                    guard let stroke = source.stroke(for: character), let typed = target.keys[stroke] else { return String(character) }
                    return typed
                })
                return isException(word, in: exceptions) || isException(mapped, in: exceptions) ? word : mapped
            }
            let words = converted.split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: .punctuationCharacters) }
            let score = words.filter { !$0.isEmpty && isWord($0, target.language) }.count
            if converted != text, best == nil || score > best!.score { best = (converted, target.id, score) }
        }
        return best.map { ($0.text, $0.layoutID) }
    }

    /// `text` with each run of non-spaces replaced; the spaces and line breaks stay where they are.
    private static func mappingWords(of text: String, _ transform: (String) -> String) -> String {
        var result = ""
        var word = ""
        for character in text {
            if character.isWhitespace {
                result += transform(word)
                word = ""
                result.append(character)
            } else {
                word.append(character)
            }
        }
        return result + transform(word)
    }

    /// Whether the dictionary of exceptions has this word, with or without what sits at its ends («vs,» is «vs»).
    static func isException(_ word: String, in exceptions: Set<String>) -> Bool {
        let key = word.lowercased()
        return exceptions.contains(key) || exceptions.contains(key.trimmingCharacters(in: CharacterSet.letters.inverted))
    }

    /// Words added by hand: spaces, commas or semicolons between them, quotes and the like around them are dropped.
    /// The first one typed ends up on top.
    static func addingExceptions(_ text: String, to list: [String]) -> [String] {
        let words = text.split { $0.isWhitespace || $0 == "," || $0 == ";" }.map { $0.trimmingCharacters(in: .punctuationCharacters) }
        return words.reversed().reduce(list) { learning($1, into: $0) }
    }

    /// An un-corrected word goes on the list of exceptions once, newest first.
    static func learning(_ word: String, into list: [String], limit: Int = 500) -> [String] {
        let key = word.lowercased()
        guard !key.isEmpty else { return list }
        return Array(([key] + list.filter { $0 != key }).prefix(limit))
    }
}

/// Double Shift and ⌥⇧ — taps of modifier keys alone, told apart from Shift held for a capital letter (SPEC-layout §3).
struct ModifierGestures {
    enum Gesture: Equatable { case doubleShift, optionShift }

    /// The longest a tap may be held, and the longest gap between the two Shift taps.
    static let tapLimit: TimeInterval = 0.35
    static let gapLimit: TimeInterval = 0.45

    private var shiftDown = false
    private var optionDown = false
    private var pressStart: TimeInterval?
    private var lastTapEnd: TimeInterval?
    private var chord = false
    private var spoiled = false

    /// Any key, a click or another modifier in between: no gesture.
    mutating func reset() {
        pressStart = nil
        lastTapEnd = nil
        chord = false
        spoiled = true
    }

    /// A modifier went down or up. `other`: ⌘, ⌃ or Fn is held.
    mutating func flags(shift: Bool, option: Bool, other: Bool, at time: TimeInterval) -> Gesture? {
        defer {
            shiftDown = shift
            optionDown = option
        }
        if other {
            reset()
            return nil
        }
        let wasIdle = !shiftDown && !optionDown
        if wasIdle, shift || option {
            spoiled = false
            pressStart = time
        }
        if shift, option { chord = true }
        guard !shift, !option, shiftDown || optionDown else { return nil }
        // Everything is up again.
        defer { chord = false }
        guard !spoiled, let start = pressStart else {
            lastTapEnd = nil
            return nil
        }
        if chord {
            lastTapEnd = nil
            return .optionShift
        }
        guard shiftDown, !optionDown, time - start <= Self.tapLimit else {
            lastTapEnd = nil
            return nil
        }
        if let end = lastTapEnd, start - end <= Self.gapLimit {
            lastTapEnd = nil
            return .doubleShift
        }
        lastTapEnd = time
        return nil
    }
}

/// «Раскладка» settings (SPEC-layout §4). Few on purpose: it works as it comes.
struct LayoutSettings: Codable, Equatable, Sendable {
    /// Fix a word typed in the wrong layout once it is finished.
    var auto = true
    var doubleShift = true
    var optionShift = true
    /// The layout's language in the menu bar, blinking when «Раскладка» switches it.
    var menuBarIcon = true
    /// Terminals take commands, not words: no automatic fixes there.
    var skipTerminals = true
    /// The dictionary of exceptions: words added by hand and words the person un-corrected. Lowercased, as typed.
    var learned: [String] = []
    /// Directions turned off for automatic fixes; everything else is on, so a newly added layout just works.
    var offDirections: [FixDirection] = []

    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "io.alacritty", "com.github.wez.wezterm",
    ]

    init() {}

    func fixes(_ direction: FixDirection) -> Bool { !offDirections.contains(direction) }

    mutating func setFixes(_ direction: FixDirection, _ on: Bool) {
        offDirections.removeAll { $0 == direction }
        if !on { offDirections.append(direction) }
    }

    /// The layouts a word typed in `current` may be fixed into.
    func autoTargets(from current: KeyLayout, among layouts: [KeyLayout]) -> [KeyLayout] {
        layouts.filter { fixes(FixDirection(from: current.language, to: $0.language)) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LayoutSettings()
        auto = (try? c.decodeIfPresent(Bool.self, forKey: .auto)) ?? defaults.auto
        doubleShift = (try? c.decodeIfPresent(Bool.self, forKey: .doubleShift)) ?? defaults.doubleShift
        optionShift = (try? c.decodeIfPresent(Bool.self, forKey: .optionShift)) ?? defaults.optionShift
        menuBarIcon = (try? c.decodeIfPresent(Bool.self, forKey: .menuBarIcon)) ?? defaults.menuBarIcon
        skipTerminals = (try? c.decodeIfPresent(Bool.self, forKey: .skipTerminals)) ?? defaults.skipTerminals
        learned = (try? c.decodeIfPresent([String].self, forKey: .learned)) ?? defaults.learned
        offDirections = (try? c.decodeIfPresent([FixDirection].self, forKey: .offDirections)) ?? defaults.offDirections
    }
}
