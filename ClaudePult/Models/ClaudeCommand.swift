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
        case .nextStep: "Следующий шаг"
        case .customTask: "Своя задача"
        case .finishSession: "Завершить сессию"
        }
    }

    var prompt: String { prompt(.oleh) }

    func prompt(_ style: PromptStyle) -> String {
        if style == .generic {
            switch self {
            case .nextStep:
                return "Прочитай README и, если есть, docs/STATUS.md, CLAUDE.md или AGENTS.md. Определи следующий разумный шаг: первый пункт списка «Next / Дальше», если он есть, иначе самую очевидную незаконченную задачу. Сделай его в отдельной ветке от основной: изменения, проверки проекта (тесты, сборка, линтер — что есть), коммит с понятным сообщением, push и pull request. Если шаг требует решения человека или неясен — ничего не меняй, а коротко опиши вопрос."
            case let .customTask(task):
                return "Задача: \(task.trimmingCharacters(in: .whitespacesAndNewlines)). Работай по правилам проекта (CLAUDE.md / AGENTS.md, если они есть): отдельная ветка от основной, проверки проекта, коммит, push, pull request."
            case .finishSession:
                return "Доведи до конца текущую работу в этой папке: прогони проверки проекта, разложи незакоммиченные изменения по смыслу на коммиты (если они относятся к разным задачам — по отдельным веткам), сделай push и pull request. Новых изменений кода не делай."
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
