//! «История буфера» (the Mac's `ClipboardHistory` and `ClipboardPolicy`): the recent copied texts — search, pin,
//! back to the clipboard in a click. Secrets are not recorded: what a program marks as hidden from clipboard
//! history, and anything copied while a password manager is in front.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

pub const KIND: &str = "clipboard";

/// «Хранить последних».
pub const LIMITS: [u32; 4] = [20, 50, 100, 200];
pub const DEFAULT_LIMIT: u32 = 50;
/// The panel shows this many.
pub const SHOWN: usize = 8;
/// A longer text is not a thing to keep a history of.
pub const MAX_BYTES: usize = 1_000_000;

/// The Mac's `ClipItem`, field for field; only texts are recorded here.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipItem {
    pub id: String,
    #[serde(default = "text_kind")]
    pub kind: String,
    pub text: String,
    #[serde(with = "stamp")]
    pub date: DateTime<Utc>,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_app: Option<String>,
}

/// The date as the Mac writes it: «2026-11-23T10:01:00Z».
mod stamp {
    use chrono::{DateTime, Utc};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(date: &DateTime<Utc>, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&date.format("%Y-%m-%dT%H:%M:%SZ").to_string())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<DateTime<Utc>, D::Error> {
        let text = String::deserialize(deserializer)?;
        DateTime::parse_from_rfc3339(&text).map(|date| date.with_timezone(&Utc)).map_err(serde::de::Error::custom)
    }
}

fn text_kind() -> String {
    "text".into()
}

impl ClipItem {
    pub fn text(text: &str, source_app: Option<String>, now: DateTime<Utc>) -> ClipItem {
        ClipItem { id: crate::runs::new_id(), kind: text_kind(), text: text.to_owned(), date: now, pinned: false, source_app }
    }
}

/// Password managers, by the program's file: nothing copied while one is in front is recorded.
pub const EXCLUDED_APPS: [&str; 9] = ["1password.exe", "bitwarden.exe", "keepassxc.exe", "keepass.exe", "lastpass.exe", "dashlane.exe", "enpass.exe", "keeperpasswordmanager.exe", "protonpass.exe"];

/// `hidden` — the copy is marked as not for clipboard history; `front` — the file of the program in front.
pub fn should_record(hidden: bool, front: Option<&str>) -> bool {
    !hidden && !front.is_some_and(|exe| EXCLUDED_APPS.contains(&exe.to_lowercase().as_str()))
}

/// A new copy goes on top; the same text again moves up instead of repeating, keeping its pin; pinned entries stay,
/// the rest beyond the limit fall off.
pub fn adding(item: ClipItem, items: &[ClipItem], limit: usize) -> Vec<ClipItem> {
    if item.text.trim().is_empty() || item.text.len() > MAX_BYTES {
        return items.to_vec();
    }
    let mut new = item;
    let mut rest = items.to_vec();
    if let Some(index) = rest.iter().position(|old| old.kind == new.kind && old.text == new.text) {
        new.pinned = rest[index].pinned;
        new.id = rest[index].id.clone();
        rest.remove(index);
    }
    let mut unpinned = 0;
    std::iter::once(new)
        .chain(rest)
        .filter(|entry| {
            if entry.pinned {
                return true;
            }
            unpinned += 1;
            unpinned <= limit
        })
        .collect()
}

/// What the panel lists: the pinned first, by the typed text when there is one.
pub fn shown<'a>(items: &'a [ClipItem], query: &str) -> Vec<&'a ClipItem> {
    let query = query.trim().to_lowercase();
    let found = |item: &&ClipItem| query.is_empty() || item.text.to_lowercase().contains(&query);
    items.iter().filter(|i| i.pinned).filter(found).chain(items.iter().filter(|i| !i.pinned).filter(found)).take(SHOWN).collect()
}

/// One line for the list: line ends as « ⏎ », a long text cut.
pub fn one_line(text: &str) -> String {
    let line = text.trim().lines().map(str::trim_end).collect::<Vec<_>>().join(" ⏎ ");
    if line.chars().count() > 200 { format!("{}…", line.chars().take(200).collect::<String>()) } else { line }
}

/// The kept list from `clipboard.json`; a file that can't be read is an empty history.
pub fn parse(text: &str) -> Vec<ClipItem> {
    serde_json::from_str::<Vec<serde_json::Value>>(text).unwrap_or_default().into_iter().filter_map(|value| serde_json::from_value::<ClipItem>(value).ok()).filter(|item| item.kind == "text").collect()
}

/// A number that changes with every copy; None where the system has none (the text itself is compared then).
#[cfg(windows)]
pub fn sequence() -> Option<u32> {
    Some(unsafe { windows_sys::Win32::System::DataExchange::GetClipboardSequenceNumber() })
}

#[cfg(not(windows))]
pub fn sequence() -> Option<u32> {
    None
}

/// The copy is marked as not for clipboard history or monitors (password managers do it).
#[cfg(windows)]
pub fn marked_hidden() -> bool {
    use windows_sys::Win32::System::DataExchange::{IsClipboardFormatAvailable, RegisterClipboardFormatW};
    ["ExcludeClipboardContentFromMonitorProcessing", "CanIncludeInClipboardHistory"].iter().any(|name| {
        let wide: Vec<u16> = name.encode_utf16().chain([0]).collect();
        let format = unsafe { RegisterClipboardFormatW(wide.as_ptr()) };
        format != 0 && unsafe { IsClipboardFormatAvailable(format) } != 0
    })
}

#[cfg(not(windows))]
pub fn marked_hidden() -> bool {
    false
}

/// The file of the program whose window is in front: «1Password.exe».
#[cfg(windows)]
pub fn front_app() -> Option<String> {
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION};
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};
    let mut process_id = 0u32;
    unsafe { GetWindowThreadProcessId(GetForegroundWindow(), &mut process_id) };
    if process_id == 0 {
        return None;
    }
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, process_id) };
    if handle.is_null() {
        return None;
    }
    let mut buffer = [0u16; 1024];
    let mut length = buffer.len() as u32;
    let ok = unsafe { QueryFullProcessImageNameW(handle, 0, buffer.as_mut_ptr(), &mut length) };
    unsafe { CloseHandle(handle) };
    if ok == 0 {
        return None;
    }
    let path = String::from_utf16_lossy(&buffer[..length as usize]);
    std::path::Path::new(&path).file_name().map(|name| name.to_string_lossy().into_owned())
}

#[cfg(not(windows))]
pub fn front_app() -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(minute: u32) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(&format!("2026-11-23T10:{minute:02}:00Z")).unwrap().with_timezone(&Utc)
    }

    #[test]
    fn what_is_recorded() {
        assert!(should_record(false, None) && should_record(false, Some("Code.exe")));
        assert!(!should_record(true, Some("Code.exe")), "marked as hidden");
        assert!(!should_record(false, Some("1Password.exe")) && !should_record(false, Some("KeePassXC.exe")), "a password manager in front");
    }

    #[test]
    fn the_list_is_kept() {
        let mut items = Vec::new();
        for (minute, text) in ["one", "two", "three"].iter().enumerate() {
            items = adding(ClipItem::text(text, None, at(minute as u32)), &items, 3);
        }
        assert_eq!(items.iter().map(|i| i.text.as_str()).collect::<Vec<_>>(), ["three", "two", "one"]);
        assert_eq!(adding(ClipItem::text("  \n", None, at(5)), &items, 3), items, "nothing but spaces");
        assert_eq!(adding(ClipItem::text(&"x".repeat(MAX_BYTES + 1), None, at(5)), &items, 3), items, "too long");

        items[2].pinned = true;
        let pinned_id = items[2].id.clone();
        let again = adding(ClipItem::text("one", Some("Code.exe".into()), at(6)), &items, 3);
        assert_eq!(again.iter().map(|i| i.text.as_str()).collect::<Vec<_>>(), ["one", "three", "two"], "the same text moves up");
        assert!(again[0].pinned && again[0].id == pinned_id && again[0].date == at(6), "with its pin and id");

        let more = adding(ClipItem::text("five", None, at(8)), &adding(ClipItem::text("four", None, at(7)), &again, 3), 3);
        assert_eq!(more.iter().map(|i| i.text.as_str()).collect::<Vec<_>>(), ["five", "four", "one", "three"], "the pinned one is not counted and stays");

        assert_eq!(shown(&more, "").iter().map(|i| i.text.as_str()).collect::<Vec<_>>(), ["one", "five", "four", "three"], "pinned first");
        assert_eq!(shown(&more, " F").iter().map(|i| i.text.as_str()).collect::<Vec<_>>(), ["five", "four"]);
        let many: Vec<ClipItem> = (0..20).map(|n| ClipItem::text(&n.to_string(), None, at(n))).collect();
        assert_eq!(shown(&many, "").len(), SHOWN);
    }

    #[test]
    fn lines_and_the_file() {
        assert_eq!(one_line("  a  \r\nb\n\nc \n"), "a ⏎ b ⏎  ⏎ c");
        assert_eq!(one_line(&"я".repeat(300)).chars().count(), 201);

        let items = vec![ClipItem { pinned: true, source_app: Some("Code.exe".into()), ..ClipItem::text("привет", None, at(1)) }, ClipItem::text("b", None, at(2))];
        let text = serde_json::to_string(&items).unwrap();
        assert!(text.contains(r#""sourceApp":"Code.exe""#) && text.contains(r#""kind":"text""#) && text.contains(r#""date":"2026-11-23T10:01:00Z""#), "{text}");
        assert_eq!(parse(&text), items);
        let mac = r#"[{"id":"a","kind":"files","text":"/a\n/b","date":"2026-11-23T10:00:00Z","pinned":false},{"id":"b","kind":"text","text":"t","date":"2026-11-23T10:00:00Z"},{"id":"c"}]"#;
        assert_eq!(parse(mac).iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), ["b"], "copied files and broken entries are left out");
        assert!(parse("not json").is_empty());
    }
}
