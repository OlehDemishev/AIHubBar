import Foundation

/// Characters that are in the text but not on the screen. Port of `desktop/skill-scanner/src/text.rs`.
enum SkillText {
    enum Hidden { case tag, bidi, zeroWidth }

    /// `previous` is the character before, to let a joiner inside an emoji or a non-Latin word pass.
    static func hidden(_ c: Unicode.Scalar, previous: Unicode.Scalar?) -> Hidden? {
        switch c.value {
        case 0xE0000...0xE007F: return .tag
        case 0x202A...0x202E, 0x2066...0x2069: return .bidi
        case 0x200B, 0x2060...0x2064, 0xFEFF, 0x180E, 0x200E, 0x200F, 0x061C: return .zeroWidth
        // Joiners are part of emoji and of several scripts; between Latin letters they have no use.
        case 0x200C, 0x200D: return (previous.map { $0.isASCII } ?? true) ? .zeroWidth : nil
        default: return nil
        }
    }

    static func hasHidden(_ line: String) -> Bool {
        var previous: Unicode.Scalar?
        for c in line.unicodeScalars {
            if hidden(c, previous: previous) != nil { return true }
            previous = c
        }
        return false
    }

    /// The line as the agent's tokenizer effectively reads it: without the invisible characters.
    static func withoutHidden(_ line: String) -> String {
        var previous: Unicode.Scalar?
        var out = String.UnicodeScalarView()
        for c in line.unicodeScalars {
            if hidden(c, previous: previous) == nil { out.append(c) }
            previous = c
        }
        return String(out)
    }

    struct Count: Equatable {
        var count = 0
        /// 1-based.
        var firstLine = 0
    }

    struct Report: Equatable {
        var tags = Count()
        var bidi = Count()
        var zeroWidth = Count()
        /// What the tag characters spell.
        var tagText = ""
    }

    static func report(_ text: String) -> Report {
        var report = Report()
        var line = 1
        var previous: Unicode.Scalar?
        var first = true
        for c in text.unicodeScalars {
            defer { previous = c; first = false }
            if c == "\n" { line += 1 }
            // A byte order mark at the very start is how some editors save a file.
            let kind = first && c.value == 0xFEFF ? nil : hidden(c, previous: previous)
            guard let kind else { continue }
            func count(_ slot: inout Count) {
                if slot.count == 0 { slot.firstLine = line }
                slot.count += 1
            }
            switch kind {
            case .tag:
                if let ascii = Unicode.Scalar(c.value - 0xE0000), (0x20...0x7E).contains(ascii.value) { report.tagText.unicodeScalars.append(ascii) }
                count(&report.tags)
            case .bidi: count(&report.bidi)
            case .zeroWidth: count(&report.zeroWidth)
            }
        }
        return report
    }

    /// A whole line for showing to a person: the invisible characters spelled out, nothing cut.
    static func visible(_ line: String) -> String {
        var previous: Unicode.Scalar?
        var shown = ""
        for c in line.unicodeScalars {
            if hidden(c, previous: previous) != nil {
                shown += String(format: "<U+%04X>", c.value)
            } else if CharacterSet.controlCharacters.contains(c) && c != "\t" {
                shown += " "
            } else {
                shown.unicodeScalars.append(c)
            }
            previous = c
        }
        return shown
    }

    /// A line for showing to a person: short, on one line, with the invisible characters spelled out.
    static func excerpt(_ text: String) -> String {
        var shown = ""
        var previous: Unicode.Scalar?
        var length = 0
        for c in text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if length >= 180 {
                shown += "…"
                break
            }
            if hidden(c, previous: previous) != nil {
                shown += String(format: "<U+%04X>", c.value)
            } else if CharacterSet.controlCharacters.contains(c) {
                shown += " "
            } else {
                shown.unicodeScalars.append(c)
            }
            previous = c
            length += 1
        }
        return shown
    }

    /// Edit distance of at most one: a letter changed, added, dropped, or two neighbours swapped.
    static func oneTypoApart(_ a: String, _ b: String) -> Bool {
        if a == b { return false }
        let (a, b) = (Array(a), Array(b))
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        switch long.count - short.count {
        case 0:
            let differing = a.indices.filter { a[$0] != b[$0] }
            if differing.count == 1 { return true }
            if differing.count == 2 {
                let (i, j) = (differing[0], differing[1])
                return j == i + 1 && a[i] == b[j] && a[j] == b[i]
            }
            return false
        case 1:
            var skipped = false
            var (i, j) = (0, 0)
            while i < short.count && j < long.count {
                if short[i] == long[j] {
                    i += 1
                    j += 1
                } else if skipped {
                    return false
                } else {
                    skipped = true
                    j += 1
                }
            }
            return true
        default:
            return false
        }
    }
}
