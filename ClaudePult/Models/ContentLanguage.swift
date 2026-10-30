import Foundation

/// The language of what ClaudePult writes and sends, not only shows: prompts for AI services, new cards and content
/// plans, template texts. It follows the interface language; Russian is the default.
enum ContentLanguage: String, CaseIterable, Sendable {
    case ru, en, es

    static var current: ContentLanguage {
        Bundle.main.preferredLocalizations.first.flatMap { code in allCases.first { code.hasPrefix($0.rawValue) } } ?? .ru
    }

    var strings: ContentStrings {
        switch self {
        case .ru: .russian
        case .en: .english
        case .es: .spanish
        }
    }
}

/// Everything a language needs for files and prompts. `{project}`, `{file}`, `{output}`, `{format}`, `{task}` are
/// filled in by `CommandText`; adding a language is adding one of these.
struct ContentStrings: Sendable {
    var cardFile: String
    var planFile: String
    /// stage, deadline, publish, format, main file, platform — as written into a new card.
    var cardLabels: [ProjectCardFile.Key: String]
    var notesHeading: String
    var planTitle: String
    var planColumns: [ContentPlan.Column: String]
    var ideaStatus: String
    var notSet: String
    var notCounted: String
    var projectWord: String
    var resultWord: String
    var agentPrompt: String
    var agentNoFile: String
    var apiHeader: String
    var apiFileIntro: String
    var apiTask: String
    var apiRule: String
    var nextStep: String
    var customTask: String
    var finishSession: String
    /// How a custom task starts and where the task text ends, to show it as a session title.
    var taskPrefix: String
    var rulesMarker: String

    static let russian = ContentStrings(
        cardFile: "проект.md", planFile: "контент-план.md",
        cardLabels: [.stage: "Этап", .deadline: "Дедлайн", .publish: "Публикация", .format: "Формат", .mainFile: "Главный файл", .platform: "Площадка"],
        notesHeading: "## Заметки", planTitle: "# Контент-план",
        planColumns: [.date: "Дата", .time: "Время", .platform: "Площадка", .topic: "Тема", .status: "Статус", .file: "Файл"],
        ideaStatus: "идея", notSet: "не указан", notCounted: "не посчитан", projectWord: "проект", resultWord: "результат",
        agentPrompt: """
        Ты работаешь в папке проекта «{project}». Исходный файл: {file}. \
        Читай любые файлы этой папки, но ничего в них не меняй. Результат запиши в новый файл {output} в этой же папке. \
        Если задача неясна или данных не хватает — напиши об этом в начале файла результата, не выдумывай.

        Задача: {task}
        """,
        agentNoFile: "нет — работай с файлами папки",
        apiHeader: "Проект: «{project}». Формат: {format}.",
        apiFileIntro: "Ниже — текст файла «{file}».",
        apiTask: "Задача: {task}",
        apiRule: "Ответь только результатом в Markdown, без вступлений и пояснений. Если данных не хватает — скажи об этом первой строкой, не выдумывай.",
        nextStep: "Прочитай README и, если есть, docs/STATUS.md, CLAUDE.md или AGENTS.md. Определи следующий разумный шаг: первый пункт списка «Next / Дальше», если он есть, иначе самую очевидную незаконченную задачу. Сделай его в отдельной ветке от основной: изменения, проверки проекта (тесты, сборка, линтер — что есть), коммит с понятным сообщением, push и pull request. Если шаг требует решения человека или неясен — ничего не меняй, а коротко опиши вопрос.",
        customTask: "Задача: {task}. Работай по правилам проекта (CLAUDE.md / AGENTS.md, если они есть): отдельная ветка от основной, проверки проекта, коммит, push, pull request.",
        finishSession: "Доведи до конца текущую работу в этой папке: прогони проверки проекта, разложи незакоммиченные изменения по смыслу на коммиты (если они относятся к разным задачам — по отдельным веткам), сделай push и pull request. Новых изменений кода не делай.",
        taskPrefix: "Задача: ", rulesMarker: ". Работай по правилам"
    )

    static let english = ContentStrings(
        cardFile: "project.md", planFile: "content-plan.md",
        cardLabels: [.stage: "Stage", .deadline: "Deadline", .publish: "Publish", .format: "Format", .mainFile: "Main file", .platform: "Platform"],
        notesHeading: "## Notes", planTitle: "# Content plan",
        planColumns: [.date: "Date", .time: "Time", .platform: "Platform", .topic: "Topic", .status: "Status", .file: "File"],
        ideaStatus: "idea", notSet: "not set", notCounted: "not counted", projectWord: "project", resultWord: "result",
        agentPrompt: """
        You are working in the folder of the project «{project}». Source file: {file}. \
        Read any files of this folder but change none of them. Write the result to a new file {output} in the same folder. \
        If the task is unclear or data is missing, say so at the top of the result file — do not make things up.

        Task: {task}
        """,
        agentNoFile: "none — work with the files of the folder",
        apiHeader: "Project: «{project}». Format: {format}.",
        apiFileIntro: "Below is the text of the file «{file}».",
        apiTask: "Task: {task}",
        apiRule: "Reply with the result only, in Markdown, without introductions or explanations. If data is missing, say so in the first line — do not make things up.",
        nextStep: "Read the README and, if present, docs/STATUS.md, CLAUDE.md or AGENTS.md. Find the next sensible step: the first item of the «Next» list if there is one, otherwise the most obvious unfinished task. Do it on a separate branch from the main one: the changes, the project's checks (tests, build, linter — whatever exists), a commit with a clear message, push and a pull request. If the step needs a person's decision or is unclear, change nothing and briefly describe the question.",
        customTask: "Task: {task}. Follow the project's rules (CLAUDE.md / AGENTS.md if present): a separate branch from the main one, the project's checks, commit, push, pull request.",
        finishSession: "Finish the current work in this folder: run the project's checks, split uncommitted changes into commits by meaning (onto separate branches if they belong to different tasks), push and open a pull request. Make no new code changes.",
        taskPrefix: "Task: ", rulesMarker: ". Follow the project's rules"
    )

    static let spanish = ContentStrings(
        cardFile: "proyecto.md", planFile: "plan-de-contenido.md",
        cardLabels: [.stage: "Etapa", .deadline: "Fecha límite", .publish: "Publicación", .format: "Formato", .mainFile: "Archivo principal", .platform: "Plataforma"],
        notesHeading: "## Notas", planTitle: "# Plan de contenido",
        planColumns: [.date: "Fecha", .time: "Hora", .platform: "Plataforma", .topic: "Tema", .status: "Estado", .file: "Archivo"],
        ideaStatus: "idea", notSet: "sin indicar", notCounted: "sin calcular", projectWord: "proyecto", resultWord: "resultado",
        agentPrompt: """
        Trabajas en la carpeta del proyecto «{project}». Archivo de origen: {file}. \
        Lee cualquier archivo de esta carpeta, pero no modifiques ninguno. Escribe el resultado en un archivo nuevo {output} en la misma carpeta. \
        Si la tarea no está clara o faltan datos, dilo al principio del archivo de resultado; no inventes nada.

        Tarea: {task}
        """,
        agentNoFile: "ninguno — trabaja con los archivos de la carpeta",
        apiHeader: "Proyecto: «{project}». Formato: {format}.",
        apiFileIntro: "A continuación, el texto del archivo «{file}».",
        apiTask: "Tarea: {task}",
        apiRule: "Responde solo con el resultado en Markdown, sin introducciones ni explicaciones. Si faltan datos, dilo en la primera línea; no inventes nada.",
        nextStep: "Lee el README y, si existen, docs/STATUS.md, CLAUDE.md o AGENTS.md. Determina el siguiente paso razonable: el primer punto de la lista «Next / Siguiente» si existe; si no, la tarea pendiente más evidente. Hazlo en una rama aparte de la principal: los cambios, las comprobaciones del proyecto (tests, build, linter — lo que haya), un commit con un mensaje claro, push y un pull request. Si el paso requiere la decisión de una persona o no está claro, no cambies nada y describe brevemente la pregunta.",
        customTask: "Tarea: {task}. Sigue las reglas del proyecto (CLAUDE.md / AGENTS.md si existen): una rama aparte de la principal, las comprobaciones del proyecto, commit, push, pull request.",
        finishSession: "Termina el trabajo actual en esta carpeta: ejecuta las comprobaciones del proyecto, reparte los cambios sin commit en commits según su sentido (en ramas separadas si pertenecen a tareas distintas), haz push y abre un pull request. No hagas cambios de código nuevos.",
        taskPrefix: "Tarea: ", rulesMarker: ". Sigue las reglas"
    )

    /// `{name}` → value, for the templates above.
    static func fill(_ text: String, _ values: [String: String]) -> String {
        values.reduce(text) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }
}
