# Texts of the Skills Catalog

The Skills Catalog keeps its own texts here, apart from `ui/i18n/` (agreed with Oleh on 2026-11-26): the interface
is English, with Russian, Ukrainian and German beside it; every other language shows English. `scripts/strings.py`
doesn't read or write this folder, and these files are edited by hand.

- A key is a name (`verdict.safe`), not a text. `%1`, `%2` are replaced in order.
- Every file has the same keys as `en.json`; a test in `skill-catalog` checks it.
- A rule's title and explanation come from the scanner itself in English (`skill-scanner/src/rules.rs`).
  A translation goes in as `rule.<id>.title` and `rule.<id>.why`; `ru.json` has every rule, a test checks that too.
