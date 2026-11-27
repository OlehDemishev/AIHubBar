import Foundation

/// What AI Hub Bar puts on another computer reached over SSH (`RemoteMachine`): the same hook as here, and a small
/// helper that reads the hook's files and prints them. Nothing else runs there, and nothing listens on a port: the
/// helper lives only while this Mac's `ssh` holds the connection.
enum RemoteScript {
    /// Raised with every change to `helper`: an older helper on the other computer is replaced on the next connect.
    static let format = 1
    /// From the home folder, where `ssh` starts: no spaces, the same on macOS and Linux.
    static let helperPath = ".aihubbar/remote.py"

    /// The program sent to `python3 -` on the other computer: writes the hook and the helper, merges the hook into
    /// `~/.claude/settings.json` (with a backup) and prints what it did as one JSON line.
    static func bootstrap(hook: String = HookScript.source, events: [String] = HookInstaller.events) -> String {
        let payload: [String: Any] = [
            "hook": hook, "helper": helper,
            "events": Dictionary(uniqueKeysWithValues: events.map { ($0, HookInstaller.timeout(for: $0)) }),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return """
        import base64, json
        P = json.loads(base64.b64decode("\(data.base64EncodedString())").decode("utf-8"))
        ns = {"__name__": "aihubbar_bootstrap"}
        exec(P["helper"], ns)
        ns["install"](P)
        """
    }

    static let helper = #"""
    #!/usr/bin/env python3
    # AI Hub Bar remote helper, format 1. Put here by AI Hub Bar from another Mac over SSH; it only reads and writes
    # AI Hub Bar's own files (and, on install, merges its hook into ~/.claude/settings.json with a backup).
    #   watch [--approvals]   print the sessions and open permission requests as JSON lines until the pipe closes
    #   decide <id> allow|deny
    #   uninstall
    import json, os, platform, re, shutil, subprocess, sys, time

    FORMAT = 1
    MARKER = "claudepult-hook"
    PROCESS_NAMES = {"claude", "claude.exe", "copilot", "codex"}
    KEEP = 3 * 3600
    REQUEST_WAIT = 290


    def root():
        if platform.system() == "Darwin":
            return os.path.expanduser("~/Library/Application Support/ClaudePult")
        return os.path.expanduser("~/.local/share/aihubbar")


    def paths():
        base = root()
        return {"sessions": os.path.join(base, "sessions"), "approvals": os.path.join(base, "approvals"),
                "hook": os.path.join(base, "hooks", "claudepult-hook.py"),
                "ours": os.path.join(base, "remote-installed"),
                "helper": os.path.expanduser("~/.aihubbar/remote.py"),
                "settings": os.path.expanduser("~/.claude/settings.json")}


    def quote(text):
        return "'" + text.replace("'", "'\\''") + "'"


    def write_atomic(path, text, mode=None):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)


    def is_ours(entry):
        return isinstance(entry, dict) and MARKER in str(entry.get("command") or "")


    def has_hook(settings):
        hooks = settings.get("hooks") if isinstance(settings, dict) else None
        for groups in (hooks or {}).values() if isinstance(hooks, dict) else []:
            for group in groups if isinstance(groups, list) else []:
                if isinstance(group, dict) and any(is_ours(e) for e in group.get("hooks") or []):
                    return True
        return False


    def removed(settings):
        hooks = settings.get("hooks")
        if not isinstance(hooks, dict):
            return settings
        for event in list(hooks):
            groups = hooks[event]
            if not isinstance(groups, list):
                continue
            kept = []
            for group in groups:
                entries = group.get("hooks") if isinstance(group, dict) else None
                if not isinstance(entries, list):
                    kept.append(group)
                    continue
                remaining = [e for e in entries if not is_ours(e)]
                if len(remaining) == len(entries):
                    kept.append(group)
                elif remaining:
                    kept.append(dict(group, hooks=remaining))
            if kept:
                hooks[event] = kept
            else:
                del hooks[event]
        if not hooks:
            del settings["hooks"]
        return settings


    def merged(settings, command, events):
        settings = removed(settings)
        hooks = settings.setdefault("hooks", {})
        for event in sorted(events):
            group = {"hooks": [{"type": "command", "command": command, "timeout": events[event]}]}
            if event == "PostToolUse":
                group["matcher"] = "*"
            hooks.setdefault(event, []).append(group)
        return settings


    def read_settings(path):
        """The settings as an object; None when there is no file. Anything unreadable raises: the file stays as it is."""
        try:
            with open(path, encoding="utf-8") as f:
                text = f.read()
        except FileNotFoundError:
            return None
        if not text.strip():
            return {}
        value = json.loads(text)
        if not isinstance(value, dict):
            raise ValueError("the root is not a JSON object")
        return value


    def write_settings(path, before, after):
        """Backs the file up next to itself and writes it; returns the backup's name or None."""
        if before == after:
            return None
        backup = None
        if os.path.exists(path):
            name = path + ".claudepult-backup-" + time.strftime("%Y%m%d-%H%M%S")
            backup, counter = name, 2
            while os.path.exists(backup):
                backup = "%s-%d" % (name, counter)
                counter += 1
            shutil.copy2(path, backup)
        # Through a symlink (settings kept in a dotfiles repository): replacing the link would break it.
        write_atomic(os.path.realpath(path), json.dumps(after, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
        return os.path.basename(backup) if backup else None


    def reply(value):
        sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\n")
        sys.stdout.flush()


    def install(payload):
        """Called by the bootstrap AI Hub Bar sends. A computer with its own AI Hub Bar keeps its own hook."""
        p = paths()
        result = {"format": FORMAT, "system": platform.system(), "host": platform.node(), "hook": "kept",
                  "claude": bool(shutil.which("claude") or os.path.exists(os.path.expanduser("~/.claude")))}
        try:
            write_atomic(p["helper"], payload["helper"], 0o755)
            before = read_settings(p["settings"])
            if not (before and has_hook(before) and not os.path.exists(p["ours"])):
                write_atomic(p["hook"], payload["hook"], 0o755)
                command = quote(p["hook"]) + " --sessions-dir " + quote(p["sessions"])
                after = merged(json.loads(json.dumps(before or {})), command, payload["events"])
                result["backup"] = write_settings(p["settings"], before, after)
                write_atomic(p["ours"], str(FORMAT))
                result["hook"] = "installed"
            os.makedirs(p["sessions"], exist_ok=True)
        except Exception as error:
            result["error"] = str(error)
        reply(result)


    def uninstall():
        p = paths()
        result = {"format": FORMAT}
        try:
            if os.path.exists(p["ours"]):
                before = read_settings(p["settings"])
                if before is not None:
                    result["backup"] = write_settings(p["settings"], before, removed(json.loads(json.dumps(before))))
                for key in ("hook", "ours"):
                    if os.path.exists(p[key]):
                        os.remove(p[key])
            if os.path.exists(p["helper"]):
                os.remove(p["helper"])
        except Exception as error:
            result["error"] = str(error)
        reply(result)


    def is_agent(pid):
        """True / False for a known process id, None without one."""
        if not isinstance(pid, int) or pid <= 0:
            return None
        try:
            out = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True, timeout=3).stdout
        except Exception:
            return None
        return os.path.basename(out.strip()) in PROCESS_NAMES


    def is_running(pid):
        if not isinstance(pid, int) or pid <= 0:
            return False
        try:
            os.kill(pid, 0)
            return True
        except PermissionError:
            return True
        except Exception:
            return False


    def sessions(directory, now):
        found = []
        try:
            names = sorted(os.listdir(directory))
        except Exception:
            return found
        for name in names:
            if not name.endswith(".json"):
                continue
            path = os.path.join(directory, name)
            try:
                age = now - os.path.getmtime(path)
                with open(path, encoding="utf-8") as f:
                    record = json.load(f)
            except Exception:
                continue
            if not isinstance(record, dict):
                continue
            alive = is_agent(record.get("claude_pid"))
            if alive is not True and age > KEEP:
                continue
            record["alive"] = alive
            found.append(record)
        return found


    def requests(directory, now):
        found = []
        try:
            names = sorted(os.listdir(directory))
        except Exception:
            return found
        for name in names:
            if not name.endswith(".request.json"):
                continue
            try:
                with open(os.path.join(directory, name), encoding="utf-8") as f:
                    request = json.load(f)
            except Exception:
                continue
            if not isinstance(request, dict) or now - float(request.get("created") or 0) >= REQUEST_WAIT:
                continue
            if "pid" in request and not is_running(request.get("pid")):
                continue
            found.append(request)
        return found


    def snapshot(now=None):
        now = time.time() if now is None else now
        p = paths()
        return {"format": FORMAT, "sessions": sessions(p["sessions"], now), "requests": requests(p["approvals"], now)}


    def watch(approvals):
        """A line on every change and every ten seconds, so the other side knows the connection is alive."""
        alive = os.path.join(paths()["approvals"], "alive")
        last, sent, touched = None, 0.0, 0.0
        while True:
            now = time.time()
            # The hook asks AI Hub Bar only while this file is fresh: with the connection gone, the agent asks as usual.
            if approvals and now - touched >= 10:
                try:
                    write_atomic(alive, str(now))
                    touched = now
                except Exception:
                    pass
            current = json.dumps(snapshot(now), ensure_ascii=False, sort_keys=True)
            if current != last or now - sent >= 10:
                try:
                    sys.stdout.write(current + "\n")
                    sys.stdout.flush()
                except Exception:
                    return
                last, sent = current, now
            time.sleep(1)


    def decide(request_id, behavior):
        if not re.fullmatch(r"[A-Za-z0-9-]{1,64}", request_id) or behavior not in ("allow", "deny"):
            reply({"error": "bad arguments"})
            return 2
        write_atomic(os.path.join(paths()["approvals"], request_id + ".decision"), behavior)
        reply({"ok": True})
        return 0


    def main(argv):
        command = argv[0] if argv else ""
        if command == "watch":
            watch("--approvals" in argv)
        elif command == "decide" and len(argv) == 3:
            return decide(argv[1], argv[2])
        elif command == "uninstall":
            uninstall()
        elif command == "snapshot":
            reply(snapshot())
        else:
            reply({"error": "unknown command", "format": FORMAT})
            return 2
        return 0


    if __name__ == "__main__":
        try:
            sys.exit(main(sys.argv[1:]))
        except (BrokenPipeError, KeyboardInterrupt):
            sys.exit(0)
    """#
}
