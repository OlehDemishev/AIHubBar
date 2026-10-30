import Foundation

/// The Claude Code hook installed to Application Support. It must never affect Claude on its own:
/// no stdout (SessionStart/UserPromptSubmit stdout would enter Claude's context), no stderr, always exit 0.
/// The one exception is an answer the person gave in ClaudePult to a PermissionRequest (see `ApprovalFiles`).
/// Events and fields follow code.claude.com/docs/en/hooks (checked 2026-10-29, see DECISIONS.md).
enum HookScript {
    static func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(source.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static let source = #"""
    #!/usr/bin/python3
    # AI Hub Bar hook, format 2. Installed by AI Hub Bar; records Claude Code session state in
    # ~/Library/Application Support/ClaudePult/sessions/<session_id>.json for the menu bar app.
    # Always exits 0 and prints nothing, except on PermissionRequest when the person answered «Разрешить» or
    # «Отклонить» in AI Hub Bar: then it prints that decision. Claude shows its own dialog meanwhile.
    import datetime, fcntl, json, os, re, signal, subprocess, sys, time, uuid

    WAITING_NOTIFICATIONS = {"permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"}
    CLAUDE_NAMES = {"claude", "claude.exe"}
    PROMPT_LIMIT = 200
    APPROVAL_WAIT = 290
    ALIVE_WITHIN = 30


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
            record["last_tool"], record["last_target"] = action_of(data)
            record["last_tool_at"] = now()
        elif event == "Stop":
            record["state"] = "done"
            record.pop("message", None)
            for key in ("last_tool", "last_target", "last_tool_at"):
                record.pop(key, None)
        elif event == "StopFailure":
            record["state"] = "done"
            record["message"] = "Ответ прерван ошибкой API"
        elif event == "SessionEnd":
            record["state"] = "ended"
            record["end_reason"] = data.get("reason")
        record["event"] = event


    def action_of(data):
        """What a tool call did, for «what Claude is doing now»: (tool, target)."""
        tool = str(data.get("tool_name") or "")
        tool_input = data.get("tool_input") or {}
        target = ""
        if isinstance(tool_input, dict):
            for key in ("file_path", "notebook_path", "command", "pattern", "url", "query", "description", "prompt"):
                value = tool_input.get(key)
                if value:
                    value = str(value)
                    target = os.path.basename(value) if key.endswith("_path") else " ".join(value.split())[:80]
                    break
        return tool, target


    def approvals_alive(directory):
        try:
            return time.time() - os.path.getmtime(os.path.join(directory, "alive")) < ALIVE_WITHIN
        except Exception:
            return False


    def open_request(data, directory, session_id):
        """Asks AI Hub Bar (only while it runs with the option on): returns the request id or None."""
        if not approvals_alive(directory):
            return None
        tool_input = data.get("tool_input") or {}
        summary = ""
        for key in ("command", "file_path", "url", "pattern", "description", "prompt"):
            if isinstance(tool_input, dict) and tool_input.get(key):
                summary = clip(str(tool_input[key]))
                break
        request_id = uuid.uuid4().hex
        project, _ = project_of(data.get("cwd"), arg("--projects-dir"))
        request = {"id": request_id, "session_id": session_id, "project": project or os.path.basename(data.get("cwd") or ""),
                   "tool": str(data.get("tool_name") or ""), "summary": summary, "created": time.time(), "pid": os.getpid()}
        tmp = os.path.join(directory, request_id + ".tmp")
        with open(tmp, "w") as f:
            json.dump(request, f, ensure_ascii=False)
        os.replace(tmp, os.path.join(directory, request_id + ".request.json"))
        return request_id


    def wait_for_decision(directory, request_id, record_path):
        """allow / deny from AI Hub Bar, or None: answered in Claude, AI Hub Bar gone, or too late."""
        started = time.time()
        decision_path = os.path.join(directory, request_id + ".decision")
        try:
            while time.time() - started < APPROVAL_WAIT:
                try:
                    with open(decision_path) as f:
                        behavior = f.read().strip()
                    if behavior in ("allow", "deny"):
                        return behavior
                except FileNotFoundError:
                    pass
                try:
                    with open(record_path) as f:
                        if json.load(f).get("event") not in ("PermissionRequest", "Notification"):
                            return None
                except Exception:
                    pass
                if not approvals_alive(directory):
                    return None
                time.sleep(0.5)
            return None
        finally:
            for suffix in (".request.json", ".decision"):
                try:
                    os.remove(os.path.join(directory, request_id + suffix))
                except Exception:
                    pass


    def main():
        data = json.load(sys.stdin)
        session_id = str(data.get("session_id") or "")
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", session_id):
            return
        directory = arg("--sessions-dir") or os.path.expanduser("~/Library/Application Support/ClaudePult/sessions")
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, session_id + ".json")

        # The request goes first, so AI Hub Bar sees it together with the «waiting» state.
        request_id = None
        approvals = os.path.join(os.path.dirname(directory), "approvals")
        if data.get("hook_event_name") == "PermissionRequest":
            try:
                request_id = open_request(data, approvals, session_id)
            except Exception:
                request_id = None

        with open(os.path.join(directory, ".lock"), "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                with open(path) as f:
                    record = json.load(f)
            except Exception:
                record = {}
            before = (record.get("state"), record.get("message"))
            stamp = now()

            # PostToolUse fires on every tool call: write when the action changes, else once a minute.
            if data.get("hook_event_name") == "PostToolUse" and record.get("state") == "running":
                try:
                    last = datetime.datetime.fromisoformat(record.get("updated_at", ""))
                    age = (datetime.datetime.now(last.tzinfo) - last).total_seconds()
                    same = action_of(data) == (record.get("last_tool"), record.get("last_target"))
                    if same and age < 60:
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

        if request_id:
            behavior = wait_for_decision(approvals, request_id, path)
            if behavior == "allow":
                decision = {"behavior": "allow"}
            elif behavior == "deny":
                decision = {"behavior": "deny", "message": "Отклонено в AI Hub Bar"}
            else:
                return
            sys.__stdout__.write(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}))
            sys.__stdout__.flush()


    if __name__ == "__main__":
        # Claude cancels a hook at its timeout: leave through `finally`, so the request files go too.
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        try:
            sys.stderr = open(os.devnull, "w")
            main()
        except Exception:
            pass
        sys.exit(0)
    """#
}
