# Security audit

Passes over `~/Projects/SECURITY-CHECKLIST.md`. Each pass says what it covered; the newest is on top.

## 2026-11-27 — Skills Catalog: remote sources and finding them (branch `chore/skills-sources-security-audit`)

**Scope.** What 0.14.0 added after the first pass: GitHub repositories as sources (`AIHubBar/Skills/SkillRemote.swift`, `AIHubBar/Services/SkillGitHub.swift`, PR #648), «Найти источники…» (`AIHubBar/Skills/SkillSourceFinder.swift`, PR #651), their parts of `SkillStore`, `SkillManage` and `SkillSourceViews.swift`, and scanner rules 4 (#656). The catalog now goes to the network by itself, so item 8 of the pass below («the only network call is api.anthropic.com») no longer holds; this pass replaces it.

**The attacker, for this pass.** The owner of a repository the person added, the author of an awesome list or of a plugin in the marketplace, and anyone who can put a repository into GitHub's search results. Everything they control — the tree, file names and contents, `marketplace.json`, a list's Markdown, a repository's description — is untrusted. Nothing from a source is run; it only reaches an agent's folder through the same install as any skill: the plan, the check, the ticked box, the hash compared after writing.

| # | Item | Status | Where / what |
|---|---|---|---|
| 1 | Secrets | OK | No token: public repositories only, without signing in. Nothing secret is sent to GitHub. |
| 4 | Validation of input | **Fixed** | A repository name passes only GitHub's own characters (`GitHubRepo.parse`); the commit must be 40 hex digits; private repositories are refused. Every path from the tree goes through `SkillGitHub.inside` (no `..`, `.`, empty or absolute parts) before anything is fetched; links (`120000`) and submodules are never downloaded; each skill keeps to the scanner's limits, at most 300 skills a repository. **Fixed:** names that differ only in case (`Tool`/`tool`, `run.sh`/`RUN.sh`) shared one folder on the Mac's case-insensitive disk — now only the first is taken, the second is listed as left out; one repository could fill the disk (300 × 64 MB) — now 256 MB a commit at most (`maxRemoteBytes`); the root skill's folder `files/_root` and its marker could be taken by a repository folder named `_root` — now it lives beside `files` and its marker is `-`, which no encoded folder name can be. |
| 6 | What a source's text can do in the interface | OK | Names, descriptions, repository descriptions, list texts are shown with `Text(verbatim:)`. A list's words lose links, HTML, control and invisible characters and are cut to 200 characters (`SkillSourceFinder.clean`). |
| 8 | HTTPS | **Fixed** | Only `https://api.github.com` and `https://raw.githubusercontent.com`, fixed in code. **Fixed:** a redirect was followed to any host; now only to GitHub's own HTTPS hosts (`SkillGitHub.StayOnGitHub`). |
| 10 | Rate limits | OK | Sources are checked by themselves at most twice a day (three API requests each); lists are read once in 12 hours from raw files, which the API limit doesn't count; the search runs only on a click. A refusal from GitHub is shown in words and leaves the old commit in place. |
| 13 | Files (here: downloads and the install from them) | OK | Files are written only under `skills/remote/<owner>/<repo>/<sha>/`, 2 MB a file, mode 644 or 755 as in the tree; a folder is used again only with its «downloaded whole» marker. An install copies the checked bytes and compares their hash; a cache folder changed after the check is refused. An update from a newer commit is checked and shown line by line before it is installed. |
| 18 | SSRF and open redirect | OK | The app never fetches an address a source or a list names: a candidate is only `owner/repo`, and adding it reads it through the fixed API. Marketplace `url` sources count only for `https://github.com/…`; `command`, `npm` and the rest are ignored. «Открыть на GitHub» opens only `https://github.com/<owner>/<repo>` built from a validated name, on a click. |
| 19 | AI | OK | A remote skill goes to the AI review exactly as a local one (item 19 below). |
| 21 | Logs | OK | Only `owner/repo`, the short commit, counts and refusal codes. |
| 22 | Dependencies | н/п | None added (URLSession, Foundation). |
| 38 | Privacy | OK | GitHub sees the Mac's address and which public repositories are read; the Settings footer says the skills come from GitHub. Nothing about the person or their skills is sent. |
| 39 | Self-attack | OK | Below. |

Trust and «official»: a repository is official only by its GitHub owner (`anthropics`, `openai`, `google-gemini`, `cursor`), which GitHub keeps unique, so this mark can't be claimed the way an `author` field can. It still lowers no verdict.

**Self-attack** (each a test in `AIHubBarTests/SkillRemoteTests.swift` / `SkillSourceFinderTests.swift`):

| Attempt (as a source's owner or a list's author) | Result | Test |
|---|---|---|
| Put `../../outside`, `/etc/evil`, `a//b` or `../../../../escape.sh` into the tree to write outside the cache | Refused before any request; nothing written | `aTreeCannotLeadADownloadOutOfTheCache` |
| Ship `Tool` and `tool`, `run.sh` and `RUN.sh` to swap files in one folder | The second is left out and listed | `namesThatDifferOnlyInCaseDontShareAFolder` |
| Name a folder `_root` or `root` to take the root skill's place | Three skills, three folders, each with its own text | `theRootSkillAndAFolderNamedLikeItStayApart` |
| Fill the disk with ten 60 MB skills | 256 MB at most; the rest not taken | `oneRepositoryCantFillTheDisk` |
| Redirect a request to another host, to plain HTTP or to `github.com.evil.example` | Not followed | `aRedirectAwayFromGitHubIsNotFollowed` |
| Put HTML, `javascript:` links, invisible and bidi characters into a list's description | Plain short text | `whatAListSaysIsShownAsPlainShortText` |
| Name a plugin source on another host or a `command` source | Ignored | `aMarketplaceGivesThePluginsRepositories` |
| Smuggle another parameter into the search (`&q=evil`) | One encoded `q` | `listsAreReadFromRawFilesAndSearchAsksGitHubOnce` |
| Mark a real webhook as a «placeholder» (`…#...`) | Still an exfiltration endpoint | `SkillScannerTests.whatOfficialSkillsSayIsNotAnAttack` |

**Left / needs Oleh:** nothing blocking. These fixes are in `main` after merge, not in 0.14.0; a skill at a repository's root downloaded by 0.14.0 is fetched again once (its folder and marker moved).

## 2026-11-26 — the Skills Catalog on the Mac (branch `chore/skills-security-audit`)

**Scope.** The Skills Catalog of the Mac app, steps 1–8 (PRs #625–#638): `AIHubBar/Skills/*`, `AIHubBar/Services/SkillStore.swift`, `AIHubBar/Views/Panel/Skill*Views.swift`, `AIHubBar/Modules/SkillsModule.swift`, plus the repository-wide items B24 and B25. The rest of AI Hub Bar was not re-audited in this pass.

**What the catalog is, for this checklist.** A local, single-person feature of a menu bar app. There is no server, no accounts, no other users' data. The attacker is **the author of a skill**: everything a skill contains — its name, description, author, homepage, file names, file contents, links — is untrusted input, read from the agents' folders, from a folder the person adds, or sent on to a model. The catalog writes only into the person's own skills folders, and only on a click.

### Checklist

| # | Item | Status | Where / what |
|---|---|---|---|
| 1 | Secrets only on the server | OK | No keys in the app. The Anthropic key for the AI review is read from the login Keychain (`APIKeyStore.read`) only when a review goes through the API, sent only in the `x-api-key` header (`SkillReviewer.swift:73`), never logged or stored by the catalog. |
| 2 | Passwords as hashes | н/п | No accounts or passwords. |
| 3 | Sessions | н/п | No sessions. |
| 4 | Validation of input | OK | Skill folders are read with limits (`SkillLimits`: 3000 files, 2 MB a file, 64 MB in all) and links are never followed into (`SkillFolder.read`). A file preview is given only for a path the skill's own folder lists (`SkillCatalog.preview`). A copy refuses any file path that is not a plain relative path (`SkillManage.isInside`). Notes are cut to 4000 characters, saved-filter names to 80, set names to 80, block reasons to 500; saved filters are read leniently (unknown values dropped). **Fixed:** the export file for «Сверить» is now refused above 20 MB before it is read (`SkillCatalog.exportLimit`, `SkillOrderViews.swift`). |
| 5 | Parameterized queries | OK | Every value goes through bound parameters (`SQLiteDB.run/query`, `bind(...)` in `SkillCatalog.conditions`). The only interpolated values are integers clamped to 0–100, the catalog's own ISO dates and lists of its own row ids. The search text goes through `ftsQuery`, which quotes every word so FTS5 operators can't be used. Tested with SQL in every typed field (`SkillSecurityTests.typedTextIsDataForTheDatabase`). |
| 6 | XSS (here: what a skill's text can do in the interface) | OK | Everything a skill says about itself is shown as plain text: `Text(verbatim:)` for names, descriptions, files, findings, the AI answer. **Fixed:** four places put skill-provided values (left-out file names, the update's source path, the author on «Доверять», a set name) into a localized SwiftUI string; they now go through `Text(verbatim: String(localized:))`, so no value from a skill can be read as Markdown or a link. No web view, no HTML. |
| 7 | CSRF | н/п | No web endpoints. |
| 8 | HTTPS and headers | н/п | No server. The catalog's only network call is HTTPS to `api.anthropic.com` (AI review via API). |
| 9 | CORS | н/п | No server. |
| 10 | Rate limits | OK | The only costly action is the AI review: only on a click, one request per skill at a time (`SkillStore.reviewing`), answers remembered by content hash so the same content is never paid for twice (`llm_reviews`), API tokens go to the spend log with the monthly budget warning (`CommandEngine.record`). |
| 11 | Roles and closed sections | OK (adapted) | Single person. The analog: the catalog moves only folders it found itself directly inside one of the person's own skills folders (`SkillManage.installed`); projects and plugins are never written. Tested: `SkillManageTests.onlyThePersonsOwnListedSkillsAreEverMoved`. |
| 12 | IDOR / tenants | н/п | One person, one catalog file. |
| 13 | File uploads (here: skill folders and copies) | OK | A copy is written from the very bytes that were checked, compared with their hash after writing; a folder changed since the plan is checked again and the old confirmation is refused. Links and dependency folders are never copied; nothing from a skill is run; executable bits are kept as they were. A skill's name can't move the copy out of the skills folder (`folderName` accepts only standard names, else the folder's own plain name). Tested: `SkillManageTests`, `SkillSecurityTests.aSkillsNameCannotLeadTheCopyOutOfTheSkillsFolder`. |
| 14 | Money on the server | н/п | No payments. |
| 15 | Production mode | н/п for the catalog | The catalog has no debug paths. (The app's `--app-command debug-panel`, used for the live checks, is existing app behaviour, outside this scope.) |
| 16 | Mass assignment and leaked fields | OK | The export carries no secrets and writes home paths as `~` (`SkillCatalog.export`); complaint links and copies cut the home folder and account name (`Feedback.redacted`). Tested: `SkillReportsTests.theGitHubPagesCarryTheFactsAndNoPaths`, `SkillHousekeepingTests`. |
| 17 | Webhooks and OAuth | н/п | None. |
| 18 | SSRF and open redirect | OK | The catalog fetches nothing a skill names. The only link built from a skill is «Автору на GitHub», only for an `https://github.com/<owner>/<repo>` it validates (`SkillCatalog.githubRepository`, tested against look-alike hosts and `javascript:`), opened only on the person's click; the person submits the issue themselves. |
| 19 | AI and LLM | OK, one note | The model gets only the skill's files, as data between markers with a fresh random word (a file can't close its block), numbered, invisible characters spelled out; it is told orders inside are findings. Claude Code runs with no tools, no settings sources, no MCP, no session kept, in an empty folder; the skill goes on stdin, never on a command line. Only the fixed JSON is an answer; anything else is «review»; the answer can only raise the verdict. Tested: `SkillReviewTests`, `SkillSecurityTests.aSkillCannotPretendToBeSafeToTheModelOrTheCatalog`; seen live with a skill built to fool the reviewer (it answered «dangerous»). **Note:** `--setting-sources ""` keeps settings and hooks out; whether Claude Code still reads the person's own `~/.claude/CLAUDE.md` in `-p` mode was not verified — it would only add the person's own words to the review, never a skill's. |
| 20 | Encryption of sensitive fields | OK | The catalog file holds no secrets (skill metadata, scan results, the person's notes and marks). The API key stays in the Keychain. |
| 21 | Logs | OK | `AppLog` lines of the catalog carry counts, verdicts, model names and refusal codes; no key, no skill content, no notes (`SkillStore.swift`). Errors may carry local file paths, which stay in the local log. |
| 22 | Dependency audit | н/п | The catalog adds no dependencies (Swift with the system SQLite and CryptoKit). |
| 23 | Image scanning | н/п | No Docker. |
| 24 | Secrets in git history | OK | `gitleaks git --log-opts="--all" --redact`: 749 commits, one finding — Sparkle's public EdDSA key `SUPublicEDKey` in `project.yml`, public by design (it verifies update signatures). Recorded in `.gitleaksignore`; nothing to rotate. |
| 25 | `.gitignore` | **Fixed** | It had no rules for secrets. Added `.env`, `.env.*` (except `.env.example`), `*.pem`, `*.p12`, `*.p8`, `*.key`, `*.mobileprovision`; no tracked file matches them. |
| 26–29 | Mobile apps | н/п | The catalog is in the Mac app. |
| 30–36 | Infrastructure | н/п | No server or infrastructure for the catalog. |
| 37 | Incident plan | н/п for the catalog | Nothing of the catalog leaves the Mac by itself; a bad skill is handled by the block list, «Убрать» and the journal. |
| 38 | GDPR | OK | Everything stays on the Mac: the catalog file `~/Library/Application Support/ClaudePult/skills/catalog.db` and the backups beside it; deleting the folder deletes all of it. Complaints are kept locally and reach GitHub only through a page the person submits. The AI review sends a skill's files to Anthropic only on a click, with the box saying where they go before it. |
| 39 | Self-attack | OK | Below. |
| 40 | External pentest | н/п | No server, no other people's personal or payment data. |

**Partial by design.** Trusted authors (step 6) match what a skill says about itself — its `author` field or the GitHub owner it names — so anyone can claim a trusted name. Trust therefore only quiets notifications and allows installing under «только от доверенных»; it never lowers a verdict or skips a confirmation, and the Settings page and the button say the author is not verified.

### Self-attack

Each attempt is a test, so it repeats on every run of `scripts/check.sh`.

| Attempt (as a skill's author) | Result | Test |
|---|---|---|
| Name the skill `../../Library/LaunchAgents/evil`, `/tmp/evil`, `a/../../b` or `..` to have the copy land outside the skills folder | Refused: the folder's own name is used; an odd folder name blocks the install | `SkillSecurityTests.aSkillsNameCannotLeadTheCopyOutOfTheSkillsFolder` |
| Ask the preview for `../../../secret.txt`, `/etc/hosts`, a folder or a missing file | Refused: only the skill's own listed files | `SkillCatalogTests.aFilesTextWithTheLinesThatWereFound` |
| Ship a link to a file outside the skill and a `node_modules` folder | Neither is copied | `SkillManageTests.linksAreLeftOutAndScriptsStayRunnable` |
| Change the folder between the plan the person saw and the install | The old confirmation is refused; the new content is checked again | `SkillManageTests.onlyTheVersionThatWasShownIsInstalled` |
| Get the catalog to move a folder it doesn't own (a project, a document folder, a path with `..`) | Refused: `not-yours` | `SkillManageTests.onlyThePersonsOwnListedSkillsAreEverMoved` |
| Be a link to a private folder and get it moved on «switch off» | The link moves; the folder behind it stays | `SkillSecurityTests.switchingOffALinkedSkillMovesTheLinkNotWhatItPointsAt` |
| Put SQL into search, notes, filter, set and trusted names; trust `%` | Stored and searched as text; the table intact; a wildcard trusts nobody | `SkillSecurityTests.typedTextIsDataForTheDatabase` |
| Imitate the review's file markers, tell the reviewer the skill is approved, hide words with zero-width spaces | The fake marker is a numbered data line; invisible characters are spelled out; the live review answered «dangerous» | `SkillReviewTests.aFileCannotCloseItsOwnBlockOrHideWhatItSays` |
| Make the model answer «safe» (or chat around the JSON) | Only the fixed JSON counts; a «safe» never lowers the static verdict | `SkillSecurityTests.aSkillCannotPretendToBeSafeToTheModelOrTheCatalog`, `SkillReviewTests.onlyTheJSONThatWasAskedForIsAnAnswer` |
| Name a homepage on a look-alike host or a `javascript:` link to get it opened | Only `https://github.com/<owner>/<repo>` is used, on a click | `SkillReportsTests.whereAComplaintCanGo` |
| Get the person's home path into a public GitHub issue | Cut out of every link and copy | `SkillReportsTests.theGitHubPagesCarryTheFactsAndNoPaths` |
| Hand the person a huge or foreign «export» to check against | Refused before or after reading | `SkillSecurityTests.aHugeOrForeignExportIsNotRead` |

**Left / needs Oleh:** nothing blocking. Optional: confirm once that `claude -p --setting-sources ""` doesn't load `~/.claude/CLAUDE.md` (it would only add your own words).
