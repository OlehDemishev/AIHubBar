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
            case .mainFile: "Главный файл"
            case .project: "Весь проект"
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
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Команда"
        task = (try? c.decodeIfPresent(String.self, forKey: .task)) ?? ""
        output = (try? c.decodeIfPresent(String.self, forKey: .output)) ?? "результат-<время>.md"
        input = (try? c.decodeIfPresent(Input.self, forKey: .input)) ?? .mainFile
        asks = try? c.decodeIfPresent(String.self, forKey: .asks)
        service = try? c.decodeIfPresent(String.self, forKey: .service)
    }

    /// Always available in a folder mode, not stored in the mode.
    static let customTask = CommandTemplate(
        id: "custom-task", title: "Своя задача", task: "{текст}", output: "результат-<время>.md", asks: "Задача"
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
enum CommandText {
    static func fill(_ template: String, _ context: CommandContext) -> String {
        let values: [String: String] = [
            "{проект}": context.projectName,
            "{файл}": context.file ?? "—",
            "{формат}": context.format ?? "не указан",
            "{площадка}": context.platform ?? "не указана",
            "{хронометраж}": context.duration ?? "не посчитан",
            "{язык}": context.text ?? "",
            "{текст}": context.text ?? "",
        ]
        return values.reduce(template) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }

    /// The result file name: placeholders filled, `<время>` and `<файл>` expanded, unsafe characters replaced,
    /// `.md` added when there is no extension, and ` (Claude)` before the extension in a comparison.
    static func outputName(_ pattern: String, _ context: CommandContext, suffix: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let fileBase = context.file.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "проект"
        var name = fill(pattern, context)
            .replacingOccurrences(of: "<время>", with: formatter.string(from: context.now))
            .replacingOccurrences(of: "<файл>", with: fileBase)
        name = name.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.hasPrefix(".") { name = "результат" + name }
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
    static func agentPrompt(task: String, context: CommandContext, output: String) -> String {
        """
        Ты работаешь в папке проекта «\(context.projectName)». Исходный файл: \(context.file ?? "нет — работай с файлами папки"). \
        Читай любые файлы этой папки, но ничего в них не меняй. Результат запиши в новый файл \(output) в этой же папке. \
        Если задача неясна или данных не хватает — напиши об этом в начале файла результата, не выдумывай.

        Задача: \(task)
        """
    }

    /// For a model by API: ClaudePult sends the file text and writes the answer itself (docs/TEMPLATES.md).
    static func apiPrompt(task: String, context: CommandContext, fileText: String?) -> String {
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
