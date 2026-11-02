//! `claudepult` — the console side of AI Hub Bar (docs/SPEC-windows.md §4.8). `AIHubBar.exe` is a window
//! program and can't print to a console, so commands live here and reach the running app through
//! `claudepult_core::ipc`. More commands (`--usage`, `--sessions`, `--hooks` …) come with their stages.

use claudepult_core::ipc::{self, Reply, Request, APP_COMMANDS};
use std::process::ExitCode;

fn usage() -> String {
    format!(
        "AI Hub Bar {}\n\nUsage:\n  claudepult --app-command <{}>   ask the running app\n  claudepult --version\n",
        env!("CARGO_PKG_VERSION"),
        APP_COMMANDS.join("|")
    )
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("--version") => {
            println!("{}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Some("--app-command") => {
            let Some(name) = args.get(1).filter(|name| APP_COMMANDS.contains(&name.as_str())) else {
                eprint!("{}", usage());
                return ExitCode::from(2);
            };
            match ipc::send(&Request::AppCommand(name.clone())) {
                Ok(Reply::Ok) => {
                    println!("sent {name} to the running app");
                    ExitCode::SUCCESS
                }
                Ok(Reply::Unknown) => {
                    eprintln!("the running app doesn't know «{name}» (an older version?)");
                    ExitCode::FAILURE
                }
                Ok(Reply::Error(text)) => {
                    eprintln!("error: {text}");
                    ExitCode::FAILURE
                }
                Err(_) => {
                    eprintln!("AI Hub Bar is not running");
                    ExitCode::FAILURE
                }
            }
        }
        _ => {
            print!("{}", usage());
            if args.is_empty() { ExitCode::SUCCESS } else { ExitCode::from(2) }
        }
    }
}
