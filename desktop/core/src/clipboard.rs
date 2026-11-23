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

/// The Mac's `ClipItem`, field for field: a copied text, or copied files as their paths, one a line.
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

pub const FILES: &str = "files";

fn text_kind() -> String {
    "text".into()
}

impl ClipItem {
    pub fn text(text: &str, source_app: Option<String>, now: DateTime<Utc>) -> ClipItem {
        ClipItem { id: crate::runs::new_id(), kind: text_kind(), text: text.to_owned(), date: now, pinned: false, source_app }
    }

    /// Copied files (the Mac's `kind: files`): their paths, one a line.
    pub fn files(paths: &[String], source_app: Option<String>, now: DateTime<Utc>) -> ClipItem {
        ClipItem { id: crate::runs::new_id(), kind: FILES.into(), text: paths.join("\n"), date: now, pinned: false, source_app }
    }

    pub fn is_files(&self) -> bool {
        self.kind == FILES
    }

    /// The paths of copied files.
    pub fn paths(&self) -> Vec<String> {
        self.text.lines().filter(|line| !line.is_empty()).map(str::to_owned).collect()
    }

    /// What the list shows: a text as one line, files by their names — «report.pdf, photo.png».
    pub fn shown_text(&self) -> String {
        if !self.is_files() {
            return one_line(&self.text);
        }
        let names: Vec<String> = self.paths().iter().map(|path| path.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next().unwrap_or(path).to_owned()).collect();
        one_line(&names.join(", "))
    }
}

/// Password managers, by the program's file: nothing copied while one is in front is recorded.
pub const EXCLUDED_APPS: [&str; 9] = ["1password.exe", "bitwarden.exe", "keepassxc.exe", "keepass.exe", "lastpass.exe", "dashlane.exe", "enpass.exe", "keeperpasswordmanager.exe", "protonpass.exe"];

/// `hidden` — the copy is marked as not for clipboard history; `front` — the file of the program in front;
/// `excluded` — «Не запоминать из приложений», programs' files in small letters.
pub fn should_record(hidden: bool, front: Option<&str>, excluded: &[String]) -> bool {
    !hidden && !front.is_some_and(|exe| excluded.contains(&exe.to_lowercase()))
}

/// «Не запоминать из приложений» as kept: what was chosen, else the password managers.
pub fn excluded_apps(saved: Option<&[String]>) -> Vec<String> {
    match saved {
        Some(list) => {
            let mut apps: Vec<String> = list.iter().map(|app| app.trim().to_lowercase()).filter(|app| !app.is_empty()).collect();
            apps.sort();
            apps.dedup();
            apps
        }
        None => EXCLUDED_APPS.iter().map(|app| (*app).to_owned()).collect(),
    }
}

/// The clipboard's own form of copied files (`CF_HDROP`): a 20-byte `DROPFILES` header, then the paths in UTF-16,
/// each ended by a zero, and one more zero after the last.
pub fn drop_files_bytes(paths: &[String]) -> Vec<u8> {
    // pFiles = 20, pt = (0, 0), fNC = 0, fWide = 1.
    let mut bytes: Vec<u8> = [20u32, 0, 0, 0, 1].iter().flat_map(|value| value.to_le_bytes()).collect();
    for path in paths {
        bytes.extend(path.encode_utf16().chain([0]).flat_map(u16::to_le_bytes));
    }
    bytes.extend(0u16.to_le_bytes());
    bytes
}

/// Copied files on the clipboard, if that is what was copied; None for a text or anything else.
#[cfg(windows)]
pub fn read_files() -> Option<Vec<String>> {
    use windows_sys::Win32::System::DataExchange::{CloseClipboard, GetClipboardData, IsClipboardFormatAvailable, OpenClipboard};
    use windows_sys::Win32::UI::Shell::DragQueryFileW;
    unsafe {
        if IsClipboardFormatAvailable(CF_HDROP) == 0 || OpenClipboard(std::ptr::null_mut()) == 0 {
            return None;
        }
        let drop = GetClipboardData(CF_HDROP);
        let mut paths = Vec::new();
        if !drop.is_null() {
            let count = DragQueryFileW(drop as _, u32::MAX, std::ptr::null_mut(), 0);
            for index in 0..count {
                let length = DragQueryFileW(drop as _, index, std::ptr::null_mut(), 0) as usize;
                let mut buffer = vec![0u16; length + 1];
                let written = DragQueryFileW(drop as _, index, buffer.as_mut_ptr(), buffer.len() as u32) as usize;
                paths.push(String::from_utf16_lossy(&buffer[..written.min(length)]));
            }
        }
        CloseClipboard();
        (!paths.is_empty()).then_some(paths)
    }
}

#[cfg(not(windows))]
pub fn read_files() -> Option<Vec<String>> {
    None
}

#[cfg(windows)]
const CF_HDROP: u32 = 15;

/// Puts the files on the clipboard, as Explorer's «Копировать» does. False when the clipboard could not be taken.
#[cfg(windows)]
pub fn write_files(paths: &[String]) -> bool {
    use windows_sys::Win32::Foundation::GlobalFree;
    use windows_sys::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData};
    use windows_sys::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
    let bytes = drop_files_bytes(paths);
    unsafe {
        let memory = GlobalAlloc(GMEM_MOVEABLE, bytes.len());
        if memory.is_null() {
            return false;
        }
        let target = GlobalLock(memory);
        if target.is_null() {
            GlobalFree(memory);
            return false;
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), target.cast::<u8>(), bytes.len());
        GlobalUnlock(memory);
        if OpenClipboard(std::ptr::null_mut()) == 0 {
            GlobalFree(memory);
            return false;
        }
        EmptyClipboard();
        // The clipboard owns the memory once it has taken it.
        let taken = !SetClipboardData(CF_HDROP, memory as _).is_null();
        if !taken {
            GlobalFree(memory);
        }
        CloseClipboard();
        taken
    }
}

#[cfg(not(windows))]
pub fn write_files(_paths: &[String]) -> bool {
    false
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
    serde_json::from_str::<Vec<serde_json::Value>>(text).unwrap_or_default().into_iter().filter_map(|value| serde_json::from_value::<ClipItem>(value).ok()).filter(|item| item.kind == "text" || item.kind == FILES).collect()
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

    #[test]
    fn copied_files() {
        let paths = vec!["C:\\Users\\Олег\\Отчёт 1.pdf".to_owned(), "D:\\photo.png".to_owned()];
        let item = ClipItem::files(&paths, Some("explorer.exe".into()), at(1));
        assert!(item.is_files() && item.paths() == paths);
        assert_eq!(item.shown_text(), "Отчёт 1.pdf, photo.png");
        assert_eq!(ClipItem::text("two\nlines", None, at(1)).shown_text(), "two ⏎ lines");
        // The Mac's file with a files entry is read whole now.
        let kept = parse(&serde_json::to_string(&vec![item.clone()]).unwrap());
        assert_eq!(kept, [item.clone()]);
        // The same files copied again move up; a text with the same characters is another entry.
        let same_as_text = ClipItem::text(&item.text, None, at(2));
        assert_eq!(adding(same_as_text, &[item.clone()], 20).len(), 2);
        assert_eq!(adding(ClipItem::files(&paths, None, at(3)), &[item], 20).len(), 1);

        let bytes = drop_files_bytes(&["C:\\a.txt".to_owned(), "Я".to_owned()]);
        assert_eq!(&bytes[..20], [20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0], "the header: where the list starts, and that it is wide");
        let wide: Vec<u16> = bytes[20..].chunks(2).map(|pair| u16::from_le_bytes([pair[0], pair[1]])).collect();
        assert_eq!(String::from_utf16(&wide).unwrap(), "C:\\a.txt\0Я\0\0");
    }

    fn at(minute: u32) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(&format!("2026-11-23T10:{minute:02}:00Z")).unwrap().with_timezone(&Utc)
    }

    #[test]
    fn what_is_recorded() {
        let managers = excluded_apps(None);
        assert!(should_record(false, None, &managers) && should_record(false, Some("Code.exe"), &managers));
        assert!(!should_record(true, Some("Code.exe"), &managers), "marked as hidden");
        assert!(!should_record(false, Some("1Password.exe"), &managers) && !should_record(false, Some("KeePassXC.exe"), &managers), "a password manager in front");
        let own = excluded_apps(Some(&[" Telegram.exe ".into(), "telegram.exe".into(), String::new(), "Code.exe".into()]));
        assert_eq!(own, ["code.exe", "telegram.exe"], "small letters, once each");
        assert!(!should_record(false, Some("CODE.EXE"), &own) && should_record(false, Some("1Password.exe"), &own), "the person's own list replaces the default");
        assert!(excluded_apps(Some(&[])).is_empty() && should_record(false, Some("1Password.exe"), &[]), "an emptied list excludes nothing");
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
        assert_eq!(parse(mac).iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), ["a", "b"], "copied files are kept, broken entries are left out");
        assert!(parse("not json").is_empty());
    }
}
