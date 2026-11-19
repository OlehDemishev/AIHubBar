# Code signing policy

Windows builds of AI Hub Bar are signed through SignPath.

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).

> Status (2026-11-19): the application to SignPath Foundation is being prepared. Until it is granted, Windows builds are unsigned and Windows SmartScreen warns before installing them. macOS builds are signed and notarized with the author's own Apple Developer ID, separately from this policy.

## What is signed

Only the binaries of this project, built from this repository's source:

- `AIHubBar.exe` — the tray app (Rust, [Tauri](https://tauri.app));
- `claudepult.exe` — its command line;
- `claudepult-hook.exe` — the session hook that Claude Code, Codex and Copilot CLI run;
- `AI Hub Bar_<version>_x64-setup.exe` — the NSIS installer that contains them.

They are built by [`.github/workflows/desktop-release.yml`](.github/workflows/desktop-release.yml) on GitHub-hosted runners, from a tag of this repository, with every job up to the signing request on GitHub's own machines. Third-party libraries come from crates.io and npm as listed in `desktop/Cargo.lock` and `desktop/package-lock.json`; no proprietary components are included. Every release is approved by hand in SignPath before it is signed.

## Team roles

- Committers and reviewers: [Oleh Demishev](https://github.com/OlehDemishev), the author and owner of this repository. Changes from anyone else come as pull requests and are reviewed before merging.
- Approvers: [Oleh Demishev](https://github.com/OlehDemishev). Each signing request is approved by him.

Everyone on the team uses multi-factor authentication for GitHub and SignPath.

## Privacy

AI Hub Bar has no account and no analytics. The Windows app talks only to services you use or set up:

- Anthropic, for your Claude Code limits, with Claude Code's own sign-in read from your computer on each refresh and never stored by the app;
- the AI services you add (Codex, GitHub Copilot through `gh`, Gemini CLI, OpenRouter, models by API key), for their limits and for the commands you run with them; keys are kept in Windows Credential Manager, never in logs or exported settings;
- GitHub through your own `git` and `gh`, for your projects' pull requests and CI.

This program will not transfer any information to other networked systems unless specifically requested by the user or the person installing or operating it. More in the [README's privacy section](README.md#privacy).

## What the Windows installer changes

It installs for the current user only, with no administrator rights:

- the app in `%LOCALAPPDATA%\AI Hub Bar` and a Start menu shortcut (Windows notifications need it);
- `.claudepult` files opened by AI Hub Bar (its settings files);
- the app's folder added to the user's `Path`, so `claudepult` works in a terminal.

Start at sign-in is off until it is switched on in Settings. Session hooks are added to `~\.claude\settings.json`, `~\.codex` or `~\.copilot` only when you install them in Settings, with a backup next to the file, and the button next to them takes them out again. The uninstaller («Apps» → AI Hub Bar → Uninstall) removes the app, the shortcut, the file association and the `Path` entry.
