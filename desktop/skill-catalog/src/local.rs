//! Where the agents keep skills on this computer, by their own documentation (checked 2026-11-26):
//!
//! | Agent | For the person | In a project |
//! |---|---|---|
//! | Claude Code | `~/.claude/skills`, plugins by `~/.claude/plugins/installed_plugins.json` | `.claude/skills` |
//! | Codex | `~/.agents/skills`; `~/.codex/skills` (older, still on disk) | `.agents/skills` |
//! | Cursor | `~/.cursor/skills`, `~/.agents/skills`, and it reads `~/.claude/skills`, `~/.codex/skills` | the same four |
//! | Gemini CLI | `~/.gemini/skills`, `~/.agents/skills`, extensions in `~/.gemini/extensions` | `.gemini/skills`, `.agents/skills` |
//!
//! Only Claude Code documents its Windows folder (`%USERPROFILE%\.claude`); for the others the home folder is used
//! the same way. Everything here only lists folders: nothing is opened for writing.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const CLAUDE: &str = "claude";
pub const CODEX: &str = "codex";
pub const CURSOR: &str = "cursor";
pub const GEMINI: &str = "gemini";
pub const AGENTS: [&str; 4] = [CLAUDE, CODEX, CURSOR, GEMINI];

/// A skill switched off in AI Hub Bar's «инструкции и MCP» window is moved to the folder beside, with this suffix.
const OFF_SUFFIX: &str = ".disabled";

#[derive(Debug, Clone)]
pub struct Roots {
    pub home: PathBuf,
    /// `~/.claude`, or `CLAUDE_CONFIG_DIR`.
    pub claude_dir: PathBuf,
    /// `~/.codex`, or `CODEX_HOME`.
    pub codex_dir: PathBuf,
    /// The folder whose subfolders are projects (`~/Projects`).
    pub projects_dir: Option<PathBuf>,
}

impl Roots {
    /// The real folders, unless `AIHUBBAR_SKILLS_HOME` names a folder to look in instead: a made-up home for
    /// trying the catalog without the person's own skills.
    pub fn or_test_home(self) -> Roots {
        match std::env::var("AIHUBBAR_SKILLS_HOME").ok().filter(|value| !value.trim().is_empty()) {
            Some(home) => Roots::under(Path::new(&home)),
            None => self,
        }
    }

    /// Where the catalog's database is: the app's own file, or one inside the made-up home, so that trying things
    /// never mixes with what is known about the person's real skills.
    pub fn database(default: PathBuf) -> PathBuf {
        match std::env::var("AIHUBBAR_SKILLS_HOME").ok().filter(|value| !value.trim().is_empty()) {
            Some(home) => Path::new(&home).join(".aihubbar-skills").join("catalog.db"),
            None => default,
        }
    }

    /// Everything under one folder, as on a fresh computer: for tests and for trying things without the real ones.
    pub fn under(home: &Path) -> Roots {
        Roots { home: home.to_owned(), claude_dir: home.join(".claude"), codex_dir: home.join(".codex"), projects_dir: Some(home.join("Projects")) }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Place {
    pub agent: &'static str,
    /// The folder as the agent sees it (it may be a link).
    pub install_path: PathBuf,
    /// `user`, `project`, `plugin` or `extension`.
    pub scope: &'static str,
    pub project: Option<String>,
    pub enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    /// `skill` or `plugin`.
    pub kind: &'static str,
    /// The real folder, links resolved: the same skill linked into several agents is one entry.
    pub folder: PathBuf,
    /// A plugin's name as its agent lists it (`name@marketplace`).
    pub listed_name: Option<String>,
    pub places: Vec<Place>,
}

fn subfolders(folder: &Path) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = std::fs::read_dir(folder)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|entry| !entry.file_name().to_string_lossy().starts_with('.'))
        .map(|entry| entry.path())
        // `is_dir` follows a link: a skill linked from a shared folder counts.
        .filter(|path| path.is_dir())
        .collect();
    found.sort();
    found
}

/// The skills of one skills folder: every subfolder with a SKILL.md, and one level deeper for a group folder.
fn skills_in(folder: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    for child in subfolders(folder) {
        if child.join("SKILL.md").is_file() {
            found.push(child);
        } else {
            found.extend(subfolders(&child).into_iter().filter(|inner| inner.join("SKILL.md").is_file()));
        }
    }
    found
}

fn beside(folder: &Path, suffix: &str) -> PathBuf {
    let mut name = folder.file_name().unwrap_or_default().to_os_string();
    name.push(suffix);
    folder.with_file_name(name)
}

struct Collector {
    by_folder: BTreeMap<PathBuf, Found>,
}

impl Collector {
    fn add(&mut self, kind: &'static str, path: &Path, listed_name: Option<String>, agents: &[&'static str], scope: &'static str, project: Option<&str>, enabled: bool) {
        let Ok(real) = std::fs::canonicalize(path) else { return };
        let found = self.by_folder.entry(real.clone()).or_insert_with(|| Found { kind, folder: real, listed_name, places: Vec::new() });
        for agent in agents {
            let place = Place { agent, install_path: path.to_owned(), scope, project: project.map(str::to_owned), enabled };
            if !found.places.iter().any(|p| p.agent == place.agent && p.install_path == place.install_path) {
                found.places.push(place);
            }
        }
    }

    fn skills_folder(&mut self, folder: &Path, agents: &[&'static str], scope: &'static str, project: Option<&str>) {
        for skill in skills_in(folder) {
            self.add("skill", &skill, None, agents, scope, project, true);
        }
        for skill in skills_in(&beside(folder, OFF_SUFFIX)) {
            self.add("skill", &skill, None, agents, scope, project, false);
        }
    }
}

/// Claude Code's installed plugins: `{"plugins": {"name@marketplace": [{"installPath": …}]}}`.
fn claude_plugins(claude_dir: &Path) -> Vec<(String, PathBuf)> {
    let Ok(text) = std::fs::read_to_string(claude_dir.join("plugins").join("installed_plugins.json")) else { return Vec::new() };
    let Ok(root) = serde_json::from_str::<serde_json::Value>(&text) else { return Vec::new() };
    let mut found = Vec::new();
    for (name, installs) in root.get("plugins").and_then(|plugins| plugins.as_object()).into_iter().flatten() {
        // Version 1 of the file had one object, version 2 a list.
        let installs: Vec<&serde_json::Value> = match installs.as_array() {
            Some(list) => list.iter().collect(),
            None => vec![installs],
        };
        for install in installs {
            if let Some(path) = install.get("installPath").and_then(|path| path.as_str()) {
                found.push((name.clone(), PathBuf::from(path)));
            }
        }
    }
    found
}

/// The person's own skills folders, each with the agents that read it.
pub fn user_skill_dirs(roots: &Roots) -> Vec<(PathBuf, Vec<&'static str>)> {
    let home = &roots.home;
    vec![
        (roots.claude_dir.join("skills"), vec![CLAUDE, CURSOR]),
        (roots.codex_dir.join("skills"), vec![CODEX, CURSOR]),
        (home.join(".agents").join("skills"), vec![CODEX, CURSOR, GEMINI]),
        (home.join(".cursor").join("skills"), vec![CURSOR]),
        (home.join(".gemini").join("skills"), vec![GEMINI]),
    ]
}

/// Where a skill is put for an agent: the folder that agent's documentation names first. The other agents that
/// read the same folder come with it.
pub fn install_dir(roots: &Roots, agent: &str) -> Option<(PathBuf, Vec<&'static str>)> {
    let index = match agent {
        CLAUDE => 0,
        CODEX => 2,
        CURSOR => 3,
        GEMINI => 4,
        _ => return None,
    };
    user_skill_dirs(roots).into_iter().nth(index)
}

/// The folder a switched-off skill is kept in, beside its skills folder.
pub fn off_dir(skills_dir: &Path) -> PathBuf {
    beside(skills_dir, OFF_SUFFIX)
}

/// Every skill and plugin the agents on this computer would load, each real folder once.
pub fn discover(roots: &Roots) -> Vec<Found> {
    let mut all = Collector { by_folder: BTreeMap::new() };
    let home = &roots.home;
    for (folder, agents) in user_skill_dirs(roots) {
        all.skills_folder(&folder, &agents, "user", None);
    }

    for (name, path) in claude_plugins(&roots.claude_dir) {
        if path.is_dir() {
            all.add("plugin", &path, Some(name), &[CLAUDE], "plugin", None, true);
        }
    }
    for extension in subfolders(&home.join(".gemini").join("extensions")) {
        if extension.join("gemini-extension.json").is_file() {
            all.add("plugin", &extension, None, &[GEMINI], "extension", None, true);
        }
    }

    for project in roots.projects_dir.iter().flat_map(|folder| subfolders(folder)) {
        let name = project.file_name().unwrap_or_default().to_string_lossy().into_owned();
        all.skills_folder(&project.join(".claude").join("skills"), &[CLAUDE, CURSOR], "project", Some(&name));
        all.skills_folder(&project.join(".agents").join("skills"), &[CODEX, CURSOR, GEMINI], "project", Some(&name));
        all.skills_folder(&project.join(".cursor").join("skills"), &[CURSOR], "project", Some(&name));
        all.skills_folder(&project.join(".codex").join("skills"), &[CURSOR], "project", Some(&name));
        all.skills_folder(&project.join(".gemini").join("skills"), &[GEMINI], "project", Some(&name));
    }
    all.by_folder.into_values().collect()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A folder of its own under the system's temporary folder, removed when dropped.
    pub(crate) struct Scratch(pub PathBuf);

    impl Scratch {
        pub(crate) fn new(name: &str) -> Scratch {
            let path = std::env::temp_dir().join(format!("aihubbar-skills-{name}-{}-{:?}", std::process::id(), std::thread::current().id()));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Scratch(std::fs::canonicalize(&path).unwrap())
        }

        pub(crate) fn write(&self, path: &str, text: &str) {
            let full = self.0.join(path);
            std::fs::create_dir_all(full.parent().unwrap()).unwrap();
            std::fs::write(full, text).unwrap();
        }

        pub(crate) fn skill(&self, folder: &str, name: &str) {
            self.write(&format!("{folder}/{name}/SKILL.md"), &format!("---\nname: {name}\ndescription: The {name} skill.\nlicense: MIT\n---\n# {name}\n"));
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn every_agents_folders_are_found() {
        let home = Scratch::new("discover");
        home.skill(".claude/skills", "one");
        home.skill(".claude/skills.disabled", "off");
        home.skill(".claude/skills/group", "nested");
        home.skill(".codex/skills", "two");
        home.skill(".agents/skills", "three");
        home.skill(".cursor/skills", "four");
        home.skill(".gemini/skills", "five");
        home.skill("Projects/app/.claude/skills", "six");
        home.skill("Projects/app/.agents/skills", "seven");
        home.write(".claude/skills/not-a-skill/README.md", "no SKILL.md here");
        home.write(".gemini/extensions/ext/gemini-extension.json", r#"{"name": "ext"}"#);
        home.write(".claude/plugins/cache/market/plug/1.0.0/.claude-plugin/plugin.json", r#"{"name": "plug"}"#);
        let install = home.0.join(".claude/plugins/cache/market/plug/1.0.0");
        home.write(".claude/plugins/installed_plugins.json", &serde_json::json!({"version": 2, "plugins": {"plug@market": [{"installPath": install}]}}).to_string());

        let found = discover(&Roots::under(&home.0));
        let named = |name: &str| found.iter().find(|f| f.folder.file_name().unwrap() == name).unwrap_or_else(|| panic!("{name} not found"));
        assert_eq!(found.len(), 11);
        assert_eq!(named("one").places.iter().map(|p| p.agent).collect::<Vec<_>>(), [CLAUDE, CURSOR]);
        assert!(named("one").places[0].enabled && !named("off").places[0].enabled);
        assert_eq!(named("nested").kind, "skill");
        assert_eq!(named("three").places.iter().map(|p| p.agent).collect::<Vec<_>>(), [CODEX, CURSOR, GEMINI]);
        assert_eq!(named("four").places.iter().map(|p| p.agent).collect::<Vec<_>>(), [CURSOR]);
        assert_eq!((named("six").places[0].scope, named("six").places[0].project.as_deref()), ("project", Some("app")));
        assert_eq!((named("ext").kind, named("ext").places[0].scope), ("plugin", "extension"));
        assert_eq!((named("1.0.0").kind, named("1.0.0").listed_name.as_deref()), ("plugin", Some("plug@market")));
    }

    #[cfg(unix)]
    #[test]
    fn a_skill_linked_into_two_agents_is_one_entry() {
        let home = Scratch::new("links");
        home.skill(".agents/skills", "shared");
        std::fs::create_dir_all(home.0.join(".claude/skills")).unwrap();
        std::os::unix::fs::symlink(home.0.join(".agents/skills/shared"), home.0.join(".claude/skills/shared")).unwrap();
        let found = discover(&Roots::under(&home.0));
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].folder, home.0.join(".agents/skills/shared"));
        let mut agents: Vec<&str> = found[0].places.iter().map(|p| p.agent).collect();
        agents.sort_unstable();
        agents.dedup();
        assert_eq!(agents, [CLAUDE, CODEX, CURSOR, GEMINI]);
        assert_eq!(found[0].places.len(), 5);
    }
}
