import CryptoKit
import Foundation

/// Reading a skill's folder as data: every file's bytes, never a process. Links are recorded, not followed.
/// Port of `desktop/skill-scanner/src/files.rs`.
struct SkillFile: Equatable, Sendable {
    /// Relative to the skill's folder, with `/`.
    var path: String
    /// Empty for a link and for a file over the limit.
    var bytes: Data
    var size: UInt64
    /// SHA-256 of the file's bytes (of the target's text for a link).
    var digest: Data
    var isExecutable = false
    /// Where a symbolic link points, as written.
    var symlink: String?
    /// Too large to check: hashed only.
    var unread = false

    /// A file made in memory, for tests and for content that came from the network.
    static func text(_ path: String, _ text: String) -> SkillFile { bytes(path, Data(text.utf8)) }

    static func bytes(_ path: String, _ data: Data) -> SkillFile {
        SkillFile(path: path, bytes: data, size: UInt64(data.count), digest: Data(SHA256.hash(data: data)))
    }

    var text: String { String(decoding: bytes, as: UTF8.self) }
}

struct SkillFiles: Equatable, Sendable {
    /// Sorted by path.
    var files: [SkillFile] = []
    /// Folders that were not walked (`node_modules`, a virtual environment).
    var skipped: [String] = []
    /// The limits were reached: some files are missing.
    var truncated = false

    init(files: [SkillFile] = [], skipped: [String] = [], truncated: Bool = false) {
        self.files = files.sorted { $0.path < $1.path }
        self.skipped = skipped
        self.truncated = truncated
    }

    func file(_ path: String) -> SkillFile? { files.first { $0.path == path } }
    var totalBytes: UInt64 { files.reduce(0) { $0 + $1.size } }

    /// One hash for the whole skill: every path with its file's hash, in path order. A renamed, added, removed or
    /// changed file changes it; the folder's own name and place do not. The same value the Rust scanner gives.
    var contentHash: String { Self.hash(files) }

    /// The hash of what an installed copy holds: the same, with the links left out (a link is never installed).
    var contentHashWithoutLinks: String { Self.hash(files.filter { $0.symlink == nil }) }

    private static func hash(_ files: [SkillFile]) -> String {
        var hasher = SHA256()
        for file in files {
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: file.digest)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// How much of a folder is read. A skill is a few text files; anything far larger is reported, not loaded.
struct SkillLimits: Sendable {
    var maxFiles = 3000
    /// A larger file is hashed but its text is not checked.
    var maxFileBytes: UInt64 = 2 * 1024 * 1024
    var maxTotalBytes: UInt64 = 64 * 1024 * 1024
}

enum SkillFolder {
    private static let silent: Set<String> = [".git", ".DS_Store", "Thumbs.db", "desktop.ini"]
    private static let notWalked: Set<String> = ["node_modules", ".venv", "venv", "__pycache__", "site-packages", ".tox"]

    /// Every file under `root`. A link is kept as a link, whatever it points to; the root itself may be a link to a
    /// folder (skills are often linked into an agent's folder from one shared place).
    static func read(_ root: URL, limits: SkillLimits = SkillLimits()) throws -> SkillFiles {
        let manager = FileManager.default
        let base = root.resolvingSymlinksInPath()
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: base.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        var files: [SkillFile] = []
        var skipped: [String] = []
        var truncated = false
        var total: UInt64 = 0
        var folders: [(URL, String)] = [(base, "")]
        while let (folder, prefix) = folders.popLast() {
            let names = try manager.contentsOfDirectory(atPath: folder.path).sorted()
            for name in names where !silent.contains(name) {
                let url = folder.appending(path: name)
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { continue }
                let type = attributes[.type] as? FileAttributeType
                if type == .typeSymbolicLink {
                    let target = (try? manager.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                    files.append(SkillFile(path: relative, bytes: Data(), size: 0, digest: Data(SHA256.hash(data: Data(target.utf8))), symlink: target))
                    continue
                }
                if type == .typeDirectory {
                    if notWalked.contains(name) { skipped.append(relative) } else { folders.append((url, relative)) }
                    continue
                }
                guard type == .typeRegular else { continue }
                if files.count >= limits.maxFiles || total >= limits.maxTotalBytes {
                    truncated = true
                    continue
                }
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                let executable = permissions & 0o111 != 0
                if size > limits.maxFileBytes {
                    files.append(SkillFile(path: relative, bytes: Data(), size: size, digest: try digest(of: url), isExecutable: executable, unread: true))
                    continue
                }
                let data = try Data(contentsOf: url)
                total += UInt64(data.count)
                files.append(SkillFile(path: relative, bytes: data, size: UInt64(data.count), digest: Data(SHA256.hash(data: data)), isExecutable: executable))
            }
        }
        return SkillFiles(files: files, skipped: skipped.sorted(), truncated: truncated)
    }

    /// SHA-256 of a file on disk, read in pieces.
    static func digest(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}

// MARK: - What a file is

enum SkillFileKind: Equatable, Sendable {
    /// Markdown and plain text: what the agent reads as instructions.
    case doc
    /// Code in a named language.
    case script(String)
    /// JSON, YAML, TOML and the like.
    case config
    /// A program: Mach-O, ELF, a Windows executable, WebAssembly, Java classes.
    case executable
    case archive
    /// Pictures, fonts, PDF, sound: not checked.
    case media
    /// Bytes that are none of the above.
    case unknownBinary
    /// Text with no known extension.
    case otherText

    /// A short name for lists: `doc`, `script`, `config`, `program`, `archive`, `media`, `binary`, `text`.
    var name: String {
        switch self {
        case .doc: "doc"
        case .script: "script"
        case .config: "config"
        case .executable: "program"
        case .archive: "archive"
        case .media: "media"
        case .unknownBinary: "binary"
        case .otherText: "text"
        }
    }

    /// Whether the file can be shown as text.
    var isText: Bool {
        switch self {
        case .doc, .script, .config, .otherText: true
        default: false
        }
    }

    static func of(_ file: SkillFile) -> SkillFileKind {
        let ext = fileExtension(file.path)
        let magic = magicKind(file.bytes)
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "tiff", "pdf", "ttf", "otf", "woff", "woff2", "mp3", "wav", "mp4", "mov", "webm", "icns",
             "docx", "xlsx", "pptx", "odt", "ods", "odp", "epub":
            // A program named like a picture is still a program.
            return magic == .executable ? .executable : .media
        case "exe", "dll", "so", "dylib", "bin", "wasm", "class", "jar", "pyc", "pyd", "node", "msi", "app", "scr", "com":
            return .executable
        case "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar", "zst", "whl", "skill", "mcpb", "dxt":
            return .archive
        default:
            break
        }
        if let magic { return magic }
        if file.unread { return scriptLanguage(ext).map(SkillFileKind.script) ?? .otherText }
        if file.bytes.prefix(8192).contains(0) { return .unknownBinary }
        if let language = scriptLanguage(ext) { return .script(language) }
        switch ext {
        case "md", "mdx", "mdc", "markdown", "txt", "rst", "adoc", "html", "htm", "xml", "svg", "csv", "tsv":
            return .doc
        case "json", "jsonc", "json5", "yaml", "yml", "toml", "ini", "cfg", "conf", "plist", "env", "lock", "properties":
            return .config
        default:
            if let language = shebangLanguage(file.bytes) { return .script(language) }
            if file.isExecutable && ext.isEmpty { return .script("shell") }
            let name = file.path.split(separator: "/").last.map(String.init) ?? file.path
            if ext.isEmpty && ["LICENSE", "NOTICE", "README", "AUTHORS", "COPYING", "CHANGELOG"].contains(name) { return .doc }
            return .otherText
        }
    }

    private static func fileExtension(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    private static func scriptLanguage(_ ext: String) -> String? {
        switch ext {
        case "sh", "bash", "zsh", "fish", "ksh", "command": "shell"
        case "py", "pyw": "python"
        case "js", "mjs", "cjs", "jsx": "javascript"
        case "ts", "mts", "cts", "tsx": "typescript"
        case "rb": "ruby"
        case "pl", "pm": "perl"
        case "php": "php"
        case "ps1", "psm1": "powershell"
        case "bat", "cmd": "batch"
        case "lua": "lua"
        case "go": "go"
        case "rs": "rust"
        case "swift": "swift"
        case "applescript", "scpt": "applescript"
        case "vbs", "wsf": "vbscript"
        case "java", "kt": "java"
        case "c", "cc", "cpp", "h": "c"
        default: nil
        }
    }

    private static func shebangLanguage(_ bytes: Data) -> String? {
        guard bytes.starts(with: Data("#!".utf8)) else { return nil }
        let line = String(decoding: bytes.prefix(120), as: UTF8.self).split(separator: "\n").first.map { $0.lowercased() } ?? ""
        if line.contains("python") { return "python" }
        if line.contains("node") || line.contains("deno") || line.contains("bun") { return "javascript" }
        if line.contains("ruby") { return "ruby" }
        if line.contains("perl") { return "perl" }
        if line.contains("pwsh") { return "powershell" }
        return "shell"
    }

    private static func magicKind(_ bytes: Data) -> SkillFileKind? {
        func starts(_ prefix: [UInt8]) -> Bool { bytes.starts(with: prefix) }
        if starts([0x7F, 0x45, 0x4C, 0x46]) || starts([0x4D, 0x5A]) || starts([0x00, 0x61, 0x73, 0x6D]) || starts([0xCA, 0xFE, 0xBA, 0xBE])
            || starts([0xCF, 0xFA, 0xED, 0xFE]) || starts([0xCE, 0xFA, 0xED, 0xFE]) || starts([0xFE, 0xED, 0xFA, 0xCF]) {
            return .executable
        }
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x1F, 0x8B]) || starts([0x42, 0x5A, 0x68]) || starts([0xFD, 0x37, 0x7A, 0x58, 0x5A])
            || starts([0x37, 0x7A, 0xBC, 0xAF]) || starts([0x52, 0x61, 0x72, 0x21]) || starts([0x28, 0xB5, 0x2F, 0xFD]) {
            return .archive
        }
        return nil
    }
}
