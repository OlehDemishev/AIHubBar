//! The calendar of folder projects (docs/specs/SPEC-modes.md §6, the Mac's `CalendarEntry`, `ContentPlan`,
//! `CalendarScanner` and `CalendarStore`): a project's deadline and publication from its card, and the rows of a
//! `контент-план.md` table, for every profile whose calendar is on. AI Hub Bar keeps no calendar of its own: the
//! dates live in those files. «Ближайшее» is the next 7 days; a reminder comes before each date.

use crate::folders::{self, Key};
use crate::i18n::Strings;
use crate::profiles::Profile;
use chrono::{Duration, NaiveDateTime, Timelike};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Deadline,
    Publish,
    Plan,
}

impl Kind {
    pub fn title(self, s: &Strings) -> String {
        match self {
            Kind::Deadline => s.t("Дедлайн"),
            Kind::Publish => s.t("Публикация"),
            Kind::Plan => s.t("Контент-план"),
        }
        .to_owned()
    }

    pub fn key(self) -> &'static str {
        match self {
            Kind::Deadline => "deadline",
            Kind::Publish => "publish",
            Kind::Plan => "plan",
        }
    }
}

/// Where a date lives.
#[derive(Debug, Clone, PartialEq)]
pub enum Source {
    Card { path: PathBuf, key: Key },
    /// The row's line in the file when it was read.
    Plan { path: PathBuf, line: usize },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    pub date: NaiveDateTime,
    pub has_time: bool,
    pub kind: Kind,
    pub title: String,
    /// Platform, stage or status: whatever helps to recognise it.
    pub detail: Option<String>,
    pub profile: String,
    /// What a click opens: the project folder, the plan row's file, or the plan.
    pub open_path: PathBuf,
    pub source: Source,
    /// The project is at its profile's last stage (or the row's status is): nothing left to do.
    pub is_done: bool,
}

impl Entry {
    pub fn id(&self) -> String {
        match &self.source {
            Source::Card { path, key } => format!("{}#{key:?}", path.display()),
            Source::Plan { path, line } => format!("{}#{line}", path.display()),
        }
    }

    /// Stable across edits of other rows, for reminders.
    pub fn reminder_key(&self) -> String {
        format!("{}|{}|{}|{}", self.open_path.display(), self.kind.key(), self.title, self.date.and_utc().timestamp())
    }

    /// A date-only deadline is overdue the day after; a timed one right after its time.
    pub fn is_overdue(&self, now: NaiveDateTime) -> bool {
        !self.is_done && if self.has_time { self.date < now } else { self.date.date() < now.date() }
    }
}

// MARK: - `контент-план.md`

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Column {
    Date,
    Time,
    Platform,
    Topic,
    Status,
    File,
}

impl Column {
    const ALL: [Column; 6] = [Column::Date, Column::Time, Column::Platform, Column::Topic, Column::Status, Column::File];

    fn name(self) -> &'static str {
        match self {
            Column::Date => "date",
            Column::Time => "time",
            Column::Platform => "platform",
            Column::Topic => "topic",
            Column::Status => "status",
            Column::File => "file",
        }
    }

    /// Every language's header (and `title` for the topic), lowercased.
    fn headers(self) -> Vec<String> {
        let mut list: Vec<String> = folders::content_languages().filter_map(|(_, entry)| entry["planColumns"][self.name()].as_str().map(str::to_lowercase)).collect();
        if self == Column::Topic {
            list.push("title".into());
        }
        list
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Row {
    pub line: usize,
    pub cells: Vec<String>,
    columns: Vec<(Column, usize)>,
}

impl Row {
    pub fn value(&self, column: Column) -> Option<&str> {
        let position = self.columns.iter().find(|(c, _)| *c == column)?.1;
        self.cells.get(position).map(String::as_str).filter(|v| !v.is_empty())
    }

    /// `2026-11-03` and `18:00`; the time column may be missing or empty.
    pub fn date(&self) -> Option<(NaiveDateTime, bool)> {
        let day = self.value(Column::Date)?;
        if let Some(date) = self.value(Column::Time).and_then(|time| folders::date(&format!("{day} {time}"))) {
            return Some((date, true));
        }
        folders::date(day).map(|date| (date, day.contains(':')))
    }
}

/// A Markdown table row's cells; `\|` is a pipe inside a cell.
pub fn cells(line: &str) -> Option<Vec<String>> {
    let trimmed = line.trim();
    let body = trimmed.strip_prefix('|')?;
    let body = body.strip_suffix('|').unwrap_or(body);
    let placeholder = '\u{1}';
    Some(body.replace("\\|", &placeholder.to_string()).split('|').map(|cell| cell.replace(placeholder, "\\|").trim().to_owned()).collect())
}

/// The first table with a date column: its rows (the Mac's `ContentPlan.parse`).
pub fn plan_rows(text: &str) -> Vec<Row> {
    let lines: Vec<&str> = text.lines().collect();
    let mut index = 0;
    while index < lines.len() {
        let Some(header) = cells(lines[index]) else {
            index += 1;
            continue;
        };
        let mut columns: Vec<(Column, usize)> = Vec::new();
        for (position, name) in header.iter().enumerate() {
            let name = name.to_lowercase();
            if let Some(column) = Column::ALL.into_iter().find(|c| c.headers().contains(&name)) {
                if !columns.iter().any(|(c, _)| *c == column) {
                    columns.push((column, position));
                }
            }
        }
        let separator = lines.get(index + 1).and_then(|line| cells(line));
        let is_separator = separator.is_some_and(|cells| cells.iter().all(|cell| cell.chars().all(|c| "-: ".contains(c))));
        if !columns.iter().any(|(c, _)| *c == Column::Date) || !is_separator {
            index += 1;
            continue;
        }
        let mut rows = Vec::new();
        let mut line = index + 2;
        while let Some(row) = lines.get(line).and_then(|l| cells(l)) {
            rows.push(Row { line, cells: row, columns: columns.clone() });
            line += 1;
        }
        return rows;
    }
    Vec::new()
}

/// The plan of a folder: under any language's name, else where a new one goes.
pub fn plan_path(folder: &Path, language: &str) -> PathBuf {
    let names: Vec<String> = folders::content_languages().filter_map(|(_, e)| e["planFile"].as_str().map(str::to_owned)).collect();
    names.iter().map(|n| folder.join(n)).find(|p| p.is_file()).unwrap_or_else(|| folder.join(folders::content_text(language, "planFile")))
}

// MARK: - Collecting

/// A profile's dates: `dates` — the cards' deadlines and publications; `contentPlan` — also the profile's own plan and
/// each project's. Nothing for a profile without folder projects or with its calendar off.
pub fn entries(profile: &Profile, home: &Path, language: &str, s: &Strings) -> Vec<Entry> {
    let calendar = profile.calendar();
    let source = profile.source();
    if calendar == "off" || !source.is_folders() {
        return Vec::new();
    }
    let done = profile.done_stage();
    let projects = folders::scan(&source, home, &[], language);
    let mut result = Vec::new();
    for project in &projects {
        for (key, kind) in [(Key::Deadline, Kind::Deadline), (Key::Publish, Kind::Publish)] {
            let Some(text) = project.card.get(key) else { continue };
            let Some(date) = folders::date(text) else { continue };
            result.push(Entry {
                date,
                has_time: text.contains(':'),
                kind,
                title: project.name.clone(),
                detail: project.card.get(Key::Platform).or(project.card.stage()).map(str::to_owned),
                profile: profile.name.clone(),
                open_path: project.path.clone(),
                source: Source::Card { path: folders::card_path(&project.path, language), key },
                is_done: done.is_some() && project.card.stage() == done.as_deref(),
            });
        }
    }
    if calendar != "contentPlan" {
        return result;
    }
    let Some(root) = profile.projects_dir(home) else { return result };
    // The profile's own plan and each project's.
    let mut places = vec![root.clone()];
    places.extend(projects.iter().map(|p| p.path.clone()).filter(|p| p != &root));
    for folder in places {
        let path = plan_path(&folder, language);
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        for row in plan_rows(&text) {
            let Some((date, has_time)) = row.date() else { continue };
            let file = row.value(Column::File).map(|f| folder.join(f)).filter(|f| f.exists());
            let detail = [row.value(Column::Platform), row.value(Column::Status)].into_iter().flatten().collect::<Vec<_>>().join(" · ");
            result.push(Entry {
                date,
                has_time,
                kind: Kind::Plan,
                title: row.value(Column::Topic).map(str::to_owned).unwrap_or_else(|| s.t("Без темы").to_owned()),
                detail: (!detail.is_empty()).then_some(detail),
                profile: profile.name.clone(),
                open_path: file.unwrap_or_else(|| path.clone()),
                source: Source::Plan { path: path.clone(), line: row.line },
                is_done: done.is_some() && row.value(Column::Status) == done.as_deref(),
            });
        }
    }
    result
}

/// Every profile's dates, earliest first.
pub fn all(profiles: &[Profile], home: &Path, language: &str, s: &Strings) -> Vec<Entry> {
    let mut list: Vec<Entry> = profiles.iter().flat_map(|p| entries(p, home, language, s)).collect();
    list.sort_by(|a, b| a.date.cmp(&b.date).then_with(|| a.title.cmp(&b.title)));
    list
}

/// The next `days` days. Overdue deadlines stay until they are moved; overdue publications and plan rows for a day;
/// finished work shows only what is still ahead and isn't a deadline.
pub fn upcoming(entries: &[Entry], days: i64, now: NaiveDateTime) -> Vec<Entry> {
    let today = now.date().and_hms_opt(0, 0, 0).expect("midnight");
    let end = today + Duration::days(days);
    let since = today - Duration::days(1);
    entries
        .iter()
        .filter(|e| {
            if e.is_done {
                e.kind != Kind::Deadline && e.date >= today && e.date < end
            } else {
                e.date < end && (e.date >= since || e.kind == Kind::Deadline)
            }
        })
        .cloned()
        .collect()
}

/// «сегодня 18:00», «завтра», «через 3 дн», «просрочено 2 дн».
pub fn relative(date: NaiveDateTime, has_time: bool, now: NaiveDateTime, s: &Strings) -> String {
    let days = (date.date() - now.date()).num_days();
    let time = if has_time { format!(" {:02}:{:02}", date.hour(), date.minute()) } else { String::new() };
    match days {
        ..=-1 => s.format("просрочено %lld дн", &[&(-days).to_string()]),
        0 => s.t("сегодня").to_owned() + &time,
        1 => s.t("завтра").to_owned() + &time,
        _ => s.format("через %lld дн", &[&days.to_string()]) + &time,
    }
}

/// What to announce now, with its reminder key: per entry the closest offset that has come and wasn't announced;
/// a date that has passed isn't announced (the Mac's `CalendarStore.due`).
pub fn due(entries: &[Entry], hours: &[i64], reminded: &HashSet<String>, now: NaiveDateTime) -> Vec<(Entry, String)> {
    let mut offsets: Vec<i64> = hours.iter().copied().filter(|h| *h > 0).collect();
    offsets.sort_unstable();
    entries
        .iter()
        .filter(|e| e.date > now && !e.is_done)
        .filter_map(|e| {
            let offset = offsets.iter().find(|h| now >= e.date - Duration::hours(**h))?;
            let key = format!("{}|{offset}", e.reminder_key());
            (!reminded.contains(&key)).then(|| (e.clone(), key))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn at(text: &str) -> NaiveDateTime {
        folders::date(text).unwrap()
    }

    fn s() -> Strings {
        Strings::from_json("{}")
    }

    #[test]
    fn content_plans() {
        let text = "# Контент-план\n\nТекст\n\n| Дата | Время | Площадка | Тема | Статус | Файл | Своя |\n|---|:-:|---|---|---|---|---|\n| 2026-11-20 | 18:00 | YouTube | Ролик \\| часть 1 | идея | ролик.md | x |\n| 2026-11-21 | | Telegram | | готово | | |\n| завтра | | | Без даты | | | |\nпосле таблицы\n| 2026-12-01 | | | не из таблицы | | | |\n";
        let rows = plan_rows(text);
        assert_eq!(rows.len(), 3, "the table ends at the first line that isn't a row");
        assert_eq!(rows[0].value(Column::Topic), Some("Ролик \\| часть 1"));
        assert_eq!(rows[0].date(), Some((at("2026-11-20 18:00"), true)));
        assert_eq!(rows[1].date(), Some((at("2026-11-21"), false)));
        assert_eq!(rows[1].value(Column::Topic), None);
        assert_eq!(rows[2].date(), None);
        let english = plan_rows("| Date | Title | Platform |\n|---|---|---|\n| 05.12.2026 | Post | X |\n");
        assert_eq!((english[0].value(Column::Topic), english[0].date()), (Some("Post"), Some((at("2026-12-05"), false))));
        assert!(plan_rows("| a | b |\n|---|---|\n| 1 | 2 |\n").is_empty(), "no date column");
        assert_eq!(cells("not a row"), None);
    }

    #[test]
    fn a_profiles_dates() {
        let root = std::env::temp_dir().join(format!("claudepult-calendar-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for (name, card) in [("Ролик", "Этап: монтаж\nДедлайн: 2026-11-20\nПубликация: 2026-11-22 18:00\nПлощадка: YouTube\n"), ("Старый", "Этап: опубликовано\nПубликация: 2026-11-19\n")] {
            std::fs::create_dir_all(root.join(name)).unwrap();
            std::fs::write(root.join(name).join("проект.md"), card).unwrap();
        }
        std::fs::write(root.join("Ролик").join("ролик.md"), "x").unwrap();
        std::fs::write(root.join("контент-план.md"), "| Дата | Тема | Статус | Файл |\n|---|---|---|---|\n| 2026-11-21 | Анонс | идея | Ролик/ролик.md |\n").unwrap();
        let mut profile = Profile::from_value(&json!({
            "name": "Видео", "source": {"folders": {"_0": root.to_string_lossy()}},
            "stages": ["идея", "монтаж", "опубликовано"], "calendar": "dates"
        }))
        .unwrap();
        let s = s();
        let dates = entries(&profile, Path::new("/"), "ru", &s);
        assert_eq!(dates.len(), 3, "two from «Ролик», one from «Старый»; the plan only with «contentPlan»");
        let publish = dates.iter().find(|e| e.kind == Kind::Publish && e.title == "Ролик").unwrap();
        assert!(publish.has_time && publish.detail.as_deref() == Some("YouTube"));
        assert!(dates.iter().find(|e| e.title == "Старый").unwrap().is_done);

        profile.other.insert("calendar".into(), json!("contentPlan"));
        let all = all(&[profile.clone()], Path::new("/"), "ru", &s);
        let plan = all.iter().find(|e| e.kind == Kind::Plan).unwrap();
        assert_eq!((plan.title.as_str(), plan.detail.as_deref()), ("Анонс", Some("идея")));
        assert_eq!(plan.open_path, root.join("Ролик").join("ролик.md"), "the row's file when it is there");
        assert!(all.windows(2).all(|w| w[0].date <= w[1].date));

        profile.other.insert("calendar".into(), json!("off"));
        assert!(entries(&profile, Path::new("/"), "ru", &s).is_empty());
        std::fs::remove_dir_all(root).unwrap();
    }

    fn entry(date: &str, kind: Kind, done: bool) -> Entry {
        Entry { date: at(date), has_time: date.contains(':'), kind, title: date.into(), detail: None, profile: "p".into(), open_path: PathBuf::from("/x"), source: Source::Plan { path: PathBuf::from("/x"), line: 0 }, is_done: done }
    }

    #[test]
    fn the_week_ahead() {
        let now = at("2026-11-18 12:00");
        let list = vec![
            entry("2026-11-10", Kind::Deadline, false),
            entry("2026-11-10", Kind::Publish, false),
            entry("2026-11-17", Kind::Publish, false),
            entry("2026-11-19 18:00", Kind::Plan, false),
            entry("2026-11-20", Kind::Deadline, true),
            entry("2026-11-21", Kind::Publish, true),
            entry("2026-11-25", Kind::Plan, false),
        ];
        let titles: Vec<String> = upcoming(&list, 7, now).into_iter().map(|e| format!("{:?} {}", e.kind, e.title)).collect();
        assert_eq!(titles, ["Deadline 2026-11-10", "Publish 2026-11-17", "Plan 2026-11-19 18:00", "Publish 2026-11-21"]);
        assert!(list[0].is_overdue(now) && !entry("2026-11-18", Kind::Deadline, false).is_overdue(now));
        assert!(entry("2026-11-18 11:00", Kind::Deadline, false).is_overdue(now));
        let s = s();
        assert_eq!(relative(at("2026-11-16"), false, now, &s), "просрочено 2 дн");
        assert_eq!(relative(at("2026-11-18 18:05"), true, now, &s), "сегодня 18:05");
        assert_eq!(relative(at("2026-11-19"), false, now, &s), "завтра");
        assert_eq!(relative(at("2026-11-21"), false, now, &s), "через 3 дн");
    }

    #[test]
    fn reminders() {
        let now = at("2026-11-18 12:00");
        let soon = entry("2026-11-19 10:00", Kind::Deadline, false);
        let later = entry("2026-11-25", Kind::Publish, false);
        let past = entry("2026-11-18 11:00", Kind::Plan, false);
        let list = vec![soon.clone(), later, past];
        let due_now = due(&list, &[24, 2], &HashSet::new(), now);
        assert_eq!(due_now.len(), 1, "only the one within 24 hours, not the past one");
        assert!(due_now[0].1.ends_with("|24"));
        let reminded: HashSet<String> = due_now.into_iter().map(|(_, k)| k).collect();
        assert!(due(&list, &[24, 2], &reminded, now).is_empty(), "once per offset");
        assert_eq!(due(&list, &[24, 2], &reminded, at("2026-11-19 08:30")).len(), 1, "the 2-hour one comes later");
        assert!(due(&list, &[0], &HashSet::new(), now).is_empty(), "«не напоминать»");
    }
}
