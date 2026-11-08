<p align="center">
  <img src="docs/images/hero.png" alt="AI Hub Bar: your AI and your Mac, one click away — AI limits and agent sessions, the notch island and Mac tools in the menu bar" width="100%">
</p>

<p align="center">
  <a href="https://github.com/OlehDemishev/AIHubBar/releases/latest"><img src="https://img.shields.io/github/v/release/OlehDemishev/AIHubBar?label=download&color=d9774b" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-1f1a17?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-f05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/languages-13-5b524c" alt="13 languages">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3fa66b" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://github.com/OlehDemishev/AIHubBar/releases/latest"><b>Download</b></a> ·
  <a href="https://olehdemishev.github.io/AIHubBar/"><b>Website</b></a> ·
  <a href="docs/GUIDE.md"><b>Guide</b></a> ·
  <a href="docs/AI-Hub-Bar-Overview-en.pdf"><b>Overview (PDF)</b></a> ·
  <a href="docs/AI-Hub-Bar-Overview-ru.pdf">Overview in Russian (PDF)</a>
</p>

**AI Hub Bar** is a small, native Mac app that lives in the menu bar. One click on ✦ opens a panel with the limits of your AI services, every agent session running on the Mac, and ready-made AI commands for your projects. It doesn't replace Claude Code, Codex, Gemini, Copilot or any other AI tool — it keeps an eye on them and starts them for you.

Free, open source, no account. Nothing goes through a server of ours, except the optional shared Telegram bot.

<p align="center">
  <a href="https://olehdemishev.github.io/AIHubBar/#demo"><img src="docs/images/demo.gif" alt="The AI Hub Bar panel opens from the menu bar and shows Claude limits and two agent sessions. One session asks to run git push, Allow is clicked in the panel, and the session finishes." width="540"></a>
</p>

## Features

### Limits — how much is left, and for how long
- **Every AI service in one place:** Claude, Codex, GitHub Copilot, Gemini CLI, Cursor, OpenRouter credits, OpenAI and Anthropic API spend. They appear by themselves.
- **Session and weekly limits** as rings, with a reset countdown, right in the menu bar.
- A **forecast** from your recent pace: "enough until the reset" or "lasts until ~16:40", and the same for the week.
- **Usage by project** — which project and which session ate the limit today or this week.
- **Usage history** — tokens by day for up to 90 days, CSV export, and a cost estimate at the price you enter.
- **Several Claude accounts**, each with its limits, and a note when Anthropic reports an outage.
- Notifications at the thresholds you choose, for each service; near the limit, background runs pause and resume after the reset.

### Every agent session in one list
- Claude Code, Codex and Copilot CLI, in Terminal, the Claude app or in the background: state, task, duration — and **what the agent is doing right now** ("editing LimitsView.swift", "running npm test").
- **Allow / Deny** permission requests from the notification, the panel or Telegram.
- Context fullness, files changed since the session started, and a heads-up when a session goes quiet.
- **Recently finished** sessions continue in Terminal with one click.
- **Background runs** under an explicit permission list (no push to main, no force push, no deleting, no reading secrets), a night queue and a morning summary.

### Projects and AI commands — not only for developers
Profiles built from modules, each with its own panel and menu bar. Start from a template:

| Template | A project is | Commands, for example |
|---|---|---|
| Developer | a git repository | Next step, Custom task, Finish (checks, commit, push, PR) |
| Video | a folder per video | hooks, a Shorts version, description with timestamps, titles |
| Writing | a folder per text | edit, proofread, another tone, SEO, split into posts |
| Research | a folder per topic | source summary, quotes with references, overview table |
| Social media | a campaign or platform | posts per platform, ad variants, a week's content plan |
| Custom | any folder | your own, with `{project}`, `{file}`, `{language}` … |

A command's result is always a **new file** — nothing is overwritten. **Compare** runs one command with two or three services side by side. Works with Claude Code, Codex CLI, Gemini CLI, Antigravity, Copilot CLI, Cursor CLI, and models by API (Anthropic, OpenAI, Google, xAI, DeepSeek, Mistral, Qwen, Kimi, GLM, MiniMax, Ollama, LM Studio, OpenRouter).

### And more
- **Calendar** of deadlines, publications and content plans straight from your project files — drag an entry and the file is updated.
- **Mac tools** as optional modules: Mac Resources, Keep Awake, Quick Commands, Quick Toggles, Clipboard History, Notes and Keyboard Layout: a word typed in the wrong layout fixes itself.
- **Beta builds** (Settings → General): new versions and features in testing before everyone else.
- **⌃⌥C search** and **⌃⌥B for the panel** from any app, **widgets**, a **Control Center** toggle, **Shortcuts** actions, **Telegram** alerts and a weekly summary.
- **13 languages**: English, Русский, Українська, Español, Português (Brasil), Français, Deutsch, Italiano, Polski, 日本語, 한국어, Bahasa Indonesia, العربية.

## Install

1. Download `AIHubBar-<version>.dmg` from [Releases](https://github.com/OlehDemishev/AIHubBar/releases/latest).
2. Open it and drag **AI Hub Bar** to Applications.
3. Open the app. It is signed with a Developer ID and notarized by Apple.

After that the app updates itself (Settings → General → Updates). The first start opens an assistant that checks what the Mac still needs and sets up your first profile. Everything else is in the [guide](docs/GUIDE.md).

**Requirements:** macOS 14 or later (Apple Silicon or Intel) and at least one AI service: an agent such as Claude Code, Codex, Gemini CLI, Copilot CLI or Cursor CLI, or a model by API key. Each service's limits need that service; live session rows need Claude Code, Codex or Copilot CLI.

## Privacy

- No account, no analytics. AI Hub Bar talks to the AI services you use, to GitHub for updates and, when the limits fail, to Anthropic's public status page.
- The one server of ours is the relay of the optional shared Telegram bot, on Cloudflare: it logs no message text and keeps only which chat belongs to which Mac. With a bot of your own, or without Telegram, nothing goes through it.
- Your files go only to the service you run a command with.
- API keys are kept in the macOS Keychain, never in logs or exported settings. Claude Code's sign-in is read from the Keychain on each refresh and never stored.
- The session hook only writes small status files on your Mac and never changes what the agent does; Settings → Agent sessions → Turn Off Tracking takes it out.

## Build from source

```bash
brew install xcodegen
scripts/build-and-install.sh          # --test runs the unit tests first
```

Needs Xcode with Swift 6. The project is generated from `project.yml`; SwiftUI, Swift concurrency, Sparkle for updates. Releases: [docs/RELEASE.md](docs/RELEASE.md).

## Documentation

- [Guide](docs/GUIDE.md) — install, first start, everyday use, privacy, troubleshooting, uninstall
- [Overview PDF](docs/AI-Hub-Bar-Overview-en.pdf) · [in Russian](docs/AI-Hub-Bar-Overview-ru.pdf)
- [Reference](docs/REFERENCE.md) — every feature in detail, background mode rules, session hooks, command line
- [Specification](docs/specs/SPEC.md) · [Decisions](DECISIONS.md) · [Status](docs/STATUS.md)

> AI Hub Bar was called **ClaudePult** until October 2026; the bundle id and the data folders keep the old name.

## Support the project

AI Hub Bar is free. If it saves you time, there are a few ways to help on the [support page](https://olehdemishev.github.io/AIHubBar/support.html).

## License

[MIT](LICENSE). AI Hub Bar is an independent project and is not affiliated with Anthropic, OpenAI, Google or GitHub.
