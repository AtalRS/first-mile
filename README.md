# First Mile

A guided 9-week run/walk plan (Couch to 5K style) as an installable web app.

- `index.html` – the whole app (markup, styles, script)
- `coach/` – Coach Hannah's voice clips (63 MP3s, generated with Kokoro TTS, voice `af_heart`)
- `icons/` – Home Screen icons, plus `app-store-icon-1024.png` for the App Store
- `manifest.json`, `sw.js` – make it installable and usable offline

## Run locally

    python3 -m http.server 8000

Then open http://localhost:8000

## Notes

- Every line the coach speaks must have a clip listed in the `CLIP` map in `index.html`. New or reworded lines need new recordings.
- After changing any file, bump `CACHE` in `sw.js` so phones pick up the update.
- Host on any static host (GitHub Pages, Netlify, Cloudflare Pages).
