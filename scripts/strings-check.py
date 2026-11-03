#!/usr/bin/env python3
"""Checks the Mac string catalog (AIHubBar/Resources/Localizable.xcstrings) — docs/specs/SPEC-refactor.md §7.

    python3 scripts/strings-check.py            # check, exit 1 on problems
    python3 scripts/strings-check.py --format   # also rewrite the file in the repository's JSON style

Problems: a Russian string in use without all 12 translations, format specifiers that differ from the Russian,
Russian letters left in a translation, Russian-only letters in Ukrainian. Stale keys are only counted: some are used
by desktop/ (desktop/scripts/strings.py checks those).
"""
import json
import re
import sys
from pathlib import Path

CATALOG = Path(__file__).resolve().parent.parent / "AIHubBar/Resources/Localizable.xcstrings"
LANGUAGES = ["en", "uk", "de", "fr", "es", "it", "pt-BR", "pl", "ja", "ko", "ar", "id"]
SPECIFIER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|%)")
CYRILLIC = re.compile(r"[А-Яа-яЁё]")
RUSSIAN_ONLY = re.compile(r"[ыэъёЫЭЪЁ]")


def specifiers(text):
    # «%1$lld» and «%lld» are the same argument for this check.
    return sorted(re.sub(r"\d+\$", "", s) for s in SPECIFIER.findall(text))


def main():
    data = json.loads(CATALOG.read_text(encoding="utf-8"))
    problems = []
    stale = 0
    for key, entry in data["strings"].items():
        if entry.get("extractionState") == "stale":
            stale += 1
            continue
        if entry.get("shouldTranslate") is False:
            continue
        units = {lang: loc.get("stringUnit", {}).get("value") for lang, loc in entry.get("localizations", {}).items()}
        if CYRILLIC.search(key):
            missing = [lang for lang in LANGUAGES if not units.get(lang)]
            if missing:
                problems.append(f"no {', '.join(missing)}: {key[:90]}")
        for lang, value in units.items():
            if not value or lang == "ru":
                continue
            if specifiers(value) != specifiers(key):
                problems.append(f"{lang} specifiers differ: {key[:70]} → {value[:70]}")
            if lang != "uk" and CYRILLIC.search(value):
                problems.append(f"{lang} has Russian letters: {value[:90]}")
            if lang == "uk" and RUSSIAN_ONLY.search(value):
                problems.append(f"uk has ы/э/ъ/ё: {value[:90]}")
    if "--format" in sys.argv:
        CATALOG.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"{len(data['strings'])} keys, {stale} stale, {len(problems)} problem(s)")
    for problem in problems:
        print("  " + problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
