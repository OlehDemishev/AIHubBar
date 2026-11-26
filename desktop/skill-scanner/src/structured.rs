//! What a plugin adds besides instructions, read from its JSON files: hooks, MCP servers, permissions.

use crate::rules::Severity;
use crate::{scan_text, Findings};
use serde_json::Value;

/// The 1-based line where `needle` first stands, or 0.
fn line_of(text: &str, needle: &str) -> usize {
    if needle.is_empty() {
        return 0;
    }
    text.lines().position(|line| line.contains(needle)).map(|index| index + 1).unwrap_or(0)
}

/// The first words of a command as they stand in the JSON text.
fn needle(command: &str) -> String {
    let short: String = command.chars().take_while(|c| !matches!(c, '"' | '\\' | '\n')).take(40).collect();
    short
}

const NETWORK: [&str; 6] = ["net-call", "net-upload", "exfil-endpoint", "pipe-to-shell", "hardcoded-ip", "exfil-combo"];

/// A command that runs by itself on an agent event.
pub(crate) fn hook(path: &str, line: usize, event: &str, command: &str, out: &mut Findings) {
    if command.trim().is_empty() {
        return;
    }
    out.push("hook-command", Severity::Medium, path, line, &format!("{event}: {command}"));
    let matched = scan_text(path, command, false, Some(line), out);
    if NETWORK.iter().any(|rule| matched.contains(rule)) {
        out.push("hook-network", Severity::High, path, line, &format!("{event}: {command}"));
    }
}

fn command_of(entry: &Value) -> Option<String> {
    let command = entry.get("command").and_then(Value::as_str)?;
    let args: Vec<&str> = entry.get("args").and_then(Value::as_array).map(|args| args.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
    Some(if args.is_empty() { command.to_owned() } else { format!("{command} {}", args.join(" ")) })
}

fn hooks(path: &str, text: &str, hooks: &Value, out: &mut Findings) {
    let Some(events) = hooks.as_object() else { return };
    for (event, entries) in events {
        for entry in entries.as_array().into_iter().flatten() {
            // Claude Code: `{matcher, hooks: [{type, command}]}`; Codex and Copilot put the command on the entry.
            let inner: Vec<&Value> = match entry.get("hooks").and_then(Value::as_array) {
                Some(list) => list.iter().collect(),
                None => vec![entry],
            };
            for item in inner {
                for key in ["command", "commandWindows", "bash", "powershell", "prompt", "url"] {
                    let command = if key == "command" { command_of(item) } else { item.get(key).and_then(Value::as_str).map(str::to_owned) };
                    if let Some(command) = command {
                        hook(path, line_of(text, &needle(&command)), event, &command, out);
                    }
                }
            }
        }
    }
}

fn local_address(url: &str) -> bool {
    let host = url.split("://").nth(1).unwrap_or_default();
    host.starts_with("localhost") || host.starts_with("127.") || host.starts_with("[::1]")
}

fn bare_ip(url: &str) -> bool {
    let host = url.split("://").nth(1).unwrap_or_default().split(['/', ':']).next().unwrap_or_default();
    host.split('.').count() == 4 && host.split('.').all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
}

fn mcp_servers(path: &str, text: &str, servers: &Value, out: &mut Findings) {
    let Some(servers) = servers.as_object() else { return };
    for (name, server) in servers {
        let line = line_of(text, &format!("\"{name}\""));
        if let Some(command) = command_of(server) {
            out.push("mcp-server", Severity::Medium, path, line, &format!("{name}: {command}"));
            scan_text(path, &command, false, Some(line), out);
            let program = command.split_whitespace().next().unwrap_or_default().rsplit(['/', '\\']).next().unwrap_or_default().trim_end_matches(".cmd").trim_end_matches(".exe");
            let fetched = matches!(program, "npx" | "bunx" | "uvx" | "pipx" | "pnpx") || command.contains(" dlx ") || command.contains("npm exec") || command.contains("uv tool run");
            // `package@1.2.3` or `package==1.2.3` names one version; `@latest` and a bare name don't.
            let pinned = command.split_whitespace().skip(1).any(|word| {
                let version = word.rsplit_once("==").map(|(_, v)| v).or_else(|| word.rfind('@').filter(|at| *at > 0).map(|at| &word[at + 1..]));
                version.is_some_and(|v| v.starts_with(|c: char| c.is_ascii_digit()))
            });
            if fetched && !pinned {
                out.push("mcp-remote-code", Severity::High, path, line, &format!("{name}: {command}"));
            }
        }
        if let Some(url) = server.get("url").or_else(|| server.get("httpUrl")).and_then(Value::as_str) {
            out.push("mcp-server", Severity::Medium, path, line, &format!("{name}: {url}"));
            if !local_address(url) && (url.starts_with("http://") || url.starts_with("ws://") || bare_ip(url)) {
                out.push("mcp-insecure-url", Severity::High, path, line, &format!("{name}: {url}"));
            }
            scan_text(path, url, false, Some(line), out);
        }
    }
}

fn permissions(path: &str, text: &str, root: &Value, out: &mut Findings) {
    let wide = |rule: &str| matches!(rule, "*" | "Bash" | "Bash(*)" | "Bash(*:*)" | "PowerShell" | "PowerShell(*)") || rule.starts_with("Bash(*") && rule.len() <= 8;
    for rule in root.pointer("/permissions/allow").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str) {
        if wide(rule) {
            out.push("broad-permissions", Severity::High, path, line_of(text, "\"allow\""), &format!("allow: {rule}"));
        }
    }
    if root.pointer("/permissions/defaultMode").and_then(Value::as_str) == Some("bypassPermissions") {
        out.push("broad-permissions", Severity::High, path, line_of(text, "defaultMode"), "defaultMode: bypassPermissions");
    }
    if root.get("enableAllProjectMcpServers").and_then(Value::as_bool) == Some(true) {
        out.push("broad-permissions", Severity::High, path, line_of(text, "enableAllProjectMcpServers"), "enableAllProjectMcpServers: true");
    }
}

/// Returns whether the file names a license (a plugin's manifest does).
pub(crate) fn scan_json(path: &str, text: &str, out: &mut Findings) -> bool {
    let Ok(root) = serde_json::from_str::<Value>(text.trim_start_matches('\u{feff}')) else { return false };
    if let Some(found) = root.get("hooks").filter(|value| value.is_object()) {
        hooks(path, text, found, out);
    }
    if let Some(found) = root.get("mcpServers").filter(|value| value.is_object()) {
        mcp_servers(path, text, found, out);
    } else if path == ".mcp.json" || path.ends_with("/.mcp.json") {
        // A plugin's `.mcp.json` may list the servers at the top level.
        mcp_servers(path, text, &root, out);
    }
    permissions(path, text, &root, out);
    let manifest = path.ends_with("plugin.json") || path.ends_with("gemini-extension.json") || path.ends_with("package.json");
    manifest && root.get("license").and_then(Value::as_str).is_some_and(|license| !license.is_empty())
}
