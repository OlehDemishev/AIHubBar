# Launch kit

Drafts and the order of posts for getting AI Hub Bar its first users. Posted so far: the r/ClaudeAI megathread comment (2026-11-25). Every post goes out from Oleh's own account.

Text in `[brackets]` needs Oleh's own words: it is a personal detail nobody else can vouch for.

## Where we start from (2026-11-08)

0 stars, 50 DMG downloads in total, 6 unique repository visitors in two weeks.

2026-11-25, before the first post (0.13.0 is out): 0 stars, 115 DMG downloads in total, 13 unique repository visitors in two weeks. Oleh chose r/ClaudeAI as the first place.

The Reddit account `u/OlehDemishev` on 2026-11-25: karma 1, two weeks old, one post — about AI Hub Bar in r/OpenSourceAI, 16 days before. So r/ClaudeAI starts with the megathread comment; the full post waits for karma over 100, which comes from real answers in other threads.

Developer ID and notarization are done, from 0.7.2 on, so nothing about signing holds back r/macapps, Show HN or Homebrew.

The demo is in the README and on the site (`site/demo.mp4`, `docs/images/demo.gif`): limits, a session waiting, Allow in the panel. The notification's own button is in the Mac's language, so a shot of Allow on the banner takes a Mac in English. Attach `site/demo.mp4` to posts.

## Order

| Step | What | Needs |
|---|---|---|
| 1 | Done: demo recording, the website in the About box | — |
| 2 | r/ClaudeAI post: the audience that has the problem. Fix what comes back | Karma over 100, or the megathread |
| 3 | Open-source and Claude Code lists (below) | First feedback handled |
| 4 | r/macapps post | A notarized release |
| 5 | Show HN | A notarized release |
| 6 | Product Hunt | Show HN done, demo ready |
| 7 | Homebrew | Own tap first, official cask once the project is notable |

One post every few days, so each round of feedback can be fixed before the next. On the day of a post, stay and answer comments. Never ask for votes or stars from friends: HN forbids it.

Watch after each step: DMG downloads, stars, repository traffic (`gh api repos/OlehDemishev/AIHubBar/traffic/views`).

## Questions to be ready for

- **"Is it signed?"** Yes, with a Developer ID, and notarized by Apple. The source is open and can be built with `scripts/build-and-install.sh`.
- **"It reads my Claude token?"** It reads Claude Code's sign-in from the Keychain on each refresh and never stores it. It talks to the AI services you use and to GitHub for updates. There are no analytics. The only server of ours is the relay of the optional shared Telegram bot, which logs no message text.
- **"Is the limits API official?"** No. It is an undocumented Anthropic usage endpoint, so it can change or stop working. Say this plainly, don't wait to be asked.
- **"Does the hook change what Claude does?"** No, it only writes small status files on the Mac, and Settings → Agent sessions → Turn Off Tracking takes it out.

## r/ClaudeAI

The subreddit's rules, read 2026-11-08 (Oleh pasted them):
- A project post is welcome if you built it with Claude Code or for Claude, and it says what was built, **how Claude helped, in detail**, and what it does.
- It must be free to try and say so. Minimal promotional language, no referral links, no job seeking.
- **Posts on the feed need karma over 100.** Below that, use the comment version in the project showcase megathread ([list of megathreads](https://www.reddit.com/r/ClaudeAI/comments/1s7fepn/rclaudeai_list_of_ongoing_megathreads/)).
- Choose the flair closest to the post: «Built with Claude» if it is offered. Upvote manipulation is an immediate permanent ban.

Attach `site/demo.mp4`. The numbers below are from git on 2026-11-25 (the Mac app only, without the Windows version).

### As a post

**Title:** I built a free, open-source Mac menu bar app with Claude Code to keep an eye on limits and sessions

I built this because I needed to always see my limits and what each session was working on, and to stay in control of both. It's free and open source (MIT), with no paid tier.

**What it does**

- 5-hour and weekly limits as rings, with a reset countdown and a forecast from your pace ("lasts until ~16:40")
- which project and session used the limit
- every Claude Code session on the Mac, with what it is doing right now ("running npm test")
- permission requests you can Allow or Deny from a notification, the panel or Telegram
- a notice when a session has gone quiet for 20 minutes or keeps running the same command
- background tasks that pause near the limit and go on after the reset

It also picks up Codex, Copilot, Gemini CLI, Cursor and OpenRouter if you use them.

**How Claude helped**

Claude Code built all of it in about four weeks: some 720 commits co-authored by Claude, across almost 600 pull requests. That's about 42,000 lines of Swift and over 740 tests.

The way of working mattered more than any prompt. For anything big, Claude wrote a short spec and I answered its questions. Then one task, one branch, one PR. Claude ran the tests for each change and kept a status file, so the next session could pick up where the last one stopped. A separate agent translated the interface into 13 languages. For the interface, Claude drove the running app through Accessibility and read screenshots of it.

**A few things I learned**

- Tests aren't the same as looking. One walk through the real app found five bugs that 500+ tests had missed, such as a whole line turning red with no word about why.
- A hook can watch sessions without changing what Claude does. It writes a small status file and prints nothing, because stdout from some hooks goes into Claude's context.
- In the Claude app, the prompt a hook receives can start with a `<system-reminder>` block. If you clip the prompt for a title, remove that first, or your own words are gone.
- A background run with no shell can't open a `.docx`. It reports the failure in its result file and the run still counts as a success, so check what you got, not just the exit status.

**Good to know**

The limits come from an undocumented Anthropic endpoint, so they can break if it changes. The app reads Claude Code's sign-in from the Keychain on each refresh and never stores it. There's no account and no analytics, and it's signed and notarized. The sessions in the video are samples.

GitHub: https://github.com/OlehDemishev/AIHubBar

What would you want from it that isn't there?

### As a comment in the megathread

**AI Hub Bar**: a free, open-source (MIT) Mac menu bar app for Claude limits and Claude Code sessions.

I needed to always see my limits and what each session was working on, and to stay in control of both. It shows your 5-hour and weekly limits with a forecast from your pace and every session with what it is doing right now, and you can Allow or Deny permission requests from a notification, the panel or Telegram.

Claude Code built it in about four weeks: some 720 commits and almost 600 pull requests, with a short spec for anything big, one branch per task, and a status file so each session could pick up from the last. The limits come from an undocumented Anthropic endpoint, so they can break if it changes.

https://github.com/OlehDemishev/AIHubBar

## r/macapps

**Title:** AI Hub Bar: a native menu bar app for AI limits and agent sessions, plus small Mac tools (free, open source)

[One sentence: why you made it.]

It started as a way to watch Claude limits and Claude Code sessions, and grew into a modular menu bar panel. You turn on only what you need:

- AI limits and agent sessions, with Allow / Deny from a notification
- a live island around the notch
- keyboard layout fix: a word typed in the wrong layout fixes itself
- clipboard history, notes, keep awake, quick commands and toggles, Mac resources
- a Telegram bot for alerts on your phone

SwiftUI, macOS 14+, 13 languages, MIT, no account, no analytics.

https://github.com/OlehDemishev/AIHubBar

## Show HN

**Title:** Show HN: AI Hub Bar – Claude limits and agent sessions in the Mac menu bar

**URL:** https://github.com/OlehDemishev/AIHubBar

**First comment:**

Hi HN, I'm Oleh. [Why you built it, in your own words.]

AI Hub Bar is a native SwiftUI menu bar app. It shows Claude's 5-hour and weekly limits with a forecast from your pace, lists every Claude Code session on the Mac with what it is doing right now, and lets you answer permission requests from a notification. Codex, Copilot, Gemini CLI, Cursor and OpenRouter show up on their own if you use them.

How it works: a Claude Code hook writes small status files on the Mac, and the app reads those and the session journals. The hook doesn't change what Claude does. Limits come from an undocumented Anthropic usage endpoint with Claude Code's sign-in, read from the Keychain on each refresh and never stored, so that part can break if the endpoint changes.

There is no account and no analytics, and nothing goes through a server of ours unless you turn on the shared Telegram bot. MIT licensed.

I'd like to hear what's missing and what you'd want to check in the code before trusting it.

## Product Hunt

**Name:** AI Hub Bar

**Tagline (60 characters at most):** Your AI limits and agent sessions in the Mac menu bar

**Description:** A free, open-source Mac menu bar app. See Claude limits with a forecast, every agent session and what it is doing, answer permission requests from a notification, and add the small Mac tools you use every day.

**First comment:** the Show HN comment, shorter and warmer. [Your own words.]

**Needs:** the icon, 3–5 screenshots, the demo recording.

## Short post (X, LinkedIn, Threads)

I built AI Hub Bar: a free, open-source Mac menu bar app that shows your Claude limits, a forecast from your pace, and every Claude Code session with what it's doing right now. Allow or deny requests from a notification.

No account, no analytics.

https://olehdemishev.github.io/AIHubBar/

[Attach the demo recording.]

## Lists

Each list's rules were read on 2026-11-25 from its repository; they change, so look again on the day. Nothing is submitted yet. One list at a time, a few days apart.

| Order | List | How | Can go now? |
|---|---|---|---|
| 1 | `jaywcjlove/awesome-mac` (119k stars) | A pull request to four README files | Yes: no stars are asked for |
| 2 | `hesreallyhim/awesome-claude-code` (59k stars) | A web form, filled by a person | Yes by the rule (14 days of active development), but the maintainer says plainly that a project with no users is unlikely to be taken |
| 3 | `serhii-londar/open-source-mac-os-apps` (52k stars) | A pull request to `applications.json` | No: its checklist asks for at least 5 stars |

### 1. awesome-mac

Rules (`docs/CONTRIBUTING.md`): one pull request per app; the entry goes in alphabetical order into the fitting section; one sentence; the same entry in `README.md`, `README-zh.md`, `README-ja.md` and `README-ko.md`; a useful title for the pull request. AI-assisted pull requests are welcome if they follow the same rules.

Section «AI Tools», between «Agenttrace» and «Airbag». A similar app, «Agent Monitor», is already listed under «Developer Utilities», so the entry says what is different: several services' limits in one place and answering permission requests.

```markdown
* [AI Hub Bar](https://olehdemishev.github.io/AIHubBar/) - Open-source menu bar app that shows the usage limits of Claude, Codex, Copilot, Gemini CLI and Cursor, lists every running agent session, and answers their permission requests from a notification. [![Open-Source Software][OSS Icon]](https://github.com/OlehDemishev/AIHubBar) ![Freeware][Freeware Icon]
```

Pull request title: `Add AI Hub Bar to AI Tools`. The three translated files get the same line in their own language, written to match the neighbouring entries of that file.

Sent 2026-11-25: https://github.com/jaywcjlove/awesome-mac/pull/5063 (from the fork `OlehDemishev/awesome-mac`, branch `add-ai-hub-bar`; five README files, Portuguese too).

### 2. awesome-claude-code

Rules (`CONTRIBUTING.md`): only through the web form, **by a person** — a submission made with `gh` or by an agent risks a temporary block; no pull requests; one resource at a time; the description is a description, not a pitch, one line, no emojis, no «you». The project must be 14 days old with active development (ours: first commit 2026-10-29) or have 100 stars.

Form: https://github.com/hesreallyhim/awesome-claude-code/issues/new?template=recommend-resource.yml

| Field | Value |
|---|---|
| Title | `[Resource]: AI Hub Bar` |
| Display Name | `AI Hub Bar` |
| Category | `Observability & Monitoring > Session Monitors` |
| Link | `https://github.com/OlehDemishev/AIHubBar` |
| Author Name | `Oleh Demishev` |
| Author Link | `https://github.com/OlehDemishev` |

Description:

```text
Native macOS menu bar app that lists every Claude Code session on the Mac with its current tool call, answers permission requests from a notification, the panel or Telegram, and shows the 5-hour and weekly limits with a forecast from the current pace. Sessions are tracked by a hook that writes small status files and prints nothing. MIT, no account.
```

Checklist: tick the first five boxes only after really doing what they say (open the list, look through «Session Monitors» and «Usage & Cost» for a resource that does the same). **Leave the last box unticked** — it is a trap for people who tick everything. One box says «This resource is specific to Claude Code»: the sessions, the hook and the permission requests are; the limits of other services are an extra, and it is honest to say so in a comment if asked.

### 3. open-source-mac-os-apps

Rules (`CONTRIBUTING.md`, `PULL_REQUEST_TEMPLATE.md`): one pull request per app; edit `applications.json`, not the README; the description ends with a full stop; the checklist has «The repository has at least 5 stars». Wait for five stars.

```json
{
    "short_description": "Menu bar app for AI limits and agent sessions: Claude, Codex, Copilot, Gemini CLI and Cursor in one panel, with permission requests answered from a notification.",
    "categories": [
        "ai",
        "menubar",
        "development"
    ],
    "repo_url": "https://github.com/OlehDemishev/AIHubBar",
    "title": "AI Hub Bar",
    "icon_url": "https://raw.githubusercontent.com/OlehDemishev/AIHubBar/main/AIHubBar/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png",
    "screenshots": [
        "https://raw.githubusercontent.com/OlehDemishev/AIHubBar/main/docs/images/hero.png"
    ],
    "official_site": "https://olehdemishev.github.io/AIHubBar/",
    "languages": [
        "swift"
    ]
}
```

Pull request body, by their template: Project URL, Category `ai, menubar, development`, the description above, and the checklist with every box ticked once the stars are there.

## Homebrew

The official cask needs notability, and repositories this new with no stars are rejected. So the order is: a cask in an own tap (`OlehDemishev/homebrew-tap`, `brew install --cask olehdemishev/tap/ai-hub-bar`), then the official cask once the project has the numbers.
