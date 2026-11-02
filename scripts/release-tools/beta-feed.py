#!/usr/bin/env python3
"""The beta channel's appcast (docs/RELEASE.md «Beta builds»):
    beta-feed.py <out.xml> <appcast.xml>...
Takes every item from the appcasts given (missing files are skipped) and keeps the newest release and the newest
beta (`<sparkle:channel>beta</sparkle:channel>`) by build number. Sparkle in a beta tester's copy offers whichever
of the two is newer, so a release made after a beta reaches beta testers too.
"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def build(item):
    try:
        return int(item.findtext(f"{{{SPARKLE}}}version", "0"))
    except ValueError:
        return 0


def main(out, sources):
    newest = {}
    for source in sources:
        path = Path(source)
        if not path.is_file():
            continue
        for item in ET.parse(path).getroot().iter("item"):
            kind = "beta" if item.findtext(f"{{{SPARKLE}}}channel") == "beta" else "release"
            if kind not in newest or build(item) > build(newest[kind]):
                newest[kind] = item
    if not newest:
        sys.exit("beta-feed: no items in " + ", ".join(sources))
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "AI Hub Bar beta"
    ET.SubElement(channel, "link").text = "https://github.com/OlehDemishev/AIHubBar/releases"
    for item in sorted(newest.values(), key=build, reverse=True):
        channel.append(item)
    ET.indent(rss)
    ET.ElementTree(rss).write(out, encoding="utf-8", xml_declaration=True)
    for item in sorted(newest.values(), key=build, reverse=True):
        print(f"    {item.findtext('title')} (build {build(item)})")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("usage: beta-feed.py <out.xml> <appcast.xml>...")
    main(sys.argv[1], sys.argv[2:])
