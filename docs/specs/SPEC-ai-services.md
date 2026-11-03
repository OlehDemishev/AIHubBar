# SPEC — AI services: Claude as one of them, the same view for every service

Status: stages 1–6 done (#159, #162–#170), 2026-11-02. 2026-11-03: Copilot CLI has hooks after all — with AI Hub Bar's hook (Settings → Copilot, `CopilotHooks`) its sessions are rows with «работает / ждёт / готово» and «ждёт» notifies. Left: «waiting» for Codex and Antigravity (no hooks; Antigravity's run status only has IDLE / RUNNING / BUSY / CANCELING), Cursor CLI (not installed here).
Asked by Oleh on 2026-10-31 and 2026-11-02: move Claude Code into «Сервисы AI», give every AI its own nested tab
with all its settings, and bring the other services up to Claude Code's level — one model per service for rings,
forecast, week strip, credits, per-project tokens and context.

## 1. What Claude Code has today

| Area | What | Where in the code |
|---|---|---|
| Limits | 5 h session and week rings, other windows (Opus, Sonnet…) when > 0 % | `UsageService`, `UsageStore`, `Usage.swift`, `LimitsView` |
| Forecast | «runs out at …» from the pace of the current window | `UsageStore`, `LimitsView` |
| History | week strip (daily peak), `usage.json` history | `UsagePoint`, `WeekStrip` |
| Credits | extra usage: on/off, used credits, monthly limit | `ExtraUsage` |
| Alerts | thresholds per window, once per window, Telegram copy | `UsageStore`, Settings → Модули → Лимиты |
| Run guard | pause background runs at a threshold, resume after reset | `LaunchController`, `runGuardPercent` |
| Weekly summary | Telegram: week spend by project, heavy sessions, limit hits | `WeeklySummary` |
| Tokens per project | from `~/.claude/projects/**/*.jsonl` | `TokenUsage` |
| Context | how full each session's context is | `ContextUsage` |
| Sessions | live list of sessions (Terminal, Claude app, background) via hooks; current action; approve / deny | `HookController`, `SessionStore`, `Approvals` |
| Launch | Terminal / background (`claude -p`), worktrees, night queue, saved prompts | `ClaudeLauncher`, `LaunchController`, `NightQueue` |
| Config | CLAUDE.md / AGENTS.md editor, MCP servers on/off | `ClaudeConfig`, `ClaudeConfigWindow` |
| Login | keep the Claude Code sign-in fresh | `LoginRenewal` |
| Menu bar, widget, notch | session / week %, forecast | `MenuBarConfig`, `WidgetStatus`, `NotchIsland` |

## 2. The other services today and what can be had

Facts on Oleh's Mac (2026-11-02): `claude` 2.1.314 in `/opt/homebrew/bin`; `codex` 0.166.0-alpha.5.1 only inside
`/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` (`AIHubBar --services`); `~/.codex` exists with
`auth.json`, `config.toml`, `state_5.sqlite` (table `threads`: `cwd`, `tokens_used`, `model`, `git_branch`,
`reasoning_effort`, `updated_at` — 0 rows here) and no `sessions/` folder yet; no `gemini`, `agy`, `copilot`,
`cursor-agent`, `~/.gemini`, `~/.cursor`. `gh` is installed. 2026-10-31: the bundled `codex app-server` answered
`account/rateLimits/read` with Oleh's ChatGPT sign-in (STATUS, #155).

| Service | Today in AI Hub Bar | Limits / windows | History, forecast | Credits / plan | Tokens per project | Context | Sessions | Background |
|---|---|---|---|---|---|---|---|---|
| Claude Code | everything in §1 | ✅ API | ✅ | ✅ extra usage | ✅ jsonl | ✅ | ✅ hooks | ✅ |
| Codex | agent row, «Другие AI» row: 5 h + week % | ✅ `app-server` `account/rateLimits/read` (primary / secondary, resets, window length) | ⚙️ same store as Claude once readings are kept | ⚙️ `credits`, `planType` in the same answer (openai/codex `app-server-protocol/v2/account.rs`) | ⚙️ `state_5.sqlite` `threads` (`cwd`, `tokens_used`); session logs `~/.codex/sessions/**/rollout-*.jsonl` `token_count` | ⚙️ `token_count.info.last_token_usage` vs `model_context_window` | ⚙️ threads with recent `updated_at`; no hooks yet (Codex `notify` in `config.toml` can call a script) | ❌ until `--sandbox`/approval flags are checked live |
| Gemini CLI | agent row, quota with consent or today's requests | ✅ Code Assist `retrieveUserQuota` (consent) / requests per day | ⚙️ | — free / plan daily limit only | ⚙️ `~/.gemini/tmp/<hash>/` chats (project hash, not path — needs mapping) | ❓ | ❓ | ❌ |
| Antigravity (`agy`) | agent row | ❓ not documented | — | — | ❓ | ❓ | ❓ | ❌ |
| GitHub Copilot CLI | agent row, `gh api /copilot_internal/user` premium requests | ✅ monthly quota | ⚙️ | ✅ entitlement / remaining | ❌ | ❌ | ❌ | ❌ |
| Cursor CLI | agent row, usage with consent | ✅ requests / spend | ⚙️ | ✅ | ❌ | ❌ | ❌ | ❌ |
| API providers (Anthropic, OpenAI, Google, xAI, DeepSeek, Mistral, Qwen, Kimi, GLM, MiniMax, compatible) | key, check, model, own spend | — (pay per token) | ✅ own requests (`CommandEngine`) | OpenAI / Anthropic admin cost APIs, OpenRouter credits | ✅ own requests per project | — | — | text only |

✅ works now · ⚙️ available, not built · ❓ unverified · ❌ not available. Every ⚙️ needs a live check on a Mac
that uses the service before it ships (Codex here has no sessions yet).

## 3. One model per service

```swift
struct ServiceUsage: Identifiable {          // replaces UsageSnapshot (Claude) and HubLimit (others) in the views
    var service: AIServiceID                  // claude-code, agent:codex, …, api:openai
    var windows: [LimitWindow]                // id, title, percent?, resetsAt?, runsOutAt?, detail?
    var credits: Credits?                     // used, limit, currency, enabled
    var plan: String?
    var history: [LimitReading]               // per window id, for the week strip and the forecast
    var fetchedAt: Date
    var error: String?
}
protocol UsageSource { func fetch() async -> ServiceUsage }      // ClaudeUsageSource, CodexUsageSource, …
protocol ProjectTokenSource { func tokens(since: Date) -> [ProjectTokens] }   // TokenUsage, CodexThreads, …
protocol ContextSource { func context(for session: String) -> ContextFill? }
```

Built in stage 2 (`Models/ServiceUsage.swift`): `ServiceUsage` (service, title, `rings` — the first two windows with a
percentage, `bars` — the rest and spend, `forecast`, `week`, `notes`, `error`, `isStale`) and `LimitWindow`, made by
`ServiceUsage.claude(snapshot…)` and `ServiceUsage.hub(limit, history:)`; `LimitHistory` keeps every other service's
readings for 8 days in `limit-history.json` (the forecast survives restarts, and the week by day is the daily growth
of the window that resets last). Claude keeps its own fetch, `usage.json` and journal-based week. The protocols above
and per-service sections in `usage.json` wait for stage 3, when Codex has more than limits to give.

- `UsageStore` keeps one `ServiceUsage` per enabled service, one `usage.json` with a section per service (Claude's
  current file is read as the `claude-code` section, so history carries over).
- Alerts, thresholds, run guard, forecast and the week strip work on `LimitWindow` + `history`, the same for all.
- The menu bar, widget and notch choose «which service» per element (default Claude, as now).

## 4. Settings and panel

Settings sidebar (like System Settings, #164) → group «Сервисы AI»: **Claude Code · Codex · Gemini · Copilot · Cursor ·
Другие**, a status dot each. Each page: the agent (path, version, sign-in, install), its limits (on/off, status, keys, consents), its
API access (Anthropic in Claude Code, OpenAI in Codex, Google in Gemini), then service-only options (Claude Code:
sessions and hooks, Telegram answers, saved prompts, CLAUDE.md and MCP, background runs). «Другие»: Antigravity,
xAI / DeepSeek / Mistral / Qwen / Kimi / GLM / MiniMax / compatible API, OpenRouter, the API spend and budget. Modules → Лимиты keeps the
module-wide options (alerts, run guard, weekly summary) and points to «Сервисы AI» for per-service ones.

Panel → Лимиты: one card per service, all drawn by the same view (rings, forecast, week strip, credits); Claude
first, the rest in the order of the tabs. Projects: tokens per project from every service that has them, with a
service mark. Sessions: Codex threads next to Claude sessions once a source exists.

## 5. Stages (one PR each)

1. **Settings structure** (done): «Claude Code» tab moves into «Сервисы AI» with nested tabs per service; all
   Claude Code options in its tab; per-service «Другие AI» rows (limits, keys, consents) and API providers move to
   their service's tab; old `settingsTab == "claude"` and every link that opened Claude Code open «Сервисы AI» →
   Claude Code.
2. **Common model** (done): `ServiceUsage` / `LimitWindow` / `LimitHistory`; Claude and the hub sources produce it;
   `LimitsView` draws every service with the same card (rings, forecast, week strip for all). Tests on stored answers.
3. **Codex in full** (done): plan and credits from `account/rateLimits/read` (`CodexThreads.accountNotes`), history
   and forecast (stage 2), tokens per project this week from `state_<N>.sqlite` `threads` (whole threads, not archived),
   the context of today's latest thread from its rollout's last `token_count` (tokens without reasoning over
   `model_context_window`, as Codex counts it). Live (2026-11-02, one `codex exec` in a scratch folder with Oleh's OK):
   plan «Free», project 16 132 tokens, context 6 % (16 132 of 258 400) — the real rollout matches the parser.
4. **Per-service alerts, menu bar and widget** (done): thresholds per service (`serviceThresholds`, own / common /
   none, on each service's page); «which service» was already there for the menu bar (the «Другие AI» element with a
   chosen or the fullest service, #130) and the widget (up to three other services); the notch gets an «Другие AI»
   ear; the weekly summary ends with a line per other service (limits, growth over the week, Codex projects).
5. **Codex sessions** (done): threads updated in the last 3 hours in «Сессии» under Claude's (project, title, when,
   context from 70 %); a click runs `codex resume <id>` in Terminal in the thread's folder. No state dot: Codex has no
   hooks here. The `notify` hook is **not** installed: Codex has one `notify` command and on Oleh's Mac it already
   belongs to ChatGPT's computer use (`SkyComputerUseClient turn-ended`) — replacing it would break that, chaining it
   means editing ChatGPT's config. Revisit if Codex gets real hooks.
6. **Gemini / Copilot / Cursor**: their ⚙️ history and forecast came with stage 2's `LimitHistory`. **Copilot CLI**
   (1.0.105, checked live 2026-11-02 on a real session): `~/.copilot/session-store.db` — `sessions` (`cwd`, `summary`,
   ISO `updated_at`) and `assistant_usage_events` (per request tokens and `total_nano_aiu` = AI credits × 10⁹), and
   `session-state/<id>/events.jsonl` `session.usage_record` (`inputTokens`, `maxPromptTokens` = the context window).
   The Copilot card shows AI credits this week, tokens per project and the context of today's latest session; its
   recent sessions join Codex's in «Сессии» (click → `copilot --resume=<id>`). Correction to §2: Copilot does have
   per-project and context data. **Gemini CLI 0.66** keeps chats per project in `~/.gemini/tmp/<short name>/` with
   `~/.gemini/projects.json` mapping folder → name (not a hash) — but its Google sign-in now fails: «This client is no
   longer supported for Gemini Code Assist for individuals … migrate to Antigravity» (2026-11-02), so it only works
   with an API key or Vertex. **Antigravity CLI** (agy 1.4.12, signed in and checked live): no limits or token counts
   readable on disk (`agy models` lists models only; usage sits in protobuf blobs); `conversation_summaries.db` gives
   each conversation's title, folder (`workspace_uris`), time and run status, so its recent conversations join «Сессии»
   with «работает» while running (click → `agy --conversation <id>`). Homebrew's `gemini-cli` is deprecated (disabled
   2026-12-18); its replacement `antigravity-cli` links `agy`. Cursor CLI: not installed here.

Rules for every stage: hover hint on each icon-only control, accessibility walk at the end of each UI stage
(SPEC §3.1), all strings in 13 languages, nothing read without the consent the service already asks for.
