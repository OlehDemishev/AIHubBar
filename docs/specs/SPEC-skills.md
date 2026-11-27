# SPEC: Skills Catalog — the common safety rules

Every skill and plugin, wherever it comes from, is judged by the same rules. This document is the standard; the code
follows it (`AIHubBar/Skills/`, Swift; the reference port in `desktop/skill-scanner/`, Rust). Started 2026-11-26.

## 1. What a check is

- **Static only.** A skill's files are read as bytes. Nothing in them is run, loaded, followed or obeyed — not
  during a check, not to «try» a skill. Links are recorded, never followed.
- **Everything is looked at**: SKILL.md and references (as instructions the agent will follow), scripts, configs,
  hooks (`hooks/hooks.json`, `settings.json`, a skill's own frontmatter), MCP servers (`.mcp.json`), slash commands,
  permissions, metadata. Pictures, fonts and PDFs are not read; programs, archives and unknown binaries are a finding
  because they can't be read.
- **Limits**: 3,000 files, 64 MB, 2 MB per file. A larger file is hashed, not read, and that is a finding; bundled
  `node_modules` and virtual environments are not walked, and that is a finding too.

## Rules 3 (Mac, 2026-11-27)

Found on anthropics/skills, the first real source: its document skills (docx, pptx, xlsx) and claude-api read «dangerous».
Changed: a Unix domain socket (`AF_UNIX`) is not network; `os.environ.copy()` (an environment for a child process) is not
an environment dump; `curl | sh` with nothing between the tool and the pipe names the practice and is not a command; «do
not tell the user they need to…» and «never … without asking the user» are not concealment; «a new system prompt» is not
one being set (unless announced with `:`, «is», «follows», «below»); a match in a comment line of a script weighs two
steps less, except the rules aimed at the agent (`pi-…`); the medium and low findings add 34 at most; `rm-rf-home` is
critical. The Rust scanner in desktop/ stays at rules 2 until the Windows work resumes.

## 2. From findings to a verdict

1. Each rule that matches gives a **finding**: rule, severity, file, line, the line itself.
2. **Severity weights**: info 0, low 5, medium 15, high 35, critical 80.
3. **The risk score (0–100)**: every rule counts once at its worst severity; up to three more findings of the same rule
   add a fifth of their own weight each. Since rules 3 (2026-11-27) the medium and low findings together add 34 at most, so a
   long skill full of examples can't reach «dangerous» without one serious finding; the sum stops at 100.
4. **The verdict**:
   - 🔴 **Dangerous** — any critical finding, or a score of 70 or more.
   - 🟡 **Review** — a score of 5 or more: scripts, network, settings or anything else worth reading.
   - 🟢 **Safe** — under 5: instructions only.
5. **A document weighs less than code**: in Markdown most patterns are a mention or an example, so most rules count one
   step lower there. What the agent would *follow* (download-and-run, prompt injection, data sent to a named service,
   destruction) counts the same.
6. **Quoting is not saying**: a prompt-injection phrase right after a quotation mark counts one step lower — a skill that
   warns about «"ignore previous instructions"» is not an attack — but it still counts, so quotes are no way around it.
7. **Together is worse**: reading secrets and sending data out in the same file is its own critical finding
   (`exfil-combo`); in a document only when they stand within three lines.
8. **Invisible text**: words split with zero-width characters are read with them removed; if a rule matches only then,
   that is `pi-hidden-text`, critical.
9. **Known-harmless matches** are dropped: a public key (`id_ed25519.pub`, `known_hosts`), `.env.example`, a picture
   or a lock file's hash written as base64.

## 3. Why this verdict

Every verdict comes with its reasons, so a person never has to read all findings to understand it:

- **Reasons**: at most three rules, one finding each, the most serious first. For «Dangerous» only the findings that
  reached the level that made it so (critical, else high); for «Review» whatever is worth reading. The rest is counted.
- **What the skill can do**: network, sends data, runs code, reads secrets, changes the system, changes the agent,
  installs packages, hooks, MCP, hidden content, instructions against you — each none, present, or risky (from a
  high finding).
- **What would make it safer**: one piece of advice per kind of problem (pin versions, narrow tools, ship readable
  source…). A «Dangerous» verdict decided by an attack (sending secrets, hidden orders, staying in the system,
  destruction) gets only «don't install»: no fix makes such a skill safe as it is.

## 4. The AI review (level 2)

Optional, on request, one skill at a time. The skill goes to Claude as untrusted, numbered data between markers made
for that one request; the answer must be one JSON object of a fixed shape, else it counts as «Review». A model's
verdict can only make the static one **stricter**, never milder. Reviews are remembered by content hash.

## 4a. Where to find sources (Mac, 2026-11-27)

«Найти источники…» in Settings → Скиллы → «Источники» suggests GitHub repositories; it never adds, downloads or trusts
one by itself (`AIHubBar/Skills/SkillSourceFinder.swift`). Only public, documented ways without a token:

- **Awesome lists**, read as Markdown from raw.githubusercontent.com at `HEAD` (not counted against the API's 60 an
  hour): ComposioHQ/awesome-claude-skills, VoltAgent/awesome-agent-skills, travisvn/awesome-claude-skills,
  BehiSecc/awesome-claude-skills, heilcheng/awesome-agent-skills. Every `[text](https://github.com/<owner>/<repo>…)` in a
  list item or a table row is a candidate, the text after it its description; GitHub's own pages and the list itself
  are not.
- **The official plugin marketplace**, `anthropics/claude-plugins-official/.claude-plugin/marketplace.json`
  (code.claude.com/docs/en/plugins/marketplace-reference): `github`, `url` (github.com only), `git-subdir` and `./path`
  sources give repositories; `command`, `npm` and the rest are ignored.
- **GitHub's repository search** (docs.github.com/en/rest/search) for `topic:agent-skills` or `topic:claude-skills`, most
  stars first, no forks or archived ones — only on a click (10 searches a minute without a token).

Lists are read once in 12 hours; candidates are merged by repository, the most-named first. Everything a list says is
untrusted text: links, HTML, control and invisible characters are removed, descriptions are cut to 200 characters and
shown verbatim. Left out on purpose: skills.sh (its API needs a Vercel token), skillsmp.com (its docs refuse automated
reading), GitHub code search (needs a token).

## 5. Versions and the shared contract

- `SkillReport.scannerVersion` (2) rises with every change of rules or scoring; results of an older version are made
  again.
- The fixtures in `desktop/skill-scanner/tests/fixtures` — 15 bad, 5 clean, 2 for review, all harmless by design — and
  the per-rule test lines are the contract: the Swift and Rust scanners must give the same verdicts on them
  (`AIHubBarTests/SkillScannerTests.swift`, `desktop/skill-scanner/tests`).
- A new rule needs a test line that it catches, a line it must leave alone, a category, a capability, advice if a fix
  exists, and its words in the string catalog.

## 6. The rules

| Category | Rule | Severity | What it means |
|---|---|---|---|
| scripts | `scripts-present` | low | Contains a script |
| scripts | `executable-binary` | high | Contains a compiled program |
| scripts | `archive` | medium | Contains an archive |
| scripts | `unknown-binary` | low | Contains a file that is not text |
| scripts | `symlink` | medium; high when it points outside | Contains a link to another place |
| scripts | `large-file` | low | A file too large to check |
| scripts | `truncated` | medium | Too many files to check them all |
| network | `net-call` | medium; in a document one step lower | Talks to the network |
| network | `net-upload` | high; in a document one step lower | Sends data out |
| network | `exfil-endpoint` | high; in a document same | Uses a service often used to steal data |
| network | `hardcoded-ip` | medium; in a document one step lower | Connects to a bare IP address |
| execution | `pipe-to-shell` | critical; in a document same | Downloads code and runs it at once |
| execution | `decode-exec` | critical; in a document same | Decodes hidden text and runs it |
| execution | `dynamic-exec` | medium; in a document one step lower | Builds and runs commands on the fly |
| secrets | `secret-read` | critical; in a document one step lower | Reads your keys or passwords |
| secrets | `sensitive-path` | high; in a document one step lower | Mentions where keys and passwords are kept |
| secrets | `env-dump` | high; in a document one step lower | Collects every environment variable |
| secrets | `env-secret` | medium; in a document one step lower | Reads a key or token from the environment |
| secrets | `dotenv-read` | low; in a document not checked | Works with a .env file |
| secrets | `exfil-combo` | critical in code; high in a document when within 3 lines | Reads secrets and sends data out |
| system | `rm-rf-home` | critical (high before rules 3); in a document same | Can erase your files or a disk |
| system | `rm-rf` | medium; in a document one step lower | Deletes folders without asking |
| system | `sudo` | medium; in a document one step lower | Asks for administrator rights |
| system | `chmod-open` | medium; in a document one step lower | Weakens the system's protection |
| system | `persistence` | high; in a document one step lower | Starts itself with the system |
| system | `shell-rc` | high; in a document one step lower | Changes your terminal's start-up files |
| system | `agent-config` | high; in a document same | Changes the agent's permissions |
| dependencies | `not-walked` | medium | Bundled dependencies were not checked |
| dependencies | `pkg-install` | medium; in a document one step lower | Installs packages |
| dependencies | `pkg-remote` | high; in a document one step lower | Installs a package from an unusual place |
| dependencies | `typosquat` | high in code; medium in a document | A package name that looks like a typo |
| obfuscation | `minified` | medium | Code packed into very long lines |
| obfuscation | `long-base64` | high; in a document one step lower | A long block of encoded text |
| obfuscation | `long-hex` | medium; in a document one step lower | A long block of hex codes |
| obfuscation | `char-codes` | medium; in a document one step lower | Text built from character codes |
| obfuscation | `packed-code` | medium; in a document not checked | Unpacks code at run time |
| injection | `pi-override` | high; in a document same | Tells the agent to ignore its instructions |
| injection | `pi-conceal` | high; in a document same | Tells the agent to hide something from you |
| injection | `pi-disable-safety` | high; in a document same | Tells the agent to switch off checks |
| injection | `pi-exfil` | critical; in a document same | Tells the agent to send your data somewhere |
| injection | `pi-role` | medium; in a document same | Imitates a system message |
| injection | `pi-hidden-text` | critical | An instruction hidden with invisible characters |
| injection | `pi-hidden-comment` | high | An instruction in a hidden comment |
| injection | `invisible-tags` | critical | Hidden text in invisible Unicode tags |
| injection | `invisible-bidi` | high | Characters that reorder text on screen |
| injection | `invisible-chars` | medium; high from 10 characters | Invisible characters in the text |
| plugin | `hook-command` | medium | Adds a hook: a command that runs by itself |
| plugin | `hook-network` | high | A hook that talks to the network |
| plugin | `mcp-server` | medium | Adds an MCP server |
| plugin | `mcp-remote-code` | high | An MCP server downloaded at every start |
| plugin | `mcp-insecure-url` | high | An MCP server over an unprotected connection |
| plugin | `broad-permissions` | high | Grants itself wide permissions |
| plugin | `allowed-tools-shell` | medium | May run any shell command without asking |
| plugin | `command-inline-exec` | medium | A slash command that runs a shell command |
| metadata | `no-skill-md` | low | No valid SKILL.md |
| metadata | `frontmatter` | low; info for a bad name or a long description | SKILL.md doesn't follow the standard |
| metadata | `no-license` | info | No license |

A check lowers the risk; it can't guarantee that a skill is safe.
