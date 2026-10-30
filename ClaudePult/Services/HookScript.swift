import Foundation

/// The Claude Code hook installed to Application Support. It must never affect Claude:
/// no stdout (SessionStart/UserPromptSubmit stdout would enter Claude's context), no stderr, always exit 0.
/// Events and fields follow code.claude.com/docs/en/hooks (checked 2026-10-29, see DECISIONS.md).
enum HookScript {
    static func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(source.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static let source = #"""
    #!/usr/bin/python3
    # ClaudePult hook, format 1. Installed by ClaudePult.app; records Claude Code session state in
    # ~/Library/Application Support/ClaudePult/sessions/<session_id>.json for the menu bar app.
    # Prints nothing and always exits 0, so it can never change what Claude does.
    import datetime, fcntl, json, os, re, subprocess, sys

    WAITING_NOTIFICATIONS = {"permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"}
    CLAUDE_NAMES = {"claude", "claude.exe"}
    PROMPT_LIMIT = 200


    def arg(name, default=None):
        argv = sys.argv[1:]
        return argv[argv.index(name) + 1] if name in argv and argv.index(name) + 1 < len(argv) else default


    def now():
        return datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat(timespec="seconds")


    def clip(text):
        text = " ".join((text or "").split())
        return text[:PROMPT_LIMIT]


    def project_of(cwd, projects_dir):
        if not cwd or not projects_dir:
            return None, None
        root = os.path.normpath(projects_dir)
        cwd = os.path.normpath(cwd)
        if not cwd.startswith(root + os.sep):
            return None, None
        name = cwd[len(root) + 1:].split(os.sep)[0]
        return name, os.path.join(root, name)


    def claude_process():
        """Walks up from the hook to the Claude Code process: (pid, tty or None)."""
        pid = os.getppid()
        for _ in range(5):
            try:
                out = subprocess.run(["/bin/ps", "-o", "ppid=,tty=,comm=", "-p", str(pid)],
                                     capture_output=True, text=True, timeout=2).stdout.strip()
            except Exception:
                return None, None
            parts = out.split(None, 2)
            if len(parts) < 3:
                return None, None
            ppid, tty, comm = parts
            if os.path.basename(comm) in CLAUDE_NAMES:
                return pid, (None if tty in ("??", "-") else "/dev/" + tty)
            pid = int(ppid)
            if pid <= 1:
                break
        return None, None


    def apply(record, data):
        event = data.get("hook_event_name", "")
        state = record.get("state")
        if event == "SessionStart":
            if data.get("source") != "compact" or not state:
                record["state"] = "done"
                record.pop("message", None)
        elif event == "UserPromptSubmit":
            record["state"] = "running"
            record.pop("message", None)
            prompt = clip(data.get("prompt"))
            if prompt:
                record["last_prompt"] = prompt
                record.setdefault("first_prompt", prompt)
        elif event == "PermissionRequest":
            record["state"] = "waiting"
            record["message"] = clip("Нужно разрешение: " + str(data.get("tool_name") or "инструмент"))
        elif event == "Notification":
            if data.get("notification_type") in WAITING_NOTIFICATIONS:
                record["state"] = "waiting"
                record["message"] = clip(data.get("message"))
        elif event == "PostToolUse":
            record["state"] = "running"
            record.pop("message", None)
        elif event == "Stop":
            record["state"] = "done"
            record.pop("message", None)
        elif event == "StopFailure":
            record["state"] = "done"
            record["message"] = "Ответ прерван ошибкой API"
        elif event == "SessionEnd":
            record["state"] = "ended"
            record["end_reason"] = data.get("reason")
        record["event"] = event


    def main():
        data = json.load(sys.stdin)
        session_id = str(data.get("session_id") or "")
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", session_id):
            return
        directory = arg("--sessions-dir") or os.path.expanduser("~/Library/Application Support/ClaudePult/sessions")
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, session_id + ".json")

        with open(os.path.join(directory, ".lock"), "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                with open(path) as f:
                    record = json.load(f)
            except Exception:
                record = {}
            before = (record.get("state"), record.get("message"))
            stamp = now()

            # PostToolUse fires on every tool call: write only when something changes or once a minute.
            if data.get("hook_event_name") == "PostToolUse" and record.get("state") == "running":
                try:
                    last = datetime.datetime.fromisoformat(record.get("updated_at", ""))
                    if (datetime.datetime.now(last.tzinfo) - last).total_seconds() < 60:
                        return
                except Exception:
                    pass

            record.update({"version": 1, "session_id": session_id, "updated_at": stamp})
            record.setdefault("started_at", stamp)
            for key in ("cwd", "transcript_path"):
                if data.get(key):
                    record[key] = data[key]
            record["project"], record["project_path"] = project_of(record.get("cwd"), arg("--projects-dir"))
            # A resumed session (the Claude app restarted, `claude --resume`) runs in a new process: follow it,
            # or the panel would take the old, gone process for an ended session.
            pid, tty = claude_process()
            if "claude_pid" not in record or (pid and pid != record.get("claude_pid")):
                record["claude_pid"], record["tty"] = pid, tty
                record["term_program"] = os.environ.get("TERM_PROGRAM")
                record["entrypoint"] = os.environ.get("CLAUDE_CODE_ENTRYPOINT")
            apply(record, data)

            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(record, f, ensure_ascii=False, indent=1)
            os.replace(tmp, path)


    if __name__ == "__main__":
        try:
            sys.stderr = open(os.devnull, "w")
            main()
        except Exception:
            pass
        sys.exit(0)
    """#
}
