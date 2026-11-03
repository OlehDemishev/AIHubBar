# Specs

Every spec of the Mac app (and the postponed Windows/Linux versions), with where it stands. Details and what is left
are in each spec and in the journal: `docs/STATUS.md`, older months in `docs/status/`.

| Spec | What | State |
|---|---|---|
| [SPEC.md](SPEC.md) | the programmer's control panel: projects, sessions, commands | done (stages 1–8) |
| [SPEC-modes.md](SPEC-modes.md) | work modes, templates, the assistant, AI services | done; modes became profiles (next row) |
| [SPEC-profiles.md](SPEC-profiles.md) | profiles made of modules, empty by default | done |
| [SPEC-hub.md](SPEC-hub.md) | limits and usage of other AIs | done 2026-10-30; its leftovers (forecast, per-service alerts, menu bar, widget) done in SPEC-ai-services |
| [SPEC-ai-services.md](SPEC-ai-services.md) | Claude as one of the AI services, one view for every service | done (stages 1–6); Copilot states via its hooks (2026-11-03); «waiting» for Codex / Antigravity, Cursor CLI left |
| [SPEC-notch.md](SPEC-notch.md) | the island at the notch | done (stages 1–5); a live VoiceOver walk left |
| [SPEC-layout.md](SPEC-layout.md) | «Раскладка», automatic keyboard layout switch | in beta |
| [SPEC-settings.md](SPEC-settings.md) | Settings around modules, places, menu bar | done (#201, #203) |
| [SPEC-help.md](SPEC-help.md) | help in the app and on the site | done (#206) |
| [SPEC-refactor.md](SPEC-refactor.md) | refactoring audit and plan | done (stages 0–8) |
| [SPEC-windows.md](SPEC-windows.md) | Windows version (`desktop/`, Tauri 2) | postponed after stages 1–3 main parts |
| [SPEC-linux.md](SPEC-linux.md) | Linux version (same code as Windows) | postponed with Windows |

A new spec goes here as `SPEC-<topic>.md` with a row in this table; update the row when its state changes.
