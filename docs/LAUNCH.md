# Launch kit

Drafts and the order of posts for getting AI Hub Bar its first users. Nothing here has been posted. Every post goes out from Oleh's own account.

Text in `[brackets]` needs Oleh's own words: it is a personal detail nobody else can vouch for.

## Where we start from (2026-11-08)

0 stars, 50 DMG downloads in total, 6 unique repository visitors in two weeks.

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

Attach `site/demo.mp4`. The numbers below are from git on 2026-11-08.

### As a post

**Title:** I built a free, open-source Mac menu bar app with Claude Code to keep an eye on limits and sessions

I built this because I needed to always see my limits and what each session was working on, and to stay in control of both. It's free and open source (MIT), with no paid tier.

**What it does**

- 5-hour and weekly limits as rings, with a reset countdown and a forecast from your pace ("lasts until ~16:40")
- which project and session used the limit
- every Claude Code session on the Mac, with what it is doing right now ("running npm test")
- permission requests you can Allow or Deny from a notification, the panel or Telegram

It also picks up Codex, Copilot, Gemini CLI, Cursor and OpenRouter if you use them.

**How Claude helped**

Claude Code built all of it in about ten days: 376 commits, every one co-authored by Claude, across 320 pull requests. That's about 36,000 lines of SwiftUI and 527 tests.

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

Claude Code built it in about ten days: 376 commits and 320 pull requests, with a short spec for anything big, one branch per task, and a status file so each session could pick up from the last. The limits come from an undocumented Anthropic endpoint, so they can break if it changes.

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

Check each list's contribution rules first, as they can change. Candidates:

- `hesreallyhim/awesome-claude-code`
- `jaywcjlove/awesome-mac`
- `serhii-londar/open-source-mac-os-apps`

## Homebrew

The official cask needs notability, and repositories this new with no stars are rejected. So the order is: a cask in an own tap (`OlehDemishev/homebrew-tap`, `brew install --cask olehdemishev/tap/ai-hub-bar`), then the official cask once the project has the numbers.
