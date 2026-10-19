#!/usr/bin/env python3
"""Record any coach clips that are missing from coach/.

Reads the CLIP map in index.html (spoken line -> coach/<file>.mp3) and, for
each file that doesn't exist yet, speaks the line with Kokoro TTS in Coach
Hannah's voice (af_heart) and saves it as a 24 kHz mono MP3. Existing clips
are left alone.

Needs Python 3.10+:  pip install kokoro soundfile
Then, from anywhere:  python3 scripts/make_clips.py
Afterwards run scripts/check_clips.py.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
html = (root / "index.html").read_text()
clips = json.loads(re.search(r"var CLIP=(\{.*?\});", html).group(1))

for text, path in clips.items():
    expected = "coach/" + hashlib.md5(text.encode()).hexdigest()[:10] + ".mp3"
    if path != expected:
        print(f"warning: {path} is usually named {expected} for: {text}")

missing = {t: p for t, p in clips.items() if not (root / p).exists()}
if not missing:
    print(f"OK: all {len(clips)} clips already exist")
    sys.exit(0)

import numpy as np
import soundfile as sf
from kokoro import KPipeline

pipeline = KPipeline(lang_code="a")
for n, (text, path) in enumerate(missing.items(), 1):
    audio = np.concatenate([a for _, _, a in pipeline(text, voice="af_heart")])
    sf.write(root / path, audio, 24000, format="MP3")
    print(f"[{n}/{len(missing)}] {path}  {text}")
print(f"Recorded {len(missing)} clips")
