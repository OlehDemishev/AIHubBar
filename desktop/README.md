# AI Hub Bar for Windows and Linux

Tauri 2: a Rust core plus a small HTML interface. The plan and the stages are in [docs/specs/SPEC-windows.md](../docs/specs/SPEC-windows.md) and [docs/specs/SPEC-linux.md](../docs/specs/SPEC-linux.md). The Mac app (Swift, in `AIHubBar/`) shares no code with this folder, only file formats and texts.

**Stage 1 «Каркас»** is done:
- the tray icon with its menu;
- the panel at the icon;
- the settings window (language, start at sign-in);
- 13 languages;
- one running copy;
- `claudepult --app-command panel|settings|quit`.

**Stage 2 «Лимиты»** is mostly done:
- the session and week limits from Claude Code's token file;
- the tray icon drawn as a ring, with the summary in its hint;
- the forecast;
- notifications at 50 / 80 / 95 %;
- `usage.json`.

Still to come in stage 2: Telegram, spend per project, custom thresholds.

**Stage 3 «Сессии»** is mostly done:
- `claudepult-hook`, a port of the Mac hook that writes the same session files;
- installing it into Claude Code's `settings.json` in exec form (Settings → Hooks);
- the sessions list in the panel;
- an orange dot on the tray icon while a session waits.

Still to come in stage 3: «Show» (bringing the terminal forward), checking whether the process is alive, answering permission requests from the app.

On a Mac this build never installs hooks into the real `~/.claude/settings.json`: the Mac app owns it. It does so only with another `CLAUDE_CONFIG_DIR`.

## Layout

| Folder | What |
|---|---|
| `core/` | Shared logic with no interface: paths, `settings.json`, languages, the link to the running app, limits (`usage.rs`, `texts.rs`, `tray_icon.rs`). `cargo test -p claudepult-core` runs on any system |
| `app/` | The tray app, `AIHubBar.exe` / `AIHubBar` (`tauri.conf.json`, icons, capabilities) |
| `cli/` | `claudepult`, the console program: `AIHubBar.exe` is a window program and cannot print to a console |
| `hook/` | `claudepult-hook`, the Claude Code hook (port of the Mac's Python hook); `cargo test -p claudepult-hook` runs it with real events |
| `ui/` | The panel and settings pages, plain HTML/JS with no bundler; `ui/i18n/*.json` are generated |
| `scripts/strings.py` | Writes `ui/i18n/` from the Mac app's String Catalog |

The two programs are called `AIHubBar` and `claudepult`, not `ClaudePult` and `claudepult`. Windows and macOS file systems ignore letter case, so names that differ only in case would overwrite each other.

## Texts

Keys are the Russian texts of the Mac catalog, `AIHubBar/Resources/Localizable.xcstrings`. A new text works like this:
1. Add it to the catalog first, with all 12 translations.
2. Use it in the code: `data-t="…"` or `t("…")` in `ui/`, `.t("…")` in Rust.
3. Run `python3 scripts/strings.py`.

`--check` fails when a key or a translation is missing, or when the files are out of date. CI runs it.

## Build and run

You need Rust (stable) and Node 22. On Linux you also need the Tauri libraries: `libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev libssl-dev`.

```bash
npm ci
cargo test --workspace
npx tauri dev                      # the app, with reload
cargo build --release -p claudepult-hook -p claudepult-cli
./scripts/stage-binaries.sh        # puts both next to the app in the installer
npx tauri build --bundles nsis --config app/tauri.bundle.conf.json   # Windows installer (current user, no admin)
npx tauri build --bundles deb --config app/tauri.bundle.conf.json    # Linux package
```

On a Mac this version runs for development only:
- its files go to `~/Library/Application Support/ClaudePult Desktop Dev/`, never the real app's folder;
- `claudepult` talks to it through `/tmp/ClaudePult-<user>`.

## CI

`.github/workflows/desktop.yml` runs on GitHub's Windows and Linux machines. The repository is public, so it costs nothing. It does three things:
- checks the texts;
- runs `cargo test`;
- builds the Windows installer and the `.deb`, kept for 14 days as artifacts of the run.
