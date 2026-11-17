# Developing the Windows version on a Windows PC

Work on `desktop/` moved from the Mac to Oleh's Windows laptop on 2026-11-17: there the app can be built, run and checked against a real tray, real hooks and Claude Code's real token. The Mac app (`AIHubBar/`) stays on the Mac. What will and won't work on Windows: [SPEC-windows §11](../docs/specs/SPEC-windows.md#11-карта-функций-mac-версии-2026-11-17). Rules for the agent: [CLAUDE.md](CLAUDE.md).

## 1. Install

| What | How |
|---|---|
| Git for Windows (Git Bash comes with it) | `winget install Git.Git` |
| GitHub CLI | `winget install GitHub.cli`, then `gh auth login` |
| Visual Studio Build Tools, workload «Desktop development with C++» | `winget install Microsoft.VisualStudio.2022.BuildTools`, then tick the workload in the Visual Studio Installer. Rust needs its linker |
| Rust (stable, MSVC) | `winget install Rustlang.Rustup`, then `rustup default stable` |
| Node 22 | `winget install OpenJS.NodeJS.22` |
| Python 3 (for `scripts/strings.py`) | `winget install Python.Python.3.13` |
| Claude Code | `winget install Anthropic.ClaudeCode`, then `claude` and sign in with the same account as on the Mac |

WebView2 is part of Windows 11; Windows 10 gets it from the installer.

Then, once:

```powershell
git config --global core.longpaths true
```

Worktree paths in `.claude\worktrees\…` easily pass Windows' 260-character limit.

## 2. Get the code

Keep it out of OneDrive (it syncs `target\`, gigabytes of build output) and in a short path:

```powershell
mkdir $HOME\Projects; cd $HOME\Projects
gh repo clone OlehDemishev/AIHubBar
cd AIHubBar\desktop
npm ci
cargo test --workspace
```

Line endings are fixed by `.gitattributes`: files stay LF whatever Git's `core.autocrlf` says, `.cmd` and `.bat` are CRLF.

## 3. Bring the rules over

The repository has no rules of Oleh's own: they live outside it on the Mac. Copy them to the same places on Windows, so the laptop's sessions follow the same STATUS format, branches and PRs:

| On the Mac | On Windows |
|---|---|
| `~/Projects/CLAUDE.md` | `%USERPROFILE%\Projects\CLAUDE.md` |
| `~/.claude/CLAUDE.md` | `%USERPROFILE%\.claude\CLAUDE.md` |

The memory folder (`~/.claude/projects/-Users-…-ClaudePult/memory/`) is tied to the Mac's path and is mostly about the Mac app; it is not needed.

## 4. Run

```powershell
cd desktop
npx tauri dev
```

The app appears in the tray (look under «^»). Settings → Hooks installs `claudepult-hook.exe` into the real `%USERPROFILE%\.claude\settings.json` (a backup goes next to it). In a dev build the hook is `target\debug\claudepult-hook.exe`: remove the hooks in Settings before deleting `target\`, or every Claude Code session will report a missing hook.

The installer, as CI builds it:

```powershell
cargo build --release -p claudepult-hook -p claudepult-cli
bash scripts/stage-binaries.sh
npx tauri build --bundles nsis --config app/tauri.bundle.conf.json
```

## 5. Working next to the Mac

- `git pull` before every session: the Mac's sessions change `docs/STATUS.md` and the string catalog too.
- Small PRs, pushed often: the morning report on the Mac sees only what is pushed.
- A change to `AIHubBar/Resources/Localizable.xcstrings` (new texts for Windows) is also a Mac change: CI on GitHub checks the catalog, the Mac checks (`scripts/check.sh`) run only on the Mac.
- CI (`.github/workflows/desktop.yml`) runs the tests on Windows and Linux and builds the installers for every PR that touches `desktop/` or the catalog.

## 6. First session on the laptop

Start with the live check of SPEC-windows §11.4: install the CI build or run `npx tauri dev`, then check the hook, the token file, the tray and a notification with buttons, and write what was found into SPEC-windows and STATUS.
