//! Batch tasks: one command over several folder projects, one project after another (the Mac's `Batch` and
//! `BatchRunner`, SPEC-content §5): «описания для 10 роликов» now, at night or after the limit resets. Kept in
//! `batches.json` in the Mac's format, so a batch left for the night survives a restart. The app starts the runs; this
//! file decides what runs next and what a batch says.

use crate::i18n::Strings;
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum When {
    Now,
    Night,
    AfterReset,
}

impl When {
    pub fn parse(text: &str) -> Option<When> {
        match text {
            "now" => Some(When::Now),
            "night" => Some(When::Night),
            "afterReset" => Some(When::AfterReset),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum State {
    #[default]
    Waiting,
    Running,
    Done,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub project_path: String,
    pub name: String,
    #[serde(default)]
    pub state: State,
    /// The file the command writes, known once it started.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result_file: Option<String>,
    /// Why it failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// Windows only: the panel's job for the run (the Mac ignores the field).
    #[serde(default, rename = "jobID", skip_serializing_if = "Option::is_none")]
    pub job_id: Option<String>,
}

impl Item {
    pub fn new(project_path: &str, name: &str) -> Item {
        Item { project_path: project_path.into(), name: name.into(), state: State::Waiting, result_file: None, note: None, job_id: None }
    }

    pub fn is_finished(&self) -> bool {
        matches!(self.state, State::Done | State::Failed)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Batch {
    pub id: String,
    /// The profile's command as the Mac's `CommandTemplate` writes it.
    pub template: Value,
    #[serde(rename = "profileID")]
    pub profile_id: String,
    /// `claude-code`, `api:openai`.
    #[serde(rename = "serviceID")]
    pub service_id: String,
    /// What the command asks for («Тон»), asked once for the whole batch.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    pub when: When,
    /// Swift's `.iso8601`: whole seconds, `Z`.
    #[serde(with = "iso8601")]
    pub start_at: DateTime<Utc>,
    pub items: Vec<Item>,
    /// The summary went out.
    #[serde(default)]
    pub announced: bool,
}

/// What became of a running project's command.
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    Running,
    Done,
    Failed(String),
    /// Nothing knows about it any more (the app was closed while a model by API was working).
    Lost,
}

impl Batch {
    pub fn title(&self) -> String {
        self.template.get("title").and_then(Value::as_str).unwrap_or("Команда").to_owned()
    }

    pub fn command_id(&self) -> Option<&str> {
        self.template.get("id").and_then(Value::as_str)
    }

    pub fn is_finished(&self) -> bool {
        self.items.iter().all(Item::is_finished)
    }

    pub fn finished_count(&self) -> usize {
        self.items.iter().filter(|i| i.is_finished()).count()
    }

    pub fn done_count(&self) -> usize {
        self.items.iter().filter(|i| i.state == State::Done).count()
    }

    pub fn running_index(&self) -> Option<usize> {
        self.items.iter().position(|i| i.state == State::Running)
    }

    pub fn next_index(&self) -> Option<usize> {
        self.items.iter().position(|i| i.state == State::Waiting)
    }

    /// Near a limit only Claude Code's runs wait: a model by API has its own budget.
    pub fn waits_for_limit(&self) -> bool {
        self.service_id == "claude-code"
    }

    /// «готово: 3 из 10», «начнётся в 01:00, проектов: 10», «3 из 10». `time` formats the start in the computer's time.
    pub fn status(&self, texts: &Strings, now: DateTime<Utc>, time: impl Fn(DateTime<Utc>) -> String) -> String {
        let (done, count) = (self.done_count().to_string(), self.items.len().to_string());
        if self.is_finished() {
            return if self.done_count() == self.items.len() {
                texts.format("готово: %lld из %lld", &[&done, &count])
            } else {
                let failed = (self.items.len() - self.done_count()).to_string();
                texts.format("готово: %lld из %lld, не получилось: %lld", &[&done, &count, &failed])
            };
        }
        if self.start_at > now && self.finished_count() == 0 && self.running_index().is_none() {
            return texts.format("начнётся в %@, проектов: %lld", &[&time(self.start_at), &count]);
        }
        texts.format("%lld из %lld", &[&self.finished_count().to_string(), &count])
    }

    /// One notification for the whole batch: the title and a line per project.
    pub fn summary(&self, texts: &Strings) -> (String, String) {
        let failed = (self.items.len() - self.done_count()).to_string();
        let title = texts.format("Пакет «%@»: ✅ %lld, ❌ %lld", &[&self.title(), &self.done_count().to_string(), &failed]);
        let body = self
            .items
            .iter()
            .map(|item| match (&item.state, &item.note) {
                (State::Done, _) => format!("✅ {}", item.name),
                (_, Some(note)) => format!("❌ {}: {note}", item.name),
                _ => format!("❌ {}", item.name),
            })
            .collect::<Vec<_>>()
            .join("\n");
        (title, body)
    }

    /// The running project's command finished, or was lost with a restart.
    pub fn settle(&mut self, outcome: impl Fn(&Item) -> Outcome, interrupted: &str) {
        let Some(index) = self.running_index() else { return };
        let item = &mut self.items[index];
        if item.result_file.is_none() {
            item.state = State::Failed;
            return;
        }
        match outcome(item) {
            Outcome::Running => {}
            Outcome::Done => item.state = State::Done,
            Outcome::Failed(message) => {
                item.state = State::Failed;
                item.note = Some(message);
            }
            Outcome::Lost => {
                let exists = item.result_file.as_deref().is_some_and(|f| Path::new(f).exists());
                item.state = if exists { State::Done } else { State::Failed };
                if !exists {
                    item.note = Some(interrupted.to_owned());
                }
            }
        }
    }

    pub fn fail(&mut self, index: usize, note: &str) {
        self.items[index].state = State::Failed;
        self.items[index].note = Some(note.to_owned());
    }
}

/// The batch whose next project starts now: none while any project runs (one at a time over all batches), and a
/// batch that waits for Claude's limit does not hold the ones behind it.
pub fn next_to_start(batches: &[Batch], now: DateTime<Utc>, held: bool) -> Option<usize> {
    if batches.iter().any(|b| b.running_index().is_some()) {
        return None;
    }
    batches.iter().position(|b| !b.is_finished() && b.start_at <= now && !(b.waits_for_limit() && held))
}

/// «Отменить»: what has not started is dropped; the project being worked on finishes. A batch left with nothing goes.
pub fn cancel(batches: &mut Vec<Batch>, id: &str) {
    if let Some(index) = batches.iter().position(|b| b.id == id) {
        batches[index].items.retain(|i| i.state != State::Waiting);
        if batches[index].items.is_empty() {
            batches.remove(index);
        }
    }
}

/// «Убрать»: a finished batch leaves the list.
pub fn dismiss(batches: &mut Vec<Batch>, id: &str) {
    batches.retain(|b| !(b.id == id && b.is_finished()));
}

/// Finished batches older than a day are not read back.
pub fn load(path: &Path, now: DateTime<Utc>) -> Vec<Batch> {
    let Ok(text) = std::fs::read_to_string(path) else { return Vec::new() };
    let batches: Vec<Batch> = serde_json::from_str(&text).unwrap_or_default();
    batches.into_iter().filter(|b| !(b.is_finished() && now - b.start_at > Duration::days(1))).collect()
}

pub fn save(path: &Path, batches: &[Batch]) -> std::io::Result<()> {
    if let Some(folder) = path.parent() {
        std::fs::create_dir_all(folder)?;
    }
    let text = serde_json::to_string_pretty(batches).map_err(std::io::Error::other)?;
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, text)?;
    std::fs::rename(&temporary, path)
}

mod iso8601 {
    use chrono::{DateTime, SecondsFormat, Utc};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(date: &DateTime<Utc>, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&date.to_rfc3339_opts(SecondsFormat::Secs, true))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<DateTime<Utc>, D::Error> {
        let text = String::deserialize(deserializer)?;
        DateTime::parse_from_rfc3339(&text).map(|d| d.with_timezone(&Utc)).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn texts() -> Strings {
        Strings::from_json("{}")
    }

    fn batch(service: &str, start: DateTime<Utc>, states: &[State]) -> Batch {
        Batch {
            id: format!("b-{service}-{}", states.len()),
            template: serde_json::json!({"id": "hooks", "title": "Хуки", "task": "Хуки для {проект}", "output": "хуки.md"}),
            profile_id: "texts".into(),
            service_id: service.into(),
            text: None,
            when: When::Now,
            start_at: start,
            items: states
                .iter()
                .enumerate()
                .map(|(n, s)| Item { state: *s, ..Item::new(&format!("C:\\p{n}"), &format!("Проект {n}")) })
                .collect(),
            announced: false,
        }
    }

    #[test]
    fn reads_and_writes_the_macs_file() {
        let mac = r#"[{"announced":false,"id":"A1","items":[{"name":"Кофе","projectPath":"/Users/o/Кофе","state":"waiting"},
            {"name":"Чай","note":"папки больше нет","projectPath":"/Users/o/Чай","state":"failed"}],
            "profileID":"texts","serviceID":"api:openai","startAt":"2026-11-25T22:00:00Z","template":{"id":"x","title":"Редактура","task":"t","output":"o.md"},
            "text":"мягко","when":"night"}]"#;
        let batches: Vec<Batch> = serde_json::from_str(mac).unwrap();
        let b = &batches[0];
        assert_eq!((b.when, b.title(), b.text.as_deref(), b.items[1].state), (When::Night, "Редактура".to_owned(), Some("мягко"), State::Failed));
        let written = serde_json::to_value(&batches).unwrap();
        assert_eq!(written[0]["startAt"], "2026-11-25T22:00:00Z");
        assert_eq!(written[0]["profileID"], "texts");
        assert!(written[0]["items"][0].get("resultFile").is_none());
        assert_eq!(written, serde_json::from_str::<Value>(mac).unwrap());
    }

    #[test]
    fn one_project_at_a_time_and_the_limit_holds_only_claude() {
        let now = Utc.with_ymd_and_hms(2026, 11, 25, 12, 0, 0).unwrap();
        let claude = batch("claude-code", now, &[State::Waiting, State::Waiting]);
        let api = batch("api:openai", now, &[State::Waiting]);
        let later = batch("api:openai", now + Duration::hours(3), &[State::Waiting]);
        assert_eq!(next_to_start(&[claude.clone(), api.clone()], now, false), Some(0));
        assert_eq!(next_to_start(&[claude.clone(), api.clone()], now, true), Some(1));
        assert_eq!(next_to_start(&[later.clone()], now, false), None);
        let mut running = claude.clone();
        running.items[0].state = State::Running;
        assert_eq!(next_to_start(&[running, api], now, false), None);
    }

    #[test]
    fn settles_says_and_sums_up() {
        let now = Utc.with_ymd_and_hms(2026, 11, 25, 12, 0, 0).unwrap();
        let texts = texts();
        let mut b = batch("claude-code", now + Duration::hours(10), &[State::Waiting, State::Waiting, State::Waiting]);
        assert_eq!(b.status(&texts, now, |_| "22:00".into()), "начнётся в 22:00, проектов: 3");
        b.start_at = now;
        b.items[0].state = State::Running;
        b.items[0].result_file = Some("C:\\nowhere\\хуки.md".into());
        b.settle(|_| Outcome::Running, "прервано");
        assert_eq!(b.status(&texts, now, |_| String::new()), "0 из 3");
        b.settle(|_| Outcome::Done, "прервано");
        assert_eq!(b.items[0].state, State::Done);
        b.items[1].state = State::Running;
        b.items[1].result_file = Some("C:\\nowhere\\хуки.md".into());
        b.settle(|_| Outcome::Lost, "прервано: приложение было закрыто");
        assert_eq!((b.items[1].state, b.items[1].note.as_deref()), (State::Failed, Some("прервано: приложение было закрыто")));
        let id = b.id.clone();
        let mut list = vec![b];
        cancel(&mut list, &id);
        let b = &list[0];
        assert_eq!(b.items.len(), 2);
        assert_eq!(b.status(&texts, now, |_| String::new()), "готово: 1 из 2, не получилось: 1");
        let (title, body) = b.summary(&texts);
        assert_eq!(title, "Пакет «Хуки»: ✅ 1, ❌ 1");
        assert_eq!(body, "✅ Проект 0\n❌ Проект 1: прервано: приложение было закрыто");
        dismiss(&mut list, &id);
        assert!(list.is_empty());
    }

    #[test]
    fn old_finished_batches_are_not_read_back() {
        let folder = std::env::temp_dir().join(format!("claudepult-batches-{}", crate::runs::new_id()));
        let path = folder.join("batches.json");
        let now = Utc.with_ymd_and_hms(2026, 11, 25, 12, 0, 0).unwrap();
        let old = batch("api:openai", now - Duration::days(2), &[State::Done]);
        let waiting = batch("claude-code", now - Duration::days(2), &[State::Waiting]);
        save(&path, &[old, waiting.clone()]).unwrap();
        assert_eq!(load(&path, now), vec![waiting]);
        std::fs::remove_dir_all(folder).unwrap();
    }
}
