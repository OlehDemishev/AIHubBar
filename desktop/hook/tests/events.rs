//! The real `claudepult-hook`, fed events the way Claude Code sends them (the Mac's hook tests, same expectations).

use serde_json::{json, Value};
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

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
        let mut data = json!({"session_id": "s-1", "cwd": "/Users/me/Projects/Ambo/app", "transcript_path": "/t.jsonl"});
        data.as_object_mut().unwrap().extend(event.as_object().unwrap().clone());
        let mut child = Command::new(env!("CARGO_BIN_EXE_claudepult-hook"))
            .args(["--projects-dir", "/Users/me/Projects", "--sessions-dir"])
            .arg(self.dir.join("sessions"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(data.to_string().as_bytes()).unwrap();
        child.wait_with_output().unwrap()
    }

    fn run(&self, events: Vec<Value>) -> Value {
        for event in events {
            let output = self.send(event);
            assert!(output.status.success(), "always exit 0");
            assert!(output.stdout.is_empty() && output.stderr.is_empty(), "never print anything");
        }
        serde_json::from_str(&std::fs::read_to_string(self.dir.join("sessions/s-1.json")).unwrap()).unwrap()
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
