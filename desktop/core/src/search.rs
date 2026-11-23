//! The panel's search (the Mac's `PanelSearch`): sessions, projects and quick commands by name, the first match
//! on Enter.

use serde::{Deserialize, Serialize};

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

/// Sessions first, then projects, then quick commands; a query typed on the wrong layout («ыгкм» for «surv»)
/// counts too. Nothing for an empty query.
pub fn results(query: &str, sessions: &[Item], projects: &[Item], quick_commands: &[Item]) -> Vec<Found> {
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
        let kinds = |query: &str| results(query, &sessions, &projects, &quick).iter().map(|f| (f.kind, f.id.clone())).collect::<Vec<_>>();
        assert!(kinds("  ").is_empty());
        assert_eq!(kinds("surv"), [(Kind::Session, "s1".into()), (Kind::Project, "C:\\p\\Survey".into()), (Kind::QuickCommand, "q1".into())]);
        assert_eq!(kinds("ыгкм"), kinds("surv"), "typed on the Russian layout");
        assert_eq!(kinds("КОРЗИН"), [(Kind::Session, "s1".into())], "a session by its task, any case");
        assert_eq!(kinds("cart"), [(Kind::Project, "C:\\p\\Survey".into())], "a project by its branch");
        assert_eq!(kinds("npm"), [(Kind::QuickCommand, "q1".into())]);
        assert!(kinds("нет такого").is_empty());
        assert_eq!(results("npm", &sessions, &projects, &quick)[0].detail, "", "a quick command's own text is not its detail");

        let many: Vec<Item> = (0..30).map(|n| item(&n.to_string(), &format!("проект {n}"), "")).collect();
        assert_eq!(results("проект", &[], &many, &[]).len(), LIMIT);
    }
}
