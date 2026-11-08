# Social accounts

Oleh's accounts under his own name, only about our products. Started 2026-11-08 with AI Hub Bar. Oleh signs up, signs in and presses «post»; the agent prepares the text. Nothing here has been posted.

Rules: real history only, nothing bought or boosted, no replies posted automatically, and it's always said that the products are made with Claude Code.

## Sign-up order

Use the same name everywhere if it's free. Check each site's rules when signing up.

| # | Network | Name | For |
|---|---|---|---|
| 1 | X | `olehdemishev` | news and short videos |
| 2 | Bluesky | `olehdemishev` | the same news |
| 3 | LinkedIn | Oleh Demishev | longer stories |
| 4 | YouTube | Oleh Demishev | demos |
| 5 | Reddit | `olehdemishev` (can't be changed later) | r/ClaudeAI, r/macapps, after karma from real answers |
| 6 | Hacker News | `olehdemishev` | Show HN |

A product can get an account of its own later. Followers don't move across, so the personal account then links to it.

## Profile

**Name:** Oleh Demishev

**Short bio (X, Bluesky, Reddit, Hacker News):**

Building AI Hub Bar, a free Mac menu bar app for AI limits and agent sessions. Made with Claude Code.

**LinkedIn headline:**

Building AI Hub Bar, a free, open-source Mac app for AI limits and agent sessions

**Long bio (LinkedIn, YouTube):**

I build software with Claude Code and share how it's made.

Right now that's AI Hub Bar, a native Mac menu bar app. It shows the limits of your AI services and every agent session on your Mac, with what each one is doing right now. It's free and open source, with no account and no analytics.

**Website:** https://olehdemishev.github.io/AIHubBar/

**GitHub:** https://github.com/OlehDemishev

**Video:** `site/demo.mp4`. YouTube's Shorts need a vertical video, so this one goes up as a normal video.

## Avatar

Give a generator a clear photo of the face, and this:

> Turn this photo into a clean, flat vector-style portrait of the same person. Keep the face recognizable. Friendly, relaxed expression, head and shoulders, centered in a square. Warm orange background (#D9774B). Simple shapes, no text, no logos. It must still read at 48 × 48 pixels.

Use the same picture everywhere. If it doesn't look like you, use the photo instead.

## First posts

Attach `site/demo.mp4` to each.

### X

I built AI Hub Bar: a free, open-source Mac menu bar app that shows your Claude limits, a forecast from your pace, and every Claude Code session with what it's doing right now.

Made with Claude Code in about ten days.

https://olehdemishev.github.io/AIHubBar/

### Bluesky

I built AI Hub Bar: a free, open-source Mac menu bar app that shows your Claude limits and every Claude Code session with what it's doing right now.

Made with Claude Code in about ten days.

https://olehdemishev.github.io/AIHubBar/

### LinkedIn

I needed to always see my AI limits and what each session was working on, so I built an app for it.

AI Hub Bar is a free, open-source Mac menu bar app. It shows Claude's 5-hour and weekly limits with a forecast from your pace, lists every Claude Code session with what it's doing right now, and lets you answer permission requests from the panel, a notification or Telegram.

Claude Code built it in about ten days: 376 commits, 320 pull requests, about 36,000 lines of SwiftUI and 527 tests.

What I learned: the way of working mattered more than any prompt. For anything big, Claude wrote a short spec and I answered its questions. Then one task, one branch, one pull request, with a status file so the next session could pick up where the last one stopped.

Tests still aren't the same as looking. One walk through the real app found five bugs that 500+ tests had missed.

https://github.com/OlehDemishev/AIHubBar

### YouTube

**Title:** AI Hub Bar: Claude limits and agent sessions in the Mac menu bar

**Description:**

A free, open-source Mac menu bar app, made with Claude Code. The video shows the limits, two sample sessions, and a permission request answered from the panel.

Website: https://olehdemishev.github.io/AIHubBar/
GitHub: https://github.com/OlehDemishev/AIHubBar

## GitHub profile

A public repository named `OlehDemishev` shows its README on the profile. Text for it:

```markdown
### Oleh Demishev

I build software with Claude Code and share how it's made.

**[AI Hub Bar](https://github.com/OlehDemishev/AIHubBar)**: a free, open-source Mac menu bar app for AI limits and agent sessions. [Website](https://olehdemishev.github.io/AIHubBar/)
```

## After each release

The agent drafts one post per network from the release notes; Oleh checks and posts it. One thing per post, in plain words, with a picture or a video when there's something to see. A small fix doesn't need a post.

Template:

AI Hub Bar {version}: {the one change people will notice, and what it does for them}.

{One more change, if it matters.}

Free and open source: https://github.com/OlehDemishev/AIHubBar/releases/latest

Ready for 0.7.8:

AI Hub Bar 0.7.8: macOS now asks for Accessibility once, not at every launch. If a permission gets stuck with its switch on, one button clears it and asks again.

Free and open source: https://github.com/OlehDemishev/AIHubBar/releases/latest
