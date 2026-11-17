//! The real `claudepult-hook`, fed events the way Claude Code sends them (the Mac's hook tests, same expectations).

use serde_json::{json, Value};
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

struct Hook {
    dir: PathBuf,
}

impl Hook {
    fn new(name: &str) -> Hook {
        let dir = std::env::temp_dir().join(format!("claudepult-hook-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        Hook { dir }
    }

    fn send(&self, event: Value) -> std::process::Output {
        self.send_as("claude", event)
    }

    fn send_as(&self, agent: &str, event: Value) -> std::process::Output {
        self.spawn(agent, event).wait_with_output().unwrap()
    }

    fn spawn(&self, agent: &str, event: Value) -> std::process::Child {
        let mut data = json!({"session_id": "s-1", "cwd": "/Users/me/Projects/Ambo/app", "transcript_path": "/t.jsonl"});
        data.as_object_mut().unwrap().extend(event.as_object().unwrap().clone());
        let mut child = Command::new(env!("CARGO_BIN_EXE_claudepult-hook"))
            .args(["--agent", agent, "--projects-dir", "/Users/me/Projects", "--sessions-dir"])
            .arg(self.dir.join("sessions"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(data.to_string().as_bytes()).unwrap();
        child
    }

    fn run(&self, events: Vec<Value>) -> Value {
        self.run_as("claude", events)
    }

    fn run_as(&self, agent: &str, events: Vec<Value>) -> Value {
        for event in events {
            let output = self.send_as(agent, event);
            assert!(output.status.success(), "always exit 0");
            assert!(output.stdout.is_empty() && output.stderr.is_empty(), "never print anything");
        }
        self.record()
    }

    fn record(&self) -> Value {
        serde_json::from_str(&std::fs::read_to_string(self.dir.join("sessions/s-1.json")).unwrap()).unwrap()
    }

    fn approvals(&self) -> PathBuf {
        self.dir.join("approvals")
    }

    /// The app running with answers on: it touches `approvals/alive`.
    fn app_alive(&self) {
        std::fs::create_dir_all(self.approvals()).unwrap();
        std::fs::write(self.approvals().join("alive"), "1").unwrap();
    }

    fn requests(&self) -> Vec<PathBuf> {
        std::fs::read_dir(self.approvals())
            .map(|d| d.filter_map(Result::ok).map(|e| e.path()).filter(|p| p.to_string_lossy().ends_with(".request.json")).collect())
            .unwrap_or_default()
    }

    /// A PermissionRequest answered in the app with `behavior`: what the hook printed.
    fn answered(&self, agent: &str, behavior: &str) -> (String, Value) {
        let child = self.spawn(agent, json!({"hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": {"command": "npm   test"}}));
        let started = Instant::now();
        let request = loop {
            if let Some(path) = self.requests().pop() {
                break path;
            }
            assert!(started.elapsed() < Duration::from_secs(10), "the hook writes a request");
            std::thread::sleep(Duration::from_millis(50));
        };
        let request_json: Value = serde_json::from_str(&std::fs::read_to_string(&request).unwrap()).unwrap();
        let id = request_json["id"].as_str().unwrap().to_owned();
        std::fs::write(self.approvals().join(format!("{id}.decision")), behavior).unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success() && output.stderr.is_empty());
        assert!(!request.exists(), "the request file is removed");
        (String::from_utf8(output.stdout).unwrap(), request_json)
    }
}

impl Drop for Hook {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn todo_write(statuses: &[&str]) -> Value {
    let todos: Vec<Value> = statuses
        .iter()
        .enumerate()
        .map(|(i, s)| json!({"content": format!("Шаг {}", i + 1), "status": s, "activeForm": format!("Делает шаг {}", i + 1)}))
        .collect();
    json!({"hook_event_name": "PostToolUse", "tool_name": "TodoWrite", "tool_input": {"todos": todos}})
}

#[test]
fn a_session_from_start_to_end() {
    let hook = Hook::new("session");
    let record = hook.run(vec![
        json!({"hook_event_name": "SessionStart", "source": "startup"}),
        json!({"hook_event_name": "UserPromptSubmit", "prompt": "Почини   тесты"}),
        json!({"hook_event_name": "PostToolUse", "tool_name": "Edit", "tool_input": {"file_path": "/Users/me/Projects/Ambo/LimitsView.swift"}}),
    ]);
    assert_eq!(record["state"], "running");
    assert_eq!(record["project"], "Ambo");
    let expected = std::path::Path::new("/Users/me/Projects").join("Ambo");
    assert_eq!(record["project_path"], expected.to_string_lossy().as_ref(), "joined with the system's separator");
    assert_eq!(record["first_prompt"], "Почини тесты");
    assert_eq!(record["last_tool"], "Edit");
    assert_eq!(record["last_target"], "LimitsView.swift");
    assert!(record["prompt_at"].is_string() && record["started_at"].is_string());
    assert_eq!(record["version"], 1);

    let waiting = hook.run(vec![json!({"hook_event_name": "PermissionRequest", "tool_name": "Bash"})]);
    assert_eq!(waiting["state"], "waiting");
    assert_eq!(waiting["message"], "Нужно разрешение: Bash");

    let done = hook.run(vec![json!({"hook_event_name": "Stop"})]);
    assert_eq!(done["state"], "done");
    assert!(done.get("last_tool").is_none() && done.get("message").is_none());

    let ended = hook.run(vec![json!({"hook_event_name": "SessionEnd", "reason": "exit"})]);
    assert_eq!(ended["state"], "ended");
    assert_eq!(ended["end_reason"], "exit");
}

#[test]
fn task_lists() {
    let hook = Hook::new("todos");
    let record = hook.run(vec![
        json!({"hook_event_name": "UserPromptSubmit", "prompt": "x"}),
        todo_write(&["in_progress", "pending", "pending"]),
        todo_write(&["completed", "completed", "in_progress"]),
    ]);
    let statuses: Vec<&str> = record["todos"].as_array().unwrap().iter().map(|t| t["status"].as_str().unwrap()).collect();
    assert_eq!(statuses, ["completed", "completed", "in_progress"], "the second list is not skipped as a repeat");
    assert_eq!(record["todos"][2]["active_form"], "Делает шаг 3");

    let hook = Hook::new("tasks");
    let create = |id: &str, subject: &str| {
        json!({"hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
               "tool_input": {"subject": subject, "activeForm": format!("Делает: {subject}")},
               "tool_response": {"task": {"id": id, "subject": subject}}})
    };
    let update = |id: &str, status: &str| json!({"hook_event_name": "PostToolUse", "tool_name": "TaskUpdate", "tool_input": {"taskId": id, "status": status}});
    let record = hook.run(vec![
        json!({"hook_event_name": "UserPromptSubmit", "prompt": "x"}),
        create("1", "Прочитать код"),
        create("2", "Написать тесты"),
        create("3", "Лишнее"),
        update("1", "completed"),
        update("2", "in_progress"),
        update("3", "deleted"),
        update("9", "completed"),
    ]);
    let todos = record["todos"].as_array().unwrap();
    assert_eq!(todos.len(), 2);
    assert_eq!(todos[1]["status"], "in_progress");
    assert_eq!(todos[1]["id"], "2");

    let hook = Hook::new("cleared");
    let record = hook.run(vec![
        json!({"hook_event_name": "UserPromptSubmit", "prompt": "x"}),
        todo_write(&["completed", "completed"]),
        json!({"hook_event_name": "Stop"}),
    ]);
    assert_eq!(record["todos"].as_array().unwrap().len(), 2, "Stop keeps the list for «Готово»");
    let record = hook.run(vec![json!({"hook_event_name": "UserPromptSubmit", "prompt": "ещё"})]);
    assert!(record.get("todos").is_none(), "a new request after a finished list starts clean");
}

#[test]
fn bad_input_changes_nothing() {
    let hook = Hook::new("bad");
    for event in [json!({"hook_event_name": "Stop", "session_id": "../escape"}), json!({"hook_event_name": "Stop", "session_id": ""})] {
        let output = hook.send(event);
        assert!(output.status.success() && output.stdout.is_empty());
    }
    let sessions = hook.dir.join("sessions");
    let files: Vec<_> = std::fs::read_dir(&sessions).map(|d| d.filter_map(Result::ok).map(|e| e.file_name()).collect()).unwrap_or_default();
    assert!(files.iter().all(|name| name == ".lock"), "no session file for a bad id: {files:?}");
}

#[test]
fn codex_sessions() {
    let hook = Hook::new("codex");
    let record = hook.run_as("codex", vec![
        json!({"hook_event_name": "UserPromptSubmit", "prompt": "Обнови README"}),
        json!({"hook_event_name": "PostToolUse", "tool_name": "apply_patch",
               "tool_input": {"command": "*** Begin Patch\n*** Update File: docs/README.md\n@@\n*** End Patch"}}),
    ]);
    assert_eq!(record["agent"], "codex");
    assert_eq!(record["entrypoint"], "codex");
    assert_eq!(record["last_tool"], "apply_patch");
    assert_eq!(record["last_target"], "README.md", "the patch's first file");
    let record = hook.run_as("codex", vec![json!({"hook_event_name": "Interrupt"})]);
    assert_eq!(record["state"], "done", "Esc in Codex waits for the next message");
    assert!(record.get("last_tool").is_none());
}

#[test]
fn prompt_without_app_wrappers() {
    let hook = Hook::new("wrappers");
    let record = hook.run(vec![json!({"hook_event_name": "UserPromptSubmit",
        "prompt": "<system-reminder>long context</system-reminder><ide_selection>code</ide_selection>  Почини тест"})]);
    assert_eq!(record["first_prompt"], "Почини тест");
    assert_eq!(record["last_prompt"], "Почини тест");

    let hook = Hook::new("old-title");
    std::fs::create_dir_all(hook.dir.join("sessions")).unwrap();
    std::fs::write(hook.dir.join("sessions/s-1.json"), r#"{"first_prompt": "<system-reminder>left by an old hook"}"#).unwrap();
    let record = hook.run(vec![json!({"hook_event_name": "UserPromptSubmit", "prompt": "Новая задача"})]);
    assert_eq!(record["first_prompt"], "Новая задача", "a title that is only a wrapper is replaced");
}

#[test]
fn answers_from_the_app() {
    let hook = Hook::new("approve");
    hook.app_alive();
    let (printed, request) = hook.answered("claude", "allow");
    assert_eq!(request["tool"], "Bash");
    assert_eq!(request["summary"], "npm test");
    assert_eq!(request["project"], "Ambo");
    assert_eq!(request["agent"], "claude");
    let printed: Value = serde_json::from_str(&printed).unwrap();
    assert_eq!(printed["hookSpecificOutput"]["hookEventName"], "PermissionRequest");
    assert_eq!(printed["hookSpecificOutput"]["decision"]["behavior"], "allow");
    assert_eq!(hook.record()["state"], "waiting");

    let (printed, _) = hook.answered("codex", "deny");
    let printed: Value = serde_json::from_str(&printed).unwrap();
    assert_eq!(printed["hookSpecificOutput"]["decision"]["behavior"], "deny");
    assert_eq!(printed["hookSpecificOutput"]["decision"]["message"], "Denied in AI Hub Bar");
}

#[test]
fn no_wait_without_the_app() {
    let hook = Hook::new("no-app");
    let started = Instant::now();
    let record = hook.run(vec![json!({"hook_event_name": "PermissionRequest", "tool_name": "Bash"})]);
    assert_eq!(record["state"], "waiting");
    assert!(started.elapsed() < Duration::from_secs(5), "no alive file: no wait");
    assert!(hook.requests().is_empty());

    // Copilot's requests are not answered from the app (as on the Mac).
    hook.app_alive();
    let output = hook.send_as("copilot", json!({"hook_event_name": "PermissionRequest", "tool_name": "Bash"}));
    assert!(output.stdout.is_empty() && hook.requests().is_empty());

    // An old alive file means the app is gone.
    let stale = std::time::SystemTime::now() - Duration::from_secs(120);
    std::fs::File::options().write(true).open(hook.approvals().join("alive")).unwrap().set_modified(stale).unwrap();
    let output = hook.send(json!({"hook_event_name": "PermissionRequest", "tool_name": "Bash"}));
    assert!(output.stdout.is_empty() && hook.requests().is_empty());
}
