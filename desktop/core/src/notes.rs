//! «Заметки» (the Mac's `NotesStore`): Markdown files in one folder, a note each. Plain files, so any editor opens
//! them; the app only lists, edits, creates and moves them to the Recycle Bin.

use std::cmp::Ordering;
use std::path::{Path, PathBuf};

pub const KIND: &str = "notes";

/// «Documents\ClaudePult Notes», the Mac's name of the folder.
pub fn default_folder() -> PathBuf {
    dirs::document_dir().or_else(dirs::home_dir).unwrap_or_else(std::env::temp_dir).join("ClaudePult Notes")
}

/// «Note 2» before «Note 10», letters without their case.
fn natural(a: &str, b: &str) -> Ordering {
    fn parts(text: &str) -> Vec<(bool, u64, String)> {
        let mut parts: Vec<(bool, u64, String)> = Vec::new();
        for c in text.to_lowercase().chars() {
            match (c.to_digit(10), parts.last_mut()) {
                (Some(digit), Some((false, number, _))) => *number = number.saturating_mul(10).saturating_add(digit as u64),
                (Some(digit), _) => parts.push((false, digit as u64, String::new())),
                (None, Some((true, _, word))) => word.push(c),
                (None, _) => parts.push((true, 0, c.to_string())),
            }
        }
        parts
    }
    parts(a).cmp(&parts(b)).then_with(|| a.cmp(b))
}

/// The notes among a folder's files: `.md`, not hidden, in order.
pub fn note_names<S: AsRef<str>>(files: &[S]) -> Vec<String> {
    let mut names: Vec<String> = files
        .iter()
        .map(AsRef::as_ref)
        .filter(|file| file.to_lowercase().ends_with(".md") && !file.starts_with('.') && file.len() > 3)
        .map(|file| file[..file.len() - 3].to_owned())
        .collect();
    names.sort_by(|a, b| natural(a, b));
    names
}

/// «Заметка», «Заметка 2», … — the first free name.
pub fn free_name(base: &str, taken: &[String]) -> String {
    if !taken.iter().any(|name| name == base) {
        return base.to_owned();
    }
    (2..).map(|number| format!("{base} {number}")).find(|name| !taken.contains(name)).unwrap_or_default()
}

/// A note's name is a file's name in the folder, never a path out of it.
pub fn is_name(name: &str) -> bool {
    !name.is_empty() && !name.starts_with('.') && !name.contains("..") && !name.chars().any(|c| c.is_control() || "/\\:<>\"|?*".contains(c))
}

pub fn file(folder: &Path, name: &str) -> Option<PathBuf> {
    is_name(name).then(|| folder.join(format!("{name}.md")))
}

/// The folder's notes; the folder is made on first use.
pub fn list(folder: &Path) -> Vec<String> {
    let _ = std::fs::create_dir_all(folder);
    let files: Vec<String> = std::fs::read_dir(folder).into_iter().flatten().flatten().filter(|entry| entry.path().is_file()).map(|entry| entry.file_name().to_string_lossy().into_owned()).collect();
    note_names(&files)
}

pub fn read(folder: &Path, name: &str) -> String {
    file(folder, name).and_then(|path| std::fs::read_to_string(path).ok()).unwrap_or_default()
}

/// Written only when the text differs from the file, through a temporary file.
pub fn write(folder: &Path, name: &str, text: &str) -> Result<(), String> {
    let path = file(folder, name).ok_or("not a note's name")?;
    if std::fs::read_to_string(&path).is_ok_and(|old| old == text) {
        return Ok(());
    }
    std::fs::create_dir_all(folder).map_err(|error| error.to_string())?;
    let tmp = folder.join(format!(".{name}.md.tmp"));
    std::fs::write(&tmp, text).and_then(|_| std::fs::rename(&tmp, &path)).map_err(|error| {
        let _ = std::fs::remove_file(&tmp);
        error.to_string()
    })
}

/// A new empty note with the first free name.
pub fn create(folder: &Path, base: &str) -> Result<String, String> {
    let name = free_name(base, &list(folder));
    let path = file(folder, &name).ok_or("not a note's name")?;
    std::fs::OpenOptions::new().write(true).create_new(true).open(path).map_err(|error| error.to_string())?;
    Ok(name)
}

/// To the Recycle Bin, not deleted: a note removed by mistake can be put back.
#[cfg(windows)]
pub fn trash(path: &Path) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::UI::Shell::{SHFileOperationW, FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_NOERRORUI, FOF_SILENT, FO_DELETE, SHFILEOPSTRUCTW};
    // The list of files ends with two zeros.
    let from: Vec<u16> = path.as_os_str().encode_wide().chain([0, 0]).collect();
    let mut operation: SHFILEOPSTRUCTW = unsafe { std::mem::zeroed() };
    operation.wFunc = FO_DELETE as _;
    operation.pFrom = from.as_ptr();
    operation.fFlags = (FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT) as _;
    let result = unsafe { SHFileOperationW(&mut operation) };
    if result != 0 || operation.fAnyOperationsAborted != 0 || path.exists() {
        return Err(format!("the Recycle Bin did not take the file ({result})"));
    }
    Ok(())
}

/// What the desktop's own tool does (`gio trash`); without it the file stays.
#[cfg(not(windows))]
pub fn trash(path: &Path) -> Result<(), String> {
    let status = std::process::Command::new("gio").arg("trash").arg(path).status().map_err(|error| error.to_string())?;
    if !status.success() || path.exists() {
        return Err("the trash did not take the file".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_of_notes() {
        assert_eq!(note_names(&["b.md", "Заметка 10.MD", "a.txt", ".hidden.md", "Заметка 2.md", "A.md", ".md", "Заметка.md"]), ["A", "b", "Заметка", "Заметка 2", "Заметка 10"]);
        let taken: Vec<String> = ["Заметка", "Заметка 2"].map(str::to_owned).to_vec();
        assert_eq!((free_name("Заметка", &[]), free_name("Заметка", &taken), free_name("План", &taken)), ("Заметка".into(), "Заметка 3".into(), "План".into()));
        assert!(is_name("План на неделю") && is_name("v1.2"));
        for bad in ["", ".env", "..", "a/b", "a\\b", "C:x", "a..b", "что?", "a\nb"] {
            assert!(!is_name(bad), "{bad:?}");
        }
    }

    #[test]
    fn notes_in_a_folder() {
        let folder = std::env::temp_dir().join(format!("claudepult-notes-{}", std::process::id())).join("made on first use");
        let _ = std::fs::remove_dir_all(&folder);
        assert!(list(&folder).is_empty() && folder.is_dir());
        assert_eq!(create(&folder, "Заметка").unwrap(), "Заметка");
        assert_eq!(create(&folder, "Заметка").unwrap(), "Заметка 2");
        std::fs::create_dir(folder.join("папка.md")).unwrap();
        assert_eq!(list(&folder), ["Заметка", "Заметка 2"], "a folder is not a note");
        assert_eq!(read(&folder, "Заметка"), "");
        write(&folder, "Заметка", "# Привет\n").unwrap();
        assert_eq!(read(&folder, "Заметка"), "# Привет\n");
        let written = std::fs::metadata(file(&folder, "Заметка").unwrap()).unwrap().modified().unwrap();
        write(&folder, "Заметка", "# Привет\n").unwrap();
        assert_eq!(std::fs::metadata(file(&folder, "Заметка").unwrap()).unwrap().modified().unwrap(), written, "the same text is not written again");
        assert!(write(&folder, "../вне", "x").is_err() && !folder.parent().unwrap().join("вне.md").exists());
        assert_eq!((read(&folder, "нет такой"), read(&folder, "..\\x")), (String::new(), String::new()));
        assert_eq!(list(&folder).len(), 2, "no temporary file is left");
        std::fs::remove_dir_all(folder.parent().unwrap()).unwrap();
    }
}
