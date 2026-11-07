# Specs

Every spec of the Mac app (and the postponed Windows/Linux versions), with where it stands. Details and what is left
are in each spec and in the journal: `docs/STATUS.md`, older months in `docs/status/`.

| Spec | What | State |
|---|---|---|
| [SPEC.md](SPEC.md) | the programmer's control panel: projects, sessions, commands | done (stages 1–8) |
| [SPEC-modes.md](SPEC-modes.md) | work modes, templates, the assistant, AI services | done; modes became profiles (next row) |
| [SPEC-profiles.md](SPEC-profiles.md) | profiles made of modules, empty by default | done |
| [SPEC-hub.md](SPEC-hub.md) | limits and usage of other AIs | done 2026-10-30; its leftovers (forecast, per-service alerts, menu bar, widget) done in SPEC-ai-services |
| [SPEC-ai-services.md](SPEC-ai-services.md) | Claude as one of the AI services, one view for every service | done (stages 1–7); Copilot and Codex states via their hooks (2026-11-03); Antigravity has no reliable «waiting» signal; Cursor CLI left |
| [SPEC-notch.md](SPEC-notch.md) | the island at the notch | done (stages 1–5); a live VoiceOver walk left |
| [SPEC-layout.md](SPEC-layout.md) | «Раскладка», automatic keyboard layout switch | done; out of beta in 0.6.0 |
| [AUDIT-ui.md](AUDIT-ui.md) | UI audit of 0.7.3: 38 findings and an order of work | open; items 1–5, 7–12, 19–21, 23, 24, 27–29 fixed |
| [SPEC-settings.md](SPEC-settings.md) | Settings around modules, places, menu bar | done (#201, #203) |
| [SPEC-content.md](SPEC-content.md) | writing texts with AI: «Тексты» profile, «Версии» module, batch tasks | agreed 2026-11-03, stage 1 next |
| [SPEC-help.md](SPEC-help.md) | help in the app and on the site | done (#206) |
| [SPEC-quick-prompt.md](SPEC-quick-prompt.md) | «Быстрый запрос»: a task to an agent from any app by a hot key | done (2026-11-03) |
| [SPEC-telegram.md](SPEC-telegram.md) | «Telegram»: one bot with its own menu — reports, sessions, tasks, limits, settings; a shared bot through a Cloudflare Worker | agreed 2026-11-03; stage 1 done (#242, #244); stages 1–4 done (#242–#255), shared bot and Mini App (§10) built; the Worker not deployed yet |
| [SPEC-refactor.md](SPEC-refactor.md) | refactoring audit and plan | done (stages 0–8) |
| [SPEC-windows.md](SPEC-windows.md) | Windows version (`desktop/`, Tauri 2) | postponed after stages 1–3 main parts |
| [SPEC-linux.md](SPEC-linux.md) | Linux version (same code as Windows) | postponed with Windows |

A new spec goes here as `SPEC-<topic>.md` with a row in this table; update the row when its state changes.
