//! The panel's search (the Mac's `PanelSearch`): sessions, projects and quick commands by name, the first match
//! on Enter.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::i18n::Strings;

/// «Свои промпты» (the Mac's `SavedPrompt`): a task kept for reuse, with {проект} and {ветка} filled in when it is
/// started from the search.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SavedPrompt {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub text: String,
}

/// Russian and English names of the same placeholder.
const PLACEHOLDERS: [([&str; 2], usize); 3] = [(["{проект}", "{project}"], 0), (["{ветка}", "{branch}"], 1), (["{файл}", "{file}"], 2)];

impl SavedPrompt {
    pub fn filled(&self, project: &str, branch: Option<&str>, file: Option<&str>) -> String {
        let values = [project, branch.unwrap_or(""), file.unwrap_or("")];
        let mut result = self.text.clone();
        for (names, value) in PLACEHOLDERS {
            for name in names {
                result = result.replace(name, values[value]);
            }
        }
        result
    }

    /// The two the Mac starts with.
    pub fn examples(s: &Strings) -> Vec<SavedPrompt> {
        vec![
            SavedPrompt { id: "review-branch".into(), title: s.t("Ревью ветки").to_owned(), text: s.t("Проверь изменения ветки {ветка} в {проект} относительно основной: ошибки, лишнее, чего не хватает в тестах. Ничего не меняй, только список.").to_owned() },
            SavedPrompt { id: "explain-file".into(), title: s.t("Объясни файл").to_owned(), text: s.t("Объясни, что делает {файл} и где он используется в {проект}. Коротко, по-русски.").to_owned() },
        ]
    }
}

/// The kept list from `settings.json`; None when there is none yet (the examples show then). Every prompt gets its
/// own id.
pub fn saved_prompts(value: Option<&Value>) -> Option<Vec<SavedPrompt>> {
    let list = value?.as_array()?;
    let mut seen = std::collections::HashSet::new();
    Some(
        list.iter()
            .filter_map(|v| serde_json::from_value::<SavedPrompt>(v.clone()).ok())
            .map(|mut prompt| {
                if prompt.id.is_empty() || !seen.insert(prompt.id.clone()) {
                    prompt.id = crate::runs::new_id();
                    seen.insert(prompt.id.clone());
                }
                prompt
            })
            .collect(),
    )
}

/// What can be found: a session (its project and task), a project (its branch), a quick command.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Item {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub detail: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Session,
    Prompt,
    Project,
    QuickCommand,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    pub kind: Kind,
    pub id: String,
    pub title: String,
    pub detail: String,
}

pub const LIMIT: usize = 12;

/// Step two of a saved prompt: the projects to start it in, all of them until something is typed; by name only.
pub fn prompt_projects(query: &str, projects: &[Item]) -> Vec<Item> {
    let query = query.trim().to_lowercase();
    let queries = [query.clone(), swapped_layout(&query)];
    projects.iter().filter(|project| query.is_empty() || queries.iter().any(|q| project.name.to_lowercase().contains(q))).take(LIMIT).cloned().collect()
}

const LATIN: &str = "qwertyuiop[]asdfghjkl;'zxcvbnm,.`";
const CYRILLIC: &str = "йцукенгшщзхъфывапролджэячсмитьбюё";

/// The same keys on the other layout: Russian ЙЦУКЕН ↔ QWERTY.
pub fn swapped_layout(text: &str) -> String {
    let latin: Vec<char> = LATIN.chars().collect();
    let cyrillic: Vec<char> = CYRILLIC.chars().collect();
    text.to_lowercase()
        .chars()
        .map(|c| {
            if let Some(index) = latin.iter().position(|l| *l == c) {
                cyrillic[index]
            } else if let Some(index) = cyrillic.iter().position(|l| *l == c) {
                latin[index]
            } else {
                c
            }
        })
        .collect()
}

/// Sessions first, then saved prompts, projects and quick commands; a query typed on the wrong layout («ыгкм» for «surv»)
/// counts too. Nothing for an empty query.
pub fn results(query: &str, sessions: &[Item], prompts: &[Item], projects: &[Item], quick_commands: &[Item]) -> Vec<Found> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return Vec::new();
    }
    let queries = [query.clone(), swapped_layout(&query)];
    let matches = |item: &&Item| queries.iter().any(|q| item.name.to_lowercase().contains(q) || item.detail.to_lowercase().contains(q));
    let found = |kind: Kind, with_detail: bool| move |item: &Item| Found { kind, id: item.id.clone(), title: item.name.clone(), detail: if with_detail { item.detail.clone() } else { String::new() } };
    sessions
        .iter()
        .filter(matches)
        .map(found(Kind::Session, true))
        .chain(prompts.iter().filter(matches).map(found(Kind::Prompt, false)))
        .chain(projects.iter().filter(matches).map(found(Kind::Project, true)))
        .chain(quick_commands.iter().filter(matches).map(found(Kind::QuickCommand, false)))
        .take(LIMIT)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, name: &str, detail: &str) -> Item {
        Item { id: id.into(), name: name.into(), detail: detail.into() }
    }

    #[test]
    fn the_other_layout() {
        assert_eq!(swapped_layout("ыгкм"), "surv");
        assert_eq!(swapped_layout("Surv"), "ыгкм");
        assert_eq!(swapped_layout("a1 б-2"), "ф1 ,-2");
    }

    #[test]
    fn what_is_found() {
        let sessions = [item("s1", "Survey", "почини корзину"), item("s2", "blog", "напиши пост")];
        let projects = [item("C:\\p\\Survey", "Survey", "feat/cart"), item("C:\\p\\blog", "blog", "")];
        let quick = [item("q1", "Сборка survey", "npm run build")];
        let prompts = [item("m1", "Ревью ветки", "Проверь изменения в survey")];
        let kinds = |query: &str| results(query, &sessions, &prompts, &projects, &quick).iter().map(|f| (f.kind, f.id.clone())).collect::<Vec<_>>();
        assert!(kinds("  ").is_empty());
        assert_eq!(kinds("surv"), [(Kind::Session, "s1".into()), (Kind::Prompt, "m1".into()), (Kind::Project, "C:\\p\\Survey".into()), (Kind::QuickCommand, "q1".into())]);
        assert_eq!(kinds("ыгкм"), kinds("surv"), "typed on the Russian layout");
        assert_eq!(kinds("КОРЗИН"), [(Kind::Session, "s1".into())], "a session by its task, any case");
        assert_eq!(kinds("cart"), [(Kind::Project, "C:\\p\\Survey".into())], "a project by its branch");
        assert_eq!(kinds("npm"), [(Kind::QuickCommand, "q1".into())]);
        assert!(kinds("нет такого").is_empty());
        assert_eq!(kinds("ревью"), [(Kind::Prompt, "m1".into())]);
        assert_eq!(results("npm", &sessions, &prompts, &projects, &quick)[0].detail, "", "a quick command's own text is not its detail");

        let many: Vec<Item> = (0..30).map(|n| item(&n.to_string(), &format!("проект {n}"), "")).collect();
        assert_eq!(results("проект", &[], &[], &many, &[]).len(), LIMIT);
        assert_eq!(prompt_projects("", &projects).len(), 2, "all until something is typed");
        assert_eq!(prompt_projects("идщп", &projects), [projects[1].clone()], "the other layout");
        assert!(prompt_projects("cart", &projects).is_empty(), "by name only");
    }

    #[test]
    fn saved_prompts_filled_and_kept() {
        let prompt = SavedPrompt { id: "a".into(), title: "Ревью".into(), text: "Проверь {ветка} в {проект}, {project}/{branch}: {файл}{file}.".into() };
        assert_eq!(prompt.filled("shop", Some("feat/cart"), None), "Проверь feat/cart в shop, shop/feat/cart: .");
        assert_eq!(prompt.filled("shop", None, Some("a.rs")), "Проверь  в shop, shop/: a.rsa.rs.");
        let examples = SavedPrompt::examples(&Strings::default());
        assert_eq!((examples.len(), examples[0].title.as_str()), (2, "Ревью ветки"));
        assert!(examples[0].text.contains("{ветка}") && examples[0].id != examples[1].id);

        assert_eq!(saved_prompts(None), None);
        assert_eq!(saved_prompts(Some(&serde_json::json!([]))), Some(Vec::new()), "an emptied list stays empty");
        let kept = saved_prompts(Some(&serde_json::json!([{"id": "x", "title": "A", "text": "a"}, {"id": "x", "title": "B"}, {"title": "C", "text": "c"}, 5]))).unwrap();
        assert_eq!(kept.len(), 3);
        assert_eq!((kept[0].id.as_str(), kept[1].text.as_str()), ("x", ""));
        assert!(kept[1].id != "x" && !kept[2].id.is_empty() && kept[1].id != kept[2].id);
    }
}
