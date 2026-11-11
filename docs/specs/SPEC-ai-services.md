# SPEC — AI services: Claude as one of them, the same view for every service

Status: stages 1–6 done (#159, #162–#170), 2026-11-02. 2026-11-03: Copilot CLI has hooks after all — with AI Hub Bar's hook (Settings → Copilot, `CopilotHooks`) its sessions are rows with «работает / ждёт / готово» and «ждёт» notifies. Stage 7 (2026-11-03): the same for Codex CLI through its own hooks (`CodexHooks`); Antigravity has no reliable «waiting» signal, so it keeps «работает» only. Left: Cursor CLI (not installed here).
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
| Codex | agent row, «Другие AI» row: 5 h + week % | ✅ `app-server` `account/rateLimits/read` (primary / secondary, resets, window length) | ⚙️ same store as Claude once readings are kept | ⚙️ `credits`, `planType` in the same answer (openai/codex `app-server-protocol/v2/account.rs`) | ⚙️ `state_5.sqlite` `threads` (`cwd`, `tokens_used`); session logs `~/.codex/sessions/**/rollout-*.jsonl` `token_count` | ⚙️ `token_count.info.last_token_usage` vs `model_context_window` | ✅ hooks (`~/.codex/hooks.json`, stage 7): работает / ждёт / готово | ❌ until `--sandbox`/approval flags are checked live |
| Gemini CLI | agent row, quota with consent or today's requests | ✅ Code Assist `retrieveUserQuota` (consent) / requests per day | ⚙️ | — free / plan daily limit only | ⚙️ `~/.gemini/tmp/<hash>/` chats (project hash, not path — needs mapping) | ❓ | ❓ | ❌ |
| Antigravity (`agy`) | agent row, quota once turned on | ✅ its own status line JSON (`AntigravityStatusLine`): `quota` buckets and `plan_tier`, while agy is open | — | ✅ plan | ❓ | ❓ | ❓ | ❌ |
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

7. **«Waiting» for Codex and Antigravity** (2026-11-03, research on this Mac: Codex 0.166.0-alpha.5.1, agy 1.4.12).
   - **Codex — reliable, built.** Codex now has lifecycle hooks (`codex features list`: `hooks  stable  true`; docs
     learn.chatgpt.com/docs/hooks, which developers.openai.com/codex/hooks redirects to). User hooks live in
     `~/.codex/hooks.json` (or inline `[hooks]` in `config.toml`), in Claude Code's shape: event → matcher groups →
     `{"type": "command", "command", "timeout"}`; all sources are loaded and merged. The stdin payload is Claude-style
     snake_case (`session_id` = the thread id, as in `state_5.sqlite` and the rollout name; `cwd`, `hook_event_name`,
     `transcript_path`, `prompt`, `tool_name`, `tool_input`; Codex adds `turn_id`, `model`, `permission_mode`). Events used:
     `SessionStart`, `UserPromptSubmit` (→ работает), **`PermissionRequest`** — «runs when Codex is about to ask for
     approval», not for commands that need none (→ ждёт, notifies), `PostToolUse` (→ работает again; `Bash`,
     `apply_patch` — the file is read from the patch), `Stop` and `Interrupt` (→ готово: the turn ended, Codex waits for
     the next message), `SessionEnd` (→ завершена; 3 s timeout at most). Empty stdout with exit 0 changes nothing.
     **Trust:** Codex runs a new or changed non-managed hook only after it is reviewed in `/hooks` (it stores
     `[hooks.state] trusted_hash` in `config.toml` itself); untrusted hooks are skipped silently (checked live: a `codex
     exec` with our hook passed by `-c hooks.…` ran nothing). AI Hub Bar never writes that trust; the command line stays
     the same across versions, so trusting is once. `CodexHooks` merges our entries into `~/.codex/hooks.json` like
     Claude's settings.json (backup `hooks.json.claudepult-backup-<time>` first, other hooks untouched, a file left
     empty is removed); Settings → Codex → «Установить hook», `AIHubBar --codex-hooks status|install|uninstall`. The
     same hook script writes `sessions/<id>.json` with `agent: codex`; a Codex hook session hides its thread row.
     Approving from AI Hub Bar is Claude-only: Codex's `PermissionRequest` answers have Claude's shape, but that needs a
     live check before it is offered. `notify` (ChatGPT's computer use owns it here, stage 5) is not needed any more.
     Not covered: Codex's `request_user_input` question tool has no hook event — such a question shows as «работает».
     Without hooks the rollout `rollout-*.jsonl` has `task_started` / `task_complete` but no approval events: a guess.
   - **Antigravity — no reliable signal, not built.** `agy` has `hooks.json` too (`~/.gemini/config/hooks.json`,
     `<workspace>/.agents/hooks.json`; named hooks, camelCase payload with `conversationId`, `workspacePaths`), but its
     events are `SessionStart`, `PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation`, `Stop` — none says an
     approval prompt is shown (`PreToolUse` runs before every tool, prompted or not; a hook can only *ask* for one). The
     run status in `conversation_summaries.db` has IDLE / RUNNING / BUSY / CANCELING only; the protobuf trajectory has
     `requested_interaction` / `STATE_WAITING_FOR_USER`, undocumented and binary. So Antigravity keeps «работает» from
     the run status. A `Stop` hook could add «готово», which IDLE already gives. Revisit if agy gets a permission event.
     A live probe (`agy -i` in a scratch folder) stopped at agy's first-run colour-scheme screen in the app's terminal and
     was closed without answering it.

8. **Antigravity's quota through its status line** (2026-11-11, agy 1.4.12 → 1.5.5, free plan «Antigravity Starter
   Quota»). What was tried, in order:
   - Files and print mode: no quota. `agy -p --output-format stream-json` gives tokens per turn only, and starts no
     status line.
   - The Code Assist address `agy` itself asks (`…cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`, with
     its sign-in from the Keychain record `gemini` / `antigravity`): it answers with `quotaInfo` per model, but only
     to a client whose User-Agent says Antigravity — 403 otherwise. Calling ourselves Antigravity is refused by Oleh
     (2026-11-11): it goes round Google's client check and could cost people their accounts. **Not built.**
   - **Built: the status line.** Antigravity runs a custom command for its status line (`/statusline <command>`,
     `statusLine` in `~/.gemini/antigravity-cli/settings.json`) and passes JSON on stdin: `quota` — buckets such as
     `gemini-weekly` and `3p-weekly` with `remaining_fraction`, `reset_time`, `reset_in_seconds` — plus `plan_tier`,
     `model`, `context_window`, `agent_state`, `email`. `AntigravityStatusLine` adds
     `{"type": "command", "command": "'<script>'", "stack_with_default": true}`; the script keeps the JSON in
     `antigravity-status.json` (0600) and prints nothing, so Antigravity's own line stays. A status line the person
     already has is not replaced; the settings are backed up before each change; turning it off takes the entry out
     and deletes what was kept.
   - The numbers are current while agy is open; ten minutes after the last one the panel shows them dimmed with their
     time. A bucket whose reset has passed is dropped. The source shows up only once it is turned on (Settings →
     «Сервисы AI» → Gemini → «Квота Antigravity»).
   - Open: `agent_state` in the same JSON may be the «waiting» signal stage 7 lacked (seen: `authenticating`,
     `initializing`); paid plans' bucket names are not seen yet.

Rules for every stage: hover hint on each icon-only control, accessibility walk at the end of each UI stage
(SPEC §3.1), all strings in 13 languages, nothing read without the consent the service already asks for.

9. **The main service** (2026-11-11, `MainService`): Claude was the main service everywhere — a person with only
   Codex or Antigravity saw «Установить Claude Code» on top of the limits and nothing in the menu bar. Now the main
   service is Claude while it has limits, else the first other service with a limit in percent, or the one chosen in
   Settings → «Лимиты AI» → «Главный сервис»; a chosen service without limits falls back to the automatic choice.
   Its card leads the panel's block with the big number, and its first two limits are the two numbers of the menu
   bar item, the folded block and the island. Not moved: the widget (`usage.json` is Claude's), the run guard,
   Telegram and the weekly summary, which are about Claude Code's own runs.
