#!/usr/bin/env python3
"""Texts for the Windows and Linux versions from the Mac app's String Catalog (docs/specs/SPEC-windows.md §2).

Finds the keys the desktop code uses — `data-t="…"` / `data-t-title="…"` / `data-t-placeholder="…"` in ui/*.html, `t("…")` in ui/*,
`s.t("…")` / `texts.format("…"` in app/src and core/src — and writes ui/i18n/<code>.json with just those keys for
each language but Russian (the keys are the Russian texts). A new text goes into AIHubBar/Resources/Localizable.xcstrings first, with all
translations, so the Mac and desktop versions never drift.

Also writes ui/i18n/prompts.json: the Mac's prompts for Claude in a project without shared rules (`nextStep`,
`customTask`, `finishSession` of every language in AIHubBar/Models/ContentLanguage.swift), and ui/i18n/templates.json:
the profile templates the desktop versions can already use (AIHubBar/Resources/Templates/template-<id>[.<code>].json),
`{id: {code: {title, mode}}}` — the Mac's profile as it is, in each content language — and ui/i18n/content.json: the
project card's file name, field names and notes heading of each content language (`ContentStrings`), for folder projects.

    python3 scripts/strings.py          # write the files
    python3 scripts/strings.py --check  # only check: every key and translation is there, the files are current
"""

import json
import re
import sys
from pathlib import Path

DESKTOP = Path(__file__).resolve().parent.parent
CATALOG = DESKTOP.parent / "AIHubBar" / "Resources" / "Localizable.xcstrings"
CONTENT = DESKTOP.parent / "AIHubBar" / "Models" / "ContentLanguage.swift"
TEMPLATES = DESKTOP.parent / "AIHubBar" / "Resources" / "Templates"
# In the order the Mac's assistant shows them; «Утилиты Mac» has no projects and Mac-only modules.
TEMPLATE_IDS = ["developer", "video", "texts", "research", "social", "custom"]
CARD_KEYS = ["stage", "deadline", "publish", "format", "mainFile", "platform"]
PROMPT_KEYS = ["nextStep", "customTask", "finishSession"]
CONTENT_LANGUAGES = {
    "russian": "ru", "english": "en", "spanish": "es", "portuguese": "pt-BR", "french": "fr", "german": "de",
    "japanese": "ja", "indonesian": "id", "korean": "ko", "italian": "it", "arabic": "ar", "polish": "pl", "ukrainian": "uk",
}
OUT = DESKTOP / "ui" / "i18n"
LANGUAGES = ["en", "es", "pt-BR", "fr", "de", "ja", "id", "ko", "it", "ar", "pl", "uk"]

PATTERNS = [
    (["ui/*.html"], r'data-t(?:-title|-placeholder)?="([^"]+)"'),
    (["ui/*.html", "ui/*.js"], r'\bt\("((?:[^"\\]|\\.)+)"'),
    # In Rust only calls on a `Strings` value: `s.t("…")`, `texts.format("…"`, `strings(app).t("…")`.
    (["app/src/**/*.rs", "core/src/**/*.rs"], r'(?:\bs|\btexts|\bstrings\([^)]*\))\.(?:t|format)\("((?:[^"\\]|\\.)+)"'),
]


def used_keys():
    keys = set()
    for globs, pattern in PATTERNS:
        for glob in globs:
            for path in DESKTOP.glob(glob):
                for match in re.finditer(pattern, path.read_text(encoding="utf-8")):
                    keys.add(match.group(1).replace('\\"', '"'))
    return sorted(keys)


def prompts():
    """{code: {nextStep, customTask, finishSession}} from the Swift `ContentStrings` tables."""
    text = CONTENT.read_text(encoding="utf-8")
    blocks = re.split(r"static let (\w+) = ContentStrings\(", text)
    result = {}
    for name, body in zip(blocks[1::2], blocks[2::2]):
        code = CONTENT_LANGUAGES.get(name)
        if code is None:
            continue
        entry = {}
        for key in PROMPT_KEYS:
            match = re.search(key + r': "((?:[^"\\]|\\.)*)"', body)
            if match:
                entry[key] = re.sub(r"\\(.)", r"\1", match.group(1))
        result[code] = entry
    return result


def templates():
    """{id: {code: mode}}: the Russian file is the source, `.<code>.json` its translations."""
    result = {}
    for template in TEMPLATE_IDS:
        modes = {}
        for code in CONTENT_LANGUAGES.values():
            path = TEMPLATES / (f"template-{template}.json" if code == "ru" else f"template-{template}.{code}.json")
            template_file = json.loads(path.read_text(encoding="utf-8"))
            modes[code] = {"title": template_file["title"], "mode": template_file["mode"]}
        result[template] = modes
    return result


AGENT_KEYS = ["agentPrompt", "agentNoFile", "agentFileIntro", "notSet", "notCounted", "projectWord", "resultWord", "apiHeader", "apiFileIntro", "apiTask", "apiRule"]


def swift_string(body, key):
    """A Swift string literal `key: "…"`, or a multi-line one between triple quotes: the closing quotes' indent is
    removed and a trailing backslash joins the next line."""
    multi = re.search(key + r': """\n(.*?)\n([ \t]*)"""', body, re.S)
    if multi:
        indent = multi.group(2)
        text = ""
        for line in multi.group(1).split("\n"):
            line = line[len(indent):] if line.startswith(indent) else line.lstrip()
            text += line[:-1] if line.endswith("\\") else line + "\n"
        return re.sub(r"\\(.)", r"\1", text.rstrip("\n"))
    single = re.search(key + r': "((?:[^"\\]|\\.)*)"', body)
    if not single:
        print(f"no {key} in {CONTENT.name}", file=sys.stderr)
        sys.exit(1)
    return re.sub(r"\\(.)", r"\1", single.group(1))


def content():
    """{code: {cardFile, cardLabels: {key: label}, notesHeading, agentPrompt…}} from the Swift `ContentStrings` tables:
    the project card's words and what an agent is told when it runs a command on a folder project."""
    text = CONTENT.read_text(encoding="utf-8")
    blocks = re.split(r"static let (\w+) = ContentStrings\(", text)
    result = {}
    for name, body in zip(blocks[1::2], blocks[2::2]):
        code = CONTENT_LANGUAGES.get(name)
        if code is None:
            continue
        labels = re.search(r"cardLabels: \[(.*?)\]", body).group(1)
        result[code] = {
            **{key: swift_string(body, key) for key in AGENT_KEYS},
            "cardFile": re.search(r'cardFile: "([^"]*)"', body).group(1),
            "cardLabels": {key: value for key, value in re.findall(r'\.(\w+): "([^"]*)"', labels)},
            "notesHeading": re.search(r'notesHeading: "([^"]*)"', body).group(1),
        }
        missing = [key for key in CARD_KEYS if key not in result[code]["cardLabels"]]
        if missing:
            print(f"no card labels {', '.join(missing)} for {code} in {CONTENT.name}", file=sys.stderr)
            sys.exit(1)
    return result


def write(path, text, check, stale):
    if check:
        if not path.exists() or path.read_text(encoding="utf-8") != text:
            stale.append(path.name)
    else:
        OUT.mkdir(parents=True, exist_ok=True)
        # LF on Windows too (Path.write_text has no `newline` before Python 3.10).
        with open(path, "w", encoding="utf-8", newline="\n") as file:
            file.write(text)


def main():
    check = "--check" in sys.argv
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]
    keys = used_keys()
    problems = []
    for key in keys:
        entry = catalog.get(key)
        if entry is None:
            problems.append(f"not in the catalog: {key!r}")
            continue
        for code in LANGUAGES:
            value = entry.get("localizations", {}).get(code, {}).get("stringUnit", {}).get("value")
            if not value:
                problems.append(f"no {code} for {key!r}")
    if problems:
        print("\n".join(problems), file=sys.stderr)
        sys.exit(1)

    stale = []
    for code in LANGUAGES:
        table = {key: catalog[key]["localizations"][code]["stringUnit"]["value"] for key in keys}
        text = json.dumps(table, ensure_ascii=False, indent=1, sort_keys=True) + "\n"
        write(OUT / f"{code}.json", text, check, stale)
    table = prompts()
    for code in CONTENT_LANGUAGES.values():
        missing = [key for key in PROMPT_KEYS if not table.get(code, {}).get(key)]
        if missing:
            print(f"no {', '.join(missing)} for {code} in {CONTENT.name}", file=sys.stderr)
            sys.exit(1)
    write(OUT / "prompts.json", json.dumps(table, ensure_ascii=False, indent=1, sort_keys=True) + "\n", check, stale)
    write(OUT / "content.json", json.dumps(content(), ensure_ascii=False, indent=1, sort_keys=True) + "\n", check, stale)
    write(OUT / "templates.json", json.dumps(templates(), ensure_ascii=False, indent=1, sort_keys=True) + "\n", check, stale)
    if stale:
        print("out of date (run python3 scripts/strings.py): " + ", ".join(stale), file=sys.stderr)
        sys.exit(1)
    print(f"{len(keys)} texts, {len(LANGUAGES)} languages" + (" — current" if check else " written"))


if __name__ == "__main__":
    main()
