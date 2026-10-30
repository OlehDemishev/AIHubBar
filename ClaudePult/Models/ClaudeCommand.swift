import Foundation

/// Whose rules the developer prompts follow: Oleh's `~/Projects/CLAUDE.md` (his own mode) or the project's own
/// CLAUDE.md / AGENTS.md (the «Разработчик (GitHub)» template, docs/TEMPLATES.md §1).
enum PromptStyle: String, Codable, Sendable {
    case oleh, generic
}

/// The three Claude commands from docs/SPEC.md §2.4. Prompts are used verbatim.
enum ClaudeCommand: Codable, Equatable, Sendable {
    case nextStep
    case customTask(String)
    case finishSession

    var title: String {
        switch self {
        case .nextStep: String(localized: "Следующий шаг")
        case .customTask: String(localized: "Своя задача")
        case .finishSession: String(localized: "Завершить сессию")
        }
    }

    var prompt: String { prompt(.oleh) }

    func prompt(_ style: PromptStyle, language: ContentLanguage = .current) -> String {
        if style == .generic {
            let words = language.strings
            switch self {
            case .nextStep: return words.nextStep
            case let .customTask(task):
                return ContentStrings.fill(words.customTask, ["task": task.trimmingCharacters(in: .whitespacesAndNewlines)])
            case .finishSession: return words.finishSession
            }
        }
        switch self {
        case .nextStep:
            return "Прочитай только шапку docs/STATUS.md и последнюю запись журнала. Возьми первый пункт из Next и выполни его по правилам ~/Projects/CLAUDE.md: отдельная ветка от origin/main, проверки проекта, коммит, push, PR, запись в STATUS.md и обновление шапки. Если пункт требует решения Олега или неясен — ничего не меняй, а запиши вопрос в Needs Oleh и закончи."
        case let .customTask(task):
            return "Задача от Олега: \(task.trimmingCharacters(in: .whitespacesAndNewlines)). Работай по правилам ~/Projects/CLAUDE.md: отдельная ветка от origin/main, проверки, коммит, push, PR, запись в STATUS.md."
        case .finishSession:
            return "Заверши текущую работу в этой папке по разделу \"Конец сессии\" из ~/Projects/CLAUDE.md: проверки, коммит, push, PR, запись в STATUS.md и шапка. Новых изменений кода не делай. Если незакоммиченные изменения относятся к разным задачам — разнеси их по отдельным веткам и PR."
        }
    }

    /// "Finish session" is about the work already in the project folder, so it never moves to a worktree.
    var canUseWorktree: Bool {
        self != .finishSession
    }

    /// Text the worktree and branch name are derived from: the task itself, or the first Next item.
    func nameSource(nextItems: [String]) -> String {
        switch self {
        case let .customTask(task): task
        case .nextStep: nextItems.first ?? "next step"
        case .finishSession: "finish session"
        }
    }
}

enum ShellQuote {
    /// Quotes a word for zsh/bash with ANSI-C quoting (`$'…'`), so quotes, backslashes and newlines
    /// survive without a literal line break in the typed command (Terminal's `do script` types it as input).
    static func quote(_ word: String) -> String {
        var out = "$'"
        for scalar in word.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\x%02X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "'"
    }

    /// `cd <folder> && <claude> <prompt>` — the line typed into the new Terminal window.
    static func claudeCommandLine(folder: String, claude: String, prompt: String) -> String {
        "cd \(quote(folder)) && \(quote(claude)) \(quote(prompt))"
    }
}

/// Worktree folder and branch names for a parallel session: `.claude/worktrees/cb-<slug>`, branch `claude/<slug>`.
struct WorktreePlan: Equatable, Sendable {
    var slug: String
    var path: String
    var branch: String

    static let maxSlugLength = 32

    /// Short ASCII slug: transliterated, lowercased, words joined with `-`.
    static func slug(from text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? text
        var words: [String] = []
        var length = 0
        for word in latin.lowercased().split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }) {
            let next = length + word.count + (words.isEmpty ? 0 : 1)
            if next > maxSlugLength { break }
            words.append(String(word))
            length = next
        }
        if words.isEmpty, let first = latin.lowercased().split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).first {
            words = [String(first.prefix(maxSlugLength))]
        }
        return words.isEmpty ? "task" : words.joined(separator: "-")
    }

    /// Picks a name that is not taken yet, adding `-2`, `-3`, … when needed.
    static func make(projectPath: String, from text: String, isTaken: (String, String) -> Bool) -> WorktreePlan {
        let base = slug(from: text)
        var candidate = base
        var counter = 2
        while true {
            let path = (projectPath as NSString).appendingPathComponent(".claude/worktrees/cb-\(candidate)")
            let branch = "claude/\(candidate)"
            if !isTaken(path, branch) {
                return WorktreePlan(slug: candidate, path: path, branch: branch)
            }
            candidate = "\(base)-\(counter)"
            counter += 1
        }
    }
}

/// «Свои промпты»: a reusable task with {проект}, {ветка}, {файл} filled in when it's run from the search (⌃⌥C).
struct SavedPrompt: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var title: String
    var text: String

    /// Russian and English names of the same placeholder.
    static let placeholders: [(names: [String], key: String)] = [
        (["{проект}", "{project}"], "project"), (["{ветка}", "{branch}"], "branch"), (["{файл}", "{file}"], "file"),
    ]

    var needsFile: Bool { Self.placeholders[2].names.contains { text.contains($0) } }

    func filled(project: String, branch: String?, file: String?) -> String {
        let values = ["project": project, "branch": branch ?? "", "file": file ?? ""]
        var result = text
        for (names, key) in Self.placeholders {
            for name in names { result = result.replacingOccurrences(of: name, with: values[key] ?? "") }
        }
        return result
    }

    static var examples: [SavedPrompt] {
        [
            SavedPrompt(title: String(localized: "Ревью ветки"),
                        text: String(localized: "Проверь изменения ветки {ветка} в {проект} относительно основной: ошибки, лишнее, чего не хватает в тестах. Ничего не меняй, только список.")),
            SavedPrompt(title: String(localized: "Объясни файл"),
                        text: String(localized: "Объясни, что делает {файл} и где он используется в {проект}. Коротко, по-русски.")),
        ]
    }
}
