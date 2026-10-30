# ClaudePult — guide

ClaudePult is a small Mac app that lives in the menu bar (✦). One click opens a panel with your projects, your Claude subscription limits, the Claude Code sessions running on this Mac and ready-made AI commands for each project. It does not replace Claude, Codex or any other AI tool. It keeps an eye on them and starts them for you.

It works in **profiles**. Each profile is a set of modules — limits, sessions, projects with their commands, the calendar — in the order you choose, so ClaudePult fits different kinds of work:

| Profile template | Projects are | Commands, for example |
|---|---|---|
| Developer (GitHub) | git repositories | Next step, Custom task, Finish — following each project's own CLAUDE.md / AGENTS.md |
| Video (YouTube, Shorts, Reels) | one folder per video | hooks, a Shorts version, description with timestamps, titles, fact check, translation |
| Writing (articles, blog, newsletter) | one folder per text | edit, proofread, another tone, shorten, SEO, split into posts |
| Research and study | one folder per topic | source summary, quotes with references, overview table, gaps, outline |
| Social media and marketing | a campaign or a platform | posts per platform, ad variants, A/B titles, replies, a week's content plan |
| Custom | any folder | your own |

You can enable several profiles and switch between them at the top of the panel. Each profile has its own panel (which blocks, in what order: **Settings… → Profiles → Panel**) and its own menu bar.

## What you need

- A Mac with macOS 14 or later.
- At least one AI service:
  - **Claude Code** with a Claude subscription. The limits block and the session list work only with Claude Code.
  - **Other agents:** OpenAI Codex CLI, Gemini CLI, Antigravity, Copilot CLI or Cursor CLI.
  - **A model by API**, with your own key: Anthropic, OpenAI, Google, xAI, DeepSeek, Mistral, or any OpenAI-compatible server (Ollama, LM Studio, OpenRouter).

## Install

For now ClaudePult is built from source. A signed download is coming. Install Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), then run this in the repository folder:

```bash
scripts/build-and-install.sh
```

The script installs `~/Applications/ClaudePult.app` and starts it.

## First start

ClaudePult starts empty: until you create a profile, the panel only offers **Assistant…** and **Import a file…**, and nothing runs in the background. It also opens the assistant by itself. The first screen, **Welcome to ClaudePult**, checks what this Mac still needs. Each row has a button when something is left to do:

| Row | Why it matters | Needed? |
|---|---|---|
| AI service | Commands need someone to run them. | Yes: Claude Code, another agent or an API key. |
| Claude Code sessions | The session list and the "Claude is waiting" alerts come from a small hook. **Install hooks** adds it to `~/.claude/settings.json` and saves a backup next to it. | With Claude Code |
| Notifications | Limit alerts, Claude waiting for you, finished commands and deadlines. | Recommended |
| Open at Login | Keeps ✦ in the menu bar after a restart. | Optional |

Next, the assistant asks a few more things:

1. **Bring your settings over?** If you have a `.claudepult` file from another Mac or a colleague, import it and you are done. Otherwise choose **No, set up from scratch**.
2. Pick a template or **From scratch**.
3. **What the panel shows**: tick the modules this profile has — AI limits, agent sessions, projects, upcoming dates. Without projects the assistant skips the project questions.
4. If the profile has projects, the folder where they live. ClaudePult looks inside and suggests a source: git repositories, or one folder per project.
5. Set the stages, what each project row shows, the calendar, the AI service, the commands, where Claude runs and what it may do, the menu bar, and the profile's name and icon. The right side shows a live preview.

You can skip any step: **Skip** keeps the template's choice. Everything can be changed later in **Settings… → Profiles**. To run the assistant again, go to **Settings… → Profiles → + → Assistant…**. The same readiness checks are at the top of the **Help** window.

## Everyday use

- **Panel blocks:**
  - **Limits:** the 5-hour session and the week, with a reset countdown and a forecast.
  - **Sessions:** every Claude Code session on this Mac. **Show** brings its Terminal tab forward.
  - **Projects:** expand a project to run its commands.
  - **Upcoming:** deadlines and publications for the next 7 days.
- **Commands:**
  - A command's result is always a **new file** in the project folder. Nothing is overwritten.
  - Models by API get the text of the project's main file.
  - Claude Code works in the background with the profile's permissions: **Project files only**, **Files + web search**, or full code access for developer projects.
  - Other agents open in Terminal with the task on the clipboard.
- **Compare:** runs one command with two or three services. The answers open side by side.
- **Project cards:** a project folder can hold a small text card, `project.md` (named in your language), with lines like `Stage:`, `Deadline:` and `Main file:`. ClaudePult reads it and updates it when you change the stage. You can edit it by hand.
- **Calendar:** a month or week view of deadlines, publications and content-plan rows. Drag an entry to another day and the date is rewritten in its file.
- **Menu bar** (**Settings… → Menu Bar**): choose what sits next to ✦, such as limits as a number, ring or bar, the reset countdown, sessions waiting for you, or the next deadline.

## Privacy and safety

- **Subscription token:** to show the limits, ClaudePult reads Claude Code's sign-in from the macOS Keychain on each refresh. It never stores or logs it.
- **API keys:** kept only in the macOS Keychain. They never go into logs or exported settings.
- **What gets sent:** your files go only to the AI service you run a command with. ClaudePult has no server of its own.
- **Session hook:** it only writes small status files on this Mac and never changes what Claude does. **Settings… → Claude Code → Remove hooks** takes it out again.
- **Background runs:** each runs under an explicit permission list. With **Project files only**, Claude can read and write inside the project folder, with no shell and no internet.

## Languages

The interface and everything ClaudePult writes are available in 13 languages: Russian, English, Spanish, Portuguese (Brazil), French, German, Japanese, Indonesian, Korean, Italian, Arabic (right-to-left), Polish and Ukrainian. This includes templates, prompts, project cards and content plans.

ClaudePult follows the system language. To pick another one, go to **Settings… → General → Interface language**, then press **Relaunch**.

## If something doesn't work

| Symptom | Fix |
|---|---|
| No limits | When macOS asks whether `security` may read "Claude Code-credentials", choose **Always Allow**. |
| No notifications | Allow them in System Settings → Notifications → ClaudePult. Then **Settings… → General → Check** sends a test one. |
| Sessions list is empty | Install the hooks: Help window → Readiness, or **Settings… → Claude Code**. |
| "Terminal" does nothing | macOS asks once whether ClaudePult may control Terminal. Allow it in System Settings → Privacy & Security → Automation. |

## Uninstall

1. Choose **Settings… → Claude Code → Remove hooks**.
2. Quit ClaudePult.
3. Delete `~/Applications/ClaudePult.app`, `~/Library/Application Support/ClaudePult` and `~/Library/Logs/ClaudePult`.
4. API keys are stored in Keychain Access under "ClaudePult API key". Delete those entries too if you want them gone.
