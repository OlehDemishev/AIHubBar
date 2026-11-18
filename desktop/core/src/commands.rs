//! Commands of a folder project (docs/specs/SPEC-modes.md §3, §11): the profile's templates and «Своя задача», a task
//! with placeholders run by Claude Code on the project or its main file, the result always a new file next to it —
//! never over an existing one. The Mac's `CommandTemplate` and `CommandText`, without the models by API and
//! «Сравнить», which come with «Сервисы AI».

use crate::folders::{self, FolderProject, Key};
use crate::profiles::Profile;
use chrono::{DateTime, Local};
use serde_json::Value;
use std::path::Path;

/// The id of «Своя задача», which every folder profile has and none stores.
pub const CUSTOM_TASK: &str = "custom-task";

#[derive(Debug, Clone, PartialEq)]
pub struct Command {
    pub id: String,
    pub title: String,
    /// With `{проект}`, `{файл}`, `{формат}`, `{площадка}`, `{хронометраж}`, `{язык}`, `{текст}` (or the English names).
    pub task: String,
    /// The result's file name: `хуки.md`, `сценарий-{язык}.md`, `результат-<время>.md`.
    pub output: String,
    /// On the main file (`mainFile`), or on the whole folder (`project`).
    pub on_main_file: bool,
    /// The field shown before running: «Язык», «Тон», «Задача»; None runs at once.
    pub asks: Option<String>,
    /// Who runs it (`claude-code`, `api:openai`); None — the one chosen for the project, else the profile's.
    pub service: Option<String>,
}

impl Command {
    /// Tolerant like the Mac's decoder; None for a non-object.
    pub fn from_value(value: &Value) -> Option<Command> {
        let object = value.as_object()?;
        let text = |key: &str| object.get(key).and_then(Value::as_str).map(str::to_owned);
        Some(Command {
            id: text("id").unwrap_or_else(crate::runs::new_id),
            title: text("title").unwrap_or_else(|| "Команда".into()),
            task: text("task").unwrap_or_default(),
            output: text("output").unwrap_or_else(|| "результат-<время>.md".into()),
            on_main_file: text("input").is_none_or(|input| input != "project"),
            asks: text("asks").filter(|a| !a.trim().is_empty()),
            service: text("service").filter(|s| !s.is_empty()),
        })
    }

    /// «Своя задача»: the person's own words, on the main file. `title` and `asks` in the interface language.
    pub fn custom_task(title: &str, asks: &str) -> Command {
        Command {
            id: CUSTOM_TASK.into(),
            title: title.into(),
            task: "{текст}".into(),
            output: "результат-<время>.md".into(),
            on_main_file: true,
            asks: Some(asks.into()),
            service: None,
        }
    }

    /// The hover hint: the task with its placeholders as «…».
    pub fn hint(&self) -> String {
        static PLACEHOLDER: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
        PLACEHOLDER.get_or_init(|| regex::Regex::new(r"\{[^}]*\}").expect("valid")).replace_all(&self.task, "…").into_owned()
    }
}

/// The profile's commands in order (none of them «Своя задача»).
pub fn of_profile(profile: &Profile) -> Vec<Command> {
    profile.other.get("commands").and_then(Value::as_array).into_iter().flatten().filter_map(Command::from_value).collect()
}

/// What a command runs on, for the placeholders.
#[derive(Debug, Clone, PartialEq)]
pub struct Context {
    pub project: String,
    /// Relative to the project folder.
    pub file: Option<String>,
    pub format: Option<String>,
    pub platform: Option<String>,
    /// «8:16» for the main file at the profile's pace.
    pub duration: Option<String>,
    /// What the person typed into the command's field.
    pub text: Option<String>,
    pub now: DateTime<Local>,
}

impl Context {
    pub fn new(command: &Command, project: &FolderProject, profile: &Profile, text: Option<&str>, now: DateTime<Local>) -> Context {
        let strings = crate::i18n::Strings::from_json("{}");
        Context {
            project: project.name.clone(),
            file: if command.on_main_file { project.main_file.clone() } else { None },
            format: project.card.get(Key::Format).map(str::to_owned),
            platform: project.card.get(Key::Platform).map(str::to_owned),
            duration: folders::metric_text("duration", project, profile.words_per_minute(), &strings, "ru", now),
            text: text.map(str::trim).filter(|t| !t.is_empty()).map(str::to_owned),
            now,
        }
    }
}

fn words(language: &str, key: &str) -> String {
    folders::content_text(language, key)
}

/// The placeholders filled; they work in Russian and English (`{проект}` = `{project}`).
pub fn fill(template: &str, context: &Context, language: &str) -> String {
    let values: [(&[&str], String); 7] = [
        (&["{проект}", "{project}"], context.project.clone()),
        (&["{файл}", "{file}"], context.file.clone().unwrap_or_else(|| "—".into())),
        (&["{формат}", "{format}"], context.format.clone().unwrap_or_else(|| words(language, "notSet"))),
        (&["{площадка}", "{platform}"], context.platform.clone().unwrap_or_else(|| words(language, "notSet"))),
        (&["{хронометраж}", "{duration}"], context.duration.clone().unwrap_or_else(|| words(language, "notCounted"))),
        (&["{язык}", "{language}"], context.text.clone().unwrap_or_default()),
        (&["{текст}", "{text}"], context.text.clone().unwrap_or_default()),
    ];
    let mut result = template.to_owned();
    for (keys, value) in &values {
        for key in *keys {
            result = result.replace(key, value);
        }
    }
    result
}

/// The result's file name: placeholders filled, `<время>` / `<time>` and `<файл>` / `<file>` expanded, characters a
/// file name can't have replaced, `.md` added when there is no extension, and ` (OpenAI)` before the extension in a
/// comparison.
pub fn output_name(pattern: &str, context: &Context, language: &str, suffix: Option<&str>) -> String {
    let file_base = context
        .file
        .as_deref()
        .and_then(|f| Path::new(f).file_stem())
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| words(language, "projectWord"));
    let mut name = fill(pattern, context, language);
    for key in ["<время>", "<time>"] {
        name = name.replace(key, &context.now.format("%Y-%m-%d-%H%M").to_string());
    }
    for key in ["<файл>", "<file>"] {
        name = name.replace(key, &file_base);
    }
    // The Mac replaces `/ : \` and line breaks; Windows refuses `< > " | ? *` as well.
    let mut name: String = name.chars().map(|c| if "/:\\\n\r\t<>\"|?*".contains(c) { '-' } else { c }).collect::<String>().trim().to_owned();
    if name.is_empty() || name.starts_with('.') {
        name = words(language, "resultWord") + &name;
    }
    if Path::new(&name).extension().is_none() {
        name.push_str(".md");
    }
    if let Some(suffix) = suffix {
        let path = Path::new(&name);
        let ext = path.extension().map(|e| e.to_string_lossy().into_owned()).unwrap_or_default();
        let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        name = format!("{stem} ({suffix}).{ext}");
    }
    name
}

/// `name.md`, else `name-2.md`, `name-3.md`…: an existing file is never overwritten.
pub fn unique_name(name: &str, exists: impl Fn(&str) -> bool) -> String {
    if !exists(name) {
        return name.to_owned();
    }
    let path = Path::new(name);
    let base = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = path.extension().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    (2..).map(|n| format!("{base}-{n}.{ext}")).find(|candidate| !exists(candidate)).unwrap_or_default()
}

/// How a run is called in the panel and in notifications: «Другой тон: дружелюбнее».
pub fn run_title(title: &str, text: Option<&str>) -> String {
    match text.filter(|t| !t.is_empty()) {
        Some(text) => format!("{title}: {text}"),
        None => title.to_owned(),
    }
}

/// What Claude is told (docs/TEMPLATES.md): work in the folder, change nothing, write the result to a new file.
/// `file_text`: the source's text when Claude can't read its format itself (an `.rtf` with no shell to convert it).
pub fn agent_prompt(task: &str, context: &Context, output: &str, file_text: Option<&str>, language: &str) -> String {
    let prompt = words(language, "agentPrompt")
        .replace("{project}", &context.project)
        .replace("{file}", &context.file.clone().unwrap_or_else(|| words(language, "agentNoFile")))
        .replace("{output}", output)
        .replace("{task}", task);
    match (file_text, &context.file) {
        (Some(text), Some(file)) => [prompt, String::new(), words(language, "agentFileIntro").replace("{file}", file), "---".into(), text.to_owned(), "---".into()].join("\n"),
        _ => prompt,
    }
}

/// For a model by API (docs/TEMPLATES.md): AI Hub Bar sends the file's text and writes the answer itself.
pub fn api_prompt(task: &str, context: &Context, file_text: Option<&str>, language: &str) -> String {
    let format = context.format.clone().unwrap_or_else(|| words(language, "notSet"));
    let mut lines = vec![words(language, "apiHeader").replace("{project}", &context.project).replace("{format}", &format)];
    if let (Some(text), Some(file)) = (file_text, &context.file) {
        lines.extend([words(language, "apiFileIntro").replace("{file}", file), "---".into(), text.to_owned(), "---".into()]);
    }
    lines.extend([words(language, "apiTask").replace("{task}", task), words(language, "apiRule")]);
    lines.join("\n")
}

/// The source's text to put into the prompt: only for formats Claude can't read with its file tools and no shell
/// (`.rtf`, `.docx`; the Mac's `inlineText`), and not when too long for a command line.
pub fn inline_text(path: &Path) -> Option<String> {
    let formatted = path.extension().is_some_and(|e| e.eq_ignore_ascii_case("rtf") || e.eq_ignore_ascii_case("docx"));
    let text = if formatted { folders::text_of(path)? } else { return None };
    (text.len() <= 24_000).then_some(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use serde_json::json;

    fn context(file: Option<&str>, text: Option<&str>) -> Context {
        Context {
            project: "Ролик".into(),
            file: file.map(str::to_owned),
            format: None,
            platform: Some("YouTube".into()),
            duration: Some("3:00".into()),
            text: text.map(str::to_owned),
            now: Local.with_ymd_and_hms(2026, 11, 18, 9, 5, 0).unwrap(),
        }
    }

    #[test]
    fn templates_read_like_the_macs() {
        let video = crate::profiles::from_template("video", "ru").unwrap();
        let commands = of_profile(&video);
        assert_eq!(commands.len(), 6);
        assert_eq!(commands[0].title, "Хуки");
        let translate = commands.iter().find(|c| c.title == "Перевод").unwrap();
        assert_eq!((translate.asks.as_deref(), translate.output.as_str(), translate.on_main_file), (Some("Язык"), "сценарий-{язык}.md", true));
        let research = crate::profiles::from_template("research", "ru").unwrap();
        assert!(!of_profile(&research).iter().find(|c| c.title == "План работы").unwrap().on_main_file);
        let broken = Command::from_value(&json!({"title": 3, "input": "project", "asks": " "})).unwrap();
        assert_eq!((broken.title.as_str(), broken.on_main_file, broken.asks), ("Команда", false, None));
        assert_eq!(Command::custom_task("Своя задача", "Задача").hint(), "…");
    }

    #[test]
    fn placeholders_and_names() {
        let c = context(Some("тексты/сценарий.md"), Some("английский"));
        assert_eq!(fill("Переведи {файл} на {язык} для {platform}, {формат}, {хронометраж}", &c, "ru"), "Переведи тексты/сценарий.md на английский для YouTube, не указан, 3:00");
        assert_eq!(output_name("сценарий-{язык}.md", &c, "ru", None), "сценарий-английский.md");
        assert_eq!(output_name("результат-<время>", &c, "ru", None), "результат-2026-11-18-0905.md");
        assert_eq!(output_name("конспект-<файл>.md", &c, "ru", None), "конспект-сценарий.md");
        assert_eq!(output_name("конспект-<file>.md", &context(None, None), "en", None), "конспект-project.md");
        assert_eq!(output_name("{текст}.md", &context(None, Some("a/b: c?")), "ru", None), "a-b- c-.md");
        assert_eq!(output_name("{текст}.md", &context(None, None), "ru", None), "результат.md");
        assert_eq!(output_name("хуки.md", &c, "ru", Some("OpenAI")), "хуки (OpenAI).md");
        let taken = ["хуки.md", "хуки-2.md"];
        assert_eq!(unique_name("хуки.md", |n| taken.contains(&n)), "хуки-3.md");
        assert_eq!(unique_name("новое.md", |n| taken.contains(&n)), "новое.md");
        assert_eq!(run_title("Другой тон", Some("дружелюбнее")), "Другой тон: дружелюбнее");
        assert_eq!(run_title("Хуки", None), "Хуки");
    }

    #[test]
    fn prompts() {
        let c = context(Some("сценарий.rtf"), None);
        let prompt = agent_prompt("Найди хуки", &c, "хуки.md", None, "ru");
        assert!(prompt.starts_with("Ты работаешь в папке проекта «Ролик». Исходный файл: сценарий.rtf."));
        assert!(prompt.contains("в новый файл хуки.md") && prompt.ends_with("Задача: Найди хуки"));
        let inlined = agent_prompt("Найди хуки", &c, "хуки.md", Some("текст сценария"), "en");
        assert!(inlined.ends_with("You don't need to open «сценарий.rtf»: its text is right here.\n---\nтекст сценария\n---"));
        assert!(agent_prompt("x", &context(None, None), "y.md", Some("ignored"), "en").contains("none — work with the files of the folder"));
        let api = api_prompt("Найди хуки", &c, Some("текст"), "ru");
        assert_eq!(api.lines().next(), Some("Проект: «Ролик». Формат: не указан."));
        assert!(api.contains("---\nтекст\n---\nЗадача: Найди хуки\n") && api.ends_with("не выдумывай."));
        assert!(!api_prompt("x", &context(None, None), Some("ignored"), "en").contains("---"), "no file, no text");
    }
}
