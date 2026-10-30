import Foundation

/// A command of a mode (SPEC-modes §3, «Команды»): a task with placeholders, run on a project or one of its files
/// by an AI service, the result going into a new file next to it — never over an existing one.
struct CommandTemplate: Codable, Identifiable, Equatable, Hashable, Sendable {
    enum Input: String, Codable, CaseIterable, Sendable {
        /// The project's main file (or the whole folder for an agent).
        case mainFile
        /// The project folder only; nothing is sent as file text.
        case project

        var title: String {
            switch self {
            case .mainFile: String(localized: "Главный файл")
            case .project: String(localized: "Весь проект")
            }
        }
    }

    var id: String
    var title: String
    /// The task with `{проект}`, `{файл}`, `{формат}`, `{площадка}`, `{хронометраж}`, `{язык}`, `{текст}`.
    var task: String
    /// Result file name, e.g. `хуки.md`, `сценарий-{язык}.md`, `результат-<время>.md`.
    var output: String
    var input: Input
    /// The field shown before running: «Язык», «Тон», «Задача»; nil = runs at once.
    var asks: String?
    /// `AIService.id`; nil = the mode's service.
    var service: String?

    init(id: String = UUID().uuidString.lowercased(), title: String, task: String, output: String,
         input: Input = .mainFile, asks: String? = nil, service: String? = nil) {
        self.id = id
        self.title = title
        self.task = task
        self.output = output
        self.input = input
        self.asks = asks
        self.service = service
    }

    enum CodingKeys: String, CodingKey { case id, title, task, output, input, asks, service }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString.lowercased()
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? String(localized: "Команда")
        task = (try? c.decodeIfPresent(String.self, forKey: .task)) ?? ""
        output = (try? c.decodeIfPresent(String.self, forKey: .output)) ?? "результат-<время>.md"
        input = (try? c.decodeIfPresent(Input.self, forKey: .input)) ?? .mainFile
        asks = try? c.decodeIfPresent(String.self, forKey: .asks)
        service = try? c.decodeIfPresent(String.self, forKey: .service)
    }

    /// Always available in a folder mode, not stored in the mode.
    static let customTask = CommandTemplate(
        id: "custom-task", title: String(localized: "Своя задача"), task: "{текст}", output: "результат-<время>.md",
        asks: String(localized: "Задача")
    )
}

/// What a command is run on, for the placeholders.
struct CommandContext: Equatable, Sendable {
    var projectName: String
    var projectPath: String
    /// Relative to the project folder.
    var file: String?
    var format: String?
    var platform: String?
    var duration: String?
    /// What the person typed into the command's field.
    var text: String?
    var now: Date = .now
}

/// Pure text work of the command engine: placeholders, file names, and the wrappers from docs/TEMPLATES.md.
/// Placeholders work in Russian and English (`{проект}` = `{project}`, `<время>` = `<time>`); the wrappers follow the
/// content language.
enum CommandText {
    static func fill(_ template: String, _ context: CommandContext, language: ContentLanguage = .current) -> String {
        let en = language == .en
        let values: [(keys: [String], value: String)] = [
            (["{проект}", "{project}"], context.projectName),
            (["{файл}", "{file}"], context.file ?? "—"),
            (["{формат}", "{format}"], context.format ?? (en ? "not set" : "не указан")),
            (["{площадка}", "{platform}"], context.platform ?? (en ? "not set" : "не указана")),
            (["{хронометраж}", "{duration}"], context.duration ?? (en ? "not counted" : "не посчитан")),
            (["{язык}", "{language}"], context.text ?? ""),
            (["{текст}", "{text}"], context.text ?? ""),
        ]
        var result = template
        for (keys, value) in values {
            for key in keys { result = result.replacingOccurrences(of: key, with: value) }
        }
        return result
    }

    /// The result file name: placeholders filled, `<время>`/`<time>` and `<файл>`/`<file>` expanded, unsafe characters
    /// replaced, `.md` added when there is no extension, and ` (Claude)` before the extension in a comparison.
    static func outputName(_ pattern: String, _ context: CommandContext, suffix: String? = nil, language: ContentLanguage = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let en = language == .en
        let fileBase = context.file.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? (en ? "project" : "проект")
        var name = fill(pattern, context, language: language)
        for key in ["<время>", "<time>"] { name = name.replacingOccurrences(of: key, with: formatter.string(from: context.now)) }
        for key in ["<файл>", "<file>"] { name = name.replacingOccurrences(of: key, with: fileBase) }
        name = name.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.hasPrefix(".") { name = (en ? "result" : "результат") + name }
        if (name as NSString).pathExtension.isEmpty { name += ".md" }
        if let suffix {
            let ext = (name as NSString).pathExtension
            name = (name as NSString).deletingPathExtension + " (\(suffix)).\(ext)"
        }
        return name
    }

    /// `name.md`, else `name-2.md`, `name-3.md` … — an existing file is never overwritten.
    static func uniqueName(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while exists("\(base)-\(counter).\(ext)") { counter += 1 }
        return "\(base)-\(counter).\(ext)"
    }

    /// For an agent working in the folder (docs/TEMPLATES.md).
    static func agentPrompt(task: String, context: CommandContext, output: String, language: ContentLanguage = .current) -> String {
        if language == .en {
            return """
            You are working in the folder of the project «\(context.projectName)». Source file: \(context.file ?? "none — work with the files of the folder"). \
            Read any files of this folder but change none of them. Write the result to a new file \(output) in the same folder. \
            If the task is unclear or data is missing, say so at the top of the result file — do not make things up.

            Task: \(task)
            """
        }
        return """
        Ты работаешь в папке проекта «\(context.projectName)». Исходный файл: \(context.file ?? "нет — работай с файлами папки"). \
        Читай любые файлы этой папки, но ничего в них не меняй. Результат запиши в новый файл \(output) в этой же папке. \
        Если задача неясна или данных не хватает — напиши об этом в начале файла результата, не выдумывай.

        Задача: \(task)
        """
    }

    /// For a model by API: ClaudePult sends the file text and writes the answer itself (docs/TEMPLATES.md).
    static func apiPrompt(task: String, context: CommandContext, fileText: String?, language: ContentLanguage = .current) -> String {
        if language == .en {
            var lines = ["Project: «\(context.projectName)». Format: \(context.format ?? "not set")."]
            if let fileText, let file = context.file {
                lines += ["Below is the text of the file «\(file)».", "---", fileText, "---"]
            }
            lines += [
                "Task: \(task)",
                "Reply with the result only, in Markdown, without introductions or explanations. If data is missing, say so in the first line — do not make things up.",
            ]
            return lines.joined(separator: "\n")
        }
        var lines = ["Проект: «\(context.projectName)». Формат: \(context.format ?? "не указан")."]
        if let fileText, let file = context.file {
            lines += ["Ниже — текст файла «\(file)».", "---", fileText, "---"]
        }
        lines += [
            "Задача: \(task)",
            "Ответь только результатом в Markdown, без вступлений и пояснений. Если данных не хватает — скажи об этом первой строкой, не выдумывай.",
        ]
        return lines.joined(separator: "\n")
    }
}
