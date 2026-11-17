# AI Hub Bar for Windows and Linux — rules for agents

Read before working in `desktop/`. The general rules (STATUS format, branches, PRs, answers to Oleh in Russian) are in `~/Projects/CLAUDE.md` on the Mac and `%USERPROFILE%\Projects\CLAUDE.md` on Windows (copied by hand, see `WINDOWS-DEV.md`). If that file is missing, ask Oleh to copy it before committing anything.

## What to read

- `docs/specs/SPEC-windows.md`: §9 the stages and what is left, §11 the map of Mac features (works / worse / won't work), §11.4 what to check live first. Linux: `docs/specs/SPEC-linux.md`.
- `desktop/README.md`: layout, texts, build.
- The Mac app (`AIHubBar/`, Swift) is the reference for behaviour and file formats. Port its logic, keep its rules and its texts.

## Don't

- Don't change the Mac app for Windows. If a shared file format changes, it changes in both at once (SPEC-windows §8).
- Don't ask for administrator rights or install services; don't change system settings without a click.
- Don't promise in the interface what doesn't work on Windows: «Показать» brings a window forward, not a tab.

## Texts

Keys are the Russian texts of `AIHubBar/Resources/Localizable.xcstrings`. A new text goes into the catalog first, with all 12 translations, then `python3 scripts/strings.py` (in `desktop/`). Never edit `ui/i18n/*.json` by hand.

## Windows pitfalls

- Every child process (`git`, `gh`, `claude`, `codex`) gets `CREATE_NO_WINDOW` (`std::os::windows::process::CommandExt::creation_flags(0x0800_0000)`), or a console window flashes on every call.
- `Command::new("claude")` doesn't find npm's `claude.cmd`: resolve the program through `PATH` and `PATHEXT` first, and start `.cmd` / `.bat` through `cmd /c`.
- Paths have spaces and non-Latin letters (`C:\Users\Олег\…`). Hooks go in exec form (`command` + `args`), never through a shell string.
- Read files with CRLF or LF; write UTF-8 without BOM, keeping the line endings the file already has.
- Background runs: Claude uses the PowerShell tool when Git Bash is missing, so permission rules need `PowerShell(...)` entries next to `Bash(...)` (SPEC-windows §11.2).

## Checks before every commit

In `desktop/` (on Windows `python` instead of `python3`):

```bash
python3 scripts/strings.py --check
cargo test --workspace
```

On Windows also run the app (`npx tauri dev`) for anything visible, and write in STATUS → Checked what was run and what was seen live. CI repeats the tests on Windows and Linux and builds the installers; a red CI is not merged.
