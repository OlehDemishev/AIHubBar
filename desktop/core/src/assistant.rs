//! The profile assistant (docs/specs/SPEC-modes.md §5, the Mac's `AssistantDraft`): what a chosen folder holds, the
//! source it suggests, and the blank profile «С нуля» starts from. The steps themselves live in `ui/assistant.html`;
//! nothing is saved until «Готово».

use crate::i18n::Strings;
use crate::profiles::{self, Profile};
use serde::Serialize;
use serde_json::{json, Value};
use std::path::Path;

/// What the chosen folder holds.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize)]
pub struct Analysis {
    pub repositories: usize,
    pub folders: usize,
    pub files: usize,
}

impl Analysis {
    /// Visible children only; a subfolder with a `.git` (folder, or file in a worktree) is a repository.
    pub fn of(path: &Path) -> Analysis {
        let mut analysis = Analysis::default();
        for entry in std::fs::read_dir(path).into_iter().flatten().flatten() {
            if entry.file_name().to_string_lossy().starts_with('.') {
                continue;
            }
            match entry.file_type() {
                Ok(kind) if kind.is_dir() => {
                    analysis.folders += 1;
                    if entry.path().join(".git").exists() {
                        analysis.repositories += 1;
                    }
                }
                Ok(_) => analysis.files += 1,
                Err(_) => {}
            }
        }
        analysis
    }

    /// Mostly repositories: the git scanner.
    pub fn suggests_git(&self) -> bool {
        self.repositories > 0 && self.repositories * 2 >= self.folders
    }

    /// «Внутри git-репозиториев: 3, обычных папок: 1, файлов: 2.»
    pub fn text(&self, s: &Strings) -> String {
        if self.folders == 0 && self.files == 0 {
            return s.t("Папка пуста — проекты появятся, когда вы их создадите.").to_owned();
        }
        let mut parts = Vec::new();
        if self.repositories > 0 {
            parts.push(s.format("git-репозиториев: %lld", &[&self.repositories.to_string()]));
        }
        if self.folders > self.repositories {
            parts.push(s.format("обычных папок: %lld", &[&(self.folders - self.repositories).to_string()]));
        }
        if self.files > 0 {
            parts.push(s.format("файлов: %lld", &[&self.files.to_string()]));
        }
        format!("{}{}.", s.t("Внутри "), parts.join(", "))
    }
}

/// «С нуля»: folder projects with two stages, words and last change, files only, background, dates in the calendar.
pub fn blank(s: &Strings) -> Profile {
    let mut profile = Profile::from_value(&json!({
        "name": s.t("Новый профиль"),
        "icon": "sparkle",
        "template": "custom",
        "source": {"folders": {"_0": s.t("~/Documents/Проекты")}},
        "card": "projectMD",
        "stages": [s.t("в работе"), s.t("готово")],
        "metrics": ["words", "lastActivity"],
        "wordsPerMinute": 150,
        "launchMode": "background",
        "permissions": "filesOnly",
        "calendar": "dates",
        "showProjects": true,
        "commonCommands": "none",
        "showCommonCommands": false,
        "commands": [],
    }))
    .expect("an object");
    profile.id = crate::runs::new_id();
    profile
}

/// A folder chosen for the draft (the Mac's `setFolder`): mostly git repositories → the git scanner with STATUS.md
/// cards and the «код» rules; otherwise the draft's folder kind stays (one folder, or a folder of projects) with
/// project cards and no rules for code.
pub fn set_folder(profile: &mut Value, path: &Path, analysis: Option<&Analysis>, home: &Path) {
    let folder = profiles::tilde(path, home);
    let inbox = profile["source"].get("inbox").is_some();
    if analysis.is_some_and(Analysis::suggests_git) {
        profile["source"] = json!({"gitBuiltin": {"projects": folder}});
        if profile["card"] == "projectMD" {
            profile["card"] = json!("statusMD");
        }
        profile["permissions"] = json!("code");
    } else {
        profile["source"] = if inbox { json!({"inbox": {"_0": folder}}) } else { json!({"folders": {"_0": folder}}) };
        if profile["card"] == "statusMD" {
            profile["card"] = json!("projectMD");
        }
        if profile["permissions"] == "code" {
            profile["permissions"] = json!("filesOnly");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folders_and_what_they_suggest() {
        let root = std::env::temp_dir().join(format!("claudepult-assistant-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for repo in ["a", "b"] {
            std::fs::create_dir_all(root.join(repo).join(".git")).unwrap();
        }
        std::fs::create_dir_all(root.join("notes")).unwrap();
        std::fs::create_dir_all(root.join(".hidden")).unwrap();
        std::fs::write(root.join("readme.md"), "x").unwrap();
        let analysis = Analysis::of(&root);
        assert_eq!(analysis, Analysis { repositories: 2, folders: 3, files: 1 });
        assert!(analysis.suggests_git());
        let s = Strings::from_json("{}");
        assert_eq!(analysis.text(&s), "Внутри git-репозиториев: 2, обычных папок: 1, файлов: 1.");
        assert_eq!(Analysis::default().text(&s), "Папка пуста — проекты появятся, когда вы их создадите.");
        assert!(!Analysis { repositories: 1, folders: 3, files: 0 }.suggests_git());

        let home = std::env::temp_dir();
        let mut draft = serde_json::to_value(blank(&s)).unwrap();
        set_folder(&mut draft, &root, Some(&analysis), &home);
        assert_eq!((draft["source"]["gitBuiltin"].is_object(), draft["card"].as_str(), draft["permissions"].as_str()), (true, Some("statusMD"), Some("code")));
        set_folder(&mut draft, &root.join("notes"), Some(&Analysis::of(&root.join("notes"))), &home);
        assert_eq!((draft["source"]["folders"].is_object(), draft["card"].as_str(), draft["permissions"].as_str()), (true, Some("projectMD"), Some("filesOnly")));
        draft["source"] = json!({"inbox": {"_0": "~/x"}});
        set_folder(&mut draft, &root.join("notes"), None, &home);
        assert!(draft["source"]["inbox"].is_object(), "one folder stays one folder");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn the_blank_profile() {
        let s = Strings::from_json("{}");
        let profile = blank(&s);
        assert_eq!(profile.name, "Новый профиль");
        assert_eq!(profile.stages(), ["в работе", "готово"]);
        assert_eq!((profile.calendar(), profile.launch_mode.as_deref()), ("dates", Some("background")));
        assert!(profile.source().is_folders());
        assert_ne!(blank(&s).id, profile.id);
    }
}
