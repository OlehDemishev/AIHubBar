#!/usr/bin/env python3
"""Texts for the Windows and Linux versions from the Mac app's String Catalog (docs/specs/SPEC-windows.md §2).

Finds the keys the desktop code uses — `data-t="…"` / `data-t-title="…"` in ui/*.html, `t("…")` in ui/*,
`s.t("…")` / `texts.format("…"` in app/src and core/src — and writes ui/i18n/<code>.json with just those keys for
each language but Russian (the keys are the Russian texts). A new text goes into AIHubBar/Resources/Localizable.xcstrings first, with all
translations, so the Mac and desktop versions never drift.

    python3 scripts/strings.py          # write the files
    python3 scripts/strings.py --check  # only check: every key and translation is there, the files are current
"""

import json
import re
import sys
from pathlib import Path

DESKTOP = Path(__file__).resolve().parent.parent
CATALOG = DESKTOP.parent / "AIHubBar" / "Resources" / "Localizable.xcstrings"
OUT = DESKTOP / "ui" / "i18n"
LANGUAGES = ["en", "es", "pt-BR", "fr", "de", "ja", "id", "ko", "it", "ar", "pl", "uk"]

PATTERNS = [
    (["ui/*.html"], r'data-t(?:-title)?="([^"]+)"'),
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
        path = OUT / f"{code}.json"
        if check:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                stale.append(path.name)
        else:
            OUT.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
    if stale:
        print("out of date (run python3 scripts/strings.py): " + ", ".join(stale), file=sys.stderr)
        sys.exit(1)
    print(f"{len(keys)} texts, {len(LANGUAGES)} languages" + (" — current" if check else " written"))


if __name__ == "__main__":
    main()
