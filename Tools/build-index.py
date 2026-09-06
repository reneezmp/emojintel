#!/usr/bin/env python3
"""Build Emojintel's bundled emoji index from Emojibase.

Emojibase splits its data across two files, which the original spec got wrong:
  en/data.json                 -> label, emoji, tags, hexcode, order, group, type, ...
  en/shortcodes/emojibase.json -> hexcode -> str | [str]        (NOT inside data.json)

This merges them, strips everything Emojintel doesn't use, and writes a slim index.
Run manually; the output is committed so the build itself never touches the network.

    python3 Tools/build-index.py
"""
import json
import sys
import urllib.request
from pathlib import Path

VERSION = "17.0.0"  # pinned; bump deliberately
BASE = f"https://cdn.jsdelivr.net/npm/emojibase-data@{VERSION}"
OUT = Path(__file__).resolve().parent.parent / "Resources" / "emoji-index.json"


def fetch(path):
    url = f"{BASE}/{path}"
    print(f"  fetching {url}")
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)


def main():
    print(f"Emojibase v{VERSION}")
    data = fetch("en/data.json")
    shortcodes = fetch("en/shortcodes/emojibase.json")

    entries = []
    skipped = 0
    for e in data:
        # type 0 is the text-presentation form; we only want emoji presentation.
        # Entries with no "group" are regional indicators, skin-tone modifiers and
        # keycap components -- not standalone emoji, and they pollute search results.
        if e.get("type") != 1 or "group" not in e:
            skipped += 1
            continue

        hexcode = e["hexcode"]
        sc = shortcodes.get(hexcode, [])
        if isinstance(sc, str):
            sc = [sc]

        entries.append({
            "e": e["emoji"],
            "l": e["label"],
            "t": e.get("tags", []),
            "s": sc,
            "o": e.get("order", 99999),
        })

    entries.sort(key=lambda x: x["o"])

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(entries, f, ensure_ascii=False, separators=(",", ":"))

    size = OUT.stat().st_size
    print(f"\n  kept    {len(entries)} emoji")
    print(f"  skipped {skipped} (text-presentation / components)")
    print(f"  wrote   {OUT.relative_to(Path.cwd())}  ({size / 1024:.0f} KB)")

    with_sc = sum(1 for e in entries if e["s"])
    print(f"  {with_sc} entries carry shortcodes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
