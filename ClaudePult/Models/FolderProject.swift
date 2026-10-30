import AppKit
import Foundation

/// A project that is just a folder (SPEC-modes §3, source «папки» / «входящие»): a video, an article, a research topic.
/// Its card is `проект.md` — plain Markdown the person can edit by hand (§8: no private formats).
struct FolderProject: Identifiable, Equatable, Sendable {
    var name: String
    var path: String
    var card: ProjectCardFile
    var hasCardFile: Bool
    /// The text the metrics are counted on: «Главный файл» from the card, else the latest text file.
    var mainFile: String?
    var words: Int?
    /// PDFs, links and notes in a sources folder (`источники`, `sources`) or PDFs anywhere in the project.
    var sources: Int
    var lastActivity: Date?

    var id: String { path }
}

/// `проект.md`: lines `Ключ: значение` anywhere in the file (also `- **Этап:** …`). Only the known keys are read;
/// everything else in the file is kept as is when a value is written back.
struct ProjectCardFile: Equatable, Sendable {
    /// Read under either name; a new card gets the content language's one.
    static let fileNames = ContentLanguage.allCases.map(\.strings.cardFile)
    static var fileName: String { ContentLanguage.current.strings.cardFile }

    /// The project's card: the existing one under any name, else where a new one goes.
    static func path(in folder: String) -> String {
        let existing = fileNames.map { folder + "/" + $0 }.first(where: FileManager.default.fileExists(atPath:))
        return existing ?? folder + "/" + fileName
    }

    enum Key: String, CaseIterable, Sendable {
        case stage, deadline, publish, format, mainFile, platform

        /// Every language's label plus synonyms, all accepted when reading.
        var labels: [String] {
            let synonyms: [String] = switch self {
            case .deadline: ["срок"]
            case .publish: ["дата публикации", "publication"]
            default: []
            }
            return ContentLanguage.allCases.compactMap { $0.strings.cardLabels[self] } + synonyms
        }

        /// The label written into a file in that language.
        func label(_ language: ContentLanguage) -> String {
            language.strings.cardLabels[self] ?? rawValue
        }
    }

    var values: [Key: String] = [:]

    var stage: String? { values[.stage] }
    var deadline: Date? { values[.deadline].flatMap(Self.date) }
    var publish: Date? { values[.publish].flatMap(Self.date) }

    static func parse(_ text: String) -> ProjectCardFile {
        var card = ProjectCardFile()
        for line in text.components(separatedBy: .newlines) {
            guard let (key, value) = field(line), card.values[key] == nil, !value.isEmpty else { continue }
            card.values[key] = value
        }
        return card
    }

    /// The key and value of one line, ignoring list markers and bold: `- **Этап:** сценарий`.
    static func field(_ line: String) -> (Key, String)? {
        var text = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- ", "* ", "+ "] where text.hasPrefix(prefix) { text = String(text.dropFirst(2)) }
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let label = text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard let key = Key.allCases.first(where: { $0.labels.contains { $0.lowercased() == label } }) else { return nil }
        return (key, text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// Writes one value back: replaces the first line with that key, or adds a line after the title.
    static func setting(_ key: Key, to value: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        // A file keeps its language: the language whose labels it already uses, else the content language.
        let newLine = "\(key.label(language(of: lines))): \(value)"
        if let index = lines.firstIndex(where: { field($0)?.0 == key }) {
            // Keep a list marker the person used.
            let marker = ["- ", "* ", "+ "].first { lines[index].trimmingCharacters(in: .whitespaces).hasPrefix($0) } ?? ""
            lines[index] = marker + newLine
        } else if let title = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            // After the title and the blank line under it; a blank line before the text that follows.
            var position = title + 1
            if position < lines.count, lines[position].trimmingCharacters(in: .whitespaces).isEmpty { position += 1 } else {
                lines.insert("", at: position)
                position += 1
            }
            lines.insert(newLine, at: position)
            let next = position + 1
            if next < lines.count, !lines[next].trimmingCharacters(in: .whitespaces).isEmpty, field(lines[next]) == nil {
                lines.insert("", at: next)
            }
        } else {
            lines.insert(newLine, at: 0)
        }
        return lines.joined(separator: "\n")
    }

    /// A new card: title, stage and the empty fields to fill in.
    static func template(name: String, stage: String?, language: ContentLanguage = .current) -> String {
        var lines = ["# \(name)", ""]
        if let stage { lines.append("\(Key.stage.label(language)): \(stage)") }
        lines += [Key.deadline, .publish, .format, .mainFile, .platform].map { "\($0.label(language)): " }
        lines += ["", language.strings.notesHeading, ""]
        return lines.joined(separator: "\n")
    }

    /// The language of the card's existing field names (the first language that has them all).
    static func language(of lines: [String]) -> ContentLanguage {
        let used = lines.compactMap { line -> String? in
            guard field(line) != nil else { return nil }
            var text = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["- ", "* ", "+ "] where text.hasPrefix(prefix) { text = String(text.dropFirst(2)) }
            text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            return text.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard !used.isEmpty else { return .current }
        // Some names are shared (German and Polish «Format», Russian and Ukrainian «Дедлайн»): prefer the current language.
        return ([ContentLanguage.current] + ContentLanguage.allCases).first { language in
            let own = Set(language.strings.cardLabels.values.map { $0.lowercased() })
            return used.allSatisfy(own.contains)
        } ?? .current
    }

    /// `2026-11-05`, `2026-11-05 18:00`, `05.11.2026`, `05.11.2026 18:00`.
    static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd", "dd.MM.yyyy HH:mm", "dd.MM.yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}

/// Metrics of a folder project shown in its row (SPEC-modes §3).
enum FolderMetric: String, CaseIterable, Codable, Sendable {
    case words, duration, readingTime, pages, sources, deadline, publishDate, lastActivity

    var title: String {
        switch self {
        case .words: String(localized: "Слова")
        case .duration: String(localized: "Хронометраж")
        case .readingTime: String(localized: "Время чтения")
        case .pages: String(localized: "Страницы")
        case .sources: String(localized: "Источники")
        case .deadline: String(localized: "Дедлайн")
        case .publishDate: String(localized: "Дата публикации")
        case .lastActivity: String(localized: "Последняя правка")
        }
    }

    /// The text for a row, nil when there is nothing to show.
    func text(for project: FolderProject, wordsPerMinute: Int, now: Date = .now) -> String? {
        switch self {
        case .words: return project.words.map { String(localized: "\($0) сл.") }
        case .duration:
            guard let words = project.words, words > 0 else { return nil }
            let seconds = Int((Double(words) / Double(max(wordsPerMinute, 1)) * 60).rounded())
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .readingTime:
            guard let words = project.words, words > 0 else { return nil }
            return String(localized: "\(max(1, Int((Double(words) / 200).rounded()))) мин чтения")
        case .pages:
            guard let words = project.words, words > 0 else { return nil }
            return String(localized: "\(max(1, Int((Double(words) / 250).rounded(.up)))) стр.")
        case .sources: return project.sources > 0 ? String(localized: "\(project.sources) ист.") : nil
        case .deadline: return project.card.deadline.map { String(localized: "до ") + FolderMetric.shortDate($0, now: now) }
        case .publishDate: return project.card.publish.map { String(localized: "публ. ") + FolderMetric.shortDate($0, now: now) }
        case .lastActivity: return project.lastActivity.map { RelativeTime.ago($0, now: now) }
        }
    }

    static func shortDate(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "сегодня") }
        if calendar.isDateInTomorrow(date) { return String(localized: "завтра") }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        return date.formatted(sameYear ? style : style.year())
    }
}

/// Reads folder projects from disk. Pure file work, off the main actor.
enum FolderScanner {
    static let textExtensions: Set<String> = ["md", "markdown", "txt", "rtf", "docx", "fountain"]
    static let sourceFolders: Set<String> = ["источники", "sources", "материалы"]

    /// `.folders`: every visible subfolder; `.inbox`: the folder itself.
    static func scan(source: ProjectSource) -> [FolderProject] {
        let fm = FileManager.default
        switch source {
        case let .folders(path):
            let root = URL(fileURLWithPath: PathText.expand(path))
            let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            return children
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !$0.lastPathComponent.hasPrefix("_") }
                .map(project)
                .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        case let .inbox(path):
            let url = URL(fileURLWithPath: PathText.expand(path))
            return fm.fileExists(atPath: url.path) ? [project(url)] : []
        default:
            return []
        }
    }

    static func project(_ folder: URL) -> FolderProject {
        let cardURL = URL(fileURLWithPath: ProjectCardFile.path(in: folder.path))
        let cardText = try? String(contentsOf: cardURL, encoding: .utf8)
        let card = cardText.map(ProjectCardFile.parse) ?? ProjectCardFile()
        let files = self.files(in: folder)
        let texts = files.filter { textExtensions.contains($0.url.pathExtension.lowercased()) && !ProjectCardFile.fileNames.contains($0.url.lastPathComponent) }
        let main: URL? = card.values[.mainFile]
            .map { folder.appending(path: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? texts.max { $0.modified < $1.modified }?.url
        let sources = files.filter { file in
            file.url.pathExtension.lowercased() == "pdf"
                || file.url.pathComponents.contains { sourceFolders.contains($0.lowercased()) }
        }.count
        return FolderProject(
            name: folder.lastPathComponent, path: folder.path, card: card, hasCardFile: cardText != nil,
            mainFile: main.map { relativePath($0, in: folder) }, words: main.flatMap(wordCount),
            sources: sources, lastActivity: files.map(\.modified).max()
        )
    }

    /// Files up to three levels deep, without hidden ones, build folders and ClaudePult's own logs.
    static func files(in folder: URL) -> [(url: URL, modified: Date)] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var result: [(URL, Date)] = []
        for case let url as URL in enumerator {
            if enumerator.level > 3 || ["node_modules", "build"].contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            result.append((url, values?.contentModificationDate ?? .distantPast))
            if result.count >= 2000 { break }
        }
        return result
    }

    static func relativePath(_ url: URL, in folder: URL) -> String {
        let base = folder.standardizedFileURL.path + "/"
        let full = url.standardizedFileURL.path
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : url.lastPathComponent
    }

    static func text(of url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "rtf", "docx":
            return try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        default:
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    static func wordCount(_ url: URL) -> Int? {
        text(of: url).map(words)
    }

    /// Words of the text without Markdown markup: headings, list markers, links' addresses don't count.
    static func words(_ text: String) -> Int {
        // Link addresses `[text](https://…)` are not words.
        let text = text.replacingOccurrences(of: #"\]\([^)]*\)"#, with: "]", options: .regularExpression)
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .localized]) { word, _, _, _ in
            if let word, word.contains(where: \.isLetter) || word.contains(where: \.isNumber) { count += 1 }
        }
        return count
    }
}
