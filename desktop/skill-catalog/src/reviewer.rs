//! Sending a review request (`review::request`) to a model and getting the text back. Two ways, both with no tools:
//!
//! - Claude Code, `claude -p`: the person's own subscription. `--tools ""` gives the model nothing to act with,
//!   `--setting-sources ""` and `--strict-mcp-config` keep the person's hooks, settings and MCP servers out,
//!   `--no-session-persistence` keeps no transcript, and it runs in an empty folder so no CLAUDE.md is read. The
//!   instructions go in a file and the skill on stdin: nothing of the skill is on a command line.
//! - The Anthropic API with the person's key, structured output fixing the answer's shape.
//!
//! Either answer is then read strictly by `review::parse_answer`.

use crate::review::Request;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// The model asked unless the person chose another.
pub const DEFAULT_MODEL: &str = "claude-opus-5-5";
const TIMEOUT: Duration = Duration::from_secs(600);
const API: &str = "https://api.anthropic.com/v1/messages";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Answer {
    pub text: String,
    pub model: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
}

/// The answer's shape for the API's structured output. The strict reading afterwards stays: the answer is untrusted.
pub fn schema() -> serde_json::Value {
    let severity = serde_json::json!({"type": "string", "enum": ["low", "medium", "high", "critical"]});
    serde_json::json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["verdict", "summary", "findings"],
        "properties": {
            "verdict": {"type": "string", "enum": ["safe", "review", "dangerous"]},
            "summary": {"type": "string"},
            "findings": {"type": "array", "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["file", "line", "severity", "title", "explanation"],
                "properties": {"file": {"type": "string"}, "line": {"type": "integer"}, "severity": severity, "title": {"type": "string"}, "explanation": {"type": "string"}}
            }}
        }
    })
}

/// The Messages API request body. Thinking stays as the model has it (adaptive); effort is high, since a missed
/// attack costs more than the tokens. On a refusal the API tries the fallback model in the same call.
pub fn api_body(request: &Request, model: &str) -> serde_json::Value {
    serde_json::json!({
        "model": model,
        "max_tokens": 16000,
        "system": request.system,
        "messages": [{"role": "user", "content": request.user}],
        "output_config": {"effort": "high", "format": {"type": "json_schema", "schema": schema()}},
        "fallbacks": "default",
    })
}

/// The text of an API answer, or a short reason. A refusal or an answer cut at the token limit is no answer.
pub fn api_answer(body: &str, model: &str) -> Result<Answer, String> {
    let value: serde_json::Value = serde_json::from_str(body).map_err(|_| "unreadable".to_owned())?;
    match value["stop_reason"].as_str() {
        Some("refusal") => return Err("refusal".into()),
        Some("max_tokens") => return Err("too-long".into()),
        _ => {}
    }
    let text: String = value["content"].as_array().into_iter().flatten().filter(|block| block["type"] == "text").filter_map(|block| block["text"].as_str()).collect::<Vec<_>>().join("");
    let usage = |key: &str| value["usage"][key].as_u64().unwrap_or(0);
    Ok(Answer { text, model: value["model"].as_str().unwrap_or(model).to_owned(), input_tokens: usage("input_tokens") + usage("cache_creation_input_tokens") + usage("cache_read_input_tokens"), output_tokens: usage("output_tokens") })
}

/// Asks the Anthropic API. The key is sent in its header and nowhere else, never logged.
pub fn via_api(request: &Request, key: &str, model: &str) -> Result<Answer, String> {
    let agent: ureq::Agent = ureq::Agent::config_builder().http_status_as_error(false).timeout_global(Some(TIMEOUT)).build().into();
    let mut response = agent
        .post(API)
        .header("Content-Type", "application/json")
        .header("User-Agent", "AIHubBar")
        .header("x-api-key", key)
        .header("anthropic-version", "2026-10-21")
        .header("anthropic-beta", "server-side-fallback-2026-07-01")
        .send(api_body(request, model).to_string())
        .map_err(|error| format!("network: {error}"))?;
    let status = response.status().as_u16();
    let body = response.body_mut().read_to_string().unwrap_or_default();
    match status {
        200..=299 => api_answer(&body, model),
        401 | 403 => Err("bad-key".into()),
        _ => {
            let value: serde_json::Value = serde_json::from_str(&body).unwrap_or_default();
            let message: String = value["error"]["message"].as_str().unwrap_or_default().chars().take(200).collect();
            Err(format!("HTTP {status}{}", if message.is_empty() { String::new() } else { format!(": {message}") }))
        }
    }
}

/// `claude`'s arguments. The skill itself is not among them: it goes on stdin.
pub fn claude_arguments(system_file: &Path, model: &str) -> Vec<String> {
    let mut args: Vec<String> = ["-p", "--tools", "", "--output-format", "json", "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands", "--model", model, "--system-prompt-file"].iter().map(|a| (*a).to_owned()).collect();
    args.push(system_file.to_string_lossy().into_owned());
    args
}

/// The text of `claude -p --output-format json`'s one result object.
pub fn claude_answer(stdout: &str, model: &str) -> Result<Answer, String> {
    let value: serde_json::Value = serde_json::from_str(stdout.trim()).map_err(|_| "unreadable".to_owned())?;
    if value["is_error"].as_bool() == Some(true) || value["subtype"].as_str().is_some_and(|kind| kind != "success") {
        let reason: String = value["result"].as_str().unwrap_or("error").chars().take(200).collect();
        return Err(reason);
    }
    let usage = |key: &str| value["usage"][key].as_u64().unwrap_or(0);
    // When a model declined and Claude Code fell back to another, both are listed: the one that wrote the answer is
    // the one that wrote the most.
    let used = value["modelUsage"].as_object().and_then(|models| models.iter().max_by_key(|(_, usage)| usage["outputTokens"].as_u64().unwrap_or(0)).map(|(name, _)| name.clone())).unwrap_or_else(|| model.to_owned());
    Ok(Answer { text: value["result"].as_str().unwrap_or_default().to_owned(), model: used, input_tokens: usage("input_tokens") + usage("cache_creation_input_tokens") + usage("cache_read_input_tokens"), output_tokens: usage("output_tokens") })
}

fn hide_window(command: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
    }
    #[cfg(not(windows))]
    let _ = command;
}

/// Asks Claude Code. `program` is `claude` as found on `PATH` (on Windows `claude.cmd` is started through `cmd /c`);
/// `scratch` is a folder of the app's own, emptied for each review.
pub fn via_claude(request: &Request, program: &Path, scratch: &Path, model: &str) -> Result<Answer, String> {
    let _ = std::fs::remove_dir_all(scratch);
    let folder = scratch.join("work");
    std::fs::create_dir_all(&folder).map_err(|error| error.to_string())?;
    let system_file = scratch.join("instructions.txt");
    std::fs::write(&system_file, &request.system).map_err(|error| error.to_string())?;
    let script = program.extension().and_then(|e| e.to_str()).is_some_and(|e| e.eq_ignore_ascii_case("cmd") || e.eq_ignore_ascii_case("bat"));
    let mut command = if script && cfg!(windows) {
        let mut command = Command::new("cmd");
        command.arg("/c").arg(program);
        command
    } else {
        Command::new(program)
    };
    hide_window(&mut command);
    command.args(claude_arguments(&system_file, model)).current_dir(&folder).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    let mut child = command.spawn().map_err(|_| "no-claude".to_owned())?;
    let mut stdin = child.stdin.take().ok_or("no-claude")?;
    let user = request.user.clone();
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(user.as_bytes());
    });
    let mut stdout = child.stdout.take().ok_or("no-claude")?;
    let reader = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = std::io::Read::read_to_string(&mut stdout, &mut text);
        text
    });
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() < TIMEOUT => std::thread::sleep(Duration::from_millis(100)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = std::fs::remove_dir_all(scratch);
                return Err("timeout".into());
            }
        }
    }
    let _ = writer.join();
    let text = reader.join().unwrap_or_default();
    let _ = std::fs::remove_dir_all(scratch);
    claude_answer(&text, model)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> Request {
        Request { system: "be careful".into(), user: "<<<FILE n SKILL.md>>>\n1|hi\n<<<END n>>>".into(), files: vec!["SKILL.md".into()], incomplete: false }
    }

    #[test]
    fn the_api_request_fixes_the_answers_shape() {
        let body = api_body(&request(), DEFAULT_MODEL);
        assert_eq!(body["model"], "claude-opus-5-5");
        assert_eq!(body["system"], "be careful");
        assert_eq!(body["messages"][0]["content"], "<<<FILE n SKILL.md>>>\n1|hi\n<<<END n>>>");
        assert_eq!(body["output_config"]["format"]["type"], "json_schema");
        assert_eq!(body["output_config"]["format"]["schema"]["properties"]["verdict"]["enum"], serde_json::json!(["safe", "review", "dangerous"]));
        assert_eq!(body["fallbacks"], "default");
        assert!(body.get("thinking").is_none() && body.get("temperature").is_none());
    }

    #[test]
    fn an_api_answer_is_read_or_refused() {
        let ok = r#"{"model": "claude-opus-5-5", "stop_reason": "end_turn", "content": [{"type": "thinking", "thinking": ""}, {"type": "text", "text": "{\"verdict\":"}, {"type": "text", "text": "\"safe\"}"}], "usage": {"input_tokens": 100, "cache_read_input_tokens": 20, "output_tokens": 7}}"#;
        assert_eq!(api_answer(ok, "x").unwrap(), Answer { text: "{\"verdict\":\"safe\"}".into(), model: "claude-opus-5-5".into(), input_tokens: 120, output_tokens: 7 });
        assert_eq!(api_answer(r#"{"stop_reason": "refusal", "content": []}"#, "x").unwrap_err(), "refusal");
        assert_eq!(api_answer(r#"{"stop_reason": "max_tokens", "content": []}"#, "x").unwrap_err(), "too-long");
        assert_eq!(api_answer("not json", "x").unwrap_err(), "unreadable");
    }

    #[test]
    fn claude_code_gets_no_tools_settings_or_skill_on_the_command_line() {
        let args = claude_arguments(Path::new("/tmp/i.txt"), DEFAULT_MODEL);
        let joined = args.join(" ");
        for wanted in ["-p", "--tools", "--no-session-persistence", "--setting-sources", "--strict-mcp-config", "--disable-slash-commands", "--system-prompt-file"] {
            assert!(args.iter().any(|a| a == wanted), "{wanted}");
        }
        let after = |flag: &str| args[args.iter().position(|a| a == flag).unwrap() + 1].clone();
        assert_eq!((after("--tools"), after("--setting-sources"), after("--model")), (String::new(), String::new(), "claude-opus-5-5".to_owned()));
        assert!(!joined.contains("SKILL.md") && !joined.contains("dangerously") && !joined.contains("bypass"));
    }

    #[test]
    fn a_claude_code_answer_is_read_or_refused() {
        let ok = r#"{"type":"result","subtype":"success","is_error":false,"result":"{\"verdict\":\"review\"}","usage":{"input_tokens":2,"cache_creation_input_tokens":957,"output_tokens":5},"modelUsage":{"claude-opus-5-5":{}}}"#;
        assert_eq!(claude_answer(ok, "x").unwrap(), Answer { text: "{\"verdict\":\"review\"}".into(), model: "claude-opus-5-5".into(), input_tokens: 959, output_tokens: 5 });
        assert!(claude_answer(r#"{"type":"result","subtype":"error_max_turns","is_error":true,"result":"stopped"}"#, "x").is_err());
        let fell_back = r#"{"type":"result","subtype":"success","is_error":false,"result":"{}","usage":{},"modelUsage":{"claude-opus-4-8":{"outputTokens":597},"claude-opus-5-5":{"outputTokens":3}}}"#;
        assert_eq!(claude_answer(fell_back, "x").unwrap().model, "claude-opus-4-8");
        assert_eq!(claude_answer("", "x").unwrap_err(), "unreadable");
    }
}
