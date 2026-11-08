# SPEC — Content: writing texts with AI as modules and the «Тексты» profile

Status: **agreed with Oleh 2026-11-03** (answers in §9); no code yet, stage 1 next.

Comes from the October draft `docs/SPEC-content.md` (commit d4fbcd8, a separate «Тексты» mode for people who write
video scripts, posts and articles with Claude). That draft was folded into `SPEC-modes.md` the same day, and most of
it was built there (stage 4–7 of SPEC-modes, 2026-10-30); modes then became profiles made of modules
(`SPEC-profiles.md`). This spec re-reads the old draft against today's app: what already works and is reused as is,
what is still missing, and how the missing parts fit the module catalog. The quick prompt from any app (old §5) is
built in its own session and spec, so it is left out here.

## 1. Who and what for

A person who writes with AI — YouTube scripts, Shorts, posts, articles, a newsletter — and keeps the material in
ordinary folders on the Mac. No git, no terminal. They want to:
- see every piece and its stage, deadline, length and running time;
- ask the AI for routine work in one click and get the result as a file next to the source;
- send long work to the background, at night or after the limit resets, and learn the outcome from a notification;
- never lose a good version of a draft — not to their own edits and not to an AI run.

## 2. What already exists and is reused as is

| Old draft (Oct) | Today | Where |
|---|---|---|
| Optional `_daily-report` / git, pluggable project source | done: sources «папки», «одна папка», built-in git scanner, `report.py` | `FolderProjectStore`, `Profile.source` |
| A separate «Тексты» mode | profile template «Тексты» (and «Видео», «Ресёрч», «Соцсети») | `Resources/Templates/template-*.json`, 13 languages |
| Folder = project, card `проект.md` | done: stage, deadline, publication, format, main file, platform; the person's file, only the written line changes | `FolderProject`, `ProjectCardFile` |
| Stages, change from the panel | done | «Проекты» module, profile settings |
| Words, running time (words/min), reading time | done; `.md`, `.txt`, `.rtf`, `.docx`, `.fountain` counted | `FolderProject.textExtensions` |
| Task templates, result as a new file, never over an existing one | done: placeholders, `-2`, `-3` …, «Своя задача», «Сравнить» with 2–3 services | `CommandTemplate`, `CommandEngine` |
| Narrower background permissions without Bash | done: «только файлы» and «файлы + поиск в интернете», checked live | `BackgroundPermissions` |
| Queue after the limit reset, notifications, Telegram | done; plus «На ночь» with a morning summary and the run guard | `NightQueue`, `RunGuard`, `Notifier` |
| Publishing calendar | done: «Ближайшее», «Календарь» window (month/week, drag to move a date), `контент-план.md`, reminders | `UpcomingModule`, `CalendarStore` |
| — | island at the notch: drop a file → run a command on it | `NotchModule` |
| — | «Заметки», «История буфера» | optional modules |

So the «Тексты» profile today is: «Лимиты AI» + «Сессии агентов» + «Проекты» (source «папки», card `проект.md`,
stages идея → черновик → редактура → опубликовано, metrics words / reading time / publication, commands Редактура,
Корректура, Другой тон, Сократить / расширить, SEO, Нарезка в посты, permissions «только файлы», background) +
«Ближайшее». Nothing of this is rebuilt.

Not yet seen by Oleh (docs/CHECKLIST.md rows marked «Oleh: …»): folder project rows and stage chips in the panel,
commands in the panel and «Сравнить», «Ближайшее» and the «Календарь» window, a profile made from a template.

## 3. What is still missing

1. **Draft versions** (old §4.5) — not built. Results never overwrite files, but «Своя задача» and agent runs may
   edit the main file (`Edit(./**)` is allowed in «только файлы»), and the person's own edits have no history at all.
2. **Batch tasks** (old §5) — one command over several projects («descriptions for 10 videos») now or at night.
3. **A walkthrough of the existing «Тексты» flow** on a real folder: it was built and tested by code, not looked at.

Everything else from the old draft is either done (§2) or not built on purpose (§8).

## 4. Draft versions — new optional module «Версии»

Catalog row (SPEC-profiles §3):

| Module | In the panel | In the menu bar | Shared settings | In the profile | Permissions | Group |
|---|---|---|---|---|---|---|
| **Версии** | «Версии» in a folder project's card | — | how often, how long to keep, size limit | — (works for every profile with folder projects) | none new | Работа |

- **Storage:** `~/Library/Application Support/ClaudePult/versions/<project id>/` — never inside the project folder.
  Own simple store, **no git** (Oleh, §9): `objects/<sha256>` holds each file content once, `<timestamp>.json`
  lists path → hash, size, modified date and why the version was taken. Git is not on a writer's Mac by default
  (`/usr/bin/git` only offers to install the developer tools).
- **What is kept:** text files (`FolderProject.textExtensions`) and the card; images, audio and video are skipped
  (Oleh, §9). Files over the size limit (default 20 MB) are skipped and named in the log.
- **When:** before every AI run on the project (background, Terminal, API, «Сравнить», drop on the island) and, while
  the Mac is on, every 10 minutes if a file changed since the last version (Oleh, §9). A version is taken only if
  something differs from the previous one.
- **How long:** every version of the last 24 hours, then one per day for 30 days (Oleh, §9); the store of a deleted
  or renamed project is removed after 30 days. Shown in «Модули → Версии»: size on disk, «Очистить».
- **In the card:** «Версии» → list by time with reason («перед „Редактура“», «автоматически»), changed files.
  - «Сравнить с текущим» — a side-by-side text view of one file (`.docx` / `.rtf` read through `NSAttributedString`).
  - «Вернуть этот файл» / «Вернуть всю версию» — takes a version of the current state first, so nothing is lost;
    restored files go back in place, files added since stay.
  - After an AI run: the run's notification and «Журнал» get «Что изменилось» (the version before the run vs now).
- **Permissions:** none new — the app already reads the folders of folder projects. Nothing leaves the Mac.
- **Not for git projects:** they have git; the module shows nothing there.

## 5. Batch tasks — inside «Проекты»

No new module: it is a way to run the existing commands.
- In the «Проекты» block of a folder profile: «Выбрать» → checkboxes on rows → a command from the profile's list
  → «Сейчас» / «На ночь» / «После сброса лимита».
- One background run per project, one after another (not in parallel) so a batch does not burn the limit at once;
  the run guard pauses the batch near a limit, as it pauses single runs. One summary at the end, like «На ночь».
- Only where background runs exist: Claude Code and models by API. Other agents run in Terminal only, so they are not
  offered for a batch.
- A command that asks for text («Другой тон» → «Тон») asks once for the whole batch.
- Versions (§4) are taken before each project's run.

## 6. Settings

- «Модули → Версии»: install / remove; how often (10 min / 30 min / only before AI runs); keep (30 / 90 days);
  size limit; disk use and «Очистить».
- «Проекты» in a profile: nothing new; the batch uses the profile's commands, service, permissions.
- Template «Тексты» (and «Видео», «Ресёрч», «Соцсети»): «Версии» ticked in the assistant's «Модули» step.

## 7. Stages (each one PR: branch, checks, install, live check, STATUS)

1. **«Тексты» walkthrough.** Make a profile from the «Тексты» template on a sample folder (3–4 projects with
   `проект.md`, `.md` and `.docx`), go through the panel rows, stage change, commands in the background with
   «только файлы», «Сравнить», «Ближайшее», the «Календарь» window, the island drop; screenshots for Oleh; fix what is
   wrong. Close the «Oleh: …» rows that screenshots can answer.
2. **«Версии»: store and automatic versions.** Module in the catalog, store, versions before AI runs and on changes,
   retention, «Модули → Версии». Tests on the store (dedup, retention, skipped files).
3. **«Версии» in the card.** List, compare, restore, «Что изменилось» after a run; accessibility walk.
4. **Batch tasks.** Selection in «Проекты», sequential queue, summary.
5. Later, on Oleh's word: `.ics` export of the calendar (SPEC-modes §6), writing goals (words per day).

Rules for every stage: hover hint on each icon-only control, all strings in 13 languages, nothing sent anywhere but
the AI service chosen for the command.

### Stage 1 results so far (2026-11-08)

Run on a sample folder with the installed 0.7.5, without the panel: `--folder-projects`, `--calendar`, and the «Корректура» command with the app's exact «только файлы» arguments on `.md`, `.rtf` and `.docx`. Fixed from this:

- **`.docx` commands failed.** With no shell the agent can't open one: it wrote a «could not read» file and the run counted as a success. Background runs now get the text of `.docx` and `.rtf` in the prompt.
- **A result became the main file.** With no «Главный файл» in the card, the newest text file won, so after «Корректура» the next command ran on `корректура.md`. Results of main-file commands no longer count, unless there is nothing else.
- **Finished work stayed overdue.** A project at the profile's last stage kept red dates in «Проекты» and «Ближайшее» forever. It is no longer overdue or reminded of, and leaves the menu bar's nearest date.

Worked as specified: row metrics and word counts (checked against `wc`), card forms, `_` folders skipped, a project with no card, results never over an existing file, source files unchanged by runs, a denied tool stays denied.

Still to look at in the real app: panel rows and stage chips, the panel's command buttons, «Сравнить», «Ближайшее», the «Календарь» window, the island drop.

## 8. Not doing

- No separate «Тексты» mode or second app: it is a profile of modules.
- No Google Docs / Notion import or export — OAuth, other people's servers; files on the Mac stay the format.
- No own editor: texts are edited in the person's app (Pages, Word, iA Writer, Obsidian…).
- No versions inside the project folder and no git requirement for writers.
- No overwriting of the person's files by results; restoring a version always keeps the current state first.
- Quick prompt from any app — its own spec and session.
- Nothing changes for Oleh's developer profile.

## 9. Decisions (Oleh, 2026-11-03)

1. First stage — the walkthrough of the existing «Тексты» (§7.1), then «Версии».
2. Versions store — own simple store without git.
3. Versions keep only texts and the card; media are skipped.
4. Batch tasks — in this wave, as a stage after «Версии» (§7.4).
5. Versions — every 10 minutes if something changed (and before every AI run); all versions of the last 24 hours,
   then one per day for 30 days. Both can be changed in «Модули → Версии».
