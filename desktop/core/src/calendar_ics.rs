//! The calendar's dates as an iCalendar file (the Mac's `CalendarICS`) for Outlook, Google Calendar and the like. A
//! file, written when the person asks: AI Hub Bar asks for no access to their calendars. A date without a time is an
//! all-day event; a timed one lasts half an hour. The UID comes from where the date lives, so importing a newer file
//! moves the events instead of doubling them.

use crate::calendar::{Entry, Source};
use crate::i18n::Strings;
use chrono::{DateTime, Duration, Local, TimeZone, Utc};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

pub fn text(entries: &[Entry], now: DateTime<Utc>, s: &Strings) -> String {
    let mut lines: Vec<String> = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//AI Hub Bar//Calendar//EN", "CALSCALE:GREGORIAN", "METHOD:PUBLISH", "X-WR-CALNAME:AI Hub Bar"].map(str::to_owned).to_vec();
    let mut sorted: Vec<&Entry> = entries.iter().collect();
    sorted.sort_by(|a, b| (a.date, a.id()).cmp(&(b.date, b.id())));
    let mut seen: HashMap<String, usize> = HashMap::new();
    for entry in sorted {
        // Two rows with the same name are two events: the later one gets a number.
        let mut id = uid(entry);
        let count = seen.entry(id.clone()).or_insert(0);
        *count += 1;
        if *count > 1 {
            id = format!("{count}-{id}");
        }
        lines.extend(["BEGIN:VEVENT".to_owned(), format!("UID:{id}"), format!("DTSTAMP:{}", utc(now))]);
        if entry.has_time {
            let start = Local.from_local_datetime(&entry.date).earliest().map_or_else(|| entry.date.and_utc(), |at| at.with_timezone(&Utc));
            lines.extend([format!("DTSTART:{}", utc(start)), "DURATION:PT30M".to_owned()]);
        } else {
            let day = entry.date.date();
            lines.extend([format!("DTSTART;VALUE=DATE:{}", day.format("%Y%m%d")), format!("DTEND;VALUE=DATE:{}", (day + Duration::days(1)).format("%Y%m%d"))]);
        }
        lines.push(format!("SUMMARY:{}", escaped(&format!("{}: {}", entry.kind.title(s), entry.title))));
        let description = [entry.detail.as_deref(), Some(entry.profile.as_str())].into_iter().flatten().filter(|t| !t.is_empty()).collect::<Vec<_>>().join("\n");
        if !description.is_empty() {
            lines.push(format!("DESCRIPTION:{}", escaped(&description)));
        }
        if entry.is_done {
            lines.push("STATUS:CONFIRMED".to_owned());
        }
        lines.push("END:VEVENT".to_owned());
    }
    lines.push("END:VCALENDAR".to_owned());
    lines.iter().flat_map(|line| folded(line)).collect::<Vec<_>>().join("\r\n") + "\r\n"
}

/// A plan row is known by its file, kind and title, not by its line: a row removed above it must not turn it into
/// another event at the next import. A new date keeps the id, so the calendar moves the event.
pub fn uid(entry: &Entry) -> String {
    let key = match &entry.source {
        Source::Card { .. } => entry.id(),
        Source::Plan { path, .. } => format!("{}|{}|{}", path.display(), entry.kind.key(), entry.title),
    };
    let digest = Sha256::digest(key.as_bytes());
    digest.iter().take(12).map(|b| format!("{b:02x}")).collect::<String>() + "@aihubbar"
}

/// RFC 5545 §3.3.11: backslash, semicolon, comma and line breaks.
pub fn escaped(text: &str) -> String {
    text.replace('\\', "\\\\").replace(';', "\\;").replace(',', "\\,").replace("\r\n", "\\n").replace('\n', "\\n")
}

/// RFC 5545 §3.1: a line is at most 75 octets; the rest goes on lines that start with a space. Cut between characters,
/// never inside one.
pub fn folded(line: &str) -> Vec<String> {
    let mut result: Vec<String> = Vec::new();
    let mut current = String::new();
    for character in line.chars() {
        let limit = if result.is_empty() { 75 } else { 74 };
        if current.len() + character.len_utf8() > limit {
            result.push(if result.is_empty() { std::mem::take(&mut current) } else { format!(" {}", std::mem::take(&mut current)) });
        }
        current.push(character);
    }
    result.push(if result.is_empty() { current } else { format!(" {current}") });
    result
}

fn utc(date: DateTime<Utc>) -> String {
    date.format("%Y%m%dT%H%M%SZ").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::calendar::Kind;
    use crate::folders::Key;
    use chrono::NaiveDate;
    use std::path::PathBuf;

    fn entry(kind: Kind, title: &str, day: u32, time: Option<(u32, u32)>, source: Source) -> Entry {
        let date = NaiveDate::from_ymd_opt(2026, 11, day).unwrap().and_hms_opt(time.map_or(0, |t| t.0), time.map_or(0, |t| t.1), 0).unwrap();
        Entry { date, has_time: time.is_some(), kind, title: title.into(), detail: Some("YouTube".into()), profile: "Видео".into(), profile_id: "v".into(), open_path: PathBuf::from("C:/P/clip"), source, is_done: false }
    }

    #[test]
    fn the_file_a_calendar_reads() {
        let s = Strings::default();
        let card = entry(Kind::Deadline, "Ролик, про кофе; часть 1", 25, None, Source::Card { path: PathBuf::from("C:/P/clip/проект.md"), key: Key::Deadline });
        let plan = entry(Kind::Plan, "Пост", 26, Some((18, 30)), Source::Plan { path: PathBuf::from("C:/P/контент-план.md"), line: 4 });
        let twin = entry(Kind::Plan, "Пост", 27, Some((18, 30)), Source::Plan { path: PathBuf::from("C:/P/контент-план.md"), line: 9 });
        let now = Utc.with_ymd_and_hms(2026, 11, 23, 12, 0, 0).unwrap();
        let text = text(&[plan.clone(), card, twin], now, &s);
        let lines: Vec<&str> = text.split("\r\n").collect();
        assert!(text.ends_with("END:VCALENDAR\r\n") && lines[0] == "BEGIN:VCALENDAR");
        assert!(lines.contains(&"DTSTART;VALUE=DATE:20261125") && lines.contains(&"DTEND;VALUE=DATE:20261126"), "all day, ends the next day");
        assert!(lines.contains(&"SUMMARY:Дедлайн: Ролик\\, про кофе\\; часть 1"));
        assert!(lines.contains(&"DESCRIPTION:YouTube\\nВидео"));
        assert_eq!(lines.iter().filter(|l| **l == "DURATION:PT30M").count(), 2, "a timed date lasts half an hour");
        // The same plan row on another line keeps its id; a second row of the same name gets a number.
        let moved = Entry { source: Source::Plan { path: PathBuf::from("C:/P/контент-план.md"), line: 12 }, ..plan.clone() };
        assert_eq!(uid(&moved), uid(&plan));
        assert!(text.contains(&format!("UID:2-{}", uid(&plan))));
        assert!(lines.iter().all(|line| line.len() <= 75));
    }

    #[test]
    fn long_lines_fold_between_characters() {
        let line = format!("SUMMARY:{}", "я".repeat(60));
        let parts = folded(&line);
        assert!(parts.len() == 2 && parts[0].len() <= 75 && parts[1].starts_with(' ') && parts[1].len() <= 75);
        assert_eq!(parts.concat().replace(" я", "я"), line);
        assert_eq!(folded("short"), ["short"]);
    }
}
