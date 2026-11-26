//! Reading a skill's folder as data: every file's bytes, never a process. Links are recorded, not followed.

use sha2::{Digest, Sha256};
use std::io::{self, Read};
use std::path::Path;

/// How much of a folder is read. A skill is a few text files; anything far larger is reported, not loaded.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub max_files: usize,
    /// A larger file is hashed but its text is not checked.
    pub max_file_bytes: u64,
    pub max_total_bytes: u64,
}

impl Default for Limits {
    fn default() -> Self {
        Limits { max_files: 3000, max_file_bytes: 2 * 1024 * 1024, max_total_bytes: 64 * 1024 * 1024 }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileEntry {
    /// Relative to the skill's folder, with `/` on every system.
    pub path: String,
    /// Empty for a link and for a file over the limit.
    pub bytes: Vec<u8>,
    pub size: u64,
    /// SHA-256 of the file's bytes (of the target's text for a link).
    pub digest: [u8; 32],
    pub executable: bool,
    /// Where a symbolic link points, as written.
    pub symlink: Option<String>,
    /// Too large to check: hashed only.
    pub unread: bool,
}

impl FileEntry {
    /// A file made in memory, for tests and for content that came from the network.
    pub fn text(path: &str, text: &str) -> FileEntry {
        FileEntry::bytes(path, text.as_bytes().to_vec())
    }

    pub fn bytes(path: &str, bytes: Vec<u8>) -> FileEntry {
        let digest = Sha256::digest(&bytes).into();
        FileEntry { path: path.to_owned(), size: bytes.len() as u64, bytes, digest, executable: false, symlink: None, unread: false }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SkillFiles {
    /// Sorted by path.
    pub files: Vec<FileEntry>,
    /// Folders that were not walked (`node_modules`, a virtual environment).
    pub skipped: Vec<String>,
    /// The limits were reached: some files are missing.
    pub truncated: bool,
}

impl SkillFiles {
    pub fn of(mut files: Vec<FileEntry>) -> SkillFiles {
        files.sort_by(|a, b| a.path.cmp(&b.path));
        SkillFiles { files, skipped: Vec::new(), truncated: false }
    }

    pub fn get(&self, path: &str) -> Option<&FileEntry> {
        self.files.iter().find(|file| file.path == path)
    }

    pub fn total_bytes(&self) -> u64 {
        self.files.iter().map(|file| file.size).sum()
    }
}

const SILENT: [&str; 4] = [".git", ".DS_Store", "Thumbs.db", "desktop.ini"];
const NOT_WALKED: [&str; 6] = ["node_modules", ".venv", "venv", "__pycache__", "site-packages", ".tox"];

fn digest_of(path: &Path) -> io::Result<[u8; 32]> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher.finalize().into())
}

#[cfg(unix)]
fn is_executable(meta: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt;
    meta.permissions().mode() & 0o111 != 0
}

#[cfg(not(unix))]
fn is_executable(_meta: &std::fs::Metadata) -> bool {
    false
}

/// Every file under `root`. A link is kept as a link, whatever it points to; the root itself may be a link to a
/// folder (skills are often linked into an agent's folder from one shared place).
pub fn read_folder(root: &Path, limits: Limits) -> io::Result<SkillFiles> {
    let root = std::fs::canonicalize(root)?;
    let mut found = SkillFiles::default();
    let mut total: u64 = 0;
    let mut folders = vec![(root.clone(), String::new())];
    while let Some((folder, prefix)) = folders.pop() {
        let mut entries: Vec<_> = std::fs::read_dir(&folder)?.flatten().collect();
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let name = entry.file_name().to_string_lossy().into_owned();
            if SILENT.contains(&name.as_str()) {
                continue;
            }
            let relative = if prefix.is_empty() { name.clone() } else { format!("{prefix}/{name}") };
            let Ok(meta) = std::fs::symlink_metadata(entry.path()) else { continue };
            if meta.file_type().is_symlink() {
                let target = std::fs::read_link(entry.path()).map(|t| t.to_string_lossy().into_owned()).unwrap_or_default();
                let digest = Sha256::digest(target.as_bytes()).into();
                found.files.push(FileEntry { path: relative, bytes: Vec::new(), size: 0, digest, executable: false, symlink: Some(target), unread: false });
                continue;
            }
            if meta.is_dir() {
                if NOT_WALKED.contains(&name.as_str()) {
                    found.skipped.push(relative);
                } else {
                    folders.push((entry.path(), relative));
                }
                continue;
            }
            if !meta.is_file() {
                continue;
            }
            if found.files.len() >= limits.max_files || total >= limits.max_total_bytes {
                found.truncated = true;
                continue;
            }
            let size = meta.len();
            let executable = is_executable(&meta);
            if size > limits.max_file_bytes {
                let digest = digest_of(&entry.path())?;
                found.files.push(FileEntry { path: relative, bytes: Vec::new(), size, digest, executable, symlink: None, unread: true });
                continue;
            }
            let bytes = std::fs::read(entry.path())?;
            total += bytes.len() as u64;
            let digest = Sha256::digest(&bytes).into();
            found.files.push(FileEntry { path: relative, size: bytes.len() as u64, bytes, digest, executable, symlink: None, unread: false });
        }
    }
    found.files.sort_by(|a, b| a.path.cmp(&b.path));
    found.skipped.sort();
    Ok(found)
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// One hash for the whole skill: every path with its file's hash, in path order. A renamed, added, removed or
/// changed file changes it; the folder's own name and place do not.
pub fn content_hash(files: &SkillFiles) -> String {
    let mut hasher = Sha256::new();
    for file in &files.files {
        hasher.update(file.path.as_bytes());
        hasher.update([0u8]);
        hasher.update(file.digest);
    }
    hex(&hasher.finalize())
}

// MARK: - What a file is

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// Markdown and plain text: what the agent reads as instructions.
    Doc,
    /// Code in a named language.
    Script(&'static str),
    /// JSON, YAML, TOML and the like.
    Config,
    /// A program: ELF, Mach-O, a Windows executable, WebAssembly, Java classes.
    Executable,
    Archive,
    /// Pictures, fonts, PDF, sound: not checked.
    Media,
    /// Bytes that are none of the above.
    UnknownBinary,
    /// Text with no known extension.
    OtherText,
}

fn extension(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    match name.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() => ext.to_ascii_lowercase(),
        _ => String::new(),
    }
}

fn script_language(ext: &str) -> Option<&'static str> {
    Some(match ext {
        "sh" | "bash" | "zsh" | "fish" | "ksh" | "command" => "shell",
        "py" | "pyw" => "python",
        "js" | "mjs" | "cjs" | "jsx" => "javascript",
        "ts" | "mts" | "cts" | "tsx" => "typescript",
        "rb" => "ruby",
        "pl" | "pm" => "perl",
        "php" => "php",
        "ps1" | "psm1" => "powershell",
        "bat" | "cmd" => "batch",
        "lua" => "lua",
        "go" => "go",
        "rs" => "rust",
        "swift" => "swift",
        "applescript" | "scpt" => "applescript",
        "vbs" | "wsf" => "vbscript",
        "java" | "kt" => "java",
        "c" | "cc" | "cpp" | "h" => "c",
        _ => return None,
    })
}

fn shebang_language(bytes: &[u8]) -> Option<&'static str> {
    if !bytes.starts_with(b"#!") {
        return None;
    }
    let line = String::from_utf8_lossy(&bytes[..bytes.len().min(120)]).lines().next().unwrap_or_default().to_ascii_lowercase();
    Some(if line.contains("python") {
        "python"
    } else if line.contains("node") || line.contains("deno") || line.contains("bun") {
        "javascript"
    } else if line.contains("ruby") {
        "ruby"
    } else if line.contains("perl") {
        "perl"
    } else if line.contains("pwsh") {
        "powershell"
    } else {
        "shell"
    })
}

fn magic(bytes: &[u8]) -> Option<Kind> {
    let starts = |prefix: &[u8]| bytes.starts_with(prefix);
    if starts(b"\x7fELF") || starts(b"MZ") || starts(b"\0asm") || starts(&[0xCA, 0xFE, 0xBA, 0xBE]) || starts(&[0xCF, 0xFA, 0xED, 0xFE]) || starts(&[0xCE, 0xFA, 0xED, 0xFE]) || starts(&[0xFE, 0xED, 0xFA, 0xCF]) {
        return Some(Kind::Executable);
    }
    if starts(b"PK\x03\x04") || starts(&[0x1F, 0x8B]) || starts(b"BZh") || starts(&[0xFD, b'7', b'z', b'X', b'Z']) || starts(b"7z\xBC\xAF") || starts(b"Rar!") || starts(&[0x28, 0xB5, 0x2F, 0xFD]) {
        return Some(Kind::Archive);
    }
    None
}

pub fn classify(file: &FileEntry) -> Kind {
    let ext = extension(&file.path);
    let by_magic = magic(&file.bytes);
    match ext.as_str() {
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "ico" | "bmp" | "tiff" | "pdf" | "ttf" | "otf" | "woff" | "woff2" | "mp3" | "wav" | "mp4" | "mov" | "webm" | "icns" => {
            // A program named like a picture is still a program.
            return if by_magic == Some(Kind::Executable) { Kind::Executable } else { Kind::Media };
        }
        // Office files and packages are zip archives by design.
        "docx" | "xlsx" | "pptx" | "odt" | "ods" | "odp" | "epub" => return if by_magic == Some(Kind::Executable) { Kind::Executable } else { Kind::Media },
        "exe" | "dll" | "so" | "dylib" | "bin" | "wasm" | "class" | "jar" | "pyc" | "pyd" | "node" | "msi" | "app" | "scr" | "com" => return Kind::Executable,
        "zip" | "gz" | "tgz" | "bz2" | "xz" | "7z" | "rar" | "tar" | "zst" | "whl" | "skill" | "mcpb" | "dxt" => return Kind::Archive,
        _ => {}
    }
    if let Some(kind) = by_magic {
        return kind;
    }
    if file.unread {
        return script_language(&ext).map(Kind::Script).unwrap_or(Kind::OtherText);
    }
    let head = &file.bytes[..file.bytes.len().min(8192)];
    if head.contains(&0) {
        return Kind::UnknownBinary;
    }
    if let Some(language) = script_language(&ext) {
        return Kind::Script(language);
    }
    match ext.as_str() {
        "md" | "mdx" | "mdc" | "markdown" | "txt" | "rst" | "adoc" | "html" | "htm" | "xml" | "svg" | "csv" | "tsv" => Kind::Doc,
        "json" | "jsonc" | "json5" | "yaml" | "yml" | "toml" | "ini" | "cfg" | "conf" | "plist" | "env" | "lock" | "properties" => Kind::Config,
        _ => match shebang_language(&file.bytes) {
            Some(language) => Kind::Script(language),
            None if file.executable && ext.is_empty() => Kind::Script("shell"),
            None if ext.is_empty() && matches!(file.path.rsplit('/').next(), Some("LICENSE" | "NOTICE" | "README" | "AUTHORS" | "COPYING" | "CHANGELOG")) => Kind::Doc,
            None => Kind::OtherText,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_hash_follows_paths_and_content_only() {
        let a = SkillFiles::of(vec![FileEntry::text("SKILL.md", "one"), FileEntry::text("scripts/a.sh", "echo")]);
        let same = SkillFiles::of(vec![FileEntry::text("scripts/a.sh", "echo"), FileEntry::text("SKILL.md", "one")]);
        let renamed = SkillFiles::of(vec![FileEntry::text("SKILL.md", "one"), FileEntry::text("scripts/b.sh", "echo")]);
        let changed = SkillFiles::of(vec![FileEntry::text("SKILL.md", "two"), FileEntry::text("scripts/a.sh", "echo")]);
        assert_eq!(content_hash(&a), content_hash(&same));
        assert_ne!(content_hash(&a), content_hash(&renamed));
        assert_ne!(content_hash(&a), content_hash(&changed));
        assert_eq!(content_hash(&a).len(), 64);
    }

    #[test]
    fn files_are_told_apart() {
        assert_eq!(classify(&FileEntry::text("SKILL.md", "# hi")), Kind::Doc);
        assert_eq!(classify(&FileEntry::text("scripts/run.py", "print(1)")), Kind::Script("python"));
        assert_eq!(classify(&FileEntry::text("bin/tool", "#!/usr/bin/env node\n")), Kind::Script("javascript"));
        assert_eq!(classify(&FileEntry::text("hooks/hooks.json", "{}")), Kind::Config);
        assert_eq!(classify(&FileEntry::bytes("assets/tool", b"\x7fELF\x02\x01".to_vec())), Kind::Executable);
        assert_eq!(classify(&FileEntry::bytes("assets/logo.png", b"MZ\x90\0".to_vec())), Kind::Executable);
        assert_eq!(classify(&FileEntry::bytes("assets/logo.png", b"\x89PNG\r\n".to_vec())), Kind::Media);
        assert_eq!(classify(&FileEntry::bytes("data.zip", b"PK\x03\x04".to_vec())), Kind::Archive);
        assert_eq!(classify(&FileEntry::bytes("blob", vec![1, 0, 2, 0])), Kind::UnknownBinary);
        assert_eq!(classify(&FileEntry::text("LICENSE", "MIT")), Kind::Doc);
    }
}
