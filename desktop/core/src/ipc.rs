//! The link between `claudepult` (console) and the running app (docs/SPEC-windows.md §4.8): a named pipe
//! `\\.\pipe\ClaudePult-<user>` on Windows, an abstract socket on Linux, a socket file in `/tmp` on macOS
//! (development only).
//! One line per request — `app-command <name>` — and one line back: `ok`, `unknown` or `error <text>`.

use interprocess::local_socket::{prelude::*, GenericNamespaced, ListenerOptions, Name, Stream};
use std::io::{self, BufRead, BufReader, Write};

/// What `--app-command` can ask the running app.
pub const APP_COMMANDS: [&str; 3] = ["panel", "settings", "quit"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    AppCommand(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reply {
    Ok,
    Unknown,
    Error(String),
}

impl Request {
    pub fn line(&self) -> String {
        match self {
            Request::AppCommand(name) => format!("app-command {name}\n"),
        }
    }

    pub fn parse(line: &str) -> Option<Request> {
        let name = line.trim().strip_prefix("app-command ")?.trim();
        (!name.is_empty() && !name.contains(char::is_whitespace)).then(|| Request::AppCommand(name.to_owned()))
    }
}

impl Reply {
    pub fn line(&self) -> String {
        match self {
            Reply::Ok => "ok\n".into(),
            Reply::Unknown => "unknown\n".into(),
            Reply::Error(text) => format!("error {}\n", text.replace('\n', " ")),
        }
    }

    pub fn parse(line: &str) -> Reply {
        match line.trim() {
            "ok" => Reply::Ok,
            "unknown" => Reply::Unknown,
            other => Reply::Error(other.strip_prefix("error ").unwrap_or(other).to_owned()),
        }
    }
}

/// One name per signed-in user, so two people on one computer don't reach each other's app.
pub fn socket_id(user: &str) -> String {
    let user: String = user.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').collect();
    format!("ClaudePult-{}", if user.is_empty() { "user" } else { &user })
}

fn current_user() -> String {
    std::env::var("USERNAME").or_else(|_| std::env::var("USER")).unwrap_or_default()
}

fn name() -> io::Result<Name<'static>> {
    socket_id(&current_user()).to_ns_name::<GenericNamespaced>()
}

/// From `claudepult`: sends one request to the running app. An error means the app isn't running.
pub fn send(request: &Request) -> io::Result<Reply> {
    let mut stream = BufReader::new(Stream::connect(name()?)?);
    stream.get_mut().write_all(request.line().as_bytes())?;
    let mut line = String::new();
    stream.read_line(&mut line)?;
    Ok(Reply::parse(&line))
}

/// In the app: answers requests on a background thread for as long as the app runs.
pub fn serve(handle: impl Fn(Request) -> Reply + Send + 'static) -> io::Result<()> {
    // A socket file left by a crashed copy is taken over (macOS; pipes and abstract sockets vanish with their
    // process). Only one copy runs at a time (the single-instance plugin), so nothing live is displaced.
    let listener = ListenerOptions::new()
        .name(name()?)
        .try_overwrite(true)
        .max_spin_time(std::time::Duration::from_secs(1))
        .create_sync()?;
    std::thread::spawn(move || {
        for connection in listener.incoming().filter_map(Result::ok) {
            let mut reader = BufReader::new(connection);
            let mut line = String::new();
            if reader.read_line(&mut line).is_err() {
                continue;
            }
            let reply = match Request::parse(&line) {
                Some(request) => handle(request),
                None => Reply::Error("bad request".into()),
            };
            let _ = reader.get_mut().write_all(reply.line().as_bytes());
        }
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protocol() {
        let request = Request::AppCommand("settings".into());
        assert_eq!(Request::parse(&request.line()), Some(request));
        assert_eq!(Request::parse("app-command "), None);
        assert_eq!(Request::parse("app-command two words"), None);
        assert_eq!(Request::parse("hello"), None);
        for reply in [Reply::Ok, Reply::Unknown, Reply::Error("no window".into())] {
            assert_eq!(Reply::parse(&reply.line()), reply);
        }
    }

    #[test]
    fn one_name_per_user() {
        assert_eq!(socket_id("Oleh"), "ClaudePult-Oleh");
        assert_eq!(socket_id("DOMAIN\\o.d"), "ClaudePult-DOMAINod");
        assert_eq!(socket_id(""), "ClaudePult-user");
    }
}
