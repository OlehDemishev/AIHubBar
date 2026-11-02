# AI Hub Bar for Windows and Linux

Tauri 2: a Rust core plus a small HTML interface. The plan and the stages are in [docs/SPEC-windows.md](../docs/SPEC-windows.md) and [docs/SPEC-linux.md](../docs/SPEC-linux.md). The Mac app (Swift, in `ClaudePult/`) shares no code with this folder, only file formats and texts.

**Stage 1 «Каркас»** is done:
- the tray icon with its menu;
- the panel at the icon;
- the settings window (language, start at sign-in);
- 13 languages;
- one running copy;
- `claudepult --app-command panel|settings|quit`.

Limits, sessions and projects come in the next stages.

## Layout

| Folder | What |
|---|---|
| `core/` | Shared logic with no interface: paths, `settings.json`, languages, the link to the running app. `cargo test -p claudepult-core` runs on any system |
| `app/` | The tray app, `AIHubBar.exe` / `AIHubBar` (`tauri.conf.json`, icons, capabilities) |
| `cli/` | `claudepult`, the console program: `AIHubBar.exe` is a window program and cannot print to a console |
| `ui/` | The panel and settings pages, plain HTML/JS with no bundler; `ui/i18n/*.json` are generated |
| `scripts/strings.py` | Writes `ui/i18n/` from the Mac app's String Catalog |

The two programs are called `AIHubBar` and `claudepult`, not `ClaudePult` and `claudepult`. Windows and macOS file systems ignore letter case, so names that differ only in case would overwrite each other.

## Texts

Keys are the Russian texts of the Mac catalog, `ClaudePult/Resources/Localizable.xcstrings`. A new text works like this:
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
npx tauri build --bundles nsis     # Windows installer (current user, no admin)
npx tauri build --bundles deb      # Linux package
cargo build --release -p claudepult-cli
```

On a Mac this version runs for development only:
- its files go to `~/Library/Application Support/ClaudePult Desktop Dev/`, never the real app's folder;
- `claudepult` talks to it through `/tmp/ClaudePult-<user>`.

## CI

`.github/workflows/desktop.yml` runs on GitHub's Windows and Linux machines. The repository is public, so it costs nothing. It does three things:
- checks the texts;
- runs `cargo test`;
- builds the Windows installer and the `.deb`, kept for 14 days as artifacts of the run.
