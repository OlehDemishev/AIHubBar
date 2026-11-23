//! «Цель по словам» of a folder profile (the Mac's `WordGoal` and `WordProgress`): how many words were added today to
//! the projects' main files. A day's start is what each file had when it was last seen the day before; a file first
//! seen today starts from what it has, so an old text dropped into the folder is not today's work. Cut text never
//! counts below zero for its file. Kept in `word-goals.json` per profile, the Mac's format: numbers only, no text.

use chrono::{Duration, NaiveDate};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::path::Path;

/// The Mac's `WordProgress`, field for field.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WordProgress {
    /// `2026-11-23` in local time.
    pub day: String,
    /// Words in each project's main file when the day began, by `key`.
    pub baselines: BTreeMap<String, usize>,
    /// The same at the last look.
    pub latest: BTreeMap<String, usize>,
    /// Words written on the days before, by day; the last 60.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history: Option<BTreeMap<String, usize>>,
    /// The day whose reached goal was already announced.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub announced_day: Option<String>,
}

impl WordProgress {
    pub fn written(&self, counts: &BTreeMap<String, usize>) -> usize {
        counts.iter().map(|(key, count)| count.saturating_sub(*self.baselines.get(key).unwrap_or(count))).sum()
    }

    /// Days in a row with the goal reached, ending today (when today's is reached) or yesterday (the day is not over).
    pub fn streak(&self, goal: usize, today_words: usize, today: NaiveDate) -> usize {
        if goal == 0 {
            return 0;
        }
        let mut count = usize::from(today_words >= goal);
        let mut date = today;
        loop {
            date -= Duration::days(1);
            let reached = self.history.as_ref().and_then(|h| h.get(&day(date))).is_some_and(|words| *words >= goal);
            if !reached {
                return count;
            }
            count += 1;
        }
    }
}

/// What a count belongs to: the project and its main file. A project whose main file changes gets a new key.
pub fn key(project: &Path, main_file: Option<&str>) -> String {
    format!("{}#{}", project.display(), main_file.unwrap_or_default())
}

pub fn day(date: NaiveDate) -> String {
    date.format("%Y-%m-%d").to_string()
}

/// The record after a look at the folder. A new day starts from yesterday's last look; after a longer break — from
/// what is there now, since nobody knows on which day those words were written.
pub fn advanced(previous: Option<&WordProgress>, counts: &BTreeMap<String, usize>, today: NaiveDate) -> WordProgress {
    let today_key = day(today);
    let Some(previous) = previous else {
        return WordProgress { day: today_key, baselines: counts.clone(), latest: counts.clone(), history: None, announced_day: None };
    };
    if previous.day == today_key {
        let mut record = previous.clone();
        for (key, count) in counts {
            record.baselines.entry(key.clone()).or_insert(*count);
        }
        record.latest = counts.clone();
        return record;
    }
    // The day that ended goes to the history with what its last look saw.
    let mut history = previous.history.clone().unwrap_or_default();
    history.insert(previous.day.clone(), previous.written(&previous.latest));
    while history.len() > 60 {
        let oldest = history.keys().next().cloned().unwrap_or_default();
        history.remove(&oldest);
    }
    let mut baselines = counts.clone();
    if previous.day == day(today - Duration::days(1)) {
        for (key, count) in counts {
            baselines.insert(key.clone(), *previous.latest.get(key).unwrap_or(count));
        }
    }
    WordProgress { day: today_key, baselines, latest: counts.clone(), history: Some(history), announced_day: previous.announced_day.clone() }
}

pub fn load(file: &Path) -> HashMap<String, WordProgress> {
    std::fs::read_to_string(file).ok().and_then(|text| serde_json::from_str(&text).ok()).unwrap_or_default()
}

pub fn save(file: &Path, records: &HashMap<String, WordProgress>) -> std::io::Result<()> {
    let sorted: BTreeMap<&String, &WordProgress> = records.iter().collect();
    std::fs::write(file, serde_json::to_string(&sorted).map_err(std::io::Error::other)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn counts(pairs: &[(&str, usize)]) -> BTreeMap<String, usize> {
        pairs.iter().map(|(k, v)| ((*k).to_owned(), *v)).collect()
    }

    #[test]
    fn words_written_today() {
        let monday = NaiveDate::from_ymd_opt(2026, 11, 23).unwrap();
        let first = advanced(None, &counts(&[("a#t.md", 1000)]), monday);
        assert_eq!(first.written(&first.latest), 0, "an old text dropped in is not today's work");
        let later = advanced(Some(&first), &counts(&[("a#t.md", 1250), ("b#x.md", 300)]), monday);
        assert_eq!(later.written(&later.latest), 250, "a file first seen today starts from what it has");
        let cut = advanced(Some(&later), &counts(&[("a#t.md", 900), ("b#x.md", 400)]), monday);
        assert_eq!(cut.written(&cut.latest), 100, "cut text never counts below zero for its file");
        // The next day starts from yesterday's last look; the day that ended goes to the history.
        let tuesday = advanced(Some(&cut), &counts(&[("a#t.md", 950), ("b#x.md", 400)]), monday + Duration::days(1));
        assert_eq!(tuesday.written(&tuesday.latest), 50);
        assert_eq!(tuesday.history.as_ref().unwrap().get("2026-11-23"), Some(&100));
        // After a longer break: from what is there now.
        let later_week = advanced(Some(&tuesday), &counts(&[("a#t.md", 2000)]), monday + Duration::days(5));
        assert_eq!(later_week.written(&later_week.latest), 0);
    }

    #[test]
    fn days_in_a_row() {
        let today = NaiveDate::from_ymd_opt(2026, 11, 23).unwrap();
        let history: BTreeMap<String, usize> = [("2026-11-22", 600), ("2026-11-21", 500), ("2026-11-20", 100)].into_iter().map(|(d, w)| (d.to_owned(), w)).collect();
        let record = WordProgress { day: "2026-11-23".into(), baselines: BTreeMap::new(), latest: BTreeMap::new(), history: Some(history), announced_day: None };
        assert_eq!(record.streak(500, 520, today), 3, "today and the two days before");
        assert_eq!(record.streak(500, 10, today), 2, "the day is not over");
        assert_eq!(record.streak(0, 900, today), 0);
    }

    #[test]
    fn the_macs_file_reads_and_goes_back() {
        let text = r#"{"profile-1":{"announcedDay":"2026-11-22","baselines":{"/p/a#t.md":10},"day":"2026-11-23","history":{"2026-11-22":700},"latest":{"/p/a#t.md":40}}}"#;
        let dir = std::env::temp_dir().join(format!("claudepult-words-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("word-goals.json");
        std::fs::write(&file, text).unwrap();
        let records = load(&file);
        assert_eq!(records["profile-1"].written(&records["profile-1"].latest), 30);
        save(&file, &records).unwrap();
        let back: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
        assert_eq!(back, serde_json::from_str::<serde_json::Value>(text).unwrap());
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(key(Path::new("/p/a"), Some("t.md")), "/p/a#t.md");
    }
}
