//! «Версии» (the Mac's `VersionStore`, SPEC-content §4): the draft versions of folder projects, kept outside the
//! project's folder and without git. `<root>/<project>/objects/<sha256>` holds each file content once,
//! `<root>/<project>/<time>.json` is one version — path → hash, size, date, and why it was taken — in the Mac's own
//! format. Text files and the card only; images, audio and video are not kept, nor files over the size limit.

use crate::folders;
use chrono::{DateTime, Datelike, Duration, Local, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Files larger than this are skipped and named in the version.
pub const DEFAULT_SIZE_LIMIT: u64 = 20 * 1024 * 1024;
/// Every version of the last day is kept, then one a day.
pub const KEEP_ALL_HOURS: i64 = 24;
pub const DEFAULT_KEEP_DAYS: i64 = 30;
const TEXT_EXTENSIONS: [&str; 6] = ["md", "markdown", "txt", "rtf", "docx", "fountain"];

mod millis {
    use chrono::{DateTime, Utc};
    use serde::{Deserialize, Deserializer, Serializer};
    pub fn serialize<S: Serializer>(date: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_i64(date.timestamp_millis())
    }
    pub fn deserialize<'d, D: Deserializer<'d>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let ms = f64::deserialize(d)?;
        DateTime::from_timestamp_millis(ms as i64).ok_or_else(|| serde::de::Error::custom("date"))
    }
}

/// One file as it was when a version was taken.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VersionFile {
    /// Relative to the project's folder, `/` between parts.
    pub path: String,
    /// SHA-256 of the content; the content itself is `objects/<hash>`.
    pub hash: String,
    pub size: u64,
    #[serde(with = "millis")]
    pub modified: DateTime<Utc>,
}

/// Why a version was taken, as Swift encodes the Mac's `VersionReason`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Reason {
    /// The files changed since the last version.
    Automatic {},
    /// Before an AI run; the command's title.
    BeforeRun {
        #[serde(rename = "_0")]
        title: String,
    },
    /// Before a version was put back, so the current state is never lost.
    BeforeRestore {},
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Version {
    /// The file's name without `.json`: the time it was taken, sortable as text.
    pub id: String,
    #[serde(with = "millis")]
    pub taken_at: DateTime<Utc>,
    pub reason: Reason,
    pub files: Vec<VersionFile>,
    /// Text files left out for their size.
    #[serde(default)]
    pub skipped: Vec<String>,
}

impl Version {
    /// Paths whose content differs from `other` (added, changed or gone), sorted.
    pub fn changed(&self, other: Option<&Version>) -> Vec<String> {
        let before: HashMap<&str, &str> = other.map(|o| o.files.iter().map(|f| (f.path.as_str(), f.hash.as_str())).collect()).unwrap_or_default();
        let now: HashMap<&str, &str> = self.files.iter().map(|f| (f.path.as_str(), f.hash.as_str())).collect();
        let mut paths: Vec<String> = before.keys().chain(now.keys()).filter(|p| before.get(*p) != now.get(*p)).map(|p| (*p).to_owned()).collect::<HashSet<_>>().into_iter().collect();
        paths.sort();
        paths
    }

    /// The version's files that are different now (changed or gone).
    pub fn differing(&self, current: &HashMap<String, String>) -> Vec<String> {
        self.files.iter().filter(|f| current.get(&f.path) != Some(&f.hash)).map(|f| f.path.clone()).collect()
    }

    /// The files that appeared after the version; putting it back leaves them.
    pub fn added(&self, current: &HashMap<String, String>) -> Vec<String> {
        let known: HashSet<&str> = self.files.iter().map(|f| f.path.as_str()).collect();
        let mut added: Vec<String> = current.keys().filter(|p| !known.contains(p.as_str())).cloned().collect();
        added.sort();
        added
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RestoreError {
    MissingContent(String),
    CurrentTooLarge(String),
    CurrentNotSaved(String),
    Io(String),
}

impl RestoreError {
    pub fn text(&self, s: &crate::i18n::Strings) -> String {
        match self {
            RestoreError::MissingContent(path) => s.format("Содержимое файла «%@» в этой версии не найдено.", &[path]),
            RestoreError::CurrentNotSaved(path) => s.format("Файл «%@» не удалось сохранить перед возвратом — ничего не изменено.", &[path]),
            RestoreError::CurrentTooLarge(path) => s.format("Файл «%@» сейчас больше лимита версий: сохранить его перед возвратом нельзя, поэтому он не тронут.", &[path]),
            RestoreError::Io(error) => error.clone(),
        }
    }
}

/// One at a time over the whole store: a clean-up must not remove contents a version being taken has just written.
static LOCK: Mutex<()> = Mutex::new(());

fn hash(data: &[u8]) -> String {
    Sha256::digest(data).iter().map(|b| format!("{b:02x}")).collect()
}

fn is_hash(text: &str) -> bool {
    text.len() == 64 && text.chars().all(|c| c.is_ascii_hexdigit())
}

/// `20261120-153012-482`, UTC: sorts as text, and two versions a moment apart still differ.
pub fn name(date: DateTime<Utc>) -> String {
    date.format("%Y%m%d-%H%M%S-%3f").to_string()
}

pub struct Store {
    pub root: PathBuf,
}

impl Store {
    /// The project's folder in the store: its name for a person looking there, and a piece of the path's hash so two
    /// projects of the same name in different places don't mix.
    pub fn folder(&self, project: &Path) -> PathBuf {
        let path = project.to_string_lossy();
        let digest: String = Sha256::digest(path.as_bytes()).iter().take(6).map(|b| format!("{b:02x}")).collect();
        let name = project.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        self.root.join(format!("{name}-{digest}"))
    }

    fn objects(&self, project: &Path) -> PathBuf {
        self.folder(project).join("objects")
    }

    /// The project's versions, newest first.
    pub fn versions(&self, project: &Path) -> Vec<Version> {
        let mut versions: Vec<Version> = std::fs::read_dir(self.folder(project))
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
            .filter_map(|e| serde_json::from_str::<Version>(&std::fs::read_to_string(e.path()).ok()?).ok())
            .collect();
        versions.sort_by(|a, b| b.id.cmp(&a.id));
        versions
    }

    /// A file's content as it was in a version.
    pub fn content(&self, project: &Path, hash: &str) -> Option<Vec<u8>> {
        is_hash(hash).then(|| std::fs::read(self.objects(project).join(hash)).ok()).flatten()
    }

    /// The project's text files and its card as they are now; nothing is written.
    pub fn scan(project: &Path, size_limit: u64) -> (Vec<(VersionFile, Vec<u8>)>, Vec<String>) {
        let mut files = Vec::new();
        let mut skipped = Vec::new();
        for (path, modified) in folders::files(project) {
            let extension = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
            if !TEXT_EXTENSIONS.contains(&extension.as_str()) {
                continue;
            }
            let relative = folders::relative(&path, project);
            let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            if size > size_limit {
                skipped.push(relative);
                continue;
            }
            let Ok(data) = std::fs::read(&path) else { continue };
            files.push((VersionFile { path: relative, hash: hash(&data), size: data.len() as u64, modified }, data));
        }
        files.sort_by(|a, b| a.0.path.cmp(&b.0.path));
        skipped.sort();
        (files, skipped)
    }

    /// The hashes of the project's files as they are, by path.
    pub fn current(project: &Path, size_limit: u64) -> HashMap<String, String> {
        Self::scan(project, size_limit).0.into_iter().map(|(f, _)| (f.path, f.hash)).collect()
    }

    /// Takes a version of the project's texts; None when nothing differs from the last one, or there is no text.
    pub fn take(&self, project: &Path, reason: Reason, now: DateTime<Utc>, size_limit: u64) -> std::io::Result<Option<Version>> {
        let _guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        self.take_locked(project, reason, now, size_limit)
    }

    fn take_locked(&self, project: &Path, reason: Reason, now: DateTime<Utc>, size_limit: u64) -> std::io::Result<Option<Version>> {
        let (files, skipped) = Self::scan(project, size_limit);
        let last = self.versions(project).into_iter().next();
        let version = Version { id: name(now), taken_at: now, reason, files: files.iter().map(|(f, _)| f.clone()).collect(), skipped };
        if version.files.is_empty() && last.as_ref().is_none_or(|l| l.files.is_empty()) {
            return Ok(None);
        }
        if version.changed(last.as_ref()).is_empty() && !(last.is_none() && !version.files.is_empty()) {
            return Ok(None);
        }
        let objects = self.objects(project);
        std::fs::create_dir_all(&objects)?;
        for (file, data) in &files {
            let path = objects.join(&file.hash);
            if !path.exists() {
                std::fs::write(&path, data)?;
            }
        }
        // Where the project is, so a person (and the clean-up of a deleted project) can tell whose versions these are.
        let origin = self.folder(project).join("project.txt");
        if !origin.exists() {
            let _ = std::fs::write(&origin, project.to_string_lossy().as_bytes());
        }
        // The objects first: a version file never names content that is not there.
        let sorted: serde_json::Value = serde_json::to_value(&version).map_err(std::io::Error::other)?;
        let tmp = self.folder(project).join(format!("{}.json.tmp", version.id));
        std::fs::write(&tmp, serde_json::to_string_pretty(&sorted).map_err(std::io::Error::other)?)?;
        std::fs::rename(&tmp, self.folder(project).join(format!("{}.json", version.id)))?;
        Ok(Some(version))
    }

    /// A path from a version file stays inside the project's folder.
    pub fn is_safe(path: &str) -> bool {
        !path.is_empty() && !path.starts_with('/') && !path.contains(':') && !path.split(['/', '\\']).any(|part| part == "..")
    }

    /// Puts the version's files (all, or only `paths`) back in place. The current state is saved as a version first,
    /// so nothing is lost; files added since the version stay. Returns the paths that were written.
    pub fn restore(&self, project: &Path, version: &Version, paths: Option<&HashSet<String>>, now: DateTime<Utc>, size_limit: u64) -> Result<Vec<String>, RestoreError> {
        let mut writes: Vec<(PathBuf, String, Vec<u8>, Option<String>)> = Vec::new();
        // Everything is checked before anything is written.
        for file in version.files.iter().filter(|f| paths.is_none_or(|p| p.contains(&f.path))) {
            let data = Self::is_safe(&file.path).then(|| self.content(project, &file.hash)).flatten().ok_or_else(|| RestoreError::MissingContent(file.path.clone()))?;
            let target = file.path.split('/').fold(project.to_path_buf(), |at, part| at.join(part));
            let mut current_hash = None;
            if let Ok(current) = std::fs::read(&target) {
                if current == data {
                    continue;
                }
                if current.len() as u64 > size_limit {
                    return Err(RestoreError::CurrentTooLarge(file.path.clone()));
                }
                current_hash = Some(hash(&current));
            }
            writes.push((target, file.path.clone(), data, current_hash));
        }
        if writes.is_empty() {
            return Ok(Vec::new());
        }
        let _guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        self.take_locked(project, Reason::BeforeRestore {}, now, size_limit).map_err(|e| RestoreError::Io(e.to_string()))?;
        // «Saved first» is checked, not assumed.
        let saved = self.versions(project).into_iter().next();
        for (_, path, _, current_hash) in &writes {
            let Some(current_hash) = current_hash else { continue };
            let there = saved.as_ref().is_some_and(|v| v.files.iter().any(|f| &f.path == path && &f.hash == current_hash)) && self.content(project, current_hash).is_some();
            if !there {
                return Err(RestoreError::CurrentNotSaved(path.clone()));
            }
        }
        for (target, _, data, _) in &writes {
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent).map_err(|e| RestoreError::Io(e.to_string()))?;
            }
            std::fs::write(target, data).map_err(|e| RestoreError::Io(e.to_string()))?;
        }
        Ok(writes.into_iter().map(|(_, path, _, _)| path).collect())
    }

    /// The newest version taken no later than `date`: what the project was before a run that started then.
    pub fn before(&self, project: &Path, date: DateTime<Utc>) -> Option<Version> {
        self.versions(project).into_iter().find(|v| v.taken_at <= date + Duration::seconds(1))
    }

    /// Removes the versions past their time and the contents no version names any more; how many versions went.
    pub fn prune(&self, project: &Path, now: DateTime<Utc>, keep_days: i64) -> usize {
        let _guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let all = self.versions(project);
        let kept = kept(&all, now, keep_days);
        for version in all.iter().filter(|v| !kept.contains(&v.id)) {
            let _ = std::fs::remove_file(self.folder(project).join(format!("{}.json", version.id)));
        }
        let used: HashSet<&str> = all.iter().filter(|v| kept.contains(&v.id)).flat_map(|v| v.files.iter().map(|f| f.hash.as_str())).collect();
        for object in std::fs::read_dir(self.objects(project)).into_iter().flatten().flatten() {
            if !used.contains(object.file_name().to_string_lossy().as_ref()) {
                let _ = std::fs::remove_file(object.path());
            }
        }
        all.len() - kept.len()
    }

    /// The stores of projects whose folder is gone, once their newest version is older than `days`.
    pub fn remove_orphans(&self, now: DateTime<Utc>, days: i64) -> Vec<String> {
        let _guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let mut removed = Vec::new();
        for folder in std::fs::read_dir(&self.root).into_iter().flatten().flatten() {
            let Ok(origin) = std::fs::read_to_string(folder.path().join("project.txt")) else { continue };
            if Path::new(&origin).exists() {
                continue;
            }
            let newest = self.versions(Path::new(&origin)).first().map(|v| v.taken_at);
            if newest.is_none_or(|at| now - at > Duration::days(days)) && std::fs::remove_dir_all(folder.path()).is_ok() {
                removed.push(origin);
            }
        }
        removed
    }

    /// Bytes on disk.
    pub fn size(&self) -> u64 {
        fn walk(dir: &Path) -> u64 {
            std::fs::read_dir(dir).into_iter().flatten().flatten().map(|e| if e.path().is_dir() { walk(&e.path()) } else { e.metadata().map(|m| m.len()).unwrap_or(0) }).sum()
        }
        walk(&self.root)
    }

    /// «Очистить»: every version of every project.
    pub fn clear(&self) {
        let _guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// Which versions stay: all of the last 24 hours, then the last one of each day for `keep_days` days.
pub fn kept(versions: &[Version], now: DateTime<Utc>, keep_days: i64) -> HashSet<String> {
    let mut sorted: Vec<&Version> = versions.iter().collect();
    sorted.sort_by(|a, b| b.id.cmp(&a.id));
    let mut kept = HashSet::new();
    let mut days = HashSet::new();
    for version in sorted {
        let age = now - version.taken_at;
        if age <= Duration::hours(KEEP_ALL_HOURS) {
            kept.insert(version.id.clone());
        } else if age <= Duration::days(keep_days) {
            let local = Local.from_utc_datetime(&version.taken_at.naive_utc());
            // Newest first, so the first one seen of a day is that day's last.
            if days.insert((local.year(), local.ordinal())) {
                kept.insert(version.id.clone());
            }
        }
    }
    kept
}

/// The text of a kept file's content: Markdown and text as they are, a Word file read like the word counts read it.
pub fn text_of(data: &[u8], path: &str) -> Option<String> {
    let extension = path.rsplit('.').next().unwrap_or_default().to_lowercase();
    match extension.as_str() {
        "docx" => crate::docx::text_of_bytes(data),
        "rtf" => Some(folders::rtf_text(&String::from_utf8_lossy(data))),
        _ => String::from_utf8(data.to_vec()).ok(),
    }
}

/// Two texts side by side, line by line (the Mac's `TextCompare.rows`): equal lines on both sides, a changed line
/// as old against new, a removed or added one alone on its side.
pub fn compare_rows(old: &str, new: &str, limit: usize) -> (Vec<(Option<String>, Option<String>)>, bool) {
    let old_lines: Vec<&str> = old.lines().take(limit).collect();
    let new_lines: Vec<&str> = new.lines().take(limit).collect();
    let cut = old.lines().count() > limit || new.lines().count() > limit;
    // The longest common subsequence, then a walk that pairs a removed line with an added one.
    let (n, m) = (old_lines.len(), new_lines.len());
    let mut lcs = vec![vec![0u32; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            lcs[i][j] = if old_lines[i] == new_lines[j] { lcs[i + 1][j + 1] + 1 } else { lcs[i + 1][j].max(lcs[i][j + 1]) };
        }
    }
    let mut rows = Vec::new();
    let (mut i, mut j) = (0, 0);
    while i < n || j < m {
        if i < n && j < m && old_lines[i] == new_lines[j] {
            rows.push((Some(old_lines[i].to_owned()), Some(new_lines[j].to_owned())));
            i += 1;
            j += 1;
        } else if i < n && j < m && lcs[i + 1][j] == lcs[i][j + 1] {
            rows.push((Some(old_lines[i].to_owned()), Some(new_lines[j].to_owned())));
            i += 1;
            j += 1;
        } else if j >= m || (i < n && lcs[i + 1][j] >= lcs[i][j + 1]) {
            rows.push((Some(old_lines[i].to_owned()), None));
            i += 1;
        } else {
            rows.push((None, Some(new_lines[j].to_owned())));
            j += 1;
        }
    }
    (rows, cut)
}

/// The reason in the list's words.
pub fn reason_text(reason: &Reason, s: &crate::i18n::Strings) -> String {
    match reason {
        Reason::Automatic {} => s.t("автоматически").to_owned(),
        Reason::BeforeRun { title } => s.format("перед «%@»", &[title]),
        Reason::BeforeRestore {} => s.t("перед возвратом версии").to_owned(),
    }
}

/// Keeps the Mac's map order in tests that compare JSON.
pub fn sorted_json(value: &serde_json::Value) -> BTreeMap<String, serde_json::Value> {
    value.as_object().map(|o| o.iter().map(|(k, v)| (k.clone(), v.clone())).collect()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> (Store, PathBuf) {
        let base = std::env::temp_dir().join(format!("claudepult-versions-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let project = base.join("Статья про кофе");
        std::fs::create_dir_all(&project).unwrap();
        (Store { root: base.join("store") }, project)
    }

    #[test]
    fn taking_and_putting_back() {
        let (store, project) = scratch("take");
        let now = Utc::now();
        assert!(store.take(&project, Reason::Automatic {}, now, DEFAULT_SIZE_LIMIT).unwrap().is_none(), "no text yet");
        std::fs::write(project.join("текст.md"), "Первая строка\nвторая\n").unwrap();
        std::fs::write(project.join("cover.png"), [0u8, 1, 2]).unwrap();
        let first = store.take(&project, Reason::BeforeRun { title: "Редактура".into() }, now, DEFAULT_SIZE_LIMIT).unwrap().unwrap();
        assert_eq!(first.files.iter().map(|f| f.path.as_str()).collect::<Vec<_>>(), ["текст.md"], "texts only");
        assert!(store.take(&project, Reason::Automatic {}, now + Duration::seconds(1), DEFAULT_SIZE_LIMIT).unwrap().is_none(), "nothing changed");
        std::fs::write(project.join("текст.md"), "Первая строка\nВТОРАЯ\nтретья\n").unwrap();
        std::fs::write(project.join("новое.txt"), "позже").unwrap();
        let second = store.take(&project, Reason::Automatic {}, now + Duration::seconds(2), DEFAULT_SIZE_LIMIT).unwrap().unwrap();
        assert_eq!(second.changed(Some(&first)), ["новое.txt", "текст.md"]);
        assert_eq!(store.versions(&project).len(), 2);
        // Putting the first back: the current state is saved first, the later file stays.
        let written = store.restore(&project, &first, None, now + Duration::seconds(3), DEFAULT_SIZE_LIMIT).unwrap();
        assert_eq!(written, ["текст.md"]);
        assert_eq!(std::fs::read_to_string(project.join("текст.md")).unwrap(), "Первая строка\nвторая\n");
        assert!(project.join("новое.txt").exists(), "a file added since stays");
        // The current state was the last version already, so none was added; it is still there to go back to.
        let all = store.versions(&project);
        assert_eq!(all.len(), 2);
        assert!(all[0].files.iter().any(|f| f.path == "текст.md" && store.content(&project, &f.hash).is_some_and(|c| c.starts_with("Первая строка\nВТОРАЯ".as_bytes()))), "what was there is kept");
        // Changed again, then put back: now a version «перед возвратом версии» comes first.
        std::fs::write(project.join("текст.md"), "совсем другое
").unwrap();
        store.restore(&project, &second, None, now + Duration::seconds(4), DEFAULT_SIZE_LIMIT).unwrap();
        assert_eq!(store.versions(&project)[0].reason, Reason::BeforeRestore {});
        assert_eq!(std::fs::read_to_string(project.join("текст.md")).unwrap(), "Первая строка
ВТОРАЯ
третья
");
        // A file too large is skipped and named.
        let skipped = Store::scan(&project, 5).1;
        assert_eq!(skipped.len(), 2);
        let _ = std::fs::remove_dir_all(project.parent().unwrap());
    }

    #[test]
    fn the_macs_version_file() {
        let text = r#"{"files":[{"hash":"aa","modified":1763990000000,"path":"текст.md","size":12}],"id":"20261124-120000-000","reason":{"beforeRun":{"_0":"Редактура"}},"skipped":[],"takenAt":1763990000000}"#;
        let version: Version = serde_json::from_str(text).unwrap();
        assert_eq!(version.reason, Reason::BeforeRun { title: "Редактура".into() });
        let back = serde_json::to_value(&version).unwrap();
        assert_eq!(sorted_json(&back), sorted_json(&serde_json::from_str(text).unwrap()));
        let automatic: Version = serde_json::from_str(&text.replace(r#"{"beforeRun":{"_0":"Редактура"}}"#, r#"{"automatic":{}}"#)).unwrap();
        assert_eq!(automatic.reason, Reason::Automatic {});
        assert!(Store::is_safe("папка/текст.md") && !Store::is_safe("../x") && !Store::is_safe("C:/x") && !Store::is_safe("/x"));
    }

    #[test]
    fn which_versions_stay() {
        let now = Utc::now();
        let version = |hours: i64| Version { id: name(now - Duration::hours(hours)), taken_at: now - Duration::hours(hours), reason: Reason::Automatic {}, files: vec![], skipped: vec![] };
        let all = vec![version(1), version(5), version(30), version(31), version(24 * 40)];
        let kept = kept(&all, now, DEFAULT_KEEP_DAYS);
        assert!(kept.contains(&all[0].id) && kept.contains(&all[1].id), "the last day whole");
        assert!(!kept.contains(&all[4].id), "past the days kept");
        assert!(kept.contains(&all[2].id) != kept.contains(&all[3].id) || (now - Duration::hours(30)).date_naive() != (now - Duration::hours(31)).date_naive(), "one a day after that");
    }

    #[test]
    fn two_texts_side_by_side() {
        let (rows, cut) = compare_rows("a\nb\nc\n", "a\nB\nc\nd\n", 3000);
        assert_eq!(rows, [(Some("a".into()), Some("a".into())), (Some("b".into()), Some("B".into())), (Some("c".into()), Some("c".into())), (None, Some("d".into()))]);
        assert!(!cut);
        assert!(compare_rows("x\n".repeat(10).as_str(), "", 5).1);
    }
}
