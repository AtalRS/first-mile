#!/usr/bin/env python3
"""Check that coach clips are consistent across the repo.

Every MP3 in coach/ must be referenced by the CLIP map in index.html and
listed in sw.js FILES (so it works offline), and every reference must point
at a file that exists. Run from anywhere: python3 scripts/check_clips.py
"""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
pattern = re.compile(r"coach/[0-9a-f]+\.mp3")

on_disk = {p.relative_to(root).as_posix() for p in (root / "coach").glob("*.mp3")}
in_index = set(pattern.findall((root / "index.html").read_text()))
in_sw = set(pattern.findall((root / "sw.js").read_text()))

problems = []
for label, found in (("index.html CLIP map", in_index), ("sw.js FILES", in_sw)):
    for f in sorted(found - on_disk):
        problems.append(f"{label} references missing file: {f}")
    for f in sorted(on_disk - found):
        problems.append(f"{f} exists but is not in {label}")

if problems:
    print("\n".join(problems))
    sys.exit(1)
print(f"OK: {len(on_disk)} clips on disk, in index.html, and in sw.js")
