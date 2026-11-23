import AppKit
import Foundation

/// Two texts side by side, line by line (a paragraph of prose is one line): «Версии» → «Сравнить с текущим»
/// (SPEC-content §4). No git: the lines are matched with the standard library's difference.
enum TextCompare {
    struct Row: Identifiable, Equatable, Sendable {
        var id: Int
        /// Nil where the line exists only on the other side.
        var old: String?
        var new: String?

        var isChanged: Bool { old != new }
    }

    /// Longer texts are compared by their beginning: the difference of very long files takes too long.
    static let lineLimit = 3000

    static func lines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    /// The rows of both texts in order: equal lines on both sides, a changed line as old against new, a removed or
    /// added one alone on its side.
    static func rows(old: String, new: String, limit: Int = lineLimit) -> (rows: [Row], cut: Bool) {
        let allOld = lines(old), allNew = lines(new)
        let oldLines = Array(allOld.prefix(limit)), newLines = Array(allNew.prefix(limit))
        let difference = newLines.difference(from: oldLines)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var rows: [Row] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            let gone = i < oldLines.count && removed.contains(i)
            let came = j < newLines.count && inserted.contains(j)
            if gone, came {
                rows.append(Row(id: rows.count, old: oldLines[i], new: newLines[j])); i += 1; j += 1
            } else if gone || j >= newLines.count {
                rows.append(Row(id: rows.count, old: oldLines[i], new: nil)); i += 1
            } else if came || i >= oldLines.count {
                rows.append(Row(id: rows.count, old: nil, new: newLines[j])); j += 1
            } else {
                rows.append(Row(id: rows.count, old: oldLines[i], new: newLines[j])); i += 1; j += 1
            }
        }
        return (rows, allOld.count > limit || allNew.count > limit)
    }

    /// The text of a file's content as it was kept in a version; `.docx` and `.rtf` are read as documents.
    static func text(of data: Data, path: String) -> String? {
        let type: NSAttributedString.DocumentType? = switch (path as NSString).pathExtension.lowercased() {
        case "docx": .officeOpenXML
        case "rtf": .rtf
        default: nil
        }
        guard let type else { return String(data: data, encoding: .utf8) }
        return try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil).string
    }
}
