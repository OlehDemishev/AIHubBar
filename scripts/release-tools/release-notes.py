#!/usr/bin/env python3
"""Release notes for Sparkle's update window (docs/RELEASE.md «Release notes»):
    release-notes.py <notes.md>
Prints the notes as plain HTML for the appcast's <description>: «## » headings, «- » lists and paragraphs, with
**bold** and `code`. Anything else in the file is kept as text — the notes are short and written by hand.
"""
import html
import re
import sys
from pathlib import Path


def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    return re.sub(r"`(.+?)`", r"<code>\1</code>", text)


def render(markdown):
    out, in_list = [], False
    for raw in markdown.splitlines():
        line = raw.strip()
        if line.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(line[2:])}</li>")
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        if not line:
            continue
        if line.startswith("#"):
            out.append(f"<h3>{inline(line.lstrip('#').strip())}</h3>")
        else:
            out.append(f"<p>{inline(line)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


if __name__ == "__main__":
    print(render(Path(sys.argv[1]).read_text(encoding="utf-8")))
