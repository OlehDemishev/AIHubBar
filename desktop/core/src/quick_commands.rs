//! «Быстрые команды» (SPEC-profiles §4.3, SPEC-windows §4.10), the Mac's `QuickCommand` and its runner: the person's
//! own buttons — a script in the background (PowerShell on Windows, `sh` on Linux) whose last line arrives as a
//! notification, a script in a terminal window, or a link, file, folder or program to open. The Mac's shortcuts from
//! «Команды» have no counterpart here; keyboard shortcuts are in `hot_keys`. The library is this computer's own, as on the Mac (not in `.claudepult`).

use crate::i18n::Strings;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    /// In the background; the result arrives as a notification.
    Script,
    /// Typed into a new terminal window.
    Terminal,
    /// The Mac's «Ярлык из «Команд»»: kept as it came, never run here.
    Shortcut,
    /// A link, file, folder or program.
    Open,
}

/// The Mac's `QuickCommand`, field for field (`hotKey` kept as it came, read through [`QuickCommand::combo`]).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuickCommand {
    pub id: String,
    pub title: String,
    #[serde(default = "default_symbol")]
    pub symbol: String,
    pub kind: Kind,
    #[serde(default)]
    pub value: String,
    /// Ask «Запустить?» first.
    #[serde(default)]
    pub confirm: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hot_key: Option<Value>,
}

fn default_symbol() -> String {
    "bolt".into()
}

/// The Mac's button symbols, drawn here as these characters.
pub const SYMBOLS: [(&str, &str); 12] = [
    ("bolt", "⚡"),
    ("terminal", "⌨"),
    ("folder", "📁"),
    ("link", "🔗"),
    ("doc", "📄"),
    ("arrow.down.circle", "⬇"),
    ("network", "🌐"),
    ("hammer", "🔨"),
    ("play", "▶"),
    ("wand.and.stars", "✨"),
    ("camera", "📷"),
    ("music.note", "♪"),
];

pub fn glyph(symbol: &str) -> &'static str {
    SYMBOLS.iter().find(|(name, _)| *name == symbol).map_or("⚡", |(_, glyph)| glyph)
}

/// What running a command does, worked out without running it.
#[derive(Debug, Clone, PartialEq)]
pub enum Invocation {
    Process { program: String, args: Vec<String> },
    Terminal(String),
    /// A link as it is, or a path with `~` expanded.
    Open(String),
    Invalid,
}

impl QuickCommand {
    pub fn new(title: &str, symbol: &str, kind: Kind, value: &str) -> QuickCommand {
        QuickCommand { id: crate::runs::new_id(), title: title.into(), symbol: symbol.into(), kind, value: value.into(), confirm: false, hot_key: None }
    }

    /// The keyboard shortcut, when the file has one that reads.
    pub fn combo(&self) -> Option<crate::hot_keys::KeyCombo> {
        self.hot_key.as_ref().and_then(crate::hot_keys::KeyCombo::from_value)
    }

    pub fn invocation(&self, home: &Path) -> Invocation {
        let value = self.value.trim();
        if value.is_empty() {
            return Invocation::Invalid;
        }
        match self.kind {
            Kind::Script => script(value),
            Kind::Terminal => Invocation::Terminal(value.to_owned()),
            Kind::Shortcut => Invocation::Invalid,
            Kind::Open if value.contains("://") => Invocation::Open(value.to_owned()),
            Kind::Open => Invocation::Open(crate::profiles::expand(value, home).to_string_lossy().into_owned()),
        }
    }
}

/// PowerShell without its profile, its output in UTF-8 (a console's code page would garble other letters); `sh -lc`
/// on Linux, `zsh -lc` on a Mac.
fn script(value: &str) -> Invocation {
    if cfg!(windows) {
        let line = format!("[Console]::OutputEncoding = [Text.Encoding]::UTF8; {value}");
        Invocation::Process { program: "powershell.exe".into(), args: ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", &line].map(str::to_owned).to_vec() }
    } else {
        let shell = if cfg!(target_os = "macos") { "/bin/zsh" } else { "sh" };
        Invocation::Process { program: shell.into(), args: vec!["-lc".into(), value.into()] }
    }
}

/// A starting library: harmless examples to edit or delete.
pub fn examples(s: &Strings) -> Vec<QuickCommand> {
    let ip = if cfg!(windows) {
        "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -in 'Dhcp','Manual' } | Select-Object -First 1).IPAddress"
    } else if cfg!(target_os = "macos") {
        "ipconfig getifaddr en0 || ipconfig getifaddr en1"
    } else {
        "hostname -I | cut -d' ' -f1"
    };
    vec![QuickCommand::new(s.t("Загрузки"), "arrow.down.circle", Kind::Open, "~/Downloads"), QuickCommand::new(s.t("Мой IP в сети"), "network", Kind::Script, ip)]
}

/// The last non-empty line of the output (stderr when stdout says nothing), short enough for a notification.
pub fn summary(stdout: &str, stderr: &str) -> String {
    let text = if stdout.trim().is_empty() { stderr } else { stdout };
    let line = text.lines().map(str::trim).rfind(|l| !l.is_empty()).unwrap_or_default();
    if line.chars().count() > 140 { format!("{}…", line.chars().take(139).collect::<String>()) } else { line.to_owned() }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    pub text: String,
    pub is_error: bool,
}

/// A script in the home folder, up to 10 minutes, without a console window: its last line, or the error.
pub fn execute(program: &str, args: &[String], home: &Path, s: &Strings) -> Outcome {
    let result = run(program, args, home, Duration::from_secs(600));
    let (code, stdout, stderr) = match result {
        Some(found) => found,
        None => (None, String::new(), String::new()),
    };
    let output = summary(&stdout, &stderr);
    if code == Some(0) {
        Outcome { text: if output.is_empty() { s.t("Готово").to_owned() } else { output }, is_error: false }
    } else {
        let head = s.format("Ошибка (код %lld)", &[&code.unwrap_or(-1).to_string()]);
        Outcome { text: if output.is_empty() { head } else { format!("{head}: {output}") }, is_error: true }
    }
}

/// Both streams, so a failing script can say why; None when it couldn't start.
fn run(program: &str, args: &[String], home: &Path, timeout: Duration) -> Option<(Option<i32>, String, String)> {
    let mut command = Command::new(program);
    command.args(args).current_dir(home).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    crate::command::hide_window(&mut command);
    let mut child = command.spawn().ok()?;
    let read = |mut pipe: Box<dyn Read + Send>| {
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = pipe.read_to_end(&mut bytes);
            String::from_utf8_lossy(&bytes).into_owned()
        })
    };
    let stdout = read(Box::new(child.stdout.take()?));
    let stderr = read(Box::new(child.stderr.take()?));
    let started = Instant::now();
    let code = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.code(),
            Ok(None) if started.elapsed() < timeout => std::thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    Some((code, stdout.join().unwrap_or_default(), stderr.join().unwrap_or_default()))
}

/// The library from `settings.json`: commands that don't read are skipped, ids made unique.
pub fn library(value: Option<&Value>) -> Option<Vec<QuickCommand>> {
    let list = value?.as_array()?;
    let mut seen = std::collections::HashSet::new();
    Some(
        list.iter()
            .filter_map(|v| serde_json::from_value::<QuickCommand>(v.clone()).ok())
            .map(|mut c| {
                if c.id.is_empty() || !seen.insert(c.id.clone()) {
                    c.id = crate::runs::new_id();
                    seen.insert(c.id.clone());
                }
                c
            })
            .collect(),
    )
}

pub fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(std::env::temp_dir)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn what_a_command_does() {
        let home = Path::new("/home/oleh");
        let open = QuickCommand::new("Загрузки", "arrow.down.circle", Kind::Open, " ~/Downloads ");
        if cfg!(unix) {
            assert_eq!(open.invocation(home), Invocation::Open("/home/oleh/Downloads".into()));
        }
        let link = QuickCommand { value: "https://example.com/a?b=1&c=2".into(), ..open.clone() };
        assert_eq!(link.invocation(home), Invocation::Open("https://example.com/a?b=1&c=2".into()));
        assert_eq!(QuickCommand { value: "   ".into(), ..open.clone() }.invocation(home), Invocation::Invalid);
        assert_eq!(QuickCommand { kind: Kind::Shortcut, value: "Морнинг".into(), ..open.clone() }.invocation(home), Invocation::Invalid, "no «Команды» here");
        assert_eq!(QuickCommand { kind: Kind::Terminal, value: "winget upgrade".into(), ..open.clone() }.invocation(home), Invocation::Terminal("winget upgrade".into()));
        let Invocation::Process { program, args } = QuickCommand { kind: Kind::Script, value: "echo hi".into(), ..open }.invocation(home) else { panic!("a process") };
        if cfg!(windows) {
            assert_eq!(program, "powershell.exe");
            assert!(args.last().unwrap().ends_with("echo hi"));
        } else {
            assert_eq!(args, ["-lc", "echo hi"]);
        }
        assert_eq!((glyph("network"), glyph("nonsense")), ("🌐", "⚡"));
    }

    #[test]
    fn the_macs_library_reads() {
        // As the Mac encodes `[QuickCommand]`, plus one it can't read and a repeated id.
        let mac = json!([
            {"id": "a", "title": "Сборка", "symbol": "hammer", "kind": "script", "value": "make", "confirm": true, "hotKey": {"keyCode": 11, "modifiers": 768}},
            {"id": "a", "title": "Ярлык", "kind": "shortcut", "value": "Утро"},
            {"title": "no kind"}
        ]);
        let list = library(Some(&mac)).unwrap();
        assert_eq!(list.len(), 2);
        assert_eq!((list[0].confirm, list[0].symbol.as_str(), list[0].hot_key.is_some()), (true, "hammer", true));
        assert_ne!(list[1].id, "a", "a repeated id is made new");
        assert_eq!(list[1].symbol, "bolt");
        assert_eq!(serde_json::to_value(&list[0]).unwrap(), mac[0], "written back as it came");
        assert_eq!(library(None), None, "no library yet: the examples");
        let s = Strings::from_json("{}");
        let examples = examples(&s);
        assert_eq!(examples.iter().map(|c| c.title.as_str()).collect::<Vec<_>>(), ["Загрузки", "Мой IP в сети"]);
    }

    #[test]
    fn running_a_script() {
        let s = Strings::from_json("{}");
        assert_eq!(summary("one\ntwo\n\n", "err"), "two");
        assert_eq!(summary("  \n", "boom\n"), "boom");
        assert_eq!(summary(&"я".repeat(200), "").chars().count(), 140);
        let home = std::env::temp_dir();
        let ok = QuickCommand::new("x", "bolt", Kind::Script, if cfg!(windows) { "Write-Output 'первая'; Write-Output 'Привет'" } else { "echo первая; echo Привет" });
        let Invocation::Process { program, args } = ok.invocation(&home) else { panic!() };
        assert_eq!(execute(&program, &args, &home, &s), Outcome { text: "Привет".into(), is_error: false });
        let bad = QuickCommand::new("x", "bolt", Kind::Script, if cfg!(windows) { "[Console]::Error.WriteLine('нет файла'); exit 3" } else { "echo 'нет файла' >&2; exit 3" });
        let Invocation::Process { program, args } = bad.invocation(&home) else { panic!() };
        assert_eq!(execute(&program, &args, &home, &s), Outcome { text: "Ошибка (код 3): нет файла".into(), is_error: true });
        let quiet = QuickCommand::new("x", "bolt", Kind::Script, "exit 0");
        let Invocation::Process { program, args } = quiet.invocation(&home) else { panic!() };
        assert_eq!(execute(&program, &args, &home, &s).text, "Готово");
    }
}
